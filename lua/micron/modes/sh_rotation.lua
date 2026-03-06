Micron = Micron or {}
local Math = Micron.Math
local Registry = Micron.ModeRegistry
local Utils = Micron.ModeUtils

local MODE = {}

MODE.DisplayName = "Rotation"
MODE.Description = "Select a pivot snap point, adjust rotation, then confirm with a second click."
MODE.RequiresTargetConnector = false
MODE.LatchDuplicateOnSource = true
MODE.RotationAxisNames = {
    "Pivot Normal",
    "Pivot Tangent",
    "Pivot Bitangent"
}
MODE.ClientConVarDefaults = {
    reverse_axis = "0",
    grid_subdivisions = "6",
    rot_snap = "90",
    local_rot_n = "0",
    local_rot_u = "0",
    local_rot_v = "0",
    freeze_prop = "0",
    weld_prop = "0",
    nocollide_pair = "0"
}

function MODE.GetSettings(tool)
    return Utils.GetCommonSettings(tool)
end

function MODE.OnRightClick(tool, ply)
    return false
end

function MODE.OnRotateInput(tool, ply, _, settings, axis, direction)
    return Utils.HandleRotateInput(tool, ply, settings, axis, direction)
end

function MODE.BuildConnector(ply, trace, settings)
    settings = settings or {}
    return Utils.BuildConnectorFromTrace(trace, settings, "World geometry cannot be selected as a connector in rotation mode.")
end

function MODE.Solve(sourceConnector, targetConnector, settings, state)
    if not sourceConnector then
        return nil, "Missing source connector."
    end

    local srcEnt = sourceConnector.entity
    if not IsValid(srcEnt) then
        return nil, "Source entity is no longer valid."
    end

    local desiredBasis = {
        u = sourceConnector.worldBasis.u,
        v = sourceConnector.worldBasis.v,
        n = sourceConnector.worldBasis.n
    }

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

    -- Keep the selected pivot world position fixed while updating source orientation.
    local pivotWorld = sourceConnector.hitPosWorld or srcEnt:LocalToWorld(sourceConnector.localPos)
    local connectorOffsetWorld = Math.MapLocalVectorToWorld(sourceConnector.localPos, srcBasis, desiredBasis)
    local finalPos = pivotWorld - connectorOffsetWorld

    return {
        entity = srcEnt,
        position = finalPos,
        angles = finalAng,
        debug = {
            pivotWorld = pivotWorld,
            desiredNormal = desiredBasis.n
        }
    }
end

if CLIENT then
    MODE.PanelClass = "MicronModeRotationPanel"

    local PANEL = {}

    function PANEL:Init()
        self:DockPadding(0, 0, 0, 0)

        local scroll = vgui.Create("DScrollPanel", self)
        scroll:Dock(FILL)
        self.Scroll = scroll

        local transformForm = vgui.Create("DForm", scroll)
        transformForm:Dock(TOP)
        transformForm:SetName("Rotation")
        transformForm:Help("Select pivot once, adjust with R/Shift+R/Alt+R and sliders, then click again to apply")

        transformForm:NumSlider("Grid Subdivisions", "micron_grid_subdivisions", 1, 16, 0)
        local snapSlider = transformForm:NumSlider("Rotation Snap Step", "micron_rot_snap", 0, 180, 0)
        snapSlider.OnValueChanged = function(_, value)
            local snapped = math.Clamp(math.Round(value / 15) * 15, 0, 180)
            if math.abs(snapped - value) > 0.001 then
                RunConsoleCommand("micron_rot_snap", tostring(snapped))
            end
        end

        local localRotForm = vgui.Create("DForm", scroll)
        localRotForm:Dock(TOP)
        localRotForm:SetName("Local Rotation")

        localRotForm:NumSlider("Pivot Normal", "micron_local_rot_n", -360, 360, 2)
        localRotForm:NumSlider("Pivot Tangent", "micron_local_rot_u", -360, 360, 2)
        localRotForm:NumSlider("Pivot Bitangent", "micron_local_rot_v", -360, 360, 2)

        local actionForm = vgui.Create("DForm", scroll)
        actionForm:Dock(TOP)
        actionForm:SetName("Actions")

        actionForm:CheckBox("Freeze Source Prop", "micron_freeze_prop")

        local keybindForm = vgui.Create("DForm", scroll)
        keybindForm:Dock(TOP)
        keybindForm:SetName("Keybinds")
        keybindForm:Help("LMB #1: select source pivot snap point")
        keybindForm:Help("LMB #2: confirm/apply current rotation")
        keybindForm:Help("R: rotate around pivot normal using snap step")
        keybindForm:Help("Shift+R: rotate around pivot tangent")
        keybindForm:Help("Alt+R: rotate around pivot bitangent")
        keybindForm:Help("Hold Ctrl with R/Shift+R/Alt+R to rotate in reverse")
        keybindForm:Help("Shift+LMB #1 or #2: duplicate on apply")
        keybindForm:Help("+USE + RMB: reset source selection")
    end

    function PANEL:GetPreferredHeight()
        return 600
    end

    vgui.Register(MODE.PanelClass, PANEL, "DPanel")
end

Registry.Register("rotation", MODE)
