# Golf Rivals: putting it into Roblox Studio

There are two ways to get the code into a place: **Rojo**, which is fast and keeps files in sync, or
**by hand**, which needs no tools. Both give the same tree. Every name below must match exactly,
because scripts find each other by name (`require(Shared.ClubStats)` and so on).

---

## Option A: Rojo (recommended)

1. Install Rojo (`aftman add rojo-rbx/rojo`, or download it from github.com/rojo-rbx/rojo) and
   the **Rojo** Studio plugin.
2. In this folder, run `rojo serve`.
3. In Studio, open the Rojo plugin, click **Connect**, and accept the sync.
4. Rojo builds the whole tree shown in Option B from `default.project.json`. Skip to
   [Game settings](#game-settings).

---

## Option B: by hand

Create each object with **Insert Object** (right-click > Insert Object), rename it, and paste the
matching file's contents into it. There are three script types:

| File name ends with | Create this object |
|---|---|
| `.server.luau` | **Script** (a server script), named without the suffix: `Main.server.luau` becomes a Script called `Main` |
| `.client.luau` | **LocalScript**, named without the suffix: `Main.client.luau` becomes a LocalScript called `Main` |
| anything else (`.luau`) | **ModuleScript** with the file name minus `.luau` |

### Step 1: ReplicatedStorage (shared by server and client)

```
ReplicatedStorage
└── GolfRivals                (Folder)
    └── Shared                (Folder)
        ├── AimGuide          (ModuleScript)  aim arc / putting line physics
        ├── Assets            (ModuleScript)  asset-id registry (blank = graceful fallbacks)
        ├── CameraMath        (ModuleScript)
        ├── CaseDatabase      (ModuleScript)
        ├── CasesView         (ModuleScript)
        ├── ClubAdvisor       (ModuleScript)
        ├── ClubDatabase      (ModuleScript)  products (club lines) for the six categories
        ├── ClubStats         (ModuleScript)  THE six categories + Power / Accuracy / Spin
        ├── Config            (ModuleScript)  every tuning knob
        ├── CourseDatabase    (ModuleScript)
        ├── CourseLayout      (ModuleScript)
        ├── CourseTerrain     (ModuleScript)
        ├── DatabaseValidator (ModuleScript)
        ├── Format            (ModuleScript)
        ├── GaugeView         (ModuleScript)
        ├── ItemDatabase      (ModuleScript)
        ├── LoadoutView       (ModuleScript)
        ├── LobbyLayout       (ModuleScript)  plaza, driving range, AFK lounge
        ├── Logger            (ModuleScript)
        ├── MatchView         (ModuleScript)
        ├── MiniMap           (ModuleScript)
        ├── ModeView          (ModuleScript)
        ├── PartFactory       (ModuleScript)
        ├── PodiumView        (ModuleScript)  who stands where on the podium
        ├── Prng              (ModuleScript)
        ├── ProfileOps        (ModuleScript)
        ├── ProfileTemplate   (ModuleScript)  save format + v1 -> v2 migration
        ├── QuestDatabase     (ModuleScript)
        ├── QuestEngine       (ModuleScript)
        ├── RangeRules        (ModuleScript)  driving-range bays, targets, payouts
        ├── Rarity            (ModuleScript)
        ├── RateLimiter       (ModuleScript)
        ├── RemoteDefs        (ModuleScript)
        ├── Remotes           (ModuleScript)
        ├── ShopRotation      (ModuleScript)
        ├── ShopView          (ModuleScript)
        ├── ShotPhysics       (ModuleScript)
        ├── Signal            (ModuleScript)
        ├── SwingMath         (ModuleScript)
        ├── SwingPose         (ModuleScript)  procedural swing / victory / defeat poses
        ├── SwingStateMachine (ModuleScript)
        ├── TableUtil         (ModuleScript)
        ├── TelemetryView     (ModuleScript)
        ├── TradeUpView       (ModuleScript)
        ├── Types             (ModuleScript)
        ├── Validate          (ModuleScript)
        └── ZoneRewards       (ModuleScript)  range / AFK daily caps and AFK timer
```
The source files are in `src/ReplicatedStorage/GolfRivals/Shared/`.

### Step 2: ServerScriptService (server only, never visible to players)

```
ServerScriptService
└── GolfRivals                (Folder)
    └── Server                (Folder)
        ├── Main              (Script)        boots everything, in order
        ├── BotBrain          (ModuleScript)
        ├── CaseRoller        (ModuleScript)
        ├── Economy           (ModuleScript)
        ├── EconomyService    (ModuleScript)
        ├── LeaderboardService(ModuleScript)
        ├── LobbyBuilder      (ModuleScript)  builds the lobby, range and AFK lounge
        ├── MatchEngine       (ModuleScript)
        ├── MatchService      (ModuleScript)
        ├── MatchSettlement   (ModuleScript)
        ├── Matchmaker        (ModuleScript)
        ├── MemoryBackend     (ModuleScript)
        ├── ProfileService    (ModuleScript)
        ├── ProfileStore      (ModuleScript)
        ├── QuestService      (ModuleScript)
        └── ZoneService       (ModuleScript)  driving-range payouts + AFK lounge
```
The source files are in `src/ServerScriptService/GolfRivals/Server/` (`Main.server.luau` is the Script).

### Step 3: StarterPlayer > StarterPlayerScripts (runs on each player's device)

```
StarterPlayer
└── StarterPlayerScripts
    └── GolfRivals                (Folder)
        └── Client                (Folder)
            ├── Main              (LocalScript)   client entry point
            ├── Bus               (ModuleScript)
            ├── ClientState       (ModuleScript)
            ├── SwingController   (ModuleScript)
            ├── Golf              (Folder)
            │   ├── AimVisual     (ModuleScript)  draws the aim arc / putting line
            │   ├── ClubLook      (ModuleScript)
            │   └── GolferRig     (ModuleScript)  swing, impact frame, celebrations
            ├── Lobby             (Folder)
            │   ├── CasesScreen, LeaderboardScreen, LoadoutScreen, LobbyController,
            │   ├── LobbyHud, ModalHost, ModeScreen, QuestsScreen, Reasons,
            │   └── ShopScreen, TradeUpScreen            (all ModuleScripts)
            ├── Match             (Folder)
            │   ├── BallAnimator, CameraController, CourseBuilder,
            │   └── MatchController, MatchHud, PodiumStage   (all ModuleScripts)
            ├── UI                (Folder)
            │   ├── AssetLoader, Icons, ItemCard, Kit,
            │   └── PowerMeter, Theme, Toast                 (all ModuleScripts)
            └── Zones             (Folder)
                └── RangeController (ModuleScript)
```
The source files are in `src/StarterPlayer/StarterPlayerScripts/GolfRivals/Client/`.

> Do **not** put anything in `Workspace` or `StarterGui`: the server builds the lobby, and every
> screen is created in code. Delete the default Baseplate. The lobby has its own ground, and a
> leftover baseplate overlaps the plaza.

---

## Game settings

1. **Game Settings > Security > Enable Studio Access to API Services**: on. Without it, progress
   runs on an in-memory store (fine for testing; nothing saves) and a warning is logged.
2. **Game Settings > Avatar**: R15 or R6 both work. GolferRig drives either rig.
3. Publish the place before testing DataStores (an unpublished place can't use them).

## Optional art: uploads with automatic fallbacks

Every image and animation slot lives in `Shared/Assets`. All of them ship **blank**, and the game
is complete without them:

- **Images** (`CoinIcon`, `GemIcon`, `ShopTile`, ...). Blank or broken IDs show the drawn
  fallback (a gold coin made of frames, gradient tiles). If an uploaded ID fails to load,
  `UI/AssetLoader` swaps the fallback in.
- **Animations** (`Swing`, `Putt`, `Victory`, `Defeat`, `Address`). Blank means the
  procedural `SwingPose` animation. To use your own swing:
  1. Animate it in the Animation Editor on an R15 rig.
  2. On the frame where the club meets the ball, add an **Animation Event** named exactly
     `Impact`. The ball launches on that marker. If the marker is missing, the ball
     launches at `Config.Match.SwingLeadSeconds`.
  3. Publish it and paste `rbxassetid://<id>` into `Assets.Animations.Swing`.

Paste IDs as `"rbxassetid://123456"`.

## First play-test checklist

1. **Boot.** Press F5. Output shows the boot steps through "Step 7: lobby coin zones" and
   "Server ready.", then "Client ready.".
2. **Topbar.** The profile card, coins and gems sit **below** Roblox's menu / chat / voice
   buttons. Coin icons are drawn (no empty boxes) and window close buttons show an X.
3. **Lobby.**
   - The left tiles open Shop, Cases, Loadout, Trade-Up, Quests and Ranks.
   - Cases shows x1 / x3 / x5 / x10 fully, with no clipped description.
   - Loadout shows six tabs: Driver, Fairway Wood, Long Iron, Short Iron, Wedge, Putter.
4. **Driving range.**
   - Press DRIVING RANGE, walk onto a bay and press E.
   - Three clicks: the swing plays, then the ball flies on impact.
   - Land on a green to earn coins; the bullseye pays double. Earnings show "x / 3,000 today".
5. **AFK lounge.** Press AFK LOUNGE. The banner counts down to "+15". After 60 s a toast
   pays out. Step off the deck and the timer resets.
6. **Bot match** (Play > Easy):
   - The fly-over plays fully. The bot does not shoot during it.
   - On your turn: your golfer stands at the ball with a club, the aim arc appears and grows
     with the vertical power meter, and three clicks start your swing. The ball leaves on impact.
   - The bot visibly swings before its ball flies.
   - On the green, the putter is selected and locked, and a putting line is drawn on the
     ground (it bends with the slope).
   - After hole 3, the podium shows both golfers: the winner celebrating on the top step, the
     loser dejected, with the scoreboard on the left. Then Return to Lobby.
7. **Two players** (Test > Local Server, 2 players). Both queue Rookie League and see each
   other's swings. The winner is paid. One quits mid-match and forfeits.
8. **Old saves.** A profile saved before this update (14-club bag) loads as the six-club bag.
   Upgrades are kept and iron skins appear in both iron slots.
