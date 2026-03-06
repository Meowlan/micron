Micron = Micron or {}
Micron.ModeRegistry = Micron.ModeRegistry or {}

local Registry = Micron.ModeRegistry
Registry._modes = Registry._modes or {}
Registry._registeredClientConVars = Registry._registeredClientConVars or {}
Registry._sortedIds = Registry._sortedIds or nil

local function invalidateSortedIds()
    Registry._sortedIds = nil
end

local function getSortedIds()
    if istable(Registry._sortedIds) then
        return Registry._sortedIds
    end

    local ids = {}

    for id, _ in pairs(Registry._modes) do
        ids[#ids + 1] = id
    end

    table.sort(ids)
    Registry._sortedIds = ids
    return ids
end

local function registerModeClientConVars(modeDef)
    if not CLIENT then
        return
    end

    if not istable(modeDef.ClientConVarDefaults) then
        return
    end

    for key, defaultValue in pairs(modeDef.ClientConVarDefaults) do
        local cvarName = "micron_" .. tostring(key)
        if not Registry._registeredClientConVars[cvarName] then
            CreateClientConVar(cvarName, tostring(defaultValue), true, true)
            Registry._registeredClientConVars[cvarName] = true
        end
    end
end

function Registry.Register(id, modeDef)
    if not isstring(id) or id == "" then
        error("Micron mode id must be a non-empty string")
    end

    if not istable(modeDef) then
        error("Micron mode definition must be a table")
    end

    if not isfunction(modeDef.BuildConnector) then
        error("Micron mode '" .. id .. "' is missing required function: BuildConnector")
    end

    if not isfunction(modeDef.Solve) then
        error("Micron mode '" .. id .. "' is missing required function: Solve")
    end

    if Registry._modes[id] then
        error("Micron mode '" .. id .. "' is already registered")
    end

    if not isstring(modeDef.DisplayName) or modeDef.DisplayName == "" then
        modeDef.DisplayName = id
    end

    if not isstring(modeDef.Description) then
        modeDef.Description = ""
    end

    modeDef.id = id
    Registry._modes[id] = modeDef
    invalidateSortedIds()
    registerModeClientConVars(modeDef)
end

function Registry.Get(id)
    return Registry._modes[id]
end

function Registry.FirstId()
    local ids = getSortedIds()
    return ids[1]
end

function Registry.ListIds()
    local sorted = getSortedIds()
    local ids = {}

    for i = 1, #sorted do
        ids[i] = sorted[i]
    end

    return ids
end
