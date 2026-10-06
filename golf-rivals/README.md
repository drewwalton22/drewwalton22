# Golf Rivals (Roblox / Luau)

Competitive 3-click-swing golf with ranked leagues, loot cases, a daily shop and club upgrades.

**Putting it into Studio:** see [docs/STUDIO_SETUP.md](docs/STUDIO_SETUP.md) for step-by-step placement
of every script (Rojo or by hand), settings, optional art uploads, and a play-test checklist.

## Layout (Rojo: `default.project.json`)

| Roblox location | Source | Purpose |
|---|---|---|
| `ReplicatedStorage.GolfRivals.Shared` | `src/ReplicatedStorage/GolfRivals/Shared` | Config, item/case/club databases, math utils, remotes |
| `ServerScriptService.GolfRivals.Server` | `src/ServerScriptService/GolfRivals/Server` | DataStore, economy, inventory validation, bots, matches |
| `StarterPlayerScripts.GolfRivals.Client` | `src/StarterPlayer/StarterPlayerScripts/GolfRivals/Client` | UI, camera, swing input, trajectory prediction |

## Build progress

- [x] 1. Project scaffold + global item / case / club databases + boot-time validator
- [x] 2. Network remotes (declarative RemoteDefs, rate limiting, input validation)
- [x] 3. Swing physics (3-click state machine, flight/bounce/roll sim, wind, slope, lie, anti-cheat timing)
- [x] 4. Player profiles: session-locked DataStore saves, validated inventory/currency ops, schema migrations
- [x] 5. Economy: daily shop rotation, server-rolled cases, sell, trade-up, club upgrades (atomic, fuzz-tested)
- [x] 6. Matchmaking, AI bots, match orchestration (course data, stroke-play engine, ranked queues, 3 bot levels)
- [x] 7a. Client: match HUD, 3-click gauge, chase camera, live telemetry, course builder (Roblox API type-checked)
- [x] 7b. Lobby: 3D hub, loadout, shop, cases (roulette), trade-up, play/matchmaking, quests, leaderboard
- [x] 8. Overhaul:
  - Topbar-safe modern UI with drawn icons and asset fallbacks.
  - Six club categories with Power / Accuracy / Spin (save migration v1 -> v2).
  - The golfer swings and the ball launches on the impact frame, for players and bots.
  - The hole intro is server-timed (fixes bots shooting during the fly-over).
  - Live aim arc, vertical power meter, auto-putter with a ground putting line.
  - Driving range and AFK lounge coin zones.
  - Post-game podium with victory and defeat animations.

## Offline checks (no Studio needed)

Download the [Luau CLI](https://github.com/luau-lang/luau/releases) then:

```sh
LUAU_BIN=/path/to/luau/bin tools/check.sh
```

Optionally also type-check every Roblox-only script (services, remotes, all client code)
against the real Roblox API with [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp):

```sh
LUAU_BIN=... LUAU_LSP=/path/to/luau-lsp ROBLOX_TYPES=/path/to/globalTypes.d.luau tools/check.sh
```
(`globalTypes.d.luau` is `scripts/globalTypes.d.luau` in the luau-lsp repo.)

This strict-type-checks the pure `Shared/` and `Server/` modules (server files mark their Roblox-only lookups with `OFFLINE-STRIP`), syntax-checks the Roblox-only ones (`ROBLOX-ONLY` tag), and runs the database validator, network helpers and spot checks. `Remotes.luau`, `ProfileService.luau`, `EconomyService.luau`, `MatchService.luau` and the entry scripts have not been run in Studio yet.

## Sync into Studio

```sh
rojo serve   # then connect from the Rojo Studio plugin
```

## First run in Roblox Studio

Everything is verified offline (pure logic + real-API type checks), but nothing has been
played in Studio yet. Suggested first pass:

1. `rojo serve` and connect. In **Game Settings > Security** enable *Studio Access to API Services*
   (otherwise profiles run on an in-memory fallback and the leaderboard shows only this server).
2. Play (F5). Output should show the boot log through "Server ready." and "Client ready.".
3. Lobby: the plaza, fountain and clubhouse sign appear; Shop / Cases / Quests / Leaderboard,
   Play, Loadout and Trade-Up all open.
4. Play > a bot (Easy): fly-over, gauge, 3 clicks, ball flight with chase camera + telemetry,
   results screen, Return to Lobby.
5. Test with 2 players (Test > Local Server, 2 players): both queue Rookie League, play, and the
   winner is paid. Quit one player mid-match to check forfeit + payout.
6. Known unknowns worth watching: arena offsets for simultaneous matches, DataStore budgets under
   load, and how the procedural swing reads on unusual avatar packages (upload a real
   `Swing` animation with an `Impact` marker in `Shared/Assets` to replace it).

The full, current checklist (driving range, AFK lounge, podium, auto-putter) is in
[docs/STUDIO_SETUP.md](docs/STUDIO_SETUP.md#first-play-test-checklist).
