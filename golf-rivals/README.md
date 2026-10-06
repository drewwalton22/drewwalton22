# Golf Rivals (Roblox / Luau)

Competitive 3-click-swing golf with ranked leagues, loot cases, a daily shop and club upgrades.

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
- [ ] 7. Quests + lobby UI + post-shot camera/telemetry

## Offline checks (no Studio needed)

Download the [Luau CLI](https://github.com/luau-lang/luau/releases) then:

```sh
LUAU_BIN=/path/to/luau/bin tools/check.sh
```

This strict-type-checks the pure `Shared/` and `Server/` modules (server files mark their Roblox-only lookups with `OFFLINE-STRIP`), syntax-checks the Roblox-only ones (`ROBLOX-ONLY` tag), and runs the database validator, network helpers and spot checks. `Remotes.luau`, `ProfileService.luau`, `EconomyService.luau`, `MatchService.luau` and the entry scripts have not been run in Studio yet.

## Sync into Studio

```sh
rojo serve   # then connect from the Rojo Studio plugin
```
