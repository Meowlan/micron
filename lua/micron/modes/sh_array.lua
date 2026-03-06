Micron = Micron or {}
local Registry = Micron.ModeRegistry
local Utils = Micron.ModeUtils

local MODE = {}

MODE.DisplayName = "Array"
MODE.Description = "Place a line of copies."
MODE.RequiresTargetConnector = false
MODE.LatchDuplicateOnSource = true
MODE.ClientConVarDefaults = {
    array_count = "5",
    array_spacing = "16",
    array_axis = "1",
    array_reverse = "0",
    grid_subdivisions = "6",
    freeze_prop = "1"
}

local function clampAxis(value)
    return math.Clamp(math.floor(tonumber(value) or 1), 1, 3)
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
    local spacing = tonumber(tool:GetClientNumber("array_spacing", 16)) or 16

    return {
        gridSubdivisions = math.floor(tonumber(tool:GetClientNumber("grid_subdivisions", 6)) or 6),
        arrayCount = count,
        arraySpacing = spacing,
        arrayAxis = clampAxis(tool:GetClientNumber("array_axis", 1)),
        reverseDirection = tool:GetClientNumber("array_reverse", 0) == 1,
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

function MODE.BuildConnector(_, trace, settings)
    settings = settings or {}
    return Utils.BuildConnectorFromTrace(trace, settings, "World geometry cannot be selected as an array source.")
end

function MODE.Solve(sourceConnector, _, settings)
    if not sourceConnector then
        return nil, "Missing source connector."
    end

    local srcEnt = sourceConnector.entity
    if not IsValid(srcEnt) then
        return nil, "Source entity is no longer valid."
    end

    local axis = resolveArrayAxisWorld(sourceConnector, settings)
    local step = axis * (settings.arraySpacing or 0)

    return {
        entity = srcEnt,
        position = srcEnt:GetPos() + step,
        angles = srcEnt:GetAngles()
    }
end

function MODE.Apply(_, ply, state, settings, _, shouldDuplicate, helpers)
    local sourceConnector = state and state.source or nil
    if not sourceConnector then
        return false
    end

    local sourceEnt = sourceConnector.entity
    if not IsValid(sourceEnt) then
        return false
    end

    local count = math.max(1, tonumber(settings.arrayCount) or 1)
    local axis = resolveArrayAxisWorld(sourceConnector, settings)
    if axis:LengthSqr() <= 1e-8 then
        return false
    end

    local step = axis * (settings.arraySpacing or 0)
    local basePos = sourceEnt:GetPos()
    local baseAng = sourceEnt:GetAngles()

    local created = {}
    local movedSource = false
    local oldPos = basePos
    local oldAng = baseAng
    local oldMotionEnabled = nil

    local sourcePhys = sourceEnt:GetPhysicsObject()
    if IsValid(sourcePhys) then
        oldMotionEnabled = sourcePhys:IsMotionEnabled()
    end

    local firstIndex = 1
    if not shouldDuplicate then
        setEntityTransform(sourceEnt, basePos + step, baseAng)
        freezeEntityIfNeeded(sourceEnt, settings.freezeProp)
        movedSource = true
        firstIndex = 2
    end

    for i = firstIndex, count do
        local duplicated = helpers.duplicateEntityForSnap(ply, sourceEnt)
        if not IsValid(duplicated) then
            break
        end

        setEntityTransform(duplicated, basePos + step * i, baseAng)
        freezeEntityIfNeeded(duplicated, settings.freezeProp)
        created[#created + 1] = duplicated
    end

    undo.Create("Micron Array")
    undo.SetPlayer(ply)

    for _, ent in ipairs(created) do
        if IsValid(ent) then
            undo.AddEntity(ent)
            cleanup.Add(ply, "props", ent)
        end
    end

    if movedSource then
        undo.AddFunction(function(_, movedEnt, revertPos, revertAng, motionEnabled)
            if not IsValid(movedEnt) then return end

            movedEnt:SetAngles(revertAng)
            movedEnt:SetPos(revertPos)

            local phys = movedEnt:GetPhysicsObject()
            if IsValid(phys) then
                phys:SetAngles(revertAng)
                phys:SetPos(revertPos)
                if motionEnabled ~= nil then
                    phys:EnableMotion(motionEnabled)
                end
                phys:Wake()
            end
        end, sourceEnt, oldPos, oldAng, oldMotionEnabled)
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
        form:CheckBox("Reverse", "micron_array_reverse")
        form:CheckBox("Freeze", "micron_freeze_prop")
        Utils.AttachSectionResetButton(form, MODE.ClientConVarDefaults, {
            "array_count",
            "array_spacing",
            "grid_subdivisions",
            "array_reverse",
            "array_axis",
            "freeze_prop"
        })

        local keybindForm = vgui.Create("DForm", scroll)
        keybindForm:Dock(TOP)
        keybindForm:SetName("Keybinds")
        keybindForm:Help("LMB #1: pick source")
        keybindForm:Help("LMB #2: apply array")
        keybindForm:Help("R/Shift+R/Alt+R: set axis")
        keybindForm:Help("RMB: toggle reverse")
        keybindForm:Help("Shift+LMB: keep source")
    end

    function PANEL:GetPreferredHeight()
        return 430
    end

    vgui.Register(MODE.PanelClass, PANEL, "DPanel")
end

Registry.Register("array", MODE)
