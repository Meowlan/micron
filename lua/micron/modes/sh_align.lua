Micron = Micron or {}
local Math = Micron.Math
local Registry = Micron.ModeRegistry
local Utils = Micron.ModeUtils

local MODE = {}

MODE.DisplayName = "Align"
MODE.Description = "Match source rotation to target."
MODE.LatchDuplicateOnSource = true
MODE.RotationAxisNames = {
    "Normal",
    "Tangent",
    "Bitangent"
}
MODE.ClientConVarDefaults = {
    reverse_axis = "0",
    grid_subdivisions = "6",
    rot_snap = "90",
    local_rot_n = "0",
    local_rot_u = "0",
    local_rot_v = "0",
    freeze_prop = "1",
    weld_prop = "0",
    nocollide_pair = "1"
}

function MODE.GetSettings(tool)
    return Utils.GetCommonSettings(tool)
end

function MODE.OnRightClick(tool, ply)
    return Utils.ToggleReverseAxis(tool, ply)
end

function MODE.OnRotateInput(tool, ply, _, settings, axis, direction)
    return Utils.HandleRotateInput(tool, ply, settings, axis, direction)
end

function MODE.BuildConnector(_, trace, settings)
    settings = settings or {}
    return Utils.BuildConnectorFromTrace(trace, settings, "World geometry cannot be selected as an align connector.")
end

function MODE.Solve(sourceConnector, targetConnector, settings, state)
    if not sourceConnector or not targetConnector then
        return nil, "Missing source or target connector."
    end

    local srcEnt = sourceConnector.entity
    if not IsValid(srcEnt) then
        return nil, "Source entity is no longer valid."
    end

    local targetNormal = targetConnector.worldBasis.n
    local desiredNormal = settings.reverseAxis and targetNormal or -targetNormal
    local desiredBasis = Math.BuildBasis(desiredNormal, targetConnector.worldBasis.u)

    local stepRotation = state.rotation or {0, 0, 0}
    local localRotation = settings.localRotation or {0, 0, 0}
    local combinedRotation = {
        (stepRotation[1] or 0) + (localRotation[1] or 0),
        (stepRotation[2] or 0) + (localRotation[2] or 0),
        (stepRotation[3] or 0) + (localRotation[3] or 0)
    }

    desiredBasis = Utils.ApplyRotationOffsets(desiredBasis, combinedRotation)

    local srcBasis = sourceConnector.localBasis
    local worldForward = Math.MapLocalVectorToWorld(Vector(1, 0, 0), srcBasis, desiredBasis)
    local worldLeft = Math.MapLocalVectorToWorld(Vector(0, 1, 0), srcBasis, desiredBasis)
    local worldUp = Math.MapLocalVectorToWorld(Vector(0, 0, 1), srcBasis, desiredBasis)

    local finalAng = Math.BasisToWorldAngle(worldForward, worldLeft, worldUp)

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
        transformForm:Help("Match source rotation to target")

        transformForm:NumSlider("Grid", "micron_grid_subdivisions", 1, 16, 0)
        local snapSlider = transformForm:NumSlider("Rotate Step", "micron_rot_snap", 0, 180, 0)
        snapSlider.OnValueChanged = function(_, value)
            local snapped = math.Clamp(math.Round(value / 15) * 15, 0, 180)
            if math.abs(snapped - value) > 0.001 then
                RunConsoleCommand("micron_rot_snap", tostring(snapped))
            end
        end
        Utils.AttachSectionResetButton(transformForm, MODE.ClientConVarDefaults, {
            "grid_subdivisions",
            "rot_snap"
        })

        local localRotForm = vgui.Create("DForm", scroll)
        localRotForm:Dock(TOP)
        localRotForm:SetName("Local")
        localRotForm:NumSlider("Normal", "micron_local_rot_n", -360, 360, 2)
        localRotForm:NumSlider("Tangent", "micron_local_rot_u", -360, 360, 2)
        localRotForm:NumSlider("Bitangent", "micron_local_rot_v", -360, 360, 2)
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
        actionForm:CheckBox("Flip Normal", "micron_reverse_axis")
        Utils.AttachSectionResetButton(actionForm, MODE.ClientConVarDefaults, {
            "freeze_prop",
            "weld_prop",
            "nocollide_pair",
            "reverse_axis"
        })

        local keybindForm = vgui.Create("DForm", scroll)
        keybindForm:Dock(TOP)
        keybindForm:SetName("Keybinds")
        keybindForm:Help("LMB #1: pick source")
        keybindForm:Help("LMB #2: pick target + apply")
        keybindForm:Help("R/Shift+R/Alt+R: rotate axis")
        keybindForm:Help("Ctrl+R: reverse")
        keybindForm:Help("Shift+LMB: duplicate")
        keybindForm:Help("RMB: flip normal")
    end

    function PANEL:GetPreferredHeight()
        return 560
    end

    vgui.Register(MODE.PanelClass, PANEL, "DPanel")
end

Registry.Register("align", MODE)
