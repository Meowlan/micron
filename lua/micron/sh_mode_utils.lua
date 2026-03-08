Micron = Micron or {}
Micron.ModeUtils = Micron.ModeUtils or {}

local Utils = Micron.ModeUtils
local Math = Micron.Math
local SnapPoints = Micron.SnapPoints

local DEFAULT_MAX_GRID_SUBDIVISIONS = 16
local DEFAULT_MAX_ROT_SNAP = 180
local DEFAULT_MAX_LOCAL_ROTATION = 360
local DEFAULT_MAX_GAP = 128
local DEFAULT_MAX_ARRAY_COUNT = 32
local DEFAULT_MAX_ARRAY_SPACING = 1024
local DEFAULT_MAX_DROP_DISTANCE = 16384
local DEFAULT_MAX_ENTITY_DISTANCE = 4096
local DEFAULT_MAX_MOVE_DISTANCE = 16384
local DEFAULT_MAX_TARGET_DISTANCE = 32768

local function isFiniteNumber(value)
    return isnumber(value) and value == value and value ~= math.huge and value ~= -math.huge
end

local function sanitizeNumber(value, defaultValue, minValue, maxValue)
    local out = tonumber(value)
    if not isFiniteNumber(out) then
        out = tonumber(defaultValue) or 0
    end

    if minValue ~= nil and maxValue ~= nil and minValue > maxValue then
        minValue, maxValue = maxValue, minValue
    end

    if minValue ~= nil and out < minValue then
        out = minValue
    end

    if maxValue ~= nil and out > maxValue then
        out = maxValue
    end

    return out
end

local function sanitizeInteger(value, defaultValue, minValue, maxValue)
    return math.floor(sanitizeNumber(value, defaultValue, minValue, maxValue))
end

local function sanitizeBool(value)
    return value and true or false
end

local function isFiniteVector(vec)
    return isvector(vec) and isFiniteNumber(vec.x) and isFiniteNumber(vec.y) and isFiniteNumber(vec.z)
end

local function isFiniteAngle(ang)
    return isangle(ang) and isFiniteNumber(ang.p) and isFiniteNumber(ang.y) and isFiniteNumber(ang.r)
end

if SERVER then
    local convarFlags = bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY)

    local function createServerConVar(name, defaultValue, helpText)
        return CreateConVar(name, tostring(defaultValue), convarFlags, helpText)
    end

    Utils.ServerConVars = Utils.ServerConVars or {
        validationEnabled = createServerConVar("micron_sv_validation_enabled", "1", "Enable server-side Micron setting and transform validation."),
        maxGridSubdivisions = createServerConVar("micron_sv_max_grid_subdivisions", tostring(DEFAULT_MAX_GRID_SUBDIVISIONS), "Maximum allowed snap grid subdivisions."),
        maxRotSnap = createServerConVar("micron_sv_max_rot_snap", tostring(DEFAULT_MAX_ROT_SNAP), "Maximum rotate step allowed by Micron."),
        maxLocalRotation = createServerConVar("micron_sv_max_local_rotation", tostring(DEFAULT_MAX_LOCAL_ROTATION), "Maximum absolute local rotation offset per axis."),
        maxGap = createServerConVar("micron_sv_max_gap", tostring(DEFAULT_MAX_GAP), "Maximum absolute gap value for modes that support gap."),
        maxArrayCount = createServerConVar("micron_sv_max_array_count", tostring(DEFAULT_MAX_ARRAY_COUNT), "Maximum number of entities created by array mode per apply."),
        maxArraySpacing = createServerConVar("micron_sv_max_array_spacing", tostring(DEFAULT_MAX_ARRAY_SPACING), "Maximum absolute array spacing value."),
        maxDropDistance = createServerConVar("micron_sv_max_drop_distance", tostring(DEFAULT_MAX_DROP_DISTANCE), "Maximum trace distance for surface drop mode."),
        maxEntityDistance = createServerConVar("micron_sv_max_entity_distance", tostring(DEFAULT_MAX_ENTITY_DISTANCE), "Maximum distance from player eye to source/target entities for Micron operations."),
        maxMoveDistance = createServerConVar("micron_sv_max_move_distance", tostring(DEFAULT_MAX_MOVE_DISTANCE), "Maximum distance an entity may be moved in a single Micron apply."),
        maxTargetDistance = createServerConVar("micron_sv_max_target_distance", tostring(DEFAULT_MAX_TARGET_DISTANCE), "Maximum distance from player eye to final placed position."),
        allowDuplication = createServerConVar("micron_sv_allow_duplication", "1", "Allow Micron duplicate operations."),
        allowFreeze = createServerConVar("micron_sv_allow_freeze", "1", "Allow Micron freeze option."),
        allowWeld = createServerConVar("micron_sv_allow_weld", "1", "Allow Micron weld option."),
        allowNocollide = createServerConVar("micron_sv_allow_nocollide", "1", "Allow Micron nocollide option."),
        allowWorldConnectors = createServerConVar("micron_sv_allow_world_connectors", "1", "Allow Micron modes to select world geometry connectors when mode supports it.")
    }
