local Players = game:GetService("Players")
local TextService = game:GetService("TextService")

local VERSION = "1.0.0"
local DEFAULT_MAX_MESSAGE_LENGTH = 200
local DEFAULT_MESSAGE_COOLDOWN = 0.4
local DEFAULT_INTRODUCTION_COOLDOWN = 3
local DEFAULT_WALK_UP_MESSAGE_LIFETIME = 8
local DEFAULT_WALK_UP_CHECK_INTERVAL = 0.5
local DEFAULT_WHISPER_KIND = "Whisper"
local DEFAULT_FILTER_PRIORITY = 999
local ROOT_PART_NAME = "HumanoidRootPart"
local MUTED_ATTRIBUTE = "Muted"
local CHAT_LOGS_ATTRIBUTE = "ChatLogsEnabled"
local THOUGHT_COLOR_HEX = "#" .. Color3.fromRGB(30, 64, 175):ToHex()

export type Delivery = "Heard" | "Inaudible" | "Hidden"

export type ChatFilter = {
	priority: number?,
	enabled: boolean?,
	prefix: string?,
	prefixAliases: { string }?,
	hearingDistance: number?,
	logDisplayPrefix: string?,
	logColor: Color3?,
	logItalic: boolean?,
	Format: (message: string) -> string,
}

export type LoadedFilter = {
	kind: string,
	priority: number,
	prefix: string?,
	prefixAliases: { string }?,
	hearingDistance: number?,
	logDisplayPrefix: string?,
	logColor: Color3?,
	logItalic: boolean?,
	Format: (message: string) -> string,
}

export type RemoteSignal = {
	Fire: (self: RemoteSignal, player: Player, ...any) -> (),
	Connect: (self: RemoteSignal, handler: (player: Player, ...any) -> ()) -> any,
}

export type RemoteProperty = {
	Get: (self: RemoteProperty) -> any,
	Set: (self: RemoteProperty, value: any) -> (),
}

export type ClientInterface = {
	Enabled: RemoteProperty,
	ReceiveInaudible: RemoteSignal,
	ReceiveChatMessage: RemoteSignal,
	ReceiveChatLog: RemoteSignal,
	SendChatMessage: RemoteSignal,
}

export type Host = {
	Client: ClientInterface,
}

export type Introductions = {
	Cooldown: number?,
	ParseName: (message: string) -> string?,
	SanitizeName: (rawName: string) -> string?,
	Introduce: (sender: Player, recipient: Player, name: string) -> (),
}

export type Options = {
	Filters: ({ [string]: ChatFilter } | Instance)?,
	WhisperKind: string?,
	MaxMessageLength: number?,
	MessageCooldown: number?,
	WalkUpMessageLifetime: number?,
	WalkUpCheckInterval: number?,
	FilterText: ((author: Player, text: string) -> string?)?,
	GetCharacterName: ((player: Player) -> string)?,
	IsMuted: ((player: Player) -> boolean)?,
	SaveMuted: ((player: Player, muted: boolean) -> boolean)?,
	IsForcedWhisper: ((player: Player) -> boolean)?,
	GetWhisperHearingMultiplier: ((player: Player) -> number)?,
	Introductions: Introductions?,
}

export type MessageDeliveredCallback = (sender: Player, filter: LoadedFilter, body: string) -> ()

export type OldChatService = Host & {
	SetPlayerMuted: (self: OldChatService, player: Player, muted: boolean) -> boolean,
	SetChatLogsEnabled: (self: OldChatService, player: Player, enabled: boolean) -> (),
	IsChatLogsEnabled: (self: OldChatService, player: Player) -> boolean,
	IsTemporarilyMuted: (self: OldChatService, player: Player) -> boolean,
	MutePlayer: (self: OldChatService, player: Player, seconds: number) -> (),
	SetEnabled: (self: OldChatService, enabled: boolean) -> (),
	Enable: (self: OldChatService) -> (),
	Disable: (self: OldChatService) -> (),
	IsEnabled: (self: OldChatService) -> boolean,
	OnMessageDelivered: (self: OldChatService, callback: MessageDeliveredCallback) -> (),
	GetFilter: (self: OldChatService, kind: string) -> LoadedFilter,
	Start: (self: OldChatService) -> (),
}

