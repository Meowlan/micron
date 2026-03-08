Micron = Micron or {}
local Math = Micron.Math
local Registry = Micron.ModeRegistry
local Utils = Micron.ModeUtils
local SnapPoints = Micron.SnapPoints

local SURFACE_DROP_SIZE_GAP_BIAS_UNITS = -0.25

local MODE = {}

MODE.DisplayName = "Surface Drop"
MODE.Description = "Drop source to a surface."
MODE.RequiresTargetConnector = false
MODE.ApplyOnSourceSelection = true
MODE.PreviewFromTraceWhenIdle = true
MODE.LatchDuplicateOnSource = false
MODE.DuplicateFromSourceOnly = true
MODE.ClientConVarDefaults = {
    drop_distance = "4096",
    gap = "0",
    align_surface = "0",
    freeze_prop = "1"
}

function MODE.GetSettings(tool)
    local distance = tonumber(tool:GetClientNumber("drop_distance", 4096)) or 4096
    distance = math.Clamp(distance, 64, 32768)

    local invertDirection = false
    if tool and tool.GetOwner then
        local owner = tool:GetOwner()
        invertDirection = IsValid(owner) and not owner:KeyDown(IN_SPEED) or false
    end

    return {
        dropDistance = distance,
        gap = tonumber(tool:GetClientNumber("gap", 0)) or 0,
        alignToSurface = tool:GetClientNumber("align_surface", 0) == 1,
        freezeProp = tool:GetClientNumber("freeze_prop", 0) == 1,
        invertDirection = invertDirection
    }
end

function MODE.OnRightClick()
    return false
end

function MODE.OnRotateInput()
    return false
end

function MODE.BuildConnector(_, trace, settings)
    if not trace or not trace.Hit then
        return nil, "No surface was hit."
    end

    if trace.HitWorld then
        return nil, "World geometry cannot be selected as a drop source."
    end

    local ent = trace.Entity
    if not IsValid(ent) or not SnapPoints or not SnapPoints.IsSnappableEntity or not SnapPoints.IsSnappableEntity(ent) then
        return nil, "Target entity cannot be dropped."
    end

    local worldNormal = Math.SafeNormalize(trace.HitNormal, Vector(0, 0, 1))
    local localHitNormal = Math.WorldDirToLocal(ent, worldNormal)

    local ax = math.abs(localHitNormal.x)
    local ay = math.abs(localHitNormal.y)
    local az = math.abs(localHitNormal.z)
    local localFaceNormal
    if ax >= ay and ax >= az then
        localFaceNormal = Vector(localHitNormal.x >= 0 and 1 or -1, 0, 0)
    elseif ay >= ax and ay >= az then
        localFaceNormal = Vector(0, localHitNormal.y >= 0 and 1 or -1, 0)
    else
        localFaceNormal = Vector(0, 0, localHitNormal.z >= 0 and 1 or -1)
    end

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

local function rotateLocalDirToWorld(localDir, ang)
    local out = Vector(localDir.x, localDir.y, localDir.z)
    out:Rotate(ang)
    return Math.SafeNormalize(out, Vector(0, 0, 1))
end

local function getSupportDistanceAlongWorld(ent, worldDir, ang)
    if not IsValid(ent) then
        return 0
    end

    local axis = Math.SafeNormalize(worldDir, Vector(0, 0, 1))
    local mins = ent:OBBMins()
    local maxs = ent:OBBMaxs()
    local maxProj = nil

    for i = 0, 7 do
        local localCorner = Vector(
            bit.band(i, 1) ~= 0 and maxs.x or mins.x,
            bit.band(i, 2) ~= 0 and maxs.y or mins.y,
            bit.band(i, 4) ~= 0 and maxs.z or mins.z
        )

        local worldCornerOffset = Vector(localCorner.x, localCorner.y, localCorner.z)
        worldCornerOffset:Rotate(ang)
        local projection = worldCornerOffset:Dot(axis)
        maxProj = maxProj and math.max(maxProj, projection) or projection
    end

    return maxProj or 0
end