end

function Utils.GetServerLimits()
    if not SERVER then
        return nil
    end

    local cvars = Utils.ServerConVars
    if not cvars then
        return nil
    end

    return {
        validationEnabled = cvars.validationEnabled:GetBool(),
        maxGridSubdivisions = sanitizeInteger(cvars.maxGridSubdivisions:GetFloat(), DEFAULT_MAX_GRID_SUBDIVISIONS, 1, 24),
        maxRotSnap = sanitizeNumber(cvars.maxRotSnap:GetFloat(), DEFAULT_MAX_ROT_SNAP, 0, 180),
        maxLocalRotation = sanitizeNumber(cvars.maxLocalRotation:GetFloat(), DEFAULT_MAX_LOCAL_ROTATION, 0, 3600),
        maxGap = sanitizeNumber(cvars.maxGap:GetFloat(), DEFAULT_MAX_GAP, 0, 4096),
        maxArrayCount = sanitizeInteger(cvars.maxArrayCount:GetFloat(), DEFAULT_MAX_ARRAY_COUNT, 1, 256),
        maxArraySpacing = sanitizeNumber(cvars.maxArraySpacing:GetFloat(), DEFAULT_MAX_ARRAY_SPACING, 0, 65536),
        maxDropDistance = sanitizeNumber(cvars.maxDropDistance:GetFloat(), DEFAULT_MAX_DROP_DISTANCE, 64, 131072),
        maxEntityDistance = sanitizeNumber(cvars.maxEntityDistance:GetFloat(), DEFAULT_MAX_ENTITY_DISTANCE, 0, 131072),
        maxMoveDistance = sanitizeNumber(cvars.maxMoveDistance:GetFloat(), DEFAULT_MAX_MOVE_DISTANCE, 0, 131072),
        maxTargetDistance = sanitizeNumber(cvars.maxTargetDistance:GetFloat(), DEFAULT_MAX_TARGET_DISTANCE, 0, 131072),
        allowDuplication = cvars.allowDuplication:GetBool(),
        allowFreeze = cvars.allowFreeze:GetBool(),
        allowWeld = cvars.allowWeld:GetBool(),
        allowNocollide = cvars.allowNocollide:GetBool(),
        allowWorldConnectors = cvars.allowWorldConnectors:GetBool()
    }
end

function Utils.AllowDuplication()
    if not SERVER then
        return true
    end

    local limits = Utils.GetServerLimits()
    if not limits or not limits.validationEnabled then
        return true
    end

    return limits.allowDuplication
end

