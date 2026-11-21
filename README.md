# FootBid — Multiplayer Auction Game v0.8

FootBid is a mobile-first, room-based football auction PWA. Contestants join from separate devices through Supabase. Every room has a shared player pool, real-time bids, private team ownership and visible squad tactics.

## What's new in v0.8

- Any purchased player can play in any tactical role. The application no longer rejects role assignments that differ from the player's listed database positions.
- Moving a player on the pitch automatically changes the tactical role from the pitch zone:
  - Own-goal centre = GK; own-goal left/right channels = LB/RB.
  - Defensive central lane = CB; wide defensive lanes = LB/RB.
  - Deeper central midfield = DMF; central midfield = CMF; advanced midfield = AMF; wide midfield = LMF/RMF.
  - Forward central lanes = SS/CF; left/right attacking lanes = LWF/RWF.
- The role dropdown offers all 13 roles. The player's natural roles are tagged `NATURAL`; other assignments are labelled `OUT OF POSITION`.
- Out-of-position assignments remain legal but reduce Starting XI Strength and Tactical Balance. A goalkeeper placed at CF is valid for a user's tactical choice, but receives a very low position-fit score.
- The results now include a team-by-team positional-impact report showing player, listed database position, assigned role and fit percentage.
- Organisers can configure team budget, squad size (11, 15 or 18), auction pool size (90–489), and independent Current / Icon / Hero opening-price multipliers (0.5×–3.0×). Each multiplier is applied to the player's dataset `base_price` and rounded to a whole point.
- Current highest bidder and live amount are displayed in a large, prominent block.
- Every device receives a SOLD / UNSOLD announcement popup. Sale messages include player, winning team and final amount. The next player is already revealed automatically.
- Player portrait is slightly smaller to create more space for the bidder name and amount.

## 1. Requirements

- Node.js 20+
- npm
- Existing FootBid Supabase project with the v0.7 migration already applied

## 2. Update your Windows project

1. Extract this ZIP into a new folder, `footbid_base_v08`.
2. Open the new folder in VS Code.
3. Copy your existing `.env` file into the new folder, alongside `package.json`. Credentials are deliberately excluded from this ZIP.
4. Open the integrated terminal and run:

   ```powershell
   npm install
   npm run build
   npm run dev -- --host 0.0.0.0
   ```

5. For phones on the same Wi-Fi, open `http://YOUR_LAPTOP_IP:5173` on each phone. For different networks, deploy the PWA and share the HTTPS URL.

Do not put a Supabase service-role key in the browser or `.env`.

## 3. Apply the Supabase v0.8 migration

Your existing Supabase project already contains the v0.7 schema and migration. Apply this new migration once:

1. Open `supabase/migrations/v0.8_flexible_positions_prices_announcements.sql`.
2. Copy the complete file.
3. In Supabase Dashboard → SQL Editor → New Query, paste it and click Run.
4. Wait for `Success. No rows returned`.

Do not rerun the original `schema.sql` or the v0.7 migration. This migration preserves existing teams, purchases and rooms. Old rooms continue using their saved pool and settings; create a new room for the v0.8 setup controls and opening-price multipliers.

## 4. Auction setup controls

- Team budget: organiser-configured, minimum 500 points.
- Squad size: 11, 15 or 18 players. An 11-player auction team has no bench; 15-player teams have 4 bench places; 18-player teams have 7.
- Player pool: organiser chooses 90–489 records from the 489-player candidate database.
- Category opening price: `player.base_price × category multiplier`, rounded to the nearest whole point. Default multipliers are 1.0× for Current, Icon and Hero. The organiser can change each independently between 0.5× and 3.0×.
- A room checks that the selected pool has enough players for all configured squads.

## 5. Tactical role mapping and scoring

The pitch is oriented with attack at the top and the team's own goal at the bottom. Dragging a token or selecting it and tapping a new pitch point derives the role from its coordinates. Users can also choose any role manually; choosing a role moves the token to that role's reference point.

Tactical roles: `GK`, `CB`, `LB`, `RB`, `DMF`, `CMF`, `AMF`, `RMF`, `LMF`, `SS`, `CF`, `RWF`, `LWF`.

The scoring model continues to use the five requested criteria:

| Criterion | Weight | How it is evaluated |
|---|---:|---|
| Starting XI strength | 35% | Normalised dataset base-price strength for placed starters, multiplied by their natural-position suitability and penalised for an incomplete XI |
| Bench strength | 20% | Normalised base-price strength and positional versatility of unplaced squad players, scaled by available bench places |
| Current + Icons + Heroes mix | 15% | Category diversity across the complete squad |
| Squad balance | 15% | Natural goalkeeper, defensive, midfield and attacking coverage |
| Tactical balance | 15% | Player-to-role suitability, pitch location, pitch-line coverage and shape distribution |

Natural position matches score 100% suitability. Different positions on the same football line receive partial suitability. Cross-line assignments are penalised; GK-to-outfield and outfield-to-GK assignments receive only 5% suitability. This allows tactical experiments while reflecting their cost in the results.

**Data limitation:** the supplied 489-player dataset includes categories, base prices, listed positions, `best_known_for` and images. It does not include actual player attributes, match statistics or performance ratings. FootBid therefore uses base price as the available strength proxy and the listed positions for positional suitability. It does not claim to predict actual football performance.

## 6. Auction flow and announcements

- The organiser starts the first player after all contestants join.
- A player's opening bid uses the category-adjusted dataset base price.
- Contestants can enter any whole-number bid at or above the current minimum.
- The highest bidder cannot quit while leading.
- If all competitors quit, the highest bidder wins at the current bid.
- If all contestants quit before any bid, the player is unsold.
- Sale and unsold events are stored with the next-player announcement and displayed as a popup across devices.
- The next player advances automatically after a sale or unsold result; no one clicks Reveal Next Player between lots.

## 7. Project structure

```text
footbid_base_v08/
├── .env.example
├── .gitignore
├── README.md
├── package.json
├── index.html
├── vite.config.ts
├── public/
├── supabase/
│   ├── schema.sql
│   └── migrations/
│       ├── v0.7_dataset_tactics_autoadvance.sql
│       └── v0.8_flexible_positions_prices_announcements.sql
└── src/
    ├── App.tsx
    ├── main.tsx
    ├── styles.css
    ├── types.ts
    ├── data/
    │   ├── players.ts
    │   └── football_auction_players.json
    └── lib/
        ├── game.ts
        ├── online.ts
        ├── pool.ts
        ├── results.ts
        ├── supabase.ts
        └── tactics.ts
```
