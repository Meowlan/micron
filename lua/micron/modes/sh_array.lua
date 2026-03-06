Micron = Micron or {}
local Registry = Micron.ModeRegistry
local Utils = Micron.ModeUtils

local ARRAY_SIZE_GAP_BIAS_UNITS = -0.5

local MODE = {}

MODE.DisplayName = "Array"
MODE.Description = "Place a line of copies."
MODE.RequiresTargetConnector = false
MODE.ApplyOnSourceSelection = true
MODE.PreviewFromTraceWhenIdle = true
MODE.AlwaysDuplicate = true
MODE.ClientConVarDefaults = {
    array_count = "5",
    array_spacing = "0",
    array_axis = "1",
    array_reverse = "0",
    array_use_size_gap = "1",
    grid_subdivisions = "4",
    freeze_prop = "1"
}

local function clampAxis(value)
    return math.Clamp(math.floor(tonumber(value) or 1), 1, 3)
end

local function shouldInvertDirectionFromShift(ply)
    return IsValid(ply) and ply:KeyDown(IN_SPEED) and true or false
end

local function getLocalPreviewShiftInvert()
    if not CLIENT then
        return false
    end

    local ply = LocalPlayer()
    return shouldInvertDirectionFromShift(ply)
end

local function buildEffectiveSettings(settings, shiftInvert)
    if not shiftInvert then
        return settings
    end

    local effective = table.Copy(settings or {})
    effective.reverseDirection = not (settings and settings.reverseDirection and true or false)
    return effective
end

local function resolveArrayAxisWorld(connector, settings)
    local axis = clampAxis(settings.arrayAxis)
    local basis = connector and connector.worldBasis
    if not basis then
        return Vector(0, 0, 1)
    end

    local vec
    if axis == 1 then
        vec = basis.n
    elseif axis == 2 then
        vec = basis.u
    else
        vec = basis.v
    end

    if settings.reverseDirection then
        vec = -vec
    end

    return vec:GetNormalized()
end

local function computeSizeAlongAxisWorld(ent, axisWorld)
    if not IsValid(ent) then
        return 0
    end

    local axis = axisWorld and axisWorld:GetNormalized() or Vector(0, 0, 1)
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

local function buildArrayPlacements(sourceConnector, settings)
    if not sourceConnector then
        return nil, nil
    end

    local sourceEnt = sourceConnector.entity
    if not IsValid(sourceEnt) then
        return nil, nil
    end

    local axis = resolveArrayAxisWorld(sourceConnector, settings)
    if axis:LengthSqr() <= 1e-8 then
        return nil, nil
    end

    local stepDistance = settings.arraySpacing or 0
    if settings.useSizeGap then
        stepDistance = stepDistance + computeSizeAlongAxisWorld(sourceEnt, axis) + ARRAY_SIZE_GAP_BIAS_UNITS
    end

    local step = axis * stepDistance
    local count = math.max(1, tonumber(settings.arrayCount) or 1)
    local basePos = sourceEnt:GetPos()
    local baseAng = sourceEnt:GetAngles()

    local placements = {}
    for i = 1, count do
        placements[#placements + 1] = {
            position = basePos + step * i,
            angles = baseAng
        }
    end

    return placements, sourceEnt
end

local function setEntityTransform(ent, pos, ang)
    ent:SetAngles(ang)
    ent:SetPos(pos)

    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetAngles(ang)
        phys:SetPos(pos)
        phys:Wake()
    end
end

local function freezeEntityIfNeeded(ent, shouldFreeze)
    if not shouldFreeze then
        return
    end

    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableMotion(false)
        phys:Wake()
    end
end

function MODE.GetSettings(tool)
    local count = math.Clamp(math.floor(tonumber(tool:GetClientNumber("array_count", 5)) or 5), 1, 32)
    local spacing = tonumber(tool:GetClientNumber("array_spacing", 0)) or 0

    return {
        gridSubdivisions = math.floor(tonumber(tool:GetClientNumber("grid_subdivisions", 5)) or 5),
        arrayCount = count,
        arraySpacing = spacing,
        arrayAxis = clampAxis(tool:GetClientNumber("array_axis", 1)),
        reverseDirection = tool:GetClientNumber("array_reverse", 0) == 1,
        useSizeGap = tool:GetClientNumber("array_use_size_gap", 1) == 1,
        freezeProp = tool:GetClientNumber("freeze_prop", 0) == 1
    }
end

