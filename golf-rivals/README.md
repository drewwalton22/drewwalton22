# Golf Rivals (Roblox / Luau)

Competitive golf with a 2-stage timing swing, overhead aiming, Smooth Terrain courses, ranked
leagues, loot cases, a daily shop, a daily wheelspin, club upgrades and mesh cosmetics.

**Putting it into Studio:** see [docs/STUDIO_SETUP.md](docs/STUDIO_SETUP.md) for step-by-step placement
of every script (Rojo or by hand), settings, optional art uploads, and a play-test checklist.

## Layout (Rojo: `default.project.json`)

| Roblox location | Source | Purpose |
|---|---|---|
| `ReplicatedStorage.GolfRivals.Shared` | `src/ReplicatedStorage/GolfRivals/Shared` | Config, item/case/club databases, math utils, remotes |
| `ServerScriptService.GolfRivals.Server` | `src/ServerScriptService/GolfRivals/Server` | DataStore, economy, inventory validation, bots, matches |
| `StarterPlayerScripts.GolfRivals.Client` | `src/StarterPlayer/StarterPlayerScripts/GolfRivals/Client` | UI, camera, swing input, trajectory prediction |
| `ServerStorage.GolfRivalsAssets.Decor` | (Studio) | optional foliage / rock templates for MapDecorator |
| `ReplicatedStorage.GolfRivalsAssets.Clubs` | (Studio) | optional 3D club models |
| `Workspace.GolfCourses` | (Studio) | optional hand-built, high-detail holes |

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
- [x] 9. Terrain, timing, aiming, wheel and cosmetics update:
  - Holes are built in Smooth Terrain (or hand-built in `Workspace.GolfCourses`); a raycast
    surface reads Grass / LeafyGrass / Sand / Water as Fairway / Rough / Bunker / Water with
    per-material bounce and friction; MapDecorator surrounds each hole with foliage and rocks.
  - Slower classic 2-stage timing bar (power, then an accuracy sweet spot; early = slice,
    late = hook) with its own, much slower putting speeds.
  - Overhead aerial aiming camera with a draggable landing reticle clamped to the club's reach.
  - Bigger cup capture and a gentle cup magnet near the rim.
  - Daily wheelspin (screen + physical lobby wheel), 24 h cooldown saved in the profile,
    weighted coin / gem / cosmetic rewards, extra spins for gems or Robux (Developer Product).
  - CosmeticsData: ball skins, Trail / Sparkle / Ribbon trails, club meshes welded to the hand,
    swing / victory animations, hole effects; Inventory screen with 3D previews.
  - Lobby visuals: Atmosphere, Bloom, SunRays, colour grading, soft shadows, depth of field,
    neon accent colour cycling and ambient particles.
- [x] 10. Course & feel overhaul:
  - A par-36, 9-hole course in the classic Wii Sports / NES Open style (CourseData): Beginner,
    Intermediate and Expert 3-hole courses with tee / green elevations, valleys, a cliff-top tee,
    banked and island greens, hazards and an out-of-bounds road.
  - CourseRelief height field shared by physics, bots and TerrainBuilder (WriteVoxels sculptor);
    slope-aware bounce and roll.
  - Short LeafyGrass fairways, tall Grass rough (GrassLength), smooth-turf greens; bots putt from
    the fringe.
  - Accuracy needle swings back and forth; 5-second timeout fires with a random hook / slice.
  - Aerial / behind-the-player view toggle (V), terrain-aware aerial height, minimap target.
  - Smaller ball, bigger white-rimmed cup, holed balls drop into the cup.
  - Daily wheel: wedges drawn correctly, cumulative-weight odds (fractions), 2D and 3D wheels
    animated from one shared server-clocked function, modern wheel screen.
  - Glassy HUD panels with glow strokes, redesigned shot meter, podium lighting fix.
- [x] 11. Playtest fixes:
  - Player swing animation fixed (AnimationConstraint joints), publishable KeyframeSequences for
    R15 / R6 (docs/ANIMATIONS.md), club resting on the ground behind the ball.
  - Real cup cut into the green, thin flagstick, small ball with a far outline, lip-outs.
  - Putting from behind the golfer, slope-following putting line, auto-scaled linear putter
    meter in feet.
  - Studio-lit podium, victory emotes as cosmetics (Roblox built-in emotes by default).
  - Daily wheel with exact wedges, icons and a matching result card.
  - Code-built 3D clubs (per category, rarity detail) and patterned balls, rotating previews
    (docs/COSMETICS.md).
  - Cartoon UI restyle and a brighter lobby (docs/UI_ICONS.md for optional icon uploads).

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
4. Play > a bot (Easy): fly-over, overhead aim (drag the target, Space), the 2-click timing bar,
   ball flight with chase camera + telemetry, results screen, Return to Lobby.
5. Test with 2 players (Test > Local Server, 2 players): both queue Rookie League, play, and the
   winner is paid. Quit one player mid-match to check forfeit + payout.
6. Known unknowns worth watching: arena offsets for simultaneous matches, DataStore budgets under
   load, and how the procedural swing reads on unusual avatar packages (upload a real
   `Swing` animation with an `Impact` marker in `Shared/Assets` to replace it).

The full, current checklist (driving range, AFK lounge, podium, auto-putter) is in
[docs/STUDIO_SETUP.md](docs/STUDIO_SETUP.md#first-play-test-checklist).
