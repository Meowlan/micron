Micron = Micron or {}
Micron.ModeUtils = Micron.ModeUtils or {}

local Utils = Micron.ModeUtils
local Math = Micron.Math
local SnapPoints = Micron.SnapPoints

function Utils.WrapRotationDegrees(value)
    local v = tonumber(value) or 0

    while v > 360 do
        v = v - 360
    end

    while v < -360 do
        v = v + 360
    end

    return v
end

function Utils.GetCommonSettings(tool)
    local localN = Utils.WrapRotationDegrees(tool:GetClientNumber("local_rot_n", 0))
    local localU = Utils.WrapRotationDegrees(tool:GetClientNumber("local_rot_u", 0))
    local localV = Utils.WrapRotationDegrees(tool:GetClientNumber("local_rot_v", 0))
    local rotSnap = tonumber(tool:GetClientNumber("rot_snap", 90)) or 90
    rotSnap = math.Clamp(math.Round(rotSnap / 15) * 15, 0, 180)

    return {
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

function Utils.ToggleReverseAxis(tool, ply)
    local reverseAxis = tool:GetClientNumber("reverse_axis", 0) == 1
    local newValue = reverseAxis and 0 or 1
    ply:ConCommand("micron_reverse_axis " .. tostring(newValue))
    return true
end

function Utils.HandleRotateInput(tool, ply, settings, axis, direction)
    axis = math.Clamp(axis or 1, 1, 3)
    direction = (tonumber(direction) or 1) < 0 and -1 or 1

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

    local currentValue = Utils.WrapRotationDegrees(tool:GetClientNumber(clientKey, 0))
    local newValue = Utils.WrapRotationDegrees(currentValue + snapStep * direction)
    ply:ConCommand(string.format("%s %.3f", cvarName, newValue))
    return true
end

function Utils.ChooseStableLocalHint(normal)
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

function Utils.BuildConnectorFromTrace(trace, settings, worldError)
    if not trace or not trace.Hit then
        return nil, "No surface was hit."
    end

    if trace.HitWorld then
        return nil, worldError or "World geometry cannot be selected as a connector."
    end

    local ent = trace.Entity
    local snapData, err = SnapPoints.ComputeForEntity(ent, trace.HitPos, trace.HitNormal, settings.gridSubdivisions)
    if not snapData then
        return nil, err or "Could not compute snap points for target entity."
    end

    local selected = snapData.selectedPoint
    local localHint = Utils.ChooseStableLocalHint(snapData.basis.n)
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

function Utils.ApplyRotationOffsets(basis, rotation)
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