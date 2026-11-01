# Rogue's Passage — Tabletop Simulator Phase 2

This folder contains the first playable TTS scripting foundation:

- Seated-player registration
- Per-player two-color selection (exactly two of W/U/B/R/G)
- On-demand download of only the selected 10-card color pools
- Randomized pre-generated 10-card pool variants for each selected color
- Spawning one shuffled, face-down 20-card custom deck in front of the player
- Campaign metadata persistence through TTS `onSave` / `onLoad`

The campaign record stores card instances and progression metadata independently of physical TTS objects. Object GUIDs are recorded only as convenience pointers; they are not used as the source of truth.

## 1. Generate the TTS starter pools

From the repository root, run:

```bash
python3 card_catalog/build_catalog.py
```

The builder generates the full catalog and validation report, retains the five color catalog exports for reference, and creates 100 small randomized starter-pool variants per color in `card_catalog/tts_starter_pools/`.

Each `starter_pool_<COLOR>_<VARIANT>.json` file contains exactly 10 eligible cards of one color. The builder enforces the configured per-Oracle-ID copy limit. The default output is 500 small files (100 variants for each of W/U/B/R/G).

To generate a different number of variants:

```bash
python3 card_catalog/build_catalog.py --tts-pool-variants 200
```

If you change the variant count, also change `STARTER_POOL_VARIANTS` in `tts_mod/Global.lua` to the same value. Commit and push the generated `card_catalog/tts_starter_pools/` directory so the TTS client can download the files from GitHub.

## 2. Host the starter pools

The default URL pattern is:

```text
https://raw.githubusercontent.com/alphacharlieecho/rogues-passage/main/card_catalog/tts_starter_pools/starter_pool_W_001.json
```

The script chooses a random variant from 001 through 100 for each selected player/color combination. Only the two selected 10-card files are downloaded. TTS decodes 10 cards per file instead of parsing a multi-thousand-card color catalog.

## 3. Install the Global script

1. Open the Tabletop Simulator save where you want to run Rogue's Passage.
2. Open **Modding → Scripting** (or the in-game scripting editor).
3. Open `tts_mod/Global.lua` in a text editor.
4. Confirm `RP_CONFIG.STARTER_POOL_BASE_URL` points to the hosted `card_catalog/tts_starter_pools/starter_pool_` filename prefix.
5. Copy the complete contents of `Global.lua` into the TTS **Global** script.
6. Save/apply the script and reload the table if needed.

When a player selects a color, TTS downloads that player's assigned 10-card color pool. Once both selected color pools are loaded, the **Generate 20-card starter pool** button becomes available. Selected variant numbers are saved in campaign data so a reload fetches the same pools until the player generates their starter pool.

## 4. Current limitations / next test pass

- This is the campaign lobby and starter-pool milestone, not the complete roguelike loop.
- Starter pools spawn as a single shuffled custom deck. Each contained card keeps its own face URL, rules text, and campaign metadata in its GM Notes; automatic deck construction, basic-land addition, duels, coins, upgrades, and cleanup are later milestones.
- The initial card grid uses each player's hand transform as its anchor. Table layouts with unusual hand positions may need layout tuning.
- Each starter pool is generated once per player record. There is not yet an admin reset or pool-regeneration command.
- Campaign state persists card metadata, selections, coins, upgrades, and progression fields. Physical cards are saved by TTS itself; the campaign data does not depend on their GUIDs.
- Test in TTS with two players: select different color pairs, confirm only the distinct selected-color files are downloaded, generate 20 cards per player, and verify campaign state survives save/reload.

## Configuration

At the top of `Global.lua`:

- `STARTER_POOL_BASE_URL`: HTTPS URL prefix ending in `starter_pool_`; the script appends a color code, variant number, and `.json`
- `STARTER_POOL_VARIANTS`: number of generated variants available per color (default 100)
- `CARDS_PER_COLOR`: defaults to 10
- `CARD_BACK_URL`: shared card-back image URL; defaults to Scryfall’s standard Magic card back. Set to `nil` to use TTS’s default back.
