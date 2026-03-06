Micron = Micron or {}
local Registry = Micron.ModeRegistry
local Utils = Micron.ModeUtils

local MODE = {}

MODE.DisplayName = "Surface Drop"
MODE.Description = "Drop source to a surface."
MODE.RequiresTargetConnector = false
MODE.LatchDuplicateOnSource = true
MODE.DuplicateFromSourceOnly = true
MODE.ClientConVarDefaults = {
    drop_distance = "4096",
    gap = "0",
    grid_subdivisions = "6",
    freeze_prop = "1"
}

function MODE.GetSettings(tool)
    local distance = tonumber(tool:GetClientNumber("drop_distance", 4096)) or 4096
    distance = math.Clamp(distance, 64, 32768)

    local invertDirection = false
    if tool and tool.GetOwner then
        local owner = tool:GetOwner()
        invertDirection = IsValid(owner) and owner:KeyDown(IN_SPEED) or false
    end

    return {
        gridSubdivisions = math.floor(tonumber(tool:GetClientNumber("grid_subdivisions", 6)) or 6),
        dropDistance = distance,
        gap = tonumber(tool:GetClientNumber("gap", 0)) or 0,
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
    settings = settings or {}
    return Utils.BuildConnectorFromTrace(trace, settings, "World geometry cannot be selected as a drop source.")
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
    local dropDir = liveSettings.invertDirection and srcBasis.n or -srcBasis.n
    if dropDir:LengthSqr() <= 1e-8 then
        return nil, "Could not resolve drop direction."
    end

    local dropDistance = math.max(64, tonumber(liveSettings.dropDistance) or 4096)
    local startPos = sourceConnector.hitPosWorld + dropDir * 0.1

    local tr = util.TraceLine({
        start = startPos,
        endpos = startPos + dropDir * dropDistance,
        filter = srcEnt,
        mask = MASK_SOLID
    })

    if not tr or not tr.Hit then
        return nil, "No surface found in drop direction."
    end

    local connectorOffsetWorld = srcEnt:LocalToWorld(sourceConnector.localPos) - srcEnt:GetPos()
    local gap = tonumber(liveSettings.gap) or 0
    local finalPos = tr.HitPos + tr.HitNormal * gap - connectorOffsetWorld

    return {
        entity = srcEnt,
        position = finalPos,
        angles = srcEnt:GetAngles()
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
        form:Help("Drop opposite the picked normal")
        form:NumSlider("Drop Range", "micron_drop_distance", 64, 32768, 0)
        form:NumSlider("Gap", "micron_gap", -64, 64, 2)
        form:NumSlider("Grid", "micron_grid_subdivisions", 1, 16, 0)
        form:CheckBox("Freeze", "micron_freeze_prop")
        Utils.AttachSectionResetButton(form, MODE.ClientConVarDefaults, {
            "drop_distance",
            "gap",
            "grid_subdivisions",
            "freeze_prop"
        })

        local keybindForm = vgui.Create("DForm", scroll)
        keybindForm:Dock(TOP)
        keybindForm:SetName("Keybinds")
        keybindForm:Help("LMB #1: pick source")
        keybindForm:Help("LMB #2: drop")
        keybindForm:Help("Hold Shift: invert drop")
        keybindForm:Help("Shift+LMB #1: duplicate")
    end

    function PANEL:GetPreferredHeight()
        return 410
    end

    vgui.Register(MODE.PanelClass, PANEL, "DPanel")
end

Registry.Register("surface_drop", MODE)
