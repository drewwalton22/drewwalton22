# Publishing the golf animations (about 1 minute each)

The game **already animates every golfer** with built-in (procedural) poses, so you can skip this
page and everything still works. Publishing the animations makes them play as real Roblox
animations, which look smoother and blend better with avatars.

## Why you have to do this by hand

Roblox only plays an animation in your game if **you** (or Roblox itself) own it. Animations made
by other creators won't load, and a script can't upload an animation for you. So the game ships
the animations as files, and you click **Save to Roblox** on each one.

## What's in Studio

When Rojo is connected, open the **Explorer** window (View tab > Explorer) and expand:

```
ServerStorage
└── GolfRivals
    └── AnimationsToPublish
        ├── Address_R15        Address_R6         (looped, lining up a full shot)
        ├── PuttAddress_R15    PuttAddress_R6     (looped, lining up a putt)
        ├── Swing_R15          Swing_R6           (has an "Impact" marker)
        ├── Putt_R15           Putt_R6            (has an "Impact" marker)
        ├── Victory_R15        Victory_R6         (looped, podium winner)
        └── Defeat_R15         Defeat_R6          (looped, podium loser)
```

`_R15` versions are for R15 avatars (most avatars today), `_R6` for the classic blocky R6 avatars.
To see which one your game uses: **Home tab > Game Settings > Avatar > Avatar Type**. If it says
"R15" you only *need* the `_R15` ones (publishing both is fine).

## Steps for each animation

1. In the Explorer, **right-click** `Swing_R15` (start with this one).
2. Click **Save to Roblox...**
3. A window called **Asset Configuration** opens.
   - **Title**: type something like `Golf Rivals Swing R15`.
   - **Creator**: pick the SAME owner as your game (yourself, or your group if the game belongs to a
     group). If they don't match, the animation won't play in the game.
   - Click **Submit** (or **Save**).
4. When it finishes, the window shows the new asset's **ID** (a long number). Click the copy icon
   next to it, or write the number down.
   - Lost it? Open the **Toolbox** (View tab > Toolbox) > **Inventory** tab > **My Animations**,
     right-click the animation > **Copy Asset ID**.
5. Open the file `src/ReplicatedStorage/GolfRivals/Shared/Assets.luau` in your code editor, find
   `Assets.Animations`, and paste the number into the right slot, written like this:

   ```lua
   Swing = { R15 = "rbxassetid://1234567890", R6 = "" },
   ```

6. Save the file. Rojo syncs it into Studio by itself.
7. Repeat for the other animations you want (Putt, Address, PuttAddress, Victory, Defeat).

Press **Play** and swing. Any slot you leave as `""` keeps using the built-in procedural pose.

## If "Save to Roblox..." isn't in the menu

Use the Animation Editor instead:

1. **Avatar tab > Rig Builder > Block Rig** (pick R15 or R6 to match the animation). A dummy
   named `Rig` appears in the Workspace.
2. **Avatar tab > Animation Editor**, then click the dummy. When asked, name a new animation
   `temp` and click **Create**. Then click the **"..."** menu > **Save**. This creates
   `ServerStorage > RBX_ANIMSAVES > Rig`.
3. In the Explorer, **copy** `Swing_R15` (Ctrl+C), click `RBX_ANIMSAVES > Rig`, and **paste**
   (Ctrl+V).
4. In the Animation Editor: **"..." > Load > Swing_R15**.
5. **"..." > Publish to Roblox**, fill in the title, pick the same Creator as your game, and
   **Submit**. Copy the ID and paste it into `Assets.luau` as in step 5 above.

## Changing the animations

The files are generated from the same pose maths the game uses (`Shared/SwingPose.luau`). If you
tweak the poses there, regenerate them with:

```sh
LUAU_BIN=/path/to/luau/bin tools/gen_animations.sh
```

and publish them again.