type FilterRegistry = {
	byKind: { [string]: LoadedFilter },
	default: LoadedFilter,
}

type RecentMessage = {
	sender: Player,
	senderCharacter: Model,
	filter: LoadedFilter,
	body: string,
	introducedName: string?,
	expiresAt: number,
	heardBy: { [Player]: boolean },
}

local function formatUnchanged(message: string): string
	return message
end

local function formatWhisper(message: string): string
	return "<i>" .. message .. "</i>"
end

local function formatInnerThought(message: string): string
	return '<font color="' .. THOUGHT_COLOR_HEX .. '">[' .. message .. "]</font>"
end

local DEFAULT_FILTERS: { [string]: ChatFilter } = {
	Proximity = {
		priority = 1,
		enabled = true,
		hearingDistance = 40,
		Format = formatUnchanged,
	},
	Whisper = {
		priority = 1,
		enabled = true,
		prefix = "/w ",
		hearingDistance = 5,
		logDisplayPrefix = "[W]",
		logColor = Color3.fromRGB(255, 255, 255),
		logItalic = true,
		Format = formatWhisper,
	},
	InnerThought = {
		priority = 2,
		enabled = true,
		prefix = "/i ",
		prefixAliases = { "/t " },
		logDisplayPrefix = "[I]",
		logColor = Color3.fromRGB(0, 170, 190),
		logItalic = false,
		Format = formatInnerThought,
	},
}

local function collectFilterModules(container: Instance): { [string]: ChatFilter }
	local filters: { [string]: ChatFilter } = {}

	for _, filterModule in container:GetChildren() do
		if not filterModule:IsA("ModuleScript") then
			continue
		end

		local success, filter = pcall(require, filterModule)
		if not success then
			warn(`[OldChatServer] Failed to load chat filter {filterModule.Name}: {filter}`)
			continue
		end

		filters[filterModule.Name] = filter
	end

	return filters
end

local function loadFilters(source: ({ [string]: ChatFilter } | Instance)?): FilterRegistry
	local filters = DEFAULT_FILTERS
	if typeof(source) == "Instance" then
		filters = collectFilterModules(source)
	elseif typeof(source) == "table" then
		filters = source
	end

	local registry: FilterRegistry = {
		byKind = {},
		default = {
			kind = "",
			priority = math.huge,
			Format = formatUnchanged,
		},
	}

	for kind, filter in filters do
		if typeof(filter) ~= "table" or typeof(filter.Format) ~= "function" then
			warn(`[OldChatServer] Chat filter {kind} is missing a Format function`)
			continue
		end

		if filter.enabled == false then
			continue
		end

		local loadedFilter: LoadedFilter = {
			kind = kind,
			priority = filter.priority or DEFAULT_FILTER_PRIORITY,
			prefix = filter.prefix,
			prefixAliases = filter.prefixAliases,
			hearingDistance = filter.hearingDistance,
			logDisplayPrefix = filter.logDisplayPrefix,
			logColor = filter.logColor,
			logItalic = filter.logItalic,
			Format = filter.Format,
		}

		registry.byKind[kind] = loadedFilter

		if loadedFilter.prefix then
			continue
		end

		local currentDefault = registry.default
		local isHigherPriority = loadedFilter.priority < currentDefault.priority
		local winsTie = loadedFilter.priority == currentDefault.priority and kind < currentDefault.kind
		if isHigherPriority or winsTie then
			registry.default = loadedFilter
		end
	end

	return registry
end

local function getRootPart(character: Model): BasePart?
	local rootPart = character:FindFirstChild(ROOT_PART_NAME)
	if not rootPart or not rootPart:IsA("BasePart") then
		return nil
	end
	return rootPart
end

local function getDelivery(filter: LoadedFilter, senderCharacter: Model, recipientCharacter: Model?, hearingDistanceOverride: number?): Delivery
	local hearingDistance = hearingDistanceOverride or filter.hearingDistance
	if not hearingDistance then
		return "Hidden"
	end

	if not recipientCharacter then
		return "Heard"
	end

	local senderRootPart = getRootPart(senderCharacter)
	local recipientRootPart = getRootPart(recipientCharacter)
	if not senderRootPart or not recipientRootPart then
		return "Heard"
	end

	if (senderRootPart.Position - recipientRootPart.Position).Magnitude > hearingDistance then
		return "Inaudible"
	end

	return "Heard"
