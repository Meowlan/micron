Micron = Micron or {}
local Math = Micron.Math
local Registry = Micron.ModeRegistry
local Utils = Micron.ModeUtils
local SnapPoints = Micron.SnapPoints

local MODE = {}

MODE.DisplayName = "Push / Pull"
MODE.Description = "Move a prop along the clicked face normal."
MODE.RequiresTargetConnector = false
MODE.ApplyOnSourceSelection = true
MODE.PreviewFromTraceWhenIdle = true
MODE.LatchDuplicateOnSource = false
MODE.DuplicateFromSourceOnly = true
MODE.ClientConVarDefaults = {
    push_pull_units = "32",
    push_pull_depth_mult = "100",
    push_pull_use_depth_mult = "0",
    freeze_prop = "0"
}

local forcedInvertPull = setmetatable({}, { __mode = "k" })

local function shouldInvertPullFromShift(ply)
    return IsValid(ply) and ply:KeyDown(IN_SPEED) and true or false
end

local function resolveDominantLocalFaceNormal(localHitNormal)
    local ax = math.abs(localHitNormal.x)
    local ay = math.abs(localHitNormal.y)
    local az = math.abs(localHitNormal.z)

    if ax >= ay and ax >= az then
        return Vector(localHitNormal.x >= 0 and 1 or -1, 0, 0)
    end

    if ay >= ax and ay >= az then
        return Vector(0, localHitNormal.y >= 0 and 1 or -1, 0)
    end

    return Vector(0, 0, localHitNormal.z >= 0 and 1 or -1)
end

local function computeDepthAlongAxisWorld(ent, axisWorld)
    if not IsValid(ent) then
        return 0
    end

    local axis = Math.SafeNormalize(axisWorld, Vector(0, 0, 1))
    if axis:LengthSqr() <= 1e-8 then
        return 0
    end

    local mins = ent:OBBMins()
    local maxs = ent:OBBMaxs()
    local minProj = nil
    local maxProj = nil

    for i = 0, 7 do
        local localCorner = Vector(
            bit.band(i, 1) ~= 0 and maxs.x or mins.x,
            bit.band(i, 2) ~= 0 and maxs.y or mins.y,
            bit.band(i, 4) ~= 0 and maxs.z or mins.z
        )

        local worldCorner = ent:LocalToWorld(localCorner)
        local projection = worldCorner:Dot(axis)

        minProj = minProj and math.min(minProj, projection) or projection
        maxProj = maxProj and math.max(maxProj, projection) or projection
    end

    if not minProj or not maxProj then
        return 0
    end

    return math.max(0, maxProj - minProj)
end

function MODE.GetSettings(tool)
    local owner = tool and tool.GetOwner and tool:GetOwner() or nil
    local invertPull = false
    if IsValid(owner) then
        invertPull = shouldInvertPullFromShift(owner)
    end

    if SERVER and IsValid(owner) and forcedInvertPull[owner] then
        invertPull = true
    end

    return {
        pushPullUnits = tonumber(tool:GetClientNumber("push_pull_units", 32)) or 32,
        pushPullDepthMult = tonumber(tool:GetClientNumber("push_pull_depth_mult", 100)) or 100,
        useDepthMultiplier = tool:GetClientNumber("push_pull_use_depth_mult", 0) == 1,
        freezeProp = tool:GetClientNumber("freeze_prop", 0) == 1,
        invertPull = invertPull
    }
end

function MODE.OnRightClick(tool, ply)
    if not SERVER then
        return true
    end

    if not IsValid(ply) or not tool then
        return false
    end

    local controller = Micron and Micron.Controller
    if not controller or not controller.LeftClick then
        return false
    end

    local ok, handled = pcall(function()
        local trace = ply:GetEyeTrace()
        return controller.LeftClick(tool, trace)
    end)

    if not ok then
        return false
    end

    return handled and true or false
end

function MODE.OnRotateInput()
    return false
end

function MODE.OnReload(tool, ply)
    if not SERVER then
        return true
    end

    if not IsValid(ply) or not tool then
        return false
    end

    local controller = Micron and Micron.Controller
    if not controller or not controller.LeftClick then
        return false
    end

    forcedInvertPull[ply] = true

    local ok, handled = pcall(function()
        local trace = ply:GetEyeTrace()
        return controller.LeftClick(tool, trace)
    end)

    forcedInvertPull[ply] = nil

    if not ok then
        return false
    end

    return handled and true or false
end

function MODE.BuildConnector(_, trace)
    if not trace or not trace.Hit then
        return nil, "No surface was hit."
    end

    if trace.HitWorld then
        return nil, "World geometry cannot be selected in Push / Pull mode."
    end

    local ent = trace.Entity
    if not IsValid(ent) or not SnapPoints or not SnapPoints.IsSnappableEntity or not SnapPoints.IsSnappableEntity(ent) then
        return nil, "Target entity cannot be moved."
    end

    local worldNormal = Math.SafeNormalize(trace.HitNormal, Vector(0, 0, 1))
    local localHitNormal = Math.WorldDirToLocal(ent, worldNormal)
    local localFaceNormal = resolveDominantLocalFaceNormal(localHitNormal)

    local snappedWorldNormal = Math.LocalDirToWorld(ent, localFaceNormal)
    local worldHint = Utils.ChooseStableLocalHint(snappedWorldNormal)
    local worldBasis = Math.BuildBasis(snappedWorldNormal, worldHint)
    local localTangent = Math.WorldDirToLocal(ent, worldBasis.u)
    local localBasis = Math.BuildBasis(localFaceNormal, localTangent)

    return {
        entity = ent,
        hitPosWorld = ent:GetPos(),
        worldBasis = worldBasis,
        localPos = vector_origin,
        localBasis = localBasis,
        snapData = nil
    }
