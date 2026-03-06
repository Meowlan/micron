Micron = Micron or {}
local Math = Micron.Math
local Registry = Micron.ModeRegistry
local SnapPoints = Micron.SnapPoints

local MODE = {}

MODE.DisplayName = "Face Snap"
MODE.Description = "Snap one entity face connector to another, including sloped surfaces."
MODE.RotationAxisNames = {
    "Snap Normal",
    "Tangent",
    "Bitangent"
}
MODE.ClientConVarDefaults = {
    gap = "0",
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

local GAP_DISTANCE_BIAS_UNITS = -0.065

local function wrapRotationDegrees(value)
    local v = tonumber(value) or 0

    while v > 360 do
        v = v - 360
    end

    while v < -360 do
        v = v + 360
    end

    return v
end

function MODE.GetSettings(tool)
    local localN = wrapRotationDegrees(tool:GetClientNumber("local_rot_n", 0))
    local localU = wrapRotationDegrees(tool:GetClientNumber("local_rot_u", 0))
    local localV = wrapRotationDegrees(tool:GetClientNumber("local_rot_v", 0))
    local rotSnap = tonumber(tool:GetClientNumber("rot_snap", 90)) or 90
    rotSnap = math.Clamp(math.Round(rotSnap / 15) * 15, 0, 180)

    return {
        gap = tonumber(tool:GetClientNumber("gap", 0)) or 0,
        reverseAxis = tool:GetClientNumber("reverse_axis", 0) == 1,
        gridSubdivisions = math.floor(tonumber(tool:GetClientNumber("grid_subdivisions", 6)) or 6),
        rotSnap = rotSnap,
        localRotation = {
            localN,
            localU,
            localV
        },
        freezeProp = tool:GetClientNumber("freeze_prop", 0) == 1,
        weldProp = tool:GetClientNumber("weld_prop", 0) == 1,
        nocollidePair = tool:GetClientNumber("nocollide_pair", 0) == 1
    }
end

function MODE.OnRightClick(tool, ply)
    local reverseAxis = tool:GetClientNumber("reverse_axis", 0) == 1
    local newValue = reverseAxis and 0 or 1
    ply:ConCommand("micron_reverse_axis " .. tostring(newValue))
    return true
end

function MODE.OnRotateInput(tool, ply, _, settings, axis)
    axis = math.Clamp(axis or 1, 1, 3)

    local cvarName
    local clientKey
    if axis == 1 then
        cvarName = "micron_local_rot_n"
        clientKey = "local_rot_n"
    elseif axis == 2 then
        cvarName = "micron_local_rot_u"
        clientKey = "local_rot_u"
    else
        cvarName = "micron_local_rot_v"
        clientKey = "local_rot_v"
    end

    local snapStep = settings.rotSnap or 90
    if snapStep <= 0 then
        return false
    end

    local currentValue = wrapRotationDegrees(tool:GetClientNumber(clientKey, 0))
    local newValue = wrapRotationDegrees(currentValue + snapStep)
    ply:ConCommand(string.format("%s %.3f", cvarName, newValue))
    return true
end

local function chooseStableLocalHint(normal)
    local candidates = {
        Vector(1, 0, 0),
        Vector(0, 1, 0),
        Vector(0, 0, 1)
    }

    local best = candidates[1]
    local bestLen = 0

    for _, axis in ipairs(candidates) do
        local projected = axis - normal * axis:Dot(normal)
        local len = projected:LengthSqr()
        if len > bestLen then
            bestLen = len
            best = projected
        end
    end

    if bestLen <= 1e-8 then
        return candidates[1]
    end

    return best
end

local function buildConnectorFromTrace(ply, trace, settings)
    if not trace or not trace.Hit then
        return nil, "No surface was hit."
    end

    if trace.HitWorld then
        return nil, "World geometry cannot be selected as a movable connector."
    end

    local ent = trace.Entity
    local snapData, err = SnapPoints.ComputeForEntity(ent, trace.HitPos, trace.HitNormal, settings.gridSubdivisions)
    if not snapData then
        return nil, err or "Could not compute snap points for target entity."
    end

    local selected = snapData.selectedPoint
    local localHint = chooseStableLocalHint(snapData.basis.n)
    local localBasis = Math.BuildBasis(snapData.basis.n, localHint)
    local worldNormal = Math.LocalDirToWorld(ent, localBasis.n)
    local worldTangent = Math.LocalDirToWorld(ent, localBasis.u)
    local worldBasis = Math.BuildBasis(worldNormal, worldTangent)

    return {
        entity = ent,
        hitPosWorld = ent:LocalToWorld(selected.position),
        worldBasis = worldBasis,
        localPos = selected.position,
        localBasis = localBasis,
        snapData = snapData
    }
end

function MODE.BuildConnector(ply, trace, settings)
    settings = settings or {}
    return buildConnectorFromTrace(ply, trace, settings)
end

function MODE.StepRotation(state, axisIndex)
    if not state.rotation then
        state.rotation = {0, 0, 0}
    end

    axisIndex = math.Clamp(axisIndex or 1, 1, 3)
    state.rotation[axisIndex] = Math.WrapRightAngle((state.rotation[axisIndex] or 0) + 90)

    return state.rotation[axisIndex], MODE.RotationAxisNames[axisIndex]
end

function MODE.ResetRotation(state)
    state.rotation = {0, 0, 0}
end

local function applyRotationOffsets(basis, rotation)
    local out = {
        u = basis.u,
        v = basis.v,
        n = basis.n
    }

    out = Math.RotateBasisAroundAxis(out, "n", rotation[1] or 0)
    out = Math.RotateBasisAroundAxis(out, "u", rotation[2] or 0)
    out = Math.RotateBasisAroundAxis(out, "v", rotation[3] or 0)

    return out
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

    desiredBasis = applyRotationOffsets(desiredBasis, combinedRotation)

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
        angles = finalAng,
        debug = {
            worldForward = worldForward,
            worldUp = worldUp,
            worldLeft = worldLeft,
            targetNormal = targetNormal,
            desiredNormal = desiredNormal
        }
    }