end

local function filterForBroadcast(author: Player, text: string): string?
	if text == "" then
		return text
	end

	local filterSuccess, filterResult = pcall(function()
		return TextService:FilterStringAsync(text, author.UserId, Enum.TextFilterContext.PublicChat)
	end)
	if not filterSuccess or not filterResult then
		return nil
	end

	local broadcastSuccess, broadcastText = pcall(function()
		return filterResult:GetNonChatStringForBroadcastAsync()
	end)
	if not broadcastSuccess then
		return nil
	end

	return broadcastText
end

local function getDisplayName(player: Player): string
	return player.DisplayName
end

local function isMutedByAttribute(player: Player): boolean
	return player:GetAttribute(MUTED_ATTRIBUTE) == true
end

local function acceptMuted(_player: Player, _muted: boolean): boolean
	return true
end

local function neverForcedWhisper(_player: Player): boolean
	return false
end

local function unitHearingMultiplier(_player: Player): number
	return 1
end

local function tryConsume(lastRequests: { [Player]: number }, cooldown: number, player: Player): boolean
	local now = os.clock()
	local lastTime = lastRequests[player]
	if lastTime and now - lastTime < cooldown then
		return false
	end

	lastRequests[player] = now
	return true
end

local function isValidDuration(seconds: any): boolean
	return typeof(seconds) == "number" and seconds == seconds and seconds > 0 and seconds ~= math.huge
end

local OldChatServer = {}

OldChatServer.Version = VERSION
OldChatServer.DefaultFilters = DEFAULT_FILTERS

function OldChatServer.GetDelivery(filter: LoadedFilter, senderCharacter: Model, recipientCharacter: Model?, hearingDistanceOverride: number?): Delivery
	return getDelivery(filter, senderCharacter, recipientCharacter, hearingDistanceOverride)
end

