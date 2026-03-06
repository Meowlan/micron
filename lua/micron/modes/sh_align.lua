Micron = Micron or {}
local Math = Micron.Math
local Registry = Micron.ModeRegistry
local Utils = Micron.ModeUtils

local MODE = {}

MODE.DisplayName = "Align"
MODE.Description = "Copy target angles or snap source to world angles."
MODE.LatchDuplicateOnSource = true
MODE.DisableSnapVisualization = true
MODE.RotationAxisNames = {
    "Pitch",
    "Yaw",
    "Roll"
}
MODE.ClientConVarDefaults = {
    align_world = "1",
    rot_snap = "90",
    local_rot_n = "0",
    local_rot_u = "0",
    local_rot_v = "0",
    freeze_prop = "1",
    weld_prop = "0",
    nocollide_pair = "1"
}

function MODE.GetSettings(tool)
    local settings = Utils.GetCommonSettings(tool)
    settings.alignWorld = tool:GetClientNumber("align_world", 0) == 1
    return settings
end

function MODE.OnRightClick(tool, ply)
    return false
end

function MODE.OnRotateInput(tool, ply, _, settings, axis, direction)
    return Utils.HandleRotateInput(tool, ply, settings, axis, direction)
end

function MODE.ApplyOnSourceSelection(_, settings)
    return settings.alignWorld and true or false
end

function MODE.BuildConnector(_, trace, settings)
    if not trace or not trace.Hit then
        return nil, "No surface was hit."
    end

    if trace.HitWorld then
        return nil, "World geometry cannot be selected as an align connector."
    end

    local ent = trace.Entity
    if not IsValid(ent) then
        return nil, "Target entity cannot be aligned."
    end

    return {
        entity = ent,
        hitPosWorld = ent:GetPos(),
        worldBasis = Math.BuildBasis(Vector(0, 0, 1), Vector(1, 0, 0)),
        localPos = vector_origin,
        localBasis = Math.BuildBasis(Vector(0, 0, 1), Vector(1, 0, 0)),
        snapData = nil
    }
end

local function getCombinedRotation(settings, state)
    local stepRotation = state.rotation or {0, 0, 0}
    local localRotation = settings.localRotation or {0, 0, 0}

    return {
        (stepRotation[1] or 0) + (localRotation[1] or 0),
        (stepRotation[2] or 0) + (localRotation[2] or 0),
        (stepRotation[3] or 0) + (localRotation[3] or 0)
    }
end

local function snapAnglesToWorld(ang)
    return Angle(
        Math.WrapRightAngle(ang.p),
        Math.WrapRightAngle(ang.y),
        Math.WrapRightAngle(ang.r)
    )
end

function MODE.Solve(sourceConnector, targetConnector, settings, state)
    if not sourceConnector then
        return nil, "Missing source connector."
    end

    local srcEnt = sourceConnector.entity
    if not IsValid(srcEnt) then
        return nil, "Source entity is no longer valid."
    end

    local baseAngles
    if settings.alignWorld then
        baseAngles = snapAnglesToWorld(srcEnt:GetAngles())
    else
        if not targetConnector then
            return nil, "Missing target connector."
        end

        local targetEnt = targetConnector.entity
        if not IsValid(targetEnt) then
            return nil, "Target entity is no longer valid."
        end

        baseAngles = targetEnt:GetAngles()
    end

    local combinedRotation = getCombinedRotation(settings, state)
    local finalAng = Angle(
        baseAngles.p + combinedRotation[1],
        baseAngles.y + combinedRotation[2],
        baseAngles.r + combinedRotation[3]
    )

    return {
        entity = srcEnt,
        position = srcEnt:GetPos(),
        angles = finalAng
    }
end

if CLIENT then
    MODE.PanelClass = "MicronModeAlignPanel"

    local PANEL = {}

    function PANEL:Init()
        self:DockPadding(0, 0, 0, 0)

        local scroll = vgui.Create("DScrollPanel", self)
        scroll:Dock(FILL)

        local transformForm = vgui.Create("DForm", scroll)
        transformForm:Dock(TOP)
        transformForm:SetName("Align")
        transformForm:Help("Copy target angles or snap source to world")

        local snapSlider = transformForm:NumSlider("Rotate Step", "micron_rot_snap", 0, 180, 0)
        snapSlider.OnValueChanged = function(_, value)
            local snapped = math.Clamp(math.Round(value / 15) * 15, 0, 180)
            if math.abs(snapped - value) > 0.001 then
                RunConsoleCommand("micron_rot_snap", tostring(snapped))
            end
        end
        Utils.AttachSectionResetButton(transformForm, MODE.ClientConVarDefaults, {
            "rot_snap"
        })

        local localRotForm = vgui.Create("DForm", scroll)
        localRotForm:Dock(TOP)
        localRotForm:SetName("Offset")
        localRotForm:NumSlider("Pitch", "micron_local_rot_n", -360, 360, 2)
        localRotForm:NumSlider("Yaw", "micron_local_rot_u", -360, 360, 2)
        localRotForm:NumSlider("Roll", "micron_local_rot_v", -360, 360, 2)
        Utils.AttachSectionResetButton(localRotForm, MODE.ClientConVarDefaults, {
            "local_rot_n",
            "local_rot_u",
            "local_rot_v"
        })

        local actionForm = vgui.Create("DForm", scroll)
        actionForm:Dock(TOP)
        actionForm:SetName("Options")
        actionForm:CheckBox("Freeze", "micron_freeze_prop")
        actionForm:CheckBox("Weld", "micron_weld_prop")
        actionForm:CheckBox("No Collide", "micron_nocollide_pair")
        actionForm:CheckBox("Align to World", "micron_align_world")
        Utils.AttachSectionResetButton(actionForm, MODE.ClientConVarDefaults, {
            "freeze_prop",
            "weld_prop",
            "nocollide_pair",
            "align_world"
        })

        local keybindForm = vgui.Create("DForm", scroll)
        keybindForm:Dock(TOP)
        keybindForm:SetName("Keybinds")
        keybindForm:Help("LMB #1: pick source")
        keybindForm:Help("LMB #2: pick target + apply")
        keybindForm:Help("R: offset pitch")
        keybindForm:Help("Shift+R: offset yaw")
        keybindForm:Help("Alt+R: offset roll")
        keybindForm:Help("Ctrl+R: reverse offset step")
        keybindForm:Help("Shift+LMB: duplicate")
        keybindForm:Help("Align to World: apply on first click")
    end

    function PANEL:GetPreferredHeight()
        return 560
    end

    vgui.Register(MODE.PanelClass, PANEL, "DPanel")
end

Registry.Register("align", MODE)
