Micron = Micron or {}
Micron.CPanel = Micron.CPanel or {}

local CPanel = Micron.CPanel
local Registry = Micron.ModeRegistry

local function safeModeIdFromConVar()
    local cvar = GetConVar("micron_mode")
    local modeId = cvar and cvar:GetString() or ""

    if modeId ~= "" and Registry.Get(modeId) then
        return modeId
    end

    return Registry.FirstId()
end

local function buildModeCombo(parent)
    local combo = parent:ComboBox("Mode", "micron_mode")
    combo:SetSortItems(false)
    return combo
end

local function addModeHost(parent)
    local host = vgui.Create("DPanel", parent)
    host:SetTall(560)

    parent:AddItem(host)
    return host
end

local function mountModePanel(state, modeId)
    if IsValid(state.activePanel) then
        state.activePanel:Remove()
        state.activePanel = nil
    end

    if not IsValid(state.modeHost) then
        return
    end

    local mode = Registry.Get(modeId)
    if not mode then
        local fallback = vgui.Create("DLabel", state.modeHost)
        fallback:Dock(FILL)
        fallback:SetContentAlignment(5)
        fallback:SetWrap(true)
        fallback:SetText("No panel is available for this mode.")
        state.activePanel = fallback
        return
    end

    local panelClass = mode.PanelClass
    if not panelClass or not vgui.GetControlTable(panelClass) then
        local fallback = vgui.Create("DLabel", state.modeHost)
        fallback:Dock(FILL)
        fallback:SetContentAlignment(5)
        fallback:SetWrap(true)
        fallback:SetText("This mode has no registered VGUI panel class.")
        state.activePanel = fallback
        return
    end

    local modePanel = vgui.Create(panelClass, state.modeHost)
    modePanel:Dock(FILL)
    state.activePanel = modePanel

    if modePanel.GetPreferredHeight then
        state.modeHost:SetTall(math.max(220, modePanel:GetPreferredHeight()))
    end

    if modePanel.SetModeDefinition then
        modePanel:SetModeDefinition(mode)
    end
end

function CPanel.Build(panel)
    panel:ClearControls()

    local state = panel.MicronCPanelState or {
        currentModeId = nil,
        modeHost = nil,
        modeCombo = nil,
        activePanel = nil
    }

    panel.MicronCPanelState = state

    panel:AddControl("Header", {
        Text = "#tool.micron.name",
        Description = "#tool.micron.desc"
    })

    local combo = buildModeCombo(panel)

    local ids = Registry.ListIds()
    for _, modeId in ipairs(ids) do
        local modeDef = Registry.Get(modeId)
        combo:AddChoice(modeDef.DisplayName or modeId, modeId)
    end

    combo.OnSelect = function(_, _, _, data)
        if not data then return end
        RunConsoleCommand("micron_mode", data)
    end

    state.modeCombo = combo
    state.modeHost = addModeHost(panel)

    state.currentModeId = safeModeIdFromConVar()
    if state.currentModeId then
        local activeMode = Registry.Get(state.currentModeId)
        if activeMode then
            combo:SetValue(activeMode.DisplayName or state.currentModeId)
        end
    end

    mountModePanel(state, state.currentModeId)

    panel.Think = function(self)
        local selfState = self.MicronCPanelState
        if not selfState then return end

        local liveModeId = safeModeIdFromConVar()
        if liveModeId ~= selfState.currentModeId then
            selfState.currentModeId = liveModeId
            local mode = Registry.Get(liveModeId)
            if mode and IsValid(selfState.modeCombo) then
                selfState.modeCombo:SetValue(mode.DisplayName or liveModeId)
            end
            mountModePanel(selfState, liveModeId)
        end
    end
end
