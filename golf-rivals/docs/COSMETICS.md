# Cosmetic models

Every cosmetic already has a **3D model built in code**, so nothing needs uploading. Uploaded
meshes are optional upgrades.

## What the game builds by itself

| Cosmetic | Built from | What rarity adds |
|---|---|---|
| Club skins | `Shared/CosmeticModels` blueprints, built by `Client/Golf/CosmeticBuilder`. Each category has its own head: big rounded **driver**, flatter **fairway wood**, thin-bladed **long iron**, taller **short iron** with a cavity back, very lofted **wedge** with a wide sole, mallet **putter** with a white sight line. | Uncommon+: accent stripes and badges. Rare+: chrome trims. Unique+: neon inlays. Legendary: gold trims, a glow light, sparkles and a swing trail. Mythical: all of that, plus a pulsing glow. |
| Balls | A sphere plus thin rings hugging it: a sight line (Hex), neon bands (Neon Dimple), marble swirls, glowing lava cracks with rising embers, gold banding with sparkles, and a Black Hole with a spinning accretion disc and orbiting clumps. Balls roll as they travel, so the patterns turn. | The pattern itself (see `CosmeticModels.ball`). |
| Trails | Trail / sparkles / lagging Beam ribbon (`CosmeticBuilder.trail`). Shown in matches and on the range. | Wider, brighter, more particles. |
| Hole-drop effects | Particle bursts (`CosmeticBuilder.holeEffect`). Play when the ball drops in the cup, and on a range **bullseye**. | Bigger bursts, fireworks, crown, supernova. |

Previews: the Shop, Cases (rewards grid and the roulette strip), Inventory, Loadout and
Trade-Up all show a rotating 3D model of the item (`Client/UI/ItemPreview`) built by the same
code, so what you see in a menu is exactly what you get in a match. (Roblox doesn't draw trails
or particles inside menus, so trails show as a comet of glowing spheres and hole effects as a
burst of neon shards.)

## Optional: uploaded meshes

Open `src/ReplicatedStorage/GolfRivals/Shared/CosmeticsData.luau`:

- `ClubMeshes.<Category>`: one head mesh used by **every skin** of that category (the skin's
  colour still tints it if the mesh has no texture).
- `ItemMeshes.<item id>`: a head mesh for **one exact skin**, e.g.
  `skin_nebula_driver = { MeshId = "rbxassetid://...", TextureId = "rbxassetid://...", Scale = 1 },`
  It replaces the code-built head; the rarity glow, sparkles and swing trail still play.
- `BallMeshes.<item id>`: a mesh / texture for one ball (replaces its code-built pattern).
- `TrailTextures.<item id>`: a texture strip for a trail.
- Or drop a whole club **Model** into `ReplicatedStorage > GolfRivalsAssets > Clubs` named after
  the item id (e.g. `skin_gold_rush_putter`) or the category (`Driver`). Give it a part named
  `Grip` where the hand holds it, with the shaft running down.

Any mesh that fails to load just shows the code-built model.

## Which items benefit most from real meshes

1. **The six club categories (`ClubMeshes`)**: biggest upgrade for the least work. Six meshes
   (driver, fairway wood, long iron, short iron, wedge, putter) improve all 78 club skins at once.
   Code-built heads are made of boxes and ovals; a sculpted mesh gets the smooth crown, toe curve
   and hosel of a real club.
2. **Mythical club skins** (Abyss, Anime Wave, Nebula): their look is all about swirly, painted
   detail (a galaxy, a pastel wave) that parts can't paint. A **texture** on the category mesh
   via `ItemMeshes` sells the rarity.
3. **Legendary club skins** (Gold Rush, Royal Flush): engraved gold and jewels.
4. **Lava Core, Golden Orb and Black Hole balls**: a sphere with a painted texture (lava cracks,
   engraving, swirling event horizon) beats rings of parts. Use `BallMeshes` with a `TextureId`.
5. **Comet, Lightning and Rainbow Nova trails**: a texture strip in `TrailTextures` makes them
   look like real streaks.

Not worth a mesh: Common / Uncommon balls and skins, Chalk Dust, and the hole-drop effects (they
are particles; the code versions already look right).
