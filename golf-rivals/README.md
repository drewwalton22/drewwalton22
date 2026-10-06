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
- [ ] 2. Network remotes
- [ ] 3. Swing physics (3-click, wind, slope, lie)
- [ ] 4. DataStore + inventory
- [ ] 5. Economy (shop rotation, cases, trade-up, upgrades)
- [ ] 6. Matchmaking, AI bots
- [ ] 7. Quests + lobby UI + post-shot camera/telemetry

## Offline checks (no Studio needed)

Download the [Luau CLI](https://github.com/luau-lang/luau/releases) then:

```sh
LUAU_BIN=/path/to/luau/bin tools/check.sh
```

This strict-type-checks `Shared/` and runs `DatabaseValidator` plus spot checks.

## Sync into Studio

```sh
rojo serve   # then connect from the Rojo Studio plugin
```