function Utils.ValidateEntityForPlayer(ply, ent)
    if not IsValid(ent) then
        return false
    end

    if SnapPoints and SnapPoints.IsSnappableEntity and not SnapPoints.IsSnappableEntity(ent) then
        return false
    end

    if not SERVER then
        return true
    end

    local limits = Utils.GetServerLimits()
    if not limits or not limits.validationEnabled then
        return true
    end

    if not IsValid(ply) then
        return false
    end

    local maxEntityDistance = limits.maxEntityDistance
    if maxEntityDistance > 0 then
        local eyePos = ply:GetShootPos()
        if not isvector(eyePos) then
            eyePos = ply:GetPos()
        end

        if eyePos:DistToSqr(ent:GetPos()) > (maxEntityDistance * maxEntityDistance) then
            return false
        end
    end

    return true
end

function Utils.ValidateTransformForPlayer(ply, ent, position, angles)
    if not IsValid(ent) then
        return false
    end

    if not isFiniteVector(position) or not isFiniteAngle(angles) then
        return false
    end

    if not SERVER then
        return true
    end

    local limits = Utils.GetServerLimits()
    if not limits or not limits.validationEnabled then
        return true
    end

    local maxMoveDistance = limits.maxMoveDistance
    if maxMoveDistance > 0 then
        local currentPos = ent:GetPos()
        if currentPos:DistToSqr(position) > (maxMoveDistance * maxMoveDistance) then
            return false
        end
    end

    if IsValid(ply) and limits.maxTargetDistance > 0 then
        local eyePos = ply:GetShootPos()
        if not isvector(eyePos) then
            eyePos = ply:GetPos()
        end

        if eyePos:DistToSqr(position) > (limits.maxTargetDistance * limits.maxTargetDistance) then
            return false
        end
    end

    return true
end

function Utils.SanitizeCommonSettings(settings)
    local out = istable(settings) and table.Copy(settings) or {}
    local limits = SERVER and Utils.GetServerLimits() or nil
    local maxGridSubdivisions = limits and limits.maxGridSubdivisions or DEFAULT_MAX_GRID_SUBDIVISIONS
    local maxLocalRotation = limits and limits.maxLocalRotation or DEFAULT_MAX_LOCAL_ROTATION
    local maxRotSnap = limits and limits.maxRotSnap or DEFAULT_MAX_ROT_SNAP

    out.reverseAxis = sanitizeBool(out.reverseAxis)
    out.gridSubdivisions = sanitizeInteger(out.gridSubdivisions, 6, 1, maxGridSubdivisions)
    out.rotSnap = sanitizeNumber(out.rotSnap, 90, 0, maxRotSnap)
    out.rotSnap = math.Clamp(math.Round(out.rotSnap / 15) * 15, 0, maxRotSnap)

    local localRotation = istable(out.localRotation) and out.localRotation or {0, 0, 0}
    out.localRotation = {
        sanitizeNumber(localRotation[1], 0, -maxLocalRotation, maxLocalRotation),
        sanitizeNumber(localRotation[2], 0, -maxLocalRotation, maxLocalRotation),
        sanitizeNumber(localRotation[3], 0, -maxLocalRotation, maxLocalRotation)
    }

    out.freezeProp = sanitizeBool(out.freezeProp)
    out.weldProp = sanitizeBool(out.weldProp)
    out.nocollidePair = sanitizeBool(out.nocollidePair)

    if SERVER and limits and limits.validationEnabled then
        if not limits.allowFreeze then
            out.freezeProp = false
        end

        if not limits.allowWeld then
            out.weldProp = false
        end

        if not limits.allowNocollide then
            out.nocollidePair = false
        end
    end

    return out
end

