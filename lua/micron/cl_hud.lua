Micron = Micron or {}
Micron.Client = Micron.Client or {}

local Client = Micron.Client
local Math = Micron.Math
local SnapPoints = Micron.SnapPoints
local Registry = Micron.ModeRegistry
local Utils = Micron.ModeUtils

local sourceColor = Color(80, 200, 255, 255)
local targetColor = Color(255, 140, 90, 255)
local gridColor = Color(120, 235, 255, 145)
local outlineColor = Color(155, 245, 255, 210)
local selectedSnapColor = Color(255, 225, 130, 255)
local targetHoloColor = Color(120, 210, 245, 170)
local targetHoloDuplicateColor = Color(255, 185, 110, 190)

local DEFAULT_LOCAL_N = Vector(0, 0, 1)
local DEFAULT_LOCAL_U = Vector(1, 0, 0)

local function hasValidToolOwner(tool)
    if not tool or not tool.GetOwner then
        return false
    end

    return IsValid(tool:GetOwner())
end

local function buildConVarReader(tool, ply)
    if tool and hasValidToolOwner(tool) then
        return tool
    end

    if not IsValid(ply) then
        return nil
    end

    local reader = {}

    function reader:GetOwner()
        return ply
    end

    function reader:GetClientInfo(key)
        return ply:GetInfo("micron_" .. tostring(key)) or ""
    end

    function reader:GetClientNumber(key, defaultValue)
        return ply:GetInfoNum("micron_" .. tostring(key), tonumber(defaultValue) or 0)
    end

    return reader
end

local function drawAxisLine(startPos, axis, length, color)
    render.DrawLine(startPos, startPos + axis * length, color, true)
end

local function drawSnapData(ent, snapData)
    if not IsValid(ent) or not snapData then return end

    for _, line in ipairs(snapData.lines or {}) do
        local worldA = ent:LocalToWorld(line.a)
        local worldB = ent:LocalToWorld(line.b)
        local color = line.kind == "outline" and outlineColor or gridColor
        render.DrawLine(worldA, worldB, color, true)
    end

    local selectedIndex = snapData.selectedIndex
    local selected = selectedIndex and snapData.points[selectedIndex] or nil
    if not selected then
        return
    end

    local worldPos = ent:LocalToWorld(selected.position)
    local normalWorld = (ent:LocalToWorld(selected.position + selected.normal) - worldPos):GetNormalized()

    render.DrawSphere(worldPos, 0.85, 7, 7, selectedSnapColor)
    render.DrawLine(worldPos, worldPos + normalWorld * 7, selectedSnapColor, true)
end

local function getToolSettings(tool)
    local ply = LocalPlayer()
    local conVarReader = buildConVarReader(tool, ply)

    local modeId = ""
    if conVarReader then
        modeId = conVarReader:GetClientInfo("mode") or ""
    end

    local mode = Registry.Get(modeId)
    if not mode then
        local fallbackId = Registry.FirstId()
        mode = fallbackId and Registry.Get(fallbackId) or nil
        modeId = fallbackId or ""
    end

    local settings = {}
    if mode and mode.GetSettings and conVarReader then
        settings = mode.GetSettings(conVarReader) or {}
    end

    if Utils and Utils.ValidateSettingsForMode then
        settings = Utils.ValidateSettingsForMode(modeId, settings)
    end

    settings.modeId = modeId
    settings.gridSubdivisions = math.max(1, math.floor(tonumber(settings.gridSubdivisions or 6) or 6))
    return settings
end

local function getActiveMode(settings)
    if not Registry then
        return nil
    end

    local mode = Registry.Get(settings.modeId)
    if mode then
        return mode
    end

    local fallbackId = Registry.FirstId()
    if not fallbackId then
        return nil
    end

    return Registry.Get(fallbackId)
end