end

if CLIENT then
    MODE.PanelClass = "MicronModeFaceSnapPanel"

    local PANEL = {}

    function PANEL:Init()
        self:DockPadding(0, 0, 0, 0)

        local scroll = vgui.Create("DScrollPanel", self)
        scroll:Dock(FILL)
        self.Scroll = scroll

        local transformForm = vgui.Create("DForm", scroll)
        transformForm:Dock(TOP)
        transformForm:SetName("Face Snap")
        transformForm:Help("Accurate face-to-face snapping with slope support")

        transformForm:NumSlider("Gap Distance", "micron_gap", -64, 64, 2)
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

        localRotForm:NumSlider("Normal", "micron_local_rot_n", -360, 360, 2)
        localRotForm:NumSlider("Tangent", "micron_local_rot_u", -360, 360, 2)
        localRotForm:NumSlider("Bitangent", "micron_local_rot_v", -360, 360, 2)

        local actionForm = vgui.Create("DForm", scroll)
        actionForm:Dock(TOP)
        actionForm:SetName("Actions")

        actionForm:CheckBox("Freeze Source Prop", "micron_freeze_prop")
        actionForm:CheckBox("Weld Source To Target", "micron_weld_prop")
        actionForm:CheckBox("NoCollide Source/Target", "micron_nocollide_pair")
        actionForm:CheckBox("Reverse Axis (match face normals)", "micron_reverse_axis")

        local keybindForm = vgui.Create("DForm", scroll)
        keybindForm:Dock(TOP)
        keybindForm:SetName("Keybinds")
        keybindForm:Help("R: rotate around normal using snap step")
        keybindForm:Help("Shift+R: rotate around tangent")
        keybindForm:Help("Alt+R: rotate around bitangent")
        keybindForm:Help("RMB: invert axis")
        keybindForm:Help("Shift+LMB apply: duplicate and snap copy")
        keybindForm:Help("+USE + RMB: reset source selection")
    end

    function PANEL:GetPreferredHeight()
        return 620
    end

    vgui.Register(MODE.PanelClass, PANEL, "DPanel")
end

Registry.Register("face_snap", MODE)
