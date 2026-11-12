local root = script.Parent.Parent.Parent
local Types = require(root.Types)
local GitHubLoader = require(root.Shared.Util.GitHubLoader)
local TextFilter = require(root.Shared.Util.TextFilter)
local PlayerData = require(root.Systems.Data.Shared.PlayerData)
local IntroductionUtil = require(root.Systems.Introduction.Shared.Util)

local e2en: Types.e2enServer = require(root) :: any

local SOURCE: GitHubLoader.Source = {
	Repository = "Yazukxa/OldChatSystem",
	Ref = "main",
	Path = "src/OldChatServer.luau",
}

local WHISPER_HEAR_STAT = "Social.WhisperHearMult"
local FORCE_WHISPER_STAT = "Social.ForceWhisper"

local OldChatService = e2en.CreateService({
	Name = "OldChatService",
	Client = {
		Enabled = e2en.CreateProperty(false),
		ReceiveInaudible = e2en.CreateSignal(),
		ReceiveChatMessage = e2en.CreateSignal(),
		ReceiveChatLog = e2en.CreateSignal(),
		SendChatMessage = e2en.CreateSignal(),
	},
	Dependencies = { "DataService", "IntroductionService" },
})

local function getSlotData(player: Player): any
	local DataService: any = e2en.GetService("DataService")
	local playerData = DataService:GetData(player)
	if not playerData then
		return nil
	end
	return playerData.slots[playerData.currentSlot]
end

local function getPlayerStat(player: Player, statPath: string, fallback: number): number
	local ModifierService: any = e2en.GetService("ModifierService")
	if not ModifierService or not ModifierService:HasPlayerStat(player, statPath) then
		return fallback
	end
	return ModifierService:GetPlayerStat(player, statPath)
end

local function getCharacterName(player: Player): string
	local slotData = getSlotData(player)
	if not slotData then
		return ""
	end
	return slotData.firstName .. " " .. slotData.lastName
end

local function isMuted(player: Player): boolean
	local slotData = getSlotData(player)
	if not slotData then
		return true
	end
	return slotData.muted == true
end

local function saveMuted(player: Player, muted: boolean): boolean
	if not getSlotData(player) then
		return false
	end

	local DataService: any = e2en.GetService("DataService")
	DataService:UpdateData(player, function(data: PlayerData.PlayerDataType)
		local slot = data.slots[data.currentSlot]
		if slot then
			slot.muted = muted
		end
	end)
	return true
end

local function introduce(sender: Player, recipient: Player, name: string)
	local IntroductionService: any = e2en.GetService("IntroductionService")
	IntroductionService:ProcessChatMessage(sender, recipient, "{" .. name .. "}")
end

local function attachUnavailableMethods(service: any)
	function service:SetPlayerMuted(): boolean
		return false
	end
	function service:SetChatLogsEnabled() end
	function service:IsChatLogsEnabled(): boolean
		return false
	end
	function service:IsTemporarilyMuted(): boolean
		return false
	end
	function service:MutePlayer() end
	function service:SetEnabled() end
	function service:Enable() end
	function service:Disable() end
	function service:IsEnabled(): boolean
		return false
	end
	function service:OnMessageDelivered() end
end

local loaded, OldChatServer = GitHubLoader.Load(SOURCE)
if not loaded then
	warn(`[OldChatService] Running without chat: {OldChatServer}`)
	attachUnavailableMethods(OldChatService)
	return OldChatService
end

OldChatServer.Attach(OldChatService, {
	Filters = script.Parent.Shared.Filters,
	FilterText = TextFilter.ForBroadcast,
	GetCharacterName = getCharacterName,
	IsMuted = isMuted,
	SaveMuted = saveMuted,
	IsForcedWhisper = function(player: Player): boolean
		return getPlayerStat(player, FORCE_WHISPER_STAT, 0) >= 1
	end,
	GetWhisperHearingMultiplier = function(player: Player): number
		return getPlayerStat(player, WHISPER_HEAR_STAT, 1)
	end,
	Introductions = {
		ParseName = IntroductionUtil.ParseName,
		SanitizeName = IntroductionUtil.SanitizeName,
		Introduce = introduce,
	},
})

return OldChatService