local function getSourceConnectorFromState(ply)
    if not ply:GetNW2Bool("Micron.HasSource", false) then
        return nil
    end

    local sourceEnt = ply:GetNW2Entity("Micron.SourceEnt", NULL)
    local localPos = ply:GetNW2Vector("Micron.SourceLocalPos", vector_origin)
    local localN = ply:GetNW2Vector("Micron.SourceLocalN", DEFAULT_LOCAL_N)
    local localU = ply:GetNW2Vector("Micron.SourceLocalU", DEFAULT_LOCAL_U)
    local localBasis = Math.BuildBasis(localN, localU)

    if not IsValid(sourceEnt) then
        local worldBasis = Math.BuildBasis(localBasis.n, localBasis.u)
        local hitPosWorld = ply:GetNW2Vector("Micron.SourcePos", vector_origin)

        return {
            entity = nil,
            localPos = vector_origin,
            localBasis = localBasis,
            worldBasis = worldBasis,
            hitPosWorld = hitPosWorld,
            duplicateOnApply = ply:GetNW2Bool("Micron.SourceDuplicateOnApply", false),
            isWorld = ply:GetNW2Bool("Micron.SourceIsWorld", false)
        }
    end

    local worldNormal = Math.LocalDirToWorld(sourceEnt, localBasis.n)
    local worldTangent = Math.LocalDirToWorld(sourceEnt, localBasis.u)
    local worldBasis = Math.BuildBasis(worldNormal, worldTangent)

    return {
        entity = sourceEnt,
        localPos = localPos,
        localBasis = localBasis,
        worldBasis = worldBasis,
        hitPosWorld = sourceEnt:LocalToWorld(localPos),
        duplicateOnApply = ply:GetNW2Bool("Micron.SourceDuplicateOnApply", false)
    }
end

local function computePreviewSolve(tool, ply, sourceConnector, settings)
    local mode = getActiveMode(settings)
    if not mode or not mode.BuildConnector or not mode.Solve then
        return nil
    end

    if mode.RequiresTargetConnector == false then
        local solve = mode.Solve(sourceConnector, nil, settings, { rotation = {0, 0, 0} })
        if not solve then
            return nil
        end

        return solve
    end

    local trace = ply:GetEyeTrace()
    if not trace or not trace.Hit then
        return nil
    end

    local targetConnector = mode.BuildConnector(ply, trace, settings)
    if not targetConnector then
        return nil
    end

    if targetConnector.entity == sourceConnector.entity then
        local shouldDuplicate = ply:KeyDown(IN_SPEED) and true or false
        local sourceClickDuplicate = sourceConnector.duplicateOnApply and true or false
        if mode.LatchDuplicateOnSource then
            shouldDuplicate = sourceClickDuplicate or shouldDuplicate
        end

        local allowSelfTarget = mode.AllowSelfTargetWhenDuplicating and shouldDuplicate
        if not allowSelfTarget then
            return nil
        end
    end

    local solve = mode.Solve(sourceConnector, targetConnector, settings, { rotation = {0, 0, 0} })
    if not solve then
        return nil
    end

    return solve
end

local function drawPreviewGhost(solve)
    if not solve or not IsValid(solve.entity) then
        return
    end

    local modelName = solve.entity:GetModel()
    if not isstring(modelName) or modelName == "" then
        return
    end

    render.SetBlend(0.35)
    render.Model({
        model = modelName,
        pos = solve.position,
        angle = solve.angles,
        skin = solve.entity:GetSkin() or 0
    })
    render.SetBlend(1)
end

