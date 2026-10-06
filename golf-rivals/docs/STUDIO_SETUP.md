# Golf Rivals: putting it into Roblox Studio

There are two ways to get the code into a place: **Rojo**, which is fast and keeps files in sync, or
**by hand**, which needs no tools. Both give the same tree. Every name below must match exactly,
because scripts find each other by name (`require(Shared.ClubStats)` and so on).

---

## Option A: Rojo (recommended)

1. Install Rojo on your computer (`aftman add rojo-rbx/rojo`, `rokit add rojo-rbx/rojo`, or download
   it from github.com/rojo-rbx/rojo/releases) and install the **Rojo** plugin in Studio
   (Plugins > Manage Plugins, or the Creator Store).
2. In the `golf-rivals/` folder, run `rojo serve`.
3. In Studio, open a new **Baseplate** place, open the Rojo plugin, click **Connect**, and accept.
4. Rojo builds the whole tree in Option B from `default.project.json`, including the empty asset
   folders (`ServerStorage.GolfRivalsAssets`, `ReplicatedStorage.GolfRivalsAssets`,
   `Workspace.GolfCourses`) and `Workspace.StreamingEnabled = false`. Anything you drop into those
   folders in Studio is left alone by Rojo. Skip to [Game settings](#game-settings).

Alternative: `rojo build -o GolfRivals.rbxlx` makes a place file you can open directly in Studio.

---

## Option B: by hand

Create each object with **Insert Object** (right-click > Insert Object), rename it, and paste the
matching file's contents into it. There are three script types:

| File name ends with | Create this object |
|---|---|
| `.server.luau` | **Script** (a server script), named without the suffix: `Main.server.luau` becomes a Script called `Main` |
| `.client.luau` | **LocalScript**, named without the suffix: `Main.client.luau` becomes a LocalScript called `Main` |
| anything else (`.luau`) | **ModuleScript** with the file name minus `.luau` |

Modules marked **NEW** arrived with the terrain / timing / aerial-aim / wheel / cosmetics update.

### Step 1: ReplicatedStorage (shared by server and client)

```
ReplicatedStorage
├── GolfRivals                (Folder)
│   └── Shared                (Folder)
│       ├── AimGuide          (ModuleScript)  aim arc / putting line physics
│       ├── AimMath           (ModuleScript)  NEW aerial reticle: distance + angle clamps, target power
│       ├── Assets            (ModuleScript)  asset-id registry (blank = graceful fallbacks)
│       ├── CameraMath        (ModuleScript)
│       ├── CaseDatabase      (ModuleScript)
│       ├── CasesView         (ModuleScript)
│       ├── ClubAdvisor       (ModuleScript)
│       ├── ClubDatabase      (ModuleScript)  products (club lines) for the six categories
│       ├── ClubStats         (ModuleScript)  THE six categories, Power / Accuracy / Spin, MaxDistance
│       ├── Config            (ModuleScript)  every tuning knob (swing speeds, cup, wheel, decor, courses)
│       ├── CosmeticsData     (ModuleScript)  NEW how every cosmetic looks: ball skins, trails, club meshes, animations, hole FX
│       ├── CourseDatabase    (ModuleScript)
│       ├── CourseLayout      (ModuleScript)
│       ├── CourseTerrain     (ModuleScript)
│       ├── DatabaseValidator (ModuleScript)
│       ├── DecorPlanner      (ModuleScript)  NEW where foliage / rocks go around a hole (seeded)
│       ├── Format            (ModuleScript)
│       ├── GaugeView         (ModuleScript)  2-stage timing bar layout
│       ├── ItemDatabase      (ModuleScript)
│       ├── LoadoutView       (ModuleScript)
│       ├── LobbyLayout       (ModuleScript)  plaza, driving range, AFK lounge, daily wheel stand
│       ├── Logger            (ModuleScript)
│       ├── MatchView         (ModuleScript)
│       ├── MiniMap           (ModuleScript)
│       ├── ModeView          (ModuleScript)
│       ├── PartFactory       (ModuleScript)
│       ├── PodiumView        (ModuleScript)
│       ├── Prng              (ModuleScript)
│       ├── ProfileOps        (ModuleScript)
│       ├── ProfileTemplate   (ModuleScript)  save format (+ Wheel: last free spin, bought spins, receipts)
│       ├── QuestDatabase     (ModuleScript)
│       ├── QuestEngine       (ModuleScript)
│       ├── RangeRules        (ModuleScript)
│       ├── Rarity            (ModuleScript)
│       ├── RateLimiter       (ModuleScript)
│       ├── RemoteDefs        (ModuleScript)  (+ GetWheel, SpinWheel, BuyWheelSpin)
│       ├── Remotes           (ModuleScript)
│       ├── ShopRotation      (ModuleScript)
│       ├── ShopView          (ModuleScript)
│       ├── ShotPhysics       (ModuleScript)  flight / bounce / roll, material physics, cup magnet
│       ├── Signal            (ModuleScript)
│       ├── SurfaceMaterials  (ModuleScript)  NEW terrain material -> Fairway / Rough / Sand / Water + physics
│       ├── SwingMath         (ModuleScript)
│       ├── SwingPose         (ModuleScript)
│       ├── SwingStateMachine (ModuleScript)  2-stage timing (power, then accuracy)
│       ├── TableUtil         (ModuleScript)
│       ├── TelemetryView     (ModuleScript)
│       ├── TerrainPlan       (ModuleScript)  NEW which Smooth Terrain fills build a hole
│       ├── TerrainSurface    (ModuleScript)  NEW raycast surface: height, lie, slope, physics
│       ├── TradeUpView       (ModuleScript)
│       ├── Types             (ModuleScript)
│       ├── Validate          (ModuleScript)
│       ├── WheelArt          (ModuleScript)  NEW draws the wheel face (screen + 3D wheel)
│       ├── WheelRules        (ModuleScript)  NEW cooldown, weighted roll, rewards, purchases
│       └── ZoneRewards       (ModuleScript)
└── GolfRivalsAssets          (Folder)  NEW, optional art the CLIENT needs
    └── Clubs                 (Folder)  custom 3D club models (see "Cosmetics art" below)
```
Source: `src/ReplicatedStorage/GolfRivals/Shared/`.

### Step 2: ServerScriptService (server only, never visible to players)

```
ServerScriptService
└── GolfRivals                (Folder)
    └── Server                (Folder)
        ├── Main              (Script)        boots everything, in order
        ├── BotBrain          (ModuleScript)
        ├── CaseRoller        (ModuleScript)
        ├── CourseRegistry    (ModuleScript)  NEW reads hand-built holes from Workspace.GolfCourses
        ├── Economy           (ModuleScript)
        ├── EconomyService    (ModuleScript)
        ├── LeaderboardService(ModuleScript)
        ├── LightingDirector  (ModuleScript)  NEW Atmosphere, Bloom, SunRays, colour grade, soft shadows, sky, water
        ├── LobbyBuilder      (ModuleScript)  builds the lobby, range, AFK lounge and the 3D daily wheel
        ├── MapDecorator      (ModuleScript)  NEW spawns foliage / rocks / grass patches around each hole
        ├── MatchEngine       (ModuleScript)
        ├── MatchService      (ModuleScript)  builds each match's hole (terrain / mapped / parts)
        ├── MatchSettlement   (ModuleScript)
        ├── Matchmaker        (ModuleScript)
        ├── MemoryBackend     (ModuleScript)
        ├── ProfileService    (ModuleScript)
        ├── ProfileStore      (ModuleScript)
        ├── QuestService      (ModuleScript)
        ├── ReceiptService    (ModuleScript)  NEW the one ProcessReceipt (Developer Products)
        ├── TerrainCourse     (ModuleScript)  NEW writes a hole into Smooth Terrain and clears it after
        ├── WheelService      (ModuleScript)  NEW daily wheel remotes, rolls, 24 h cooldown, purchases
        └── ZoneService       (ModuleScript)
```
Source: `src/ServerScriptService/GolfRivals/Server/` (`Main.server.luau` is the Script).

### Step 3: ServerStorage (server-only assets)

```
ServerStorage
└── GolfRivalsAssets          (Folder)
    └── Decor                 (Folder)
        ├── Tree              (Folder)  drop tree MeshParts / Models here
        ├── Bush              (Folder)
        ├── Rock              (Folder)
        └── GrassPatch        (Folder)
```
`MapDecorator` clones a random template from the matching folder for every decoration it places.
Empty folders are fine: it then loads the MeshPart asset ids in `Config.Decor.MeshIds` (via
`AssetService:CreateMeshPartAsync`), and if those are blank too it builds simple procedural
stand-ins. Templates are scaled, rotated and anchored automatically; give Models a PrimaryPart.

### Step 4: StarterPlayer > StarterPlayerScripts (runs on each player's device)

```
StarterPlayer
└── StarterPlayerScripts
    └── GolfRivals                (Folder)
        └── Client                (Folder)
            ├── Main              (LocalScript)   client entry point
            ├── Bus               (ModuleScript)
            ├── ClientState       (ModuleScript)
            ├── SwingController   (ModuleScript)  2-stage clicks (power, accuracy)
            ├── Golf              (Folder)
            │   ├── AerialAim       (ModuleScript)  NEW overhead camera + draggable landing reticle
            │   ├── AimVisual       (ModuleScript)  aim arc / putting line
            │   ├── CosmeticBuilder (ModuleScript)  NEW ball skins, trails (Trail/Beam/emitters), club models, hole FX
            │   └── GolferRig       (ModuleScript)  swing, impact frame, attaches the club mesh to the hand
            ├── Lobby             (Folder)
            │   ├── CasesScreen, InventoryScreen (NEW), LeaderboardScreen, LoadoutScreen,
            │   ├── LobbyAmbience (NEW), LobbyController, LobbyHud, ModalHost, ModeScreen,
            │   ├── QuestsScreen, Reasons, ShopScreen, TradeUpScreen,
            │   └── WheelController (NEW), WheelScreen (NEW)        (all ModuleScripts)
            ├── Match             (Folder)
            │   ├── BallAnimator, CameraController, CourseBuilder, CourseView (NEW),
            │   └── MatchController, MatchHud, PodiumStage           (all ModuleScripts)
            ├── UI                (Folder)
            │   ├── AssetLoader, Icons, ItemCard, Kit,
            │   └── Theme, TimingBar (NEW), Toast                    (all ModuleScripts)
            └── Zones             (Folder)
                └── RangeController (ModuleScript)
```
Source: `src/StarterPlayer/StarterPlayerScripts/GolfRivals/Client/`.
(`UI/PowerMeter` and `Golf/ClubLook` were removed: delete them if you placed them by hand earlier.)

### Step 5: Workspace

```
Workspace
└── GolfCourses               (Folder)  OPTIONAL hand-built, high-detail holes
```
Leave everything else out: the server builds the lobby and the match holes, and every screen is
created in code. **Delete the default Baseplate** (it overlaps the plaza).

---

## Game settings

1. **Game Settings > Security > Enable Studio Access to API Services**: on. Without it, progress
   (including the daily wheel's 24 h timer) runs on an in-memory store and nothing saves.
2. **Workspace > StreamingEnabled**: **off** (Rojo sets it). Matches play in far-away arenas; with
   streaming on, clients may not have the course loaded when the hole starts.
3. **Lighting > Technology**: **Future** (real-time shadows from every lamp and neon accent).
   Scripts can't set this, so set it by hand.
4. **Terrain > Decoration**: **on** (animated grass blades on Grass). Also Studio-only.
5. **Game Settings > Avatar**: R15 or R6 both work.
6. Publish the place before testing DataStores or purchases.

### Robux spins for the daily wheel (optional)

1. Creator Dashboard > your experience > **Monetization > Developer Products > Create**
   ("Extra Wheel Spin").
2. Paste its id into `Config.Wheel.RobuxProductId` (0 hides the Robux button).
   `ReceiptService` grants it idempotently and saves before confirming the purchase.

---

## What each feature uses, and where to tune it

| Feature | Where it lives | Tune it in |
|---|---|---|
| Smooth Terrain holes | `TerrainPlan` (what) + `TerrainCourse` (writes it) | `Config.Course.Mode` (`"Terrain"` or the old `"Parts"`) |
| Surface detection | `TerrainSurface` raycasts; `SurfaceMaterials` maps Grass = Fairway, LeafyGrass = Rough, Sand = Bunker, Water = Water | `SurfaceMaterials.TerrainLies` / `PhysicsOverrides` |
| Material friction / bounce | `ShotPhysics` asks the surface for per-material physics | `Config.Lies` + `SurfaceMaterials.PhysicsOverrides` |
| Foliage / rocks | `MapDecorator` + `DecorPlanner` | `Config.Decor` (density, kinds, `MeshIds`) and `ServerStorage.GolfRivalsAssets.Decor` |
| 2-stage timing bar | `SwingStateMachine`, `UI/TimingBar` | `Config.Swing.PowerSweepSeconds`, `AccuracySweepSeconds` (higher = slower) |
| Putting meter | same, putt speeds | `Config.Swing.PuttPowerSweepSeconds`, `PuttAccuracySweepSeconds` |
| Cup capture + magnet | `ShotPhysics` | `Config.Physics.CupCaptureRadius`, `CupCaptureSpeed`, `MagnetRadius`, `MagnetAccel` |
| Aerial aim | `Golf/AerialAim`, `AimMath`, `CameraController.aerial` | max distance = `ClubStats.maxDistanceYds` |
| Daily wheel | `WheelRules`, `WheelService`, `WheelScreen`, `WheelController` | `Config.Wheel` (segments, weights, cooldown, gem price) |
| Cosmetics | `CosmeticsData` (looks) -> `CosmeticBuilder` (instances) | `CosmeticsData.ClubMeshes`, `BallMeshes`, `TrailTextures`, `AnimationIds` |
| Lobby visuals | `LightingDirector` (server), `LobbyAmbience` (client) | the values at the top of each module |

---

## Hand-built holes (Workspace.GolfCourses)

Build a hole anywhere in the world with Smooth Terrain and MeshParts, then:

```
Workspace
└── GolfCourses
    └── Hole1                  (Model or Folder; attributes: Par = 4, HoleName = "Lakeside")
        ├── Tee      (Part)    the ball is teed on its top surface
        ├── Pin      (Part)    the cup is at its centre
        ├── Bounds   (Part)    optional invisible box; outside it = out of bounds
        └── ...                greens / tee boxes / paths as MeshParts with a string
                               attribute GolfLie = "Green" | "Tee" | "Fairway" | "Rough" | "Sand" | "Water"
```
Paint the ground with the Terrain Editor: **Grass** = fairway, **LeafyGrass** = rough,
**Sand** = bunkers, **Water** = hazards (rock, mud and ground count as rough with their own bounce).
Holes are played in name order; when any exist they replace the generated holes
(`Config.Course.UseMappedCourses`).

## Cosmetics art (all optional; everything has a procedural fallback)

- **Club meshes**: paste a head `MeshId` / `TextureId` per category into
  `CosmeticsData.ClubMeshes`, or put whole club Models in `ReplicatedStorage.GolfRivalsAssets.Clubs`
  named after the skin item id (one exact skin) or the category (`Driver`, `FairwayWood`,
  `LongIron`, `ShortIron`, `Wedge`, `Putter`). Give the Model a part named **Grip** (the end the
  hand holds); it is welded to the golfer's right hand during the swing.
- **Ball skins**: `CosmeticsData.BallMeshes[itemId] = { MeshId = "...", TextureId = "..." }`.
- **Trail textures**: `CosmeticsData.TrailTextures[itemId] = "rbxassetid://..."`.
- **Swing / stance / victory emote animations**: `CosmeticsData.AnimationIds[itemId]`. For swings,
  add an Animation Event named exactly **Impact** on the frame the club meets the ball.

Paste ids as `"rbxassetid://123456"`.

---

## First play-test checklist

1. **Boot.** F5. Output shows the boot steps through "Step 8: daily wheelspin", "Server ready.",
   then "Client ready.".
2. **Lobby.** Golden-hour light with haze, bloom and sun rays; the background softly blurred; lamp
   caps and signs slowly cycling colour; drifting pollen over the plaza. Tiles: Shop, Cases,
   Loadout, Inventory, Trade-Up, Quests, Daily Spin (green FREE badge), Ranks.
3. **Daily wheel.** Walk to the wheel stand west of the fountain and press E (or the Daily Spin
   tile). SPIN FREE: the on-screen wheel and the 3D wheel spin together and land on the reward.
   Spin again: "No spins left" and a countdown. Buy a spin for 25 gems and spin it.
   Rejoin: the countdown continues (saved in the profile).
4. **Inventory.** Each tab lists what you own with a 3D preview; EQUIP a ball / trail / club skin.
5. **Bot match** (Play > Easy):
   - The hole is real terrain (rolling grass, sunken sand bunkers, water) with trees and rocks
     around it.
   - Your turn starts in the **overhead view**. Drag the yellow target; it stops at the club's max
     distance (faint ring) and the arc shows the flight. Space / SWING ▶.
   - The camera glides behind your golfer, the **timing bar** arms: click once to lock POWER
     (the white tick is what the target needs), click again on the green SWEET SPOT. Early =
     slice, late = hook. ◀ AIM / Tab goes back before power is locked.
   - Balls in the sand stop quickly, balls in rough lose distance, water costs a stroke.
   - On the green the bar is much slower; a putt that just reaches the rim curls in.
   - Your equipped ball, trail, club model and hole effect show for you and your opponent.
6. **Driving range.** Same aim -> swing flow; land on a target green to earn coins.
7. **Two players** (Test > Local Server, 2 players): both see the same wheel spin and each
   other's cosmetics in a match.