function Utils.ValidateSettingsForMode(modeId, settings)
    local out = Utils.SanitizeCommonSettings(settings)
    local limits = SERVER and Utils.GetServerLimits() or nil
    local maxGap = limits and limits.maxGap or DEFAULT_MAX_GAP

    if modeId == "move" then
        out.gap = sanitizeNumber(out.gap, 0, -maxGap, maxGap)
    elseif modeId == "align" then
        out.alignWorld = sanitizeBool(out.alignWorld)
    elseif modeId == "array" then
        local maxArrayCount = limits and limits.maxArrayCount or DEFAULT_MAX_ARRAY_COUNT
        local maxArraySpacing = limits and limits.maxArraySpacing or DEFAULT_MAX_ARRAY_SPACING
        out.arrayCount = sanitizeInteger(out.arrayCount, 5, 1, maxArrayCount)
        out.arraySpacing = sanitizeNumber(out.arraySpacing, 0, -maxArraySpacing, maxArraySpacing)
        out.arrayAxis = sanitizeInteger(out.arrayAxis, 1, 1, 3)
        out.reverseDirection = sanitizeBool(out.reverseDirection)
        out.useSizeGap = sanitizeBool(out.useSizeGap)
    elseif modeId == "surface_drop" then
        local maxDropDistance = limits and limits.maxDropDistance or DEFAULT_MAX_DROP_DISTANCE
        out.dropDistance = sanitizeNumber(out.dropDistance, 4096, 64, maxDropDistance)
        out.gap = sanitizeNumber(out.gap, 0, -maxGap, maxGap)
        out.alignToSurface = sanitizeBool(out.alignToSurface)
        out.invertDirection = sanitizeBool(out.invertDirection)
    elseif modeId == "push_pull" then
        out.pushPullUnits = sanitizeNumber(out.pushPullUnits, 32, 0, maxGap)
        out.pushPullDepthMult = sanitizeNumber(out.pushPullDepthMult, 100, 0, 6400)
        out.useDepthMultiplier = sanitizeBool(out.useDepthMultiplier)
        out.invertPull = sanitizeBool(out.invertPull)
    end

    return out
end

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

    return Utils.SanitizeCommonSettings({
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
    })
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

function Utils.BuildConnectorFromTrace(trace, settings, worldError, options)
    options = options or {}

    if not trace or not trace.Hit then
        return nil, "No surface was hit."
    end

    if trace.HitWorld then
        if options.allowWorld then
            if SERVER then
                local limits = Utils.GetServerLimits()
                if limits and limits.validationEnabled and not limits.allowWorldConnectors then
                    return nil, "World connectors are disabled by this server."
                end
            end

            local worldNormal = Math.SafeNormalize(trace.HitNormal, Vector(0, 0, 1))
            local worldTangentHint = Utils.ChooseStableLocalHint(worldNormal)
            local worldBasis = Math.BuildBasis(worldNormal, worldTangentHint)

            return {
                entity = nil,
                hitPosWorld = trace.HitPos,
                worldBasis = worldBasis,
                localPos = vector_origin,
                localBasis = worldBasis,
                snapData = nil,
                isWorld = true
            }
        end

        return nil, worldError or "World geometry cannot be selected as a connector."
    end

    local ent = trace.Entity
    if SERVER and IsValid(options.player) and not Utils.ValidateEntityForPlayer(options.player, ent) then
        return nil, "Target entity failed server validation."
    end

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

if CLIENT then
    local function resetConVarsToDefaults(defaults, keys)
        if not istable(defaults) or not istable(keys) then
            return
        end

        for _, key in ipairs(keys) do
            local defaultValue = defaults[key]
            if defaultValue ~= nil then
                RunConsoleCommand("micron_" .. tostring(key), tostring(defaultValue))
            end
        end
    end

    function Utils.AttachSectionResetButton(form, defaults, keys, label)
        if not IsValid(form) or not istable(keys) or #keys == 0 then
            return
        end

        local buttonLabel = label or "Reset"
        local onReset = function()
            resetConVarsToDefaults(defaults, keys)
        end

        local header = form.Header or form.header or form.m_pHeader
        if IsValid(header) then
            local button = vgui.Create("DButton", header)
            button:Dock(RIGHT)
            button:DockMargin(4, 2, 6, 2)
            button:SetWide(60)
            button:SetText(buttonLabel)
            button.DoClick = onReset
            return
        end

        local button = vgui.Create("DButton", form)
        button:SetText(buttonLabel)
        button:SetTall(20)
        button.DoClick = onReset
        form:AddItem(button)
    end
end