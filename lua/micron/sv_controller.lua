Micron = Micron or {}
Micron.Controller = Micron.Controller or {}

local Controller = Micron.Controller
local Registry = Micron.ModeRegistry
local Math = Micron.Math
local Utils = Micron.ModeUtils

Controller._states = Controller._states or setmetatable({}, { __mode = "k" })

local function getModeId(tool)
    local requested = tool:GetClientInfo("mode")
    if requested and requested ~= "" and Registry.Get(requested) then
        return requested
    end

    return Registry.FirstId()
end

local function getState(ply)
    local state = Controller._states[ply]
    if state then
        return state
    end

    state = {
        modeId = nil,
        source = nil,
        duplicateOnApply = nil
    }

    Controller._states[ply] = state
    return state
end

local function connectorHasEntity(source)
    return source and IsValid(source.entity)
end

local function connectorHasWorldSnapshot(source)
    return source and source.hitPosWorld and source.worldBasis and source.worldBasis.n and source.worldBasis.u
end

local function connectorIsUsable(source)
    return connectorHasEntity(source) or connectorHasWorldSnapshot(source)
end

local function updateClientState(ply, state)
    if not IsValid(ply) then return end

    local source = state and state.source or nil
    local hasSource = connectorIsUsable(source)
    ply:SetNW2Bool("Micron.HasSource", hasSource and true or false)

    if hasSource then
        if connectorHasEntity(source) then
            local ent = source.entity
            local sourceLocalPos = source.localPos or vector_origin
            local sourceLocalBasis = source.localBasis or Math.BuildBasis(Vector(0, 0, 1), Vector(1, 0, 0))
            local worldPos = ent:LocalToWorld(sourceLocalPos)
            local worldNormal = Math.LocalDirToWorld(ent, sourceLocalBasis.n)

            ply:SetNW2Vector("Micron.SourcePos", worldPos)
            ply:SetNW2Vector("Micron.SourceNormal", worldNormal)
            ply:SetNW2Entity("Micron.SourceEnt", ent)
            ply:SetNW2Bool("Micron.SourceIsWorld", false)
            ply:SetNW2Vector("Micron.SourceLocalPos", sourceLocalPos)
            ply:SetNW2Vector("Micron.SourceLocalN", sourceLocalBasis.n)
            ply:SetNW2Vector("Micron.SourceLocalU", sourceLocalBasis.u)
        else
            local worldBasis = Math.BuildBasis(source.worldBasis.n, source.worldBasis.u)
            local worldPos = source.hitPosWorld or vector_origin

            ply:SetNW2Vector("Micron.SourcePos", worldPos)
            ply:SetNW2Vector("Micron.SourceNormal", worldBasis.n)
            ply:SetNW2Entity("Micron.SourceEnt", NULL)
            ply:SetNW2Bool("Micron.SourceIsWorld", true)
            ply:SetNW2Vector("Micron.SourceLocalPos", vector_origin)
            ply:SetNW2Vector("Micron.SourceLocalN", worldBasis.n)
            ply:SetNW2Vector("Micron.SourceLocalU", worldBasis.u)
        end

        ply:SetNW2String("Micron.SourceMode", state.modeId or "")
        ply:SetNW2Bool("Micron.SourceDuplicateOnApply", state.duplicateOnApply and true or false)
    else
        ply:SetNW2Vector("Micron.SourcePos", vector_origin)
        ply:SetNW2Vector("Micron.SourceNormal", vector_origin)
        ply:SetNW2Entity("Micron.SourceEnt", NULL)
        ply:SetNW2Bool("Micron.SourceIsWorld", false)
        ply:SetNW2Vector("Micron.SourceLocalPos", vector_origin)
        ply:SetNW2Vector("Micron.SourceLocalN", vector_origin)
        ply:SetNW2Vector("Micron.SourceLocalU", vector_origin)
        ply:SetNW2String("Micron.SourceMode", "")
        ply:SetNW2Bool("Micron.SourceDuplicateOnApply", false)
    end
end

local function resetState(ply)
    local state = getState(ply)
    state.source = nil
    state.duplicateOnApply = nil
    updateClientState(ply, state)
end

local function getModeSettings(mode, tool)
    local settings = {}

    if mode and mode.GetSettings then
        local fromMode = mode.GetSettings(tool)
        if istable(fromMode) then
            settings = fromMode
        end
    end

    if Utils and Utils.ValidateSettingsForMode then
        settings = Utils.ValidateSettingsForMode(mode and mode.id or "", settings)
    end

    return settings
end

local function ensureModeState(tool, ply)
    local state = getState(ply)
    local modeId = getModeId(tool)

    if modeId ~= state.modeId then
        state.modeId = modeId
        state.source = nil
        state.duplicateOnApply = nil
    end

    local mode = Registry.Get(modeId)
    return mode, state
end

local function createUndoForMove(ply, ent, oldPos, oldAng, oldMotionEnabled, createdConstraints, removeEntityOnUndo)
    undo.Create("Micron Snap")
    undo.SetPlayer(ply)

    if removeEntityOnUndo and IsValid(ent) then
        undo.AddEntity(ent)
        cleanup.Add(ply, "props", ent)
    end

    if createdConstraints then
        for _, created in ipairs(createdConstraints) do
            if IsValid(created) then
                undo.AddEntity(created)
                cleanup.Add(ply, "constraints", created)
            end
        end
    end

    if not removeEntityOnUndo then
        undo.AddFunction(function(_, movedEnt, revertPos, revertAng)
            if not IsValid(movedEnt) then return end

            movedEnt:SetAngles(revertAng)
            movedEnt:SetPos(revertPos)

            local phys = movedEnt:GetPhysicsObject()
            if IsValid(phys) then
                phys:SetAngles(revertAng)
                phys:SetPos(revertPos)
                if oldMotionEnabled ~= nil then
                    phys:EnableMotion(oldMotionEnabled)
                end
                phys:Wake()
            end
        end, ent, oldPos, oldAng)
    end

    undo.Finish()
end

local function duplicateEntityForSnap(ply, sourceEnt)
    if not IsValid(sourceEnt) then
        return nil, "Source entity is invalid."
    end

    local ok, entTable = pcall(duplicator.CopyEntTable, sourceEnt)
    if ok and istable(entTable) then
        local createOk, created = pcall(duplicator.CreateEntityFromTable, ply, entTable)
        if createOk and IsValid(created) then
            created:SetPos(sourceEnt:GetPos())
            created:SetAngles(sourceEnt:GetAngles())
            created:Activate()
            return created
        end
    end

    local className = sourceEnt:GetClass()
    local modelName = sourceEnt:GetModel()
    if not className or className == "" or not modelName or modelName == "" then
        return nil, "Source entity cannot be duplicated."
    end

    local created = ents.Create(className)
    if not IsValid(created) then
        return nil, "Failed to create duplicated entity."
    end

    created:SetModel(modelName)
    created:SetPos(sourceEnt:GetPos())
    created:SetAngles(sourceEnt:GetAngles())
    created:Spawn()
    created:Activate()

    if created.SetSkin and sourceEnt.GetSkin then
        created:SetSkin(sourceEnt:GetSkin() or 0)
    end

    if created.SetMaterial and sourceEnt.GetMaterial then
        created:SetMaterial(sourceEnt:GetMaterial() or "")
    end

    if created.SetColor and sourceEnt.GetColor then
        created:SetColor(sourceEnt:GetColor())
    end

    if created.SetRenderMode and sourceEnt.GetRenderMode then
        created:SetRenderMode(sourceEnt:GetRenderMode())
    end

    if created.SetRenderFX and sourceEnt.GetRenderFX then
        created:SetRenderFX(sourceEnt:GetRenderFX())
    end

    if created.SetModelScale and sourceEnt.GetModelScale then
        created:SetModelScale(sourceEnt:GetModelScale(), 0)
    end

    if created.SetCollisionGroup and sourceEnt.GetCollisionGroup then
        created:SetCollisionGroup(sourceEnt:GetCollisionGroup())
    end

    if created.GetNumBodyGroups and sourceEnt.GetNumBodyGroups and created.SetBodygroup and sourceEnt.GetBodygroup then
        local count = math.max(0, sourceEnt:GetNumBodyGroups() - 1)
        for i = 0, count do
            created:SetBodygroup(i, sourceEnt:GetBodygroup(i))
        end
    end

    cleanup.Add(ply, "props", created)
    return created
