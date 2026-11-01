# Rogue's Passage — Tabletop Simulator Phase 2

This folder contains the first playable TTS scripting foundation:

- Seated-player registration
- Per-player two-color selection (exactly two of W/U/B/R/G)
- On-demand download of only the selected colors' card catalogs
- Random selection of 10 cards per selected color
- Spawning 20 face-up custom cards in front of the player
- Campaign metadata persistence through TTS `onSave` / `onLoad`

The campaign record stores card instances and progression metadata independently of physical TTS objects. Object GUIDs are recorded only as convenience pointers; they are not used as the source of truth.

## 1. Generate the TTS catalogs

From the repository root, run:

```bash
python3 card_catalog/build_catalog.py
```

This generates the full catalog, validation report, and five color-specific TTS files in `card_catalog/tts_catalogs/`:

- `tts_catalog_W.json`
- `tts_catalog_U.json`
- `tts_catalog_B.json`
- `tts_catalog_R.json`
- `tts_catalog_G.json`

Each TTS file contains only one color's eligible cards and the fields needed to create starter cards. The game downloads the two files corresponding to a player's selected colors, rather than downloading and parsing the entire catalog at startup.

## 2. Host the catalogs

Host all five files at HTTPS URLs accessible to the TTS game client. With this repository on GitHub, the URL pattern is:

```text
https://raw.githubusercontent.com/alphacharlieecho/rogues-passage/main/card_catalog/tts_catalogs/tts_catalog_W.json
```

Replace the final `W` with `U`, `B`, `R`, or `G` for the other colors. The repository's `main` branch URL is configured by default in `Global.lua`.

## 3. Install the Global script

1. Open the Tabletop Simulator save where you want to run Rogue's Passage.
2. Open **Modding → Scripting** (or the in-game scripting editor).
3. Open `tts_mod/Global.lua` in a text editor.
4. Confirm `RP_CONFIG.CATALOG_BASE_URL` points to the hosted `card_catalog/tts_catalogs/tts_catalog_` filename prefix.
5. Copy the complete contents of `Global.lua` into the TTS **Global** script.
6. Save/apply the script and reload the table if needed.

When a player selects a color, its catalog downloads. Once both selected catalogs are loaded, the **Generate 20-card starter pool** button becomes available. Color catalogs are cached for the current TTS session, so different players selecting the same color do not trigger duplicate downloads.

## 4. Current limitations / next test pass

- This is the campaign lobby and starter-pool milestone, not the complete roguelike loop.
- The starter cards are spawned as individual custom card objects; automatic deck construction, basic-land addition, duels, coins, upgrades, and cleanup are later milestones.
- The initial card grid uses each player's hand transform as its anchor. Table layouts with unusual hand positions may need layout tuning.
- Each starter pool is generated once per player record. There is not yet an admin reset or pool-regeneration command.
- Campaign state persists card metadata, selections, coins, upgrades, and progression fields. Physical cards are saved by TTS itself; the campaign data does not depend on their GUIDs.
- Test in TTS with two players: select different color pairs, confirm only the distinct selected-color files are downloaded, generate 20 cards per player, and verify campaign state survives save/reload.

## Configuration

At the top of `Global.lua`:

- `CATALOG_BASE_URL`: required HTTPS URL prefix ending in `tts_catalog_`; the script appends a color code and `.json`
- `CARDS_PER_COLOR`: defaults to 10
- `MAX_COPIES_PER_ORACLE_ID`: defaults to 4
- `CARD_BACK_URL`: optional custom card-back image URL