function OldChatServer.Attach(service: Host, options: Options?): OldChatService
	local settings: Options = options or {}

	local registry = loadFilters(settings.Filters)
	local whisperKind = settings.WhisperKind or DEFAULT_WHISPER_KIND
	local maxMessageLength = settings.MaxMessageLength or DEFAULT_MAX_MESSAGE_LENGTH
	local messageCooldown = settings.MessageCooldown or DEFAULT_MESSAGE_COOLDOWN
	local walkUpMessageLifetime = settings.WalkUpMessageLifetime or DEFAULT_WALK_UP_MESSAGE_LIFETIME
	local walkUpCheckInterval = settings.WalkUpCheckInterval or DEFAULT_WALK_UP_CHECK_INTERVAL
	local filterText: (author: Player, text: string) -> string? = settings.FilterText or filterForBroadcast
	local getCharacterName: (player: Player) -> string = settings.GetCharacterName or getDisplayName
	local isPermanentlyMuted: (player: Player) -> boolean = settings.IsMuted or isMutedByAttribute
	local saveMuted: (player: Player, muted: boolean) -> boolean = settings.SaveMuted or acceptMuted
	local isForcedWhisper: (player: Player) -> boolean = settings.IsForcedWhisper or neverForcedWhisper
	local getWhisperHearingMultiplier: (player: Player) -> number = settings.GetWhisperHearingMultiplier or unitHearingMultiplier
	local introductions = settings.Introductions
	local introductionCooldown = if introductions and introductions.Cooldown then introductions.Cooldown else DEFAULT_INTRODUCTION_COOLDOWN

	local playersWithChatLogsEnabled: { [Player]: boolean } = {}
	local temporaryMutes: { [Player]: number } = {}
	local voiceMutedByChat: { [Player]: AudioDeviceInput } = {}
	local lastMessageTimes: { [Player]: number } = {}
	local lastIntroductionTimes: { [Player]: number } = {}
	local messageDeliveredListeners: { MessageDeliveredCallback } = {}
	local recentMessages: { RecentMessage } = {}
	local started = false

	local function getFilter(kind: string): LoadedFilter
		return registry.byKind[kind] or registry.default
	end

	local function isEnabled(): boolean
		return service.Client.Enabled:Get() == true
	end

	local function isTemporarilyMuted(player: Player): boolean
		local mutedUntil = temporaryMutes[player]
		if not mutedUntil then
			return false
		end
		return os.clock() < mutedUntil
	end

	local function resolveHearingDistance(filter: LoadedFilter, sender: Player, recipient: Player): number?
		local hearingDistance = filter.hearingDistance
		if not hearingDistance then
			return nil
		end

		local isWhisper = filter.kind == whisperKind
		local whisperFilter = registry.byKind[whisperKind]
		local whisperDistance = if whisperFilter then whisperFilter.hearingDistance else nil

		if whisperDistance and whisperDistance < hearingDistance and isForcedWhisper(sender) then
			hearingDistance = whisperDistance
			isWhisper = true
		end

		if not isWhisper then
			return hearingDistance
		end

		return hearingDistance * math.max(getWhisperHearingMultiplier(recipient), 0)
	end

	local function setVoiceMuted(player: Player, muted: boolean)
		if not muted then
			local mutedInput = voiceMutedByChat[player]
			voiceMutedByChat[player] = nil
			if mutedInput and mutedInput.Parent then
				pcall(function()
					mutedInput.Muted = false
				end)
			end
			return
		end

		if voiceMutedByChat[player] then
			return
		end

		local deviceInput = player:FindFirstChildOfClass("AudioDeviceInput")
		if not deviceInput or deviceInput.Muted then
			return
		end

		local success = pcall(function()
			deviceInput.Muted = true
		end)
		if success then
			voiceMutedByChat[player] = deviceInput
		end
	end

	local function resolveIntroducedName(player: Player, body: string): string?
		if not introductions then
			return nil
		end

		local rawName = introductions.ParseName(body)
		if not rawName then
			return nil
		end

		if not tryConsume(lastIntroductionTimes, introductionCooldown, player) then
			return nil
		end

		local name = introductions.SanitizeName(rawName)
		if not name then
			return nil
		end

		if filterText(player, name) ~= name then
			return nil
		end

		return name
	end

	local function introduce(sender: Player, recipient: Player, introducedName: string?)
		if not introductions or not introducedName then
			return
		end
		introductions.Introduce(sender, recipient, introducedName)
	end

	local function deliverMessage(sender: Player, senderCharacter: Model, filter: LoadedFilter, body: string, introducedName: string?)
		local characterName = getCharacterName(sender)
		local isWhisperMessage = filter.kind == whisperKind or isForcedWhisper(sender)
		local heardBy: { [Player]: boolean } = {}

		for _, listener in messageDeliveredListeners do
			task.spawn(listener, sender, filter, body)
		end

		for _, recipient in Players:GetPlayers() do
			local isSender = recipient == sender

			local delivery: Delivery = "Heard"
			if not isSender then
				delivery = getDelivery(filter, senderCharacter, recipient.Character, resolveHearingDistance(filter, sender, recipient))
			end

			if delivery == "Heard" then
				heardBy[recipient] = true
				service.Client.ReceiveChatMessage:Fire(recipient, senderCharacter, filter.kind, body)

				if not isSender then
					introduce(sender, recipient, introducedName)
				end
			elseif delivery == "Inaudible" and isWhisperMessage then
				service.Client.ReceiveInaudible:Fire(recipient, senderCharacter)
			end

			if playersWithChatLogsEnabled[recipient] then
				service.Client.ReceiveChatLog:Fire(recipient, sender.Name, characterName, filter.kind, body)
			end
		end

		if not filter.hearingDistance then
			return
		end

		table.insert(recentMessages, {
			sender = sender,
			senderCharacter = senderCharacter,
			filter = filter,
			body = body,
			introducedName = introducedName,
			expiresAt = os.clock() + walkUpMessageLifetime,
			heardBy = heardBy,
		})
	end

	local function deliverToWalkUps()
		local now = os.clock()

		for index = #recentMessages, 1, -1 do
			local message = recentMessages[index]
			if now >= message.expiresAt or not message.senderCharacter.Parent or not message.sender.Parent then
				table.remove(recentMessages, index)
				continue
			end

			for _, recipient in Players:GetPlayers() do
				if recipient == message.sender or message.heardBy[recipient] then
					continue
				end

				local recipientCharacter = recipient.Character
				if not recipientCharacter then
					continue
				end

				local hearingDistance = resolveHearingDistance(message.filter, message.sender, recipient)
				if getDelivery(message.filter, message.senderCharacter, recipientCharacter, hearingDistance) ~= "Heard" then
					continue
				end

				message.heardBy[recipient] = true
				service.Client.ReceiveChatMessage:Fire(recipient, message.senderCharacter, message.filter.kind, message.body)
				introduce(message.sender, recipient, message.introducedName)
			end
		end
	end

	local function onPlayerSendMessage(player: Player, rawBody: any, rawKind: any)
		if not isEnabled() then
			return
		end

		if typeof(rawBody) ~= "string" or typeof(rawKind) ~= "string" or rawBody == "" then
			return
		end

		local length = utf8.len(rawBody)
		if not length or length > maxMessageLength then
			return
		end

		if not tryConsume(lastMessageTimes, messageCooldown, player) then
			return
		end

		if isPermanentlyMuted(player) or isTemporarilyMuted(player) then
			return
		end

		local senderCharacter = player.Character
		if not senderCharacter then
			return
		end

		local filteredBody = filterText(player, rawBody)
		if not filteredBody or filteredBody == "" then
			return
		end

		deliverMessage(player, senderCharacter, getFilter(rawKind), filteredBody, resolveIntroducedName(player, rawBody))
	end

	local function onPlayerRemoving(player: Player)
		playersWithChatLogsEnabled[player] = nil
		temporaryMutes[player] = nil
		voiceMutedByChat[player] = nil
		lastMessageTimes[player] = nil
		lastIntroductionTimes[player] = nil
	end

	local host: any = service

	function host:SetPlayerMuted(player: Player, muted: boolean): boolean
		if not saveMuted(player, muted) then
			return false
		end

		player:SetAttribute(MUTED_ATTRIBUTE, muted)
		return true
	end

	function host:SetChatLogsEnabled(player: Player, enabled: boolean)
		if enabled then
			playersWithChatLogsEnabled[player] = true
		else
			playersWithChatLogsEnabled[player] = nil
		end
		player:SetAttribute(CHAT_LOGS_ATTRIBUTE, enabled)
	end

	function host:IsChatLogsEnabled(player: Player): boolean
		return playersWithChatLogsEnabled[player] == true
	end

	function host:IsTemporarilyMuted(player: Player): boolean
		return isTemporarilyMuted(player)
	end

	function host:MutePlayer(player: Player, seconds: number)
		if not isValidDuration(seconds) then
			return
		end

		local now = os.clock()
		local mutedUntil = math.max(temporaryMutes[player] or 0, now + seconds)
		temporaryMutes[player] = mutedUntil

		setVoiceMuted(player, true)

		task.delay(mutedUntil - now, function()
			if temporaryMutes[player] ~= mutedUntil then
				return
			end
			temporaryMutes[player] = nil
			setVoiceMuted(player, false)
		end)
	end

	function host:SetEnabled(enabled: boolean)
		service.Client.Enabled:Set(enabled)
	end

	function host:Enable()
		service.Client.Enabled:Set(true)
	end

	function host:Disable()
		service.Client.Enabled:Set(false)
	end

	function host:IsEnabled(): boolean
		return isEnabled()
	end

	function host:OnMessageDelivered(callback: MessageDeliveredCallback)
		table.insert(messageDeliveredListeners, callback)
	end

	function host:GetFilter(kind: string): LoadedFilter
		return getFilter(kind)
	end

	function host:Start()
		if started then
			return
		end
		started = true

		Players.PlayerRemoving:Connect(onPlayerRemoving)
		service.Client.SendChatMessage:Connect(onPlayerSendMessage)

		task.spawn(function()
			while true do
				task.wait(walkUpCheckInterval)
				if isEnabled() then
					deliverToWalkUps()
				end
			end
		end)
	end

	return host
end

return OldChatServer