local function drawPreviewGhosts(sourceEnt, ghosts)
    if not IsValid(sourceEnt) or not istable(ghosts) or #ghosts == 0 then
        return
    end

    local modelName = sourceEnt:GetModel()
    if not isstring(modelName) or modelName == "" then
        return
    end

    local skin = sourceEnt:GetSkin() or 0
    local maxGhosts = math.min(#ghosts, 64)

    for i = 1, maxGhosts do
        local ghost = ghosts[i]
        if ghost and ghost.position and ghost.angles then
            local blend = math.max(0.14, 0.32 - (i - 1) * 0.008)
            render.SetBlend(blend)
            render.Model({
                model = modelName,
                pos = ghost.position,
                angle = ghost.angles,
                skin = skin
            })
        end
    end

    render.SetBlend(1)
end

local function shouldPreviewDuplicate(ply, mode, sourceConnector)
    if not mode then
        return false
    end

    if mode.AlwaysDuplicate then
        return true
    end

    local shouldDuplicate = ply:KeyDown(IN_SPEED) and true or false
    local sourceClickDuplicate = sourceConnector and (sourceConnector.duplicateOnApply and true or false) or false

    if mode.DuplicateFromSourceOnly then
        shouldDuplicate = sourceClickDuplicate
    end

    if mode.LatchDuplicateOnSource and sourceConnector then
        shouldDuplicate = sourceClickDuplicate or shouldDuplicate

        if mode.DuplicateFromSourceOnly then
            shouldDuplicate = sourceClickDuplicate
        end
    end

    if mode.InvertDuplicateInput then
        shouldDuplicate = not shouldDuplicate
    end

    return shouldDuplicate
end

local function updateTargetHoloState(ent, isDuplicate)
    if not IsValid(ent) then
        Client._targetHoloEnt = nil
        Client._targetHoloColor = nil
        return
    end

    Client._targetHoloEnt = ent
    Client._targetHoloColor = isDuplicate and targetHoloDuplicateColor or targetHoloColor
end

if CLIENT and not Client._targetHoloHookInstalled then
    hook.Add("PreDrawHalos", "Micron.TargetHolo", function()
        local ply = LocalPlayer()
        if not IsValid(ply) then
            updateTargetHoloState(nil, false)
            return
        end

        local activeWeapon = ply:GetActiveWeapon()
        if not IsValid(activeWeapon) or activeWeapon:GetClass() ~= "gmod_tool" then
            updateTargetHoloState(nil, false)
            return
        end

        local activeTool = ply.GetTool and ply:GetTool() or nil
        if not activeTool or activeTool.Mode ~= "micron" then
            updateTargetHoloState(nil, false)
            return
        end

        local ent = Client._targetHoloEnt
        if not IsValid(ent) then
            return
        end

        local color = Client._targetHoloColor or targetHoloColor
        halo.Add({ ent }, color, 2, 2, 2, true, true)
    end)

    Client._targetHoloHookInstalled = true
end

function Client.RenderWorld(tool)
    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    updateTargetHoloState(nil, false)

    local settings = getToolSettings(tool)
    local mode = getActiveMode(settings)
    local sourceConnector = getSourceConnectorFromState(ply)

    local trace = ply:GetEyeTrace()
    local hoverConnector = nil
    if not sourceConnector and mode and mode.PreviewFromTraceWhenIdle and mode.BuildConnector and trace and trace.Hit and not trace.HitWorld then
        hoverConnector = mode.BuildConnector(ply, trace, settings)
    end

    local previewConnector = sourceConnector or hoverConnector

    if previewConnector and IsValid(previewConnector.entity) then
        local duplicatePreview = shouldPreviewDuplicate(ply, mode, previewConnector)
        updateTargetHoloState(previewConnector.entity, duplicatePreview)
    end

    if trace and trace.Hit then
        local len = 8
        drawAxisLine(trace.HitPos, trace.HitNormal:GetNormalized(), len, targetColor)

        if not (mode and mode.DisableSnapVisualization) and not trace.HitWorld and SnapPoints and SnapPoints.IsSnappableEntity(trace.Entity) then
            local snapData = SnapPoints.ComputeForEntity(trace.Entity, trace.HitPos, trace.HitNormal, settings.gridSubdivisions)
            if snapData then
                drawSnapData(trace.Entity, snapData)
            end
        end
    end

    if not previewConnector then
        return
    end

    local sourcePos = previewConnector.hitPosWorld
    local sourceNormal = previewConnector.worldBasis and previewConnector.worldBasis.n or vector_origin
    if IsValid(previewConnector.entity) then
        sourcePos = previewConnector.entity:LocalToWorld(previewConnector.localPos)
        sourceNormal = Math.LocalDirToWorld(previewConnector.entity, previewConnector.localBasis.n)
    end

    if sourceNormal:LengthSqr() <= 0 then
        return
    end

    drawAxisLine(sourcePos, sourceNormal:GetNormalized(), 10, sourceColor)

    if mode and mode.DrawSourceOverlay then
        mode.DrawSourceOverlay(previewConnector, settings, trace, ply)
    end

    if mode and mode.GetPreviewGhosts then
        local ghosts = mode.GetPreviewGhosts(previewConnector, settings)
        drawPreviewGhosts(previewConnector.entity, ghosts)
    else
        local solve = computePreviewSolve(tool, ply, previewConnector, settings)
        drawPreviewGhost(solve)
    end
end

function Client.DrawHUD(tool)
    return
end
