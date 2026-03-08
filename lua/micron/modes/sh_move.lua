Micron = Micron or {}
local Math = Micron.Math
local Registry = Micron.ModeRegistry
local Utils = Micron.ModeUtils

local MODE = {}

MODE.DisplayName = "Move"
MODE.Description = "Snap source to target or world."
MODE.LatchDuplicateOnSource = true
MODE.AllowSelfTargetWhenDuplicating = true
MODE.RotationAxisNames = {
    "Normal",
    "Tangent",
    "Bitangent"
}
MODE.ClientConVarDefaults = {
    gap = "0",
    reverse_axis = "0",
    grid_subdivisions = "4",
    rot_snap = "90",
    local_rot_n = "0",
    local_rot_u = "0",
    local_rot_v = "0",
    freeze_prop = "1",
    weld_prop = "0",
    nocollide_pair = "1"
}

local GAP_DISTANCE_BIAS_UNITS = -0.065

function MODE.GetSettings(tool)
    local settings = Utils.GetCommonSettings(tool)
    settings.gap = tonumber(tool:GetClientNumber("gap", 0)) or 0
    return settings
end

function MODE.OnRightClick(tool, ply)
    return Utils.ToggleReverseAxis(tool, ply)
end

function MODE.OnRotateInput(tool, ply, _, settings, axis, direction)
    return Utils.HandleRotateInput(tool, ply, settings, axis, direction)
end

function MODE.BuildConnector(ply, trace, settings)
    settings = settings or {}
    local allowWorldTarget = IsValid(ply) and ply:GetNW2Bool("Micron.HasSource", false)
    return Utils.BuildConnectorFromTrace(
        trace,
        settings,
        "Select a source first before targeting world geometry.",
        {
            allowWorld = allowWorldTarget,
            player = ply
        }
    )
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

    local connectorOffsetWorld = Math.MapLocalVectorToWorld(sourceConnector.localPos, srcBasis, desiredBasis)
    local effectiveGap = (settings.gap or 0) + GAP_DISTANCE_BIAS_UNITS
    local targetPos = targetConnector.hitPosWorld + targetNormal * effectiveGap
    local finalPos = targetPos - connectorOffsetWorld

    return {
        entity = srcEnt,
        position = finalPos,
        angles = finalAng
    }
end

if CLIENT then
    MODE.PanelClass = "MicronModeMovePanel"

    local PANEL = {}

    function PANEL:Init()
        self:DockPadding(0, 0, 0, 0)

        local scroll = vgui.Create("DScrollPanel", self)
        scroll:Dock(FILL)

        local transformForm = vgui.Create("DForm", scroll)
        transformForm:Dock(TOP)
        transformForm:SetName("Move")
        transformForm:Help("Snap source to target")

        transformForm:NumSlider("Gap", "micron_gap", -64, 64, 2)
        transformForm:NumSlider("Grid", "micron_grid_subdivisions", 1, 16, 0)
        local snapSlider = transformForm:NumSlider("Rotate Step", "micron_rot_snap", 0, 180, 0)
        snapSlider.OnValueChanged = function(_, value)
            local snapped = math.Clamp(math.Round(value / 15) * 15, 0, 180)
            if math.abs(snapped - value) > 0.001 then
                RunConsoleCommand("micron_rot_snap", tostring(snapped))
            end
        end
        Utils.AttachSectionResetButton(transformForm, MODE.ClientConVarDefaults, {
            "gap",
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
        keybindForm:Help("R: rotate normal")
        keybindForm:Help("Shift+R: rotate tangent")
        keybindForm:Help("Alt+R: rotate bitangent")
        keybindForm:Help("Ctrl+R: reverse")
        keybindForm:Help("RMB: flip normal")
        keybindForm:Help("Shift+LMB: duplicate")
        keybindForm:Help("Target can be world (no snap)")
        keybindForm:Help("Use+RMB: clear selection")
    end

    function PANEL:GetPreferredHeight()
        return 620
    end

    vgui.Register(MODE.PanelClass, PANEL, "DPanel")
end

Registry.Register("move", MODE)
