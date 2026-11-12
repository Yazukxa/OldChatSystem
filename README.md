# OldChatSystem (server)

The server half of OldChat: proximity chat, whispers, inner thoughts, walk-up delivery, chat logs, temporary and saved mutes, and optional `{Name}` introductions.

Games don't keep a copy of this code. At server start they fetch `src/OldChatServer.luau` from this repo and run it with `loadstring`, so a push here updates every game the next time a server starts. The client (chat box, bubbles, chat log UI) stays inside each game.

## Setting up a game

1. **Game Settings → Security → Allow HTTP Requests** on.
2. **ServerScriptService → LoadStringEnabled** on (Properties window).
3. Copy `loader/GitHubLoader.luau` into the game as a ModuleScript.
4. Create the service and attach the system to it. With e2en, `examples/e2en/Service.luau` is a full drop-in for `Systems/OldChat/Service`. With any other framework:

```lua
local GitHubLoader = require(path.to.GitHubLoader)

local loaded, OldChatServer = GitHubLoader.Load({
	Repository = "Yazukxa/OldChatSystem",
	Ref = "main",
	Path = "src/OldChatServer.luau",
})
if not loaded then
	error(OldChatServer)
end

OldChatServer.Attach(MyChatService, {
	GetCharacterName = function(player)
		return player.DisplayName
	end,
})
```

### Built-in copy (places without LoadStringEnabled)

`LoadStringEnabled` and Allow HTTP Requests can't be turned on by any script, so a place that loads your framework but never had them ticked can't run the GitHub copy. To keep those places working, put a copy of `src/OldChatServer.luau` in the game as a ModuleScript named `OldChatServer` under the Service. The e2en example tries GitHub first and quietly uses that copy if `loadstring` or HTTP is off. `GitHubLoader` gives up straight away in that case instead of retrying. Update the copy whenever you push a new version, or those places stay on the older code.

`Attach` adds the methods below to the service table you pass in. That table needs a `Client` table holding remote objects with the Knit/e2en shape: signals with `:Fire(player, ...)` and `:Connect(handler)`, and a property with `:Get()`, `:Set()`, `:SetTop()`, `:SetFor()` and `:GetFor()`. The system calls `Start` itself under e2en; anywhere else, call `service:Start()` once your remotes exist.

## Client contract

The in-game client has to match these remotes:

| Name | Direction | Arguments |
| --- | --- | --- |
| `Enabled` | property | `boolean` |
| `SendChatMessage` | client → server | `body: string, kind: string` |
| `ReceiveChatMessage` | server → client | `senderCharacter: Model, kind: string, body: string` |
| `ReceiveInaudible` | server → client | `senderCharacter: Model` |
| `ReceiveChatLog` | server → client | `username: string, characterName: string, kind: string, body: string` |

The client works out `kind` from the message prefix (`/w `, `/i `, `/t `) and formats bubbles itself. The server only uses `kind` to look up hearing distance. It also sets the player attributes `Muted` and `ChatLogsEnabled`.

`Enabled` is per player. A player can use OldChat when the global value is on, or when `EnabledFor` returned true for them on join. Messages only go to players who have it on. Chat logs still go to anyone with logs enabled, and the client decides whether to show them.

## Options

Everything is optional.

| Option | Default | What it does |
| --- | --- | --- |
| `Filters` | built-in Proximity, Whisper, InnerThought | Table of `{ [kind]: ChatFilter }`, or a Folder of filter ModuleScripts (pass the same folder your client uses so both sides agree) |
| `WhisperKind` | `"Whisper"` | Which filter counts as a whisper |
| `MaxMessageLength` | `200` | Longer messages are dropped |
| `MessageCooldown` | `0.4` | Seconds between messages per player |
| `WalkUpMessageLifetime` | `8` | How long a message can still reach someone who walks into range |
| `WalkUpCheckInterval` | `0.5` | How often walk-ups are checked |
| `FilterText` | Roblox broadcast filter | `(author, text) -> string?` |
| `GetCharacterName` | `player.DisplayName` | Name shown in chat logs |
| `IsMuted` | `Muted` attribute | Saved mute check |
| `SaveMuted` | returns `true` | Persist a mute; return `false` to refuse it |
| `IsForcedWhisper` | `false` | Forces every message from this player down to whisper range |
| `GetWhisperHearingMultiplier` | `1` | Scales whisper range for this listener |
| `EnabledFor` | nobody | `(player) -> boolean`, checked once on join (retried if it errors). True keeps OldChat on for that player even while the global toggle is off, e.g. `player:IsInGroup(id)` |
| `Introductions` | off | `{ ParseName, SanitizeName, Introduce, Cooldown? }` |

## Service methods

`SetEnabled`, `Enable`, `Disable`, `IsEnabled` (the global toggle; `EnabledFor` players stay on through it), `IsEnabledFor(player)`, `SetChatLogsEnabled`, `IsChatLogsEnabled`, `MutePlayer(player, seconds)`, `IsTemporarilyMuted`, `SetPlayerMuted(player, muted)`, `OnMessageDelivered(callback)`, `GetFilter(kind)`, `Start`.

## Updating and pinning

Push to `main` and new servers pick it up. Servers that are already running keep the copy they loaded. GitHub caches raw files for about five minutes, so a push can take that long to show up.

Anyone who can push to this repo can run code on every game server that loads it. For a live game, set `Ref` to a tag or commit SHA and bump it on purpose, rather than following `main`.

## Checks

```bash
luau-lsp analyze --defs=.luau-types/globalTypes.d.luau --flag:LuauSolverV2=false src loader
selene src loader
```
