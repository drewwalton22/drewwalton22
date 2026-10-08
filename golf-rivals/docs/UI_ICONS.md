# UI icons (optional uploads)

The whole UI works **without any uploaded images**: every slot below draws a fallback (a drawn
coin / gem / gift, or an emoji on a gradient tile). Uploading art just makes it look more
polished. Make your own art (don't copy another game's icons or logos).

## What to make

All images: **PNG with a transparent background**, the subject filling about 90% of the square,
bold shapes with a **thick dark outline (about 6-8% of the image width)** to match the cartoon UI.

| Slot in `Assets.Images` | Size (px) | What to draw | Where it shows |
|---|---|---|---|
| `CoinIcon` | 256 x 256 | A shiny gold coin, front-on, with a simple mark (star or golf ball) | Currency counter, prices, wheel prizes |
| `GemIcon` | 256 x 256 | A bright cyan/blue cut gem, slightly tilted | Currency counter, gem prices, wheel prizes |
| `GiftIcon` | 256 x 256 | A gift box with a ribbon and bow (purple box, gold ribbon) | Daily wheel "ITEM" prizes and the result card |
| `ShopTile` | 256 x 256 | A shop stall / shopping bag with a golf ball on it | Lobby menu |
| `CasesTile` | 256 x 256 | A treasure chest / crate glowing from inside | Lobby menu |
| `LoadoutTile` | 256 x 256 | Two crossed golf clubs | Lobby menu |
| `InventoryTile` | 256 x 256 | A golf bag full of clubs | Lobby menu |
| `TradeUpTile` | 256 x 256 | Two arrows in a circle over a star | Lobby menu |
| `QuestsTile` | 256 x 256 | A scroll or clipboard with a tick | Lobby menu |
| `WheelTile` | 256 x 256 | A colourful prize wheel | Lobby menu |
| `LeaderboardTile` | 256 x 256 | A gold trophy | Lobby menu |
| `PlayButton` | 256 x 256 | A flag in a hole on a green | Big PLAY button (left side) |
| `RangeButton` | 256 x 256 | A target / bullseye with a golf ball | DRIVING RANGE button |
| `AfkButton` | 256 x 256 | A palm tree and a deck chair | AFK LOUNGE button |

## How to upload one (about 1 minute each)

1. In Studio: **View tab > Asset Manager**.
2. Click **Bulk Import** (the icon with an up arrow), pick your PNG files, and click **Open**.
   They upload into the **Images** folder of the Asset Manager.
3. **Right-click** an image > **Copy Asset ID**.
4. Open `src/ReplicatedStorage/GolfRivals/Shared/Assets.luau`, find `Assets.Images`, and paste
   it into the matching slot, for example:

   ```lua
   CoinIcon = "rbxassetid://1234567890",
   ```

5. Save. Rojo syncs it into Studio. Press **Play** to see it.

A slot left as `""` keeps the drawn fallback, so you can upload them one at a time.