end

function MODE.Solve(sourceConnector, _, settings)
    if not sourceConnector then
        return nil, "Missing source connector."
    end

    local srcEnt = sourceConnector.entity
    if not IsValid(srcEnt) then
        return nil, "Source entity is no longer valid."
    end

    local pullAxis = sourceConnector.worldBasis and sourceConnector.worldBasis.n or nil
    if not isvector(pullAxis) or pullAxis:LengthSqr() <= 1e-8 then
        return nil, "Could not resolve push/pull axis."
    end

    pullAxis = Math.SafeNormalize(pullAxis, Vector(0, 0, 1))

    local distance = tonumber(settings.pushPullUnits) or 0
    if settings.useDepthMultiplier then
        local depth = computeDepthAlongAxisWorld(srcEnt, pullAxis)
        local depthPercent = tonumber(settings.pushPullDepthMult) or 0
        distance = depth * (depthPercent / 100)
    end

    local direction = settings.invertPull and 1 or -1
    local finalPos = srcEnt:GetPos() + pullAxis * distance * direction

    return {
        entity = srcEnt,
        position = finalPos,
        angles = srcEnt:GetAngles()
    }
end

if CLIENT then
    MODE.PanelClass = "MicronModePushPullPanel"

    local PANEL = {}

    function PANEL:Init()
        self:DockPadding(0, 0, 0, 0)

        local scroll = vgui.Create("DScrollPanel", self)
        scroll:Dock(FILL)

        local form = vgui.Create("DForm", scroll)
        form:Dock(TOP)
        form:SetName("Push / Pull")
        form:Help("Click on a prop to pull/push it along that face")

        local useDepthCheckbox = form:CheckBox("Use Depth Multiplier", "micron_push_pull_use_depth_mult")

        local amountSlider = form:NumSlider("Amount (Units)", "micron_push_pull_units", 0, 2048, 2)

        form:CheckBox("Freeze", "micron_freeze_prop")

        local sliderSyncing = false
        local function inDepthMode()
            local cvar = GetConVar("micron_push_pull_use_depth_mult")
            return cvar and cvar:GetBool() or false
        end

        local function readActiveSliderValue()
            if inDepthMode() then
                local cvar = GetConVar("micron_push_pull_depth_mult")
                return cvar and cvar:GetFloat() or 100
            end

            local cvar = GetConVar("micron_push_pull_units")
            return cvar and cvar:GetFloat() or 32
        end

        local function getSliderSpec()
            if inDepthMode() then
                return {
                    title = "Amount (Depth %)",
                    minValue = 0,
                    maxValue = 1000,
                    decimals = 1,
                    command = "micron_push_pull_depth_mult"
                }
            end

            return {
                title = "Amount (Units)",
                minValue = 0,
                maxValue = 2048,
                decimals = 2,
                command = "micron_push_pull_units"
            }
        end

        local function syncSliderFromMode()
            sliderSyncing = true

            local spec = getSliderSpec()
            amountSlider:SetText(spec.title)
            amountSlider:SetMinMax(spec.minValue, spec.maxValue)
            amountSlider:SetDecimals(spec.decimals)
            amountSlider:SetConVar(spec.command)
            amountSlider:SetValue(math.Clamp(readActiveSliderValue(), spec.minValue, spec.maxValue))

            sliderSyncing = false
        end

        if IsValid(useDepthCheckbox) then
            useDepthCheckbox.OnChange = function()
                syncSliderFromMode()
            end
        end

        syncSliderFromMode()

        self._amountSlider = amountSlider
        self._syncSliderFromMode = syncSliderFromMode
        self._lastDepthMode = inDepthMode()

        Utils.AttachSectionResetButton(form, MODE.ClientConVarDefaults, {
            "push_pull_units",
            "push_pull_depth_mult",
            "push_pull_use_depth_mult",
            "freeze_prop"
        })

        local keybindForm = vgui.Create("DForm", scroll)
        keybindForm:Dock(TOP)
        keybindForm:SetName("Keybinds")
        keybindForm:Help("LMB/RMB: push/pull prop")
        keybindForm:Help("RELOAD: pull prop")
        keybindForm:Help("Hold Shift: invert direction")
    end

    function PANEL:Think()
        if not self._syncSliderFromMode then
            return
        end

        local depthMode = GetConVar("micron_push_pull_use_depth_mult")
        local useDepth = depthMode and depthMode:GetBool() or false

        if useDepth ~= self._lastDepthMode then
            self._lastDepthMode = useDepth
            self._syncSliderFromMode()
            return
        end

        if not IsValid(self._amountSlider) then
            return
        end

        local sliderValue = tonumber(self._amountSlider:GetValue()) or 0
        local desiredValue
        if useDepth then
            local cvar = GetConVar("micron_push_pull_depth_mult")
            desiredValue = cvar and cvar:GetFloat() or sliderValue
        else
            local cvar = GetConVar("micron_push_pull_units")
            desiredValue = cvar and cvar:GetFloat() or sliderValue
        end

        if math.abs(sliderValue - desiredValue) > 0.01 then
            self._syncSliderFromMode()
        end
    end

    function PANEL:GetPreferredHeight()
        return 400
    end

    vgui.Register(MODE.PanelClass, PANEL, "DPanel")
end

Registry.Register("push_pull", MODE)