end

local function buildModeApplyHelpers(ply)
    return {
        duplicateEntityForSnap = duplicateEntityForSnap,
        validateTransform = function(ent, pos, ang)
            if not Utils or not Utils.ValidateTransformForPlayer then
                return true
            end

            return Utils.ValidateTransformForPlayer(ply, ent, pos, ang)
        end,
        allowDuplication = function()
            if not Utils or not Utils.AllowDuplication then
                return true
            end

            return Utils.AllowDuplication()
        end
    }
end

local function applyPostSnapOptions(sourceConnector, targetConnector, settings)
    local sourceEnt = sourceConnector.entity
    local targetEnt = targetConnector and targetConnector.entity or nil
    local created = {}

    if settings.freezeProp then
        local phys = sourceEnt:GetPhysicsObject()
        if IsValid(phys) then
            phys:EnableMotion(false)
            phys:Wake()
        end
    end

    if settings.weldProp and IsValid(targetEnt) then
        local weld = constraint.Weld(sourceEnt, targetEnt, 0, 0, 0, false, false)
        if IsValid(weld) then
            created[#created + 1] = weld
        end
    end

    if settings.nocollidePair and IsValid(targetEnt) then
        local nocollide = constraint.NoCollide(sourceEnt, targetEnt, 0, 0)
        if IsValid(nocollide) then
            created[#created + 1] = nocollide
        end
    end

    return created
end

local function resolveDuplicateStateForApply(mode, state, applyClickDuplicate)
    local sourceClickDuplicate = state.duplicateOnApply and true or false
    local shouldDuplicate = applyClickDuplicate and true or false

    if mode.LatchDuplicateOnSource then
        if mode.DuplicateFromSourceOnly then
            state.duplicateOnApply = sourceClickDuplicate
            shouldDuplicate = sourceClickDuplicate
        else
            state.duplicateOnApply = sourceClickDuplicate or applyClickDuplicate
            shouldDuplicate = state.duplicateOnApply and true or false
        end
    elseif mode.DuplicateFromSourceOnly then
        shouldDuplicate = sourceClickDuplicate
    end

    if mode.AlwaysDuplicate then
        shouldDuplicate = true
    end

    if mode.InvertDuplicateInput then
        shouldDuplicate = not shouldDuplicate
    end

    if shouldDuplicate and Utils and Utils.AllowDuplication and not Utils.AllowDuplication() then
        shouldDuplicate = false
    end

    return shouldDuplicate, sourceClickDuplicate
end

local function applySolvedTransform(ply, state, solve, targetConnector, settings, shouldDuplicate)
    local sourceEnt = solve.entity
    if not IsValid(sourceEnt) then
        return false
    end

    if Utils and Utils.ValidateEntityForPlayer and not Utils.ValidateEntityForPlayer(ply, sourceEnt) then
        return false
    end

    if Utils and Utils.ValidateTransformForPlayer and not Utils.ValidateTransformForPlayer(ply, sourceEnt, solve.position, solve.angles) then
        return false
    end

    local ent = sourceEnt

    if shouldDuplicate then
        local duplicated = duplicateEntityForSnap(ply, sourceEnt)
        if not IsValid(duplicated) then
            return false
        end

        if Utils and Utils.ValidateTransformForPlayer and not Utils.ValidateTransformForPlayer(ply, duplicated, solve.position, solve.angles) then
            duplicated:Remove()
            return false
        end

        ent = duplicated
    end

    local oldPos = ent:GetPos()
    local oldAng = ent:GetAngles()
    local oldMotionEnabled = nil

    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        oldMotionEnabled = phys:IsMotionEnabled()
    end

    ent:SetAngles(solve.angles)
    ent:SetPos(solve.position)

    phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetAngles(solve.angles)
        phys:SetPos(solve.position)
        phys:Wake()
    end

    local sourceConnectorForPost = {
        entity = ent,
        localPos = state.source.localPos
    }

    local createdConstraints = applyPostSnapOptions(sourceConnectorForPost, targetConnector, settings)
    createUndoForMove(ply, ent, oldPos, oldAng, oldMotionEnabled, createdConstraints, shouldDuplicate)

    return true
end

function Controller.LeftClick(tool, trace)
    local ply = tool:GetOwner()
    if not IsValid(ply) then return false end

    local mode, state = ensureModeState(tool, ply)
    if not mode then
        return false
    end

    local settings = getModeSettings(mode, tool)

    if not state.source then
        local sourceConnector = mode.BuildConnector(ply, trace, settings)
        if not sourceConnector then
            return false
        end

        if sourceConnector.entity and Utils and Utils.ValidateEntityForPlayer and not Utils.ValidateEntityForPlayer(ply, sourceConnector.entity) then
            return false
        end

        state.source = sourceConnector
        if mode.LatchDuplicateOnSource then
            state.duplicateOnApply = ply:KeyDown(IN_SPEED) and true or false
        else
            state.duplicateOnApply = nil
        end

        local instantApply = false
        if mode.ApplyOnSourceSelection ~= nil then
            if isfunction(mode.ApplyOnSourceSelection) then
                instantApply = mode.ApplyOnSourceSelection(state, settings, tool, ply) and true or false
            else
                instantApply = mode.ApplyOnSourceSelection and true or false
            end
        end

        if instantApply then
            local shouldDuplicate = resolveDuplicateStateForApply(mode, state, ply:KeyDown(IN_SPEED) and true or false)
            local helpers = buildModeApplyHelpers(ply)

            if mode.Apply then
                local handled = mode.Apply(tool, ply, state, settings, nil, shouldDuplicate, helpers)
                if handled ~= nil then
                    if handled then
                        if mode.PreserveSourceAfterApply then
                            updateClientState(ply, state)
                        else
                            resetState(ply)
                        end
                    end
                    return handled and true or false
                end
            end

            local solve = mode.Solve(state.source, nil, settings, { rotation = {0, 0, 0} })
            if not solve then
                resetState(ply)
                return false
            end

            local applied = applySolvedTransform(ply, state, solve, nil, settings, shouldDuplicate)
            if applied then
                if mode.PreserveSourceAfterApply then
                    updateClientState(ply, state)
                else
                    resetState(ply)
                end
            else
                resetState(ply)
            end
            return applied
        end

        updateClientState(ply, state)
        return true
    end

    local targetConnector = nil
    if mode.RequiresTargetConnector ~= false then
        targetConnector = mode.BuildConnector(ply, trace, settings)
        if not targetConnector then
            return false
        end

        if targetConnector.entity and Utils and Utils.ValidateEntityForPlayer and not Utils.ValidateEntityForPlayer(ply, targetConnector.entity) then
            return false
        end
    end

    if not connectorIsUsable(state.source) then
        resetState(ply)
        return false
    end

    local shouldDuplicate, _ = resolveDuplicateStateForApply(mode, state, ply:KeyDown(IN_SPEED) and true or false)

    if targetConnector and IsValid(state.source.entity) and IsValid(targetConnector.entity) and state.source.entity == targetConnector.entity then
        local allowSelfTarget = mode.AllowSelfTargetWhenDuplicating and shouldDuplicate
        if not allowSelfTarget then
            return false
        end
    end

    if mode.Apply then
        local handled = mode.Apply(tool, ply, state, settings, targetConnector, shouldDuplicate, buildModeApplyHelpers(ply))

        if handled ~= nil then
            if handled then
                if mode.PreserveSourceAfterApply then
                    updateClientState(ply, state)
                else
                    resetState(ply)
                end
            end
            return handled and true or false
        end
    end

    local solve = mode.Solve(state.source, targetConnector, settings, { rotation = {0, 0, 0} })
    if not solve then
        return false
    end

    local applied = applySolvedTransform(ply, state, solve, targetConnector, settings, shouldDuplicate)
    if not applied then
        if not mode.PreserveSourceAfterApply then
            resetState(ply)
        else
            updateClientState(ply, state)
        end
        return false
    end

    if mode.PreserveSourceAfterApply then
        updateClientState(ply, state)
    else
        resetState(ply)
    end
    return true
end

function Controller.RightClick(tool)
    local ply = tool:GetOwner()
    if not IsValid(ply) then return false end

    local mode, state = ensureModeState(tool, ply)
    if not mode then
        return false
    end

    if ply:KeyDown(IN_USE) then
        resetState(ply)
        return true
    end

    local settings = getModeSettings(mode, tool)
    if mode and mode.OnRightClick then
        local handled = mode.OnRightClick(tool, ply, state, settings)
        if handled ~= nil then
            return handled and true or false
        end
    end

    return false
end

local function resolveRotationAxis(ply)
    if ply:KeyDown(IN_WALK) then
        return 3
    end

    if ply:KeyDown(IN_SPEED) then
        return 2
    end

    return 1
end

local function resolveRotationDirection(ply)
    if ply:KeyDown(IN_DUCK) then
        return -1
    end

    return 1
end

function Controller.RotateFromInput(tool)
    local ply = tool:GetOwner()
    if not IsValid(ply) then return false end

    local mode, state = ensureModeState(tool, ply)
    if not mode then
        return false
    end

    local settings = getModeSettings(mode, tool)
    local axis = resolveRotationAxis(ply)
    local direction = resolveRotationDirection(ply)
    if mode.OnRotateInput then
        local handled = mode.OnRotateInput(tool, ply, state, settings, axis, direction)
        if handled ~= nil then
            return handled and true or false
        end
    end

    return false
end

function Controller.ResetPlayerState(ply)
    if not IsValid(ply) then return end

    Controller._states[ply] = nil
    ply:SetNW2Bool("Micron.HasSource", false)
    ply:SetNW2Vector("Micron.SourcePos", vector_origin)
    ply:SetNW2Vector("Micron.SourceNormal", vector_origin)
    ply:SetNW2Entity("Micron.SourceEnt", NULL)
    ply:SetNW2Bool("Micron.SourceIsWorld", false)
    ply:SetNW2Vector("Micron.SourceLocalPos", vector_origin)
    ply:SetNW2Vector("Micron.SourceLocalN", vector_origin)
    ply:SetNW2Vector("Micron.SourceLocalU", vector_origin)
    ply:SetNW2String("Micron.SourceMode", "")
    ply:SetNW2Bool("Micron.SourceDuplicateOnApply", false)
end

hook.Add("PlayerDisconnected", "Micron.ControllerCleanup", function(ply)
    if not Micron or not Micron.Controller or not Micron.Controller.ResetPlayerState then
        return
    end

    Micron.Controller.ResetPlayerState(ply)
end)

function Controller.Reload(tool)
    if not tool or not tool.GetOwner then
        return false
    end

    local ply = tool:GetOwner()
    if not IsValid(ply) then
        return false
    end

    local mode, state = ensureModeState(tool, ply)
    if mode and mode.OnReload then
        local settings = getModeSettings(mode, tool)
        local handled = mode.OnReload(tool, ply, state, settings)
        if handled ~= nil then
            return false
        end
    end

    Controller.RotateFromInput(tool)
    return false
end