function MODE.OnRightClick(tool, ply)
    local reverse = tool:GetClientNumber("array_reverse", 0) == 1
    local newValue = reverse and 0 or 1
    ply:ConCommand("micron_array_reverse " .. tostring(newValue))
    return true
end

function MODE.OnRotateInput(tool, ply, _, _, axis)
    axis = clampAxis(axis)
    ply:ConCommand("micron_array_axis " .. tostring(axis))
    return true
end

function MODE.BuildConnector(ply, trace, settings)
    settings = settings or {}
    return Utils.BuildConnectorFromTrace(
        trace,
        settings,
        "World geometry cannot be selected as an array source.",
        { player = ply }
    )
end

function MODE.Solve(sourceConnector, _, settings)
    local effectiveSettings = buildEffectiveSettings(settings, getLocalPreviewShiftInvert())
    local placements, srcEnt = buildArrayPlacements(sourceConnector, effectiveSettings)
    if not placements or not placements[1] or not IsValid(srcEnt) then
        return nil, "Could not build array preview."
    end

    return {
        entity = srcEnt,
        position = placements[1].position,
        angles = placements[1].angles
    }
end

function MODE.GetPreviewGhosts(sourceConnector, settings)
    local effectiveSettings = buildEffectiveSettings(settings, getLocalPreviewShiftInvert())
    local placements = buildArrayPlacements(sourceConnector, effectiveSettings)
    return placements or {}
end

function MODE.Apply(_, ply, state, settings, _, _, helpers)
    if helpers and helpers.allowDuplication and not helpers.allowDuplication() then
        return false
    end

    local sourceConnector = state and state.source or nil
    local effectiveSettings = buildEffectiveSettings(settings, shouldInvertDirectionFromShift(ply))
    local placements, sourceEnt = buildArrayPlacements(sourceConnector, effectiveSettings)
    if not placements or #placements == 0 then
        return false
    end

    local created = {}

    for _, placement in ipairs(placements) do
        local duplicated = helpers.duplicateEntityForSnap(ply, sourceEnt)
        if not IsValid(duplicated) then
            break
        end

        if helpers and helpers.validateTransform and not helpers.validateTransform(duplicated, placement.position, placement.angles) then
            duplicated:Remove()
            break
        end

        setEntityTransform(duplicated, placement.position, placement.angles)
        freezeEntityIfNeeded(duplicated, settings.freezeProp)
        created[#created + 1] = duplicated
    end

    if #created == 0 then
        return false
    end

    undo.Create("Micron Array")
    undo.SetPlayer(ply)

    for _, ent in ipairs(created) do
        if IsValid(ent) then
            undo.AddEntity(ent)
            cleanup.Add(ply, "props", ent)
        end
    end

    undo.Finish()
    return true
end

if CLIENT then
    MODE.PanelClass = "MicronModeArrayPanel"

    local PANEL = {}

    function PANEL:Init()
        self:DockPadding(0, 0, 0, 0)

        local scroll = vgui.Create("DScrollPanel", self)
        scroll:Dock(FILL)

        local form = vgui.Create("DForm", scroll)
        form:Dock(TOP)
        form:SetName("Array")
        form:Help("Place a line of copies")
        form:NumSlider("Count", "micron_array_count", 1, 32, 0)
        form:NumSlider("Spacing", "micron_array_spacing", -256, 256, 2)
        form:NumSlider("Grid", "micron_grid_subdivisions", 1, 16, 0)
        form:CheckBox("Use Size Gap", "micron_array_use_size_gap")
        form:CheckBox("Reverse", "micron_array_reverse")
        form:CheckBox("Freeze", "micron_freeze_prop")
        Utils.AttachSectionResetButton(form, MODE.ClientConVarDefaults, {
            "array_count",
            "array_spacing",
            "grid_subdivisions",
            "array_use_size_gap",
            "array_reverse",
            "array_axis",
            "freeze_prop"
        })

        local keybindForm = vgui.Create("DForm", scroll)
        keybindForm:Dock(TOP)
        keybindForm:SetName("Keybinds")
        keybindForm:Help("LMB: apply")
        keybindForm:Help("Hold Shift: temporary reverse")
        keybindForm:Help("R/Shift+R/Alt+R: set axis")
        keybindForm:Help("RMB: toggle reverse")
        keybindForm:Help("Original is never moved")
    end

    function PANEL:GetPreferredHeight()
        return 430
    end

    vgui.Register(MODE.PanelClass, PANEL, "DPanel")
end

Registry.Register("array", MODE)