local function solveSurfaceAlignedAngles(srcEnt, sourceConnector, contactLocalNormal, targetNormal)
    local sourceLocalBasis = Math.BuildBasis(contactLocalNormal, sourceConnector.localBasis.u)
    local currentWorldTangent = Math.LocalDirToWorld(srcEnt, sourceLocalBasis.u)
    local desiredBasis = Math.BuildBasis(-targetNormal, currentWorldTangent)

    local worldForward = Math.MapLocalVectorToWorld(Vector(1, 0, 0), sourceLocalBasis, desiredBasis)
    local worldLeft = Math.MapLocalVectorToWorld(Vector(0, 1, 0), sourceLocalBasis, desiredBasis)
    local worldUp = Math.MapLocalVectorToWorld(Vector(0, 0, 1), sourceLocalBasis, desiredBasis)

    return Math.BasisToWorldAngle(worldForward, worldLeft, worldUp)
end

function MODE.Solve(sourceConnector, _, settings)
    if not sourceConnector then
        return nil, "Missing source connector."
    end

    local srcEnt = sourceConnector.entity
    if not IsValid(srcEnt) then
        return nil, "Source entity is no longer valid."
    end

    local srcBasis = sourceConnector.worldBasis
    local liveSettings = settings or {}
    local contactLocalNormal = liveSettings.invertDirection and -sourceConnector.localBasis.n or sourceConnector.localBasis.n
    local dropDir = liveSettings.invertDirection and -srcBasis.n or srcBasis.n
    if dropDir:LengthSqr() <= 1e-8 then
        return nil, "Could not resolve drop direction."
    end

    local dropDistance = math.max(64, tonumber(liveSettings.dropDistance) or 4096)
    local startPos = srcEnt:GetPos() + dropDir * 0.1

    local tr = util.TraceLine({
        start = startPos,
        endpos = startPos + dropDir * dropDistance,
        filter = srcEnt,
        mask = MASK_SOLID
    })

    if not tr or not tr.Hit then
        return nil, "No surface found in drop direction."
    end

    local targetNormal = Math.SafeNormalize(tr.HitNormal, -dropDir)
    if targetNormal:Dot(dropDir) > 0 then
        targetNormal = -targetNormal
    end

    local finalAng = srcEnt:GetAngles()
    if liveSettings.alignToSurface then
        finalAng = solveSurfaceAlignedAngles(srcEnt, sourceConnector, contactLocalNormal, targetNormal)
    end

    local sourceContactNormal = rotateLocalDirToWorld(contactLocalNormal, finalAng)
    local supportDistance = getSupportDistanceAlongWorld(srcEnt, sourceContactNormal, finalAng)

    local gap = tonumber(liveSettings.gap) or 0
    local effectiveGap = gap + SURFACE_DROP_SIZE_GAP_BIAS_UNITS
    local finalPos = tr.HitPos + targetNormal * effectiveGap - sourceContactNormal * supportDistance

    return {
        entity = srcEnt,
        position = finalPos,
        angles = finalAng
    }
end

if CLIENT then
    MODE.PanelClass = "MicronModeSurfaceDropPanel"

    local PANEL = {}

    function PANEL:Init()
        self:DockPadding(0, 0, 0, 0)

        local scroll = vgui.Create("DScrollPanel", self)
        scroll:Dock(FILL)

        local form = vgui.Create("DForm", scroll)
        form:Dock(TOP)
        form:SetName("Surface Drop")
        form:Help("Preview follows hovered prop and applies on click")
        form:NumSlider("Drop Range", "micron_drop_distance", 64, 32768, 0)
        form:NumSlider("Gap", "micron_gap", -64, 64, 2)
        form:CheckBox("Align To Surface", "micron_align_surface")
        form:CheckBox("Freeze", "micron_freeze_prop")
        Utils.AttachSectionResetButton(form, MODE.ClientConVarDefaults, {
            "drop_distance",
            "gap",
            "align_surface",
            "freeze_prop"
        })

        local keybindForm = vgui.Create("DForm", scroll)
        keybindForm:Dock(TOP)
        keybindForm:SetName("Keybinds")
        keybindForm:Help("LMB: drop hovered prop")
        keybindForm:Help("Hold Shift: swap drop side")
        keybindForm:Help("Option: align to hit surface")
        keybindForm:Help("No duplicate modifier in this mode")
    end

    function PANEL:GetPreferredHeight()
        return 410
    end

    vgui.Register(MODE.PanelClass, PANEL, "DPanel")
end

Registry.Register("surface_drop", MODE)
