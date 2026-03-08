local FileName = "micron"

TOOL.Category = "Construction"
TOOL.Name = "#tool." .. FileName .. ".name"
TOOL.Command = nil
TOOL.ConfigName = ""

TOOL.ClientConVar = {
	mode = ""
}

local function sortedFileList(pattern)
	local files = file.Find(pattern, "LUA") or {}
	table.sort(files)
	return files
end

local function includeModeFiles()
	local modeRoot = "micron/modes/"
	local shared = sortedFileList(modeRoot .. "sh_*.lua")
	local client = sortedFileList(modeRoot .. "cl_*.lua")
	local server = sortedFileList(modeRoot .. "sv_*.lua")

	if SERVER then
		for _, name in ipairs(shared) do
			AddCSLuaFile(modeRoot .. name)
		end

		for _, name in ipairs(client) do
			AddCSLuaFile(modeRoot .. name)
		end
	end

	for _, name in ipairs(shared) do
		include(modeRoot .. name)
	end

	if CLIENT then
		for _, name in ipairs(client) do
			include(modeRoot .. name)
		end
	end

	if SERVER then
		for _, name in ipairs(server) do
			include(modeRoot .. name)
		end
	end
end

if SERVER then
	AddCSLuaFile("micron/sh_math.lua")
	AddCSLuaFile("micron/sh_snap_points.lua")
	AddCSLuaFile("micron/sh_mode_registry.lua")
	AddCSLuaFile("micron/sh_mode_utils.lua")
	AddCSLuaFile("micron/cl_cpanel.lua")
	AddCSLuaFile("micron/cl_hud.lua")
end

include("micron/sh_math.lua")
include("micron/sh_snap_points.lua")
include("micron/sh_mode_registry.lua")
include("micron/sh_mode_utils.lua")
includeModeFiles()

local defaultModeId = ""
if Micron and Micron.ModeRegistry then
	if Micron.ModeRegistry.Get and Micron.ModeRegistry.Get("move") then
		defaultModeId = "move"
	elseif Micron.ModeRegistry.FirstId then
		defaultModeId = Micron.ModeRegistry.FirstId() or ""
	end
end
TOOL.ClientConVar.mode = defaultModeId

if SERVER then
	include("micron/sv_controller.lua")
end

if CLIENT then
	include("micron/cl_cpanel.lua")
	include("micron/cl_hud.lua")
end

if CLIENT then
	language.Add("tool." .. FileName .. ".name", "Micron")
	language.Add("tool." .. FileName .. ".desc", "")
	language.Add("tool." .. FileName .. ".0", "Read the mode descriptions for instructions on how to use each mode.")
end

local function getController()
	return Micron and Micron.Controller
end

local function callController(actionName, tool, trace)
	if CLIENT then
		return true
	end

	local controller = getController()
	if not controller then
		return false
	end

	local action = controller[actionName]
	if not isfunction(action) then
		return false
	end

	return action(tool, trace)
end

local function getRenderHookId(tool)
	if not tool then
		return "Micron.Render"
	end

	local owner = tool:GetOwner()
	if IsValid(owner) then
		return "Micron.Render." .. owner:EntIndex()
	end

	return "Micron.Render"
end

local function attachRenderHook(tool)
	local hookId = getRenderHookId(tool)
	hook.Add("PostDrawOpaqueRenderables", hookId, function()
		if not Micron or not Micron.Client or not Micron.Client.RenderWorld then
			return
		end

		tool:Render()
	end)
end

function TOOL:Deploy()
	if CLIENT then
		attachRenderHook(self)

		local snapEnabledConVar = GetConVar("snap_enabled")
		self._micronRestoreSnapEnabled = false
		if snapEnabledConVar and snapEnabledConVar:GetBool() then
			self._micronRestoreSnapEnabled = true
			RunConsoleCommand("snap_enabled", "0")
		end
	end

	return true
end

function TOOL:Holster()
	if CLIENT then
		hook.Remove("PostDrawOpaqueRenderables", getRenderHookId(self))

		if self._micronRestoreSnapEnabled then
			RunConsoleCommand("snap_enabled", "1")
		end
		self._micronRestoreSnapEnabled = false
	end

	if SERVER then
		local controller = getController()
		if controller then
			controller.ResetPlayerState(self:GetOwner())
		end
	end

	return true
end

function TOOL:LeftClick(trace)
	return callController("LeftClick", self, trace)
end

function TOOL:RightClick(trace)
	return callController("RightClick", self, trace)
end

function TOOL:Reload(trace)
	return callController("Reload", self, trace)
end

function TOOL:Think()
	if CLIENT then
		local hookId = getRenderHookId(self)
		local hookTable = hook.GetTable()
		local renderHooks = hookTable and hookTable.PostDrawOpaqueRenderables or nil
		if not renderHooks or not renderHooks[hookId] then
			attachRenderHook(self)
		end
	end
end

function TOOL:Render()
	if not Micron or not Micron.Client or not Micron.Client.RenderWorld then
		return
	end

	if not IsValid(self:GetWeapon()) then
		return
	end

	local owner = self.GetOwner and self:GetOwner() or nil
	if not IsValid(owner) then
		return
	end

	local activeWeapon = owner:GetActiveWeapon()
	if not IsValid(activeWeapon) or activeWeapon:GetClass() ~= "gmod_tool" then
		return
	end

	local activeTool = owner.GetTool and owner:GetTool() or nil
	if not activeTool or activeTool.Mode ~= FileName then
		return
	end

	render.SetColorMaterial()
	Micron.Client.RenderWorld(self)
end

function TOOL:DrawHUD()
	if not Micron or not Micron.Client or not Micron.Client.DrawHUD then
		return
	end

	Micron.Client.DrawHUD(self)
end

function TOOL.BuildCPanel(panel)
	if Micron and Micron.CPanel and Micron.CPanel.Build then
		Micron.CPanel.Build(panel)
	end
end
