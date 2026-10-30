# Rogue's Passage — Tabletop Simulator Phase 2

This folder contains the first playable TTS scripting foundation:

- Seated-player registration
- Per-player two-color selection (exactly two of W/U/B/R/G)
- Loading a compact card catalog over HTTPS
- Random selection of 10 cards per selected color
- Spawning 20 face-up custom cards in front of the player
- Campaign metadata persistence through TTS `onSave` / `onLoad`

The campaign record stores card instances and progression metadata independently of physical TTS objects. Object GUIDs are recorded only as convenience pointers; they are not used as the source of truth.

## 1. Generate the TTS catalog

From the repository root, run:

```bash
python3 card_catalog/build_catalog.py
```

This now generates three outputs:

- `card_catalog/catalog.json` — full catalog for future tools
- `card_catalog/pool_report.json` — validation report
- `card_catalog/tts_catalog.json` — compact catalog with one representative image URL per card

The compact TTS file is the one the mod downloads. It is much smaller than the full catalog because it omits the full printing history.

## 2. Host the compact catalog

TTS Lua cannot read a file directly from your computer. Host `card_catalog/tts_catalog.json` at a URL accessible to the TTS game client over HTTPS. A public GitHub repository's raw file URL is one straightforward option.

Example URL shape (replace the placeholders):

```text
https://raw.githubusercontent.com/OWNER/REPOSITORY/BRANCH/card_catalog/tts_catalog.json
```

The compact file contains card names, rules text, Oracle IDs, and Scryfall image URLs. Do not publish it if you are uncomfortable making that information publicly accessible.

## 3. Install the Global script

1. Open the Tabletop Simulator save where you want to run Rogue's Passage.
2. Open **Modding → Scripting** (or the in-game scripting editor).
3. Open `tts_mod/Global.lua` in a text editor.
4. Replace `PASTE_PUBLIC_RAW_TTS_CATALOG_URL_HERE` with your hosted file URL.
5. Copy the complete contents of `Global.lua` into the TTS **Global** script.
6. Save/apply the script and reload the table if needed.

When the catalog loads, seated players will see a Rogue's Passage panel. Each player selects exactly two colors and presses **Generate 20-card starter pool**. The cards spawn face-up in a grid in front of that player's hand area.

## 4. Current limitations / next test pass

- This is the campaign lobby and starter-pool milestone, not the complete roguelike loop.
- The starter cards are spawned as individual custom card objects; automatic deck construction, basic-land addition, duels, coins, upgrades, and cleanup are later milestones.
- The initial card grid uses each player's hand transform as its anchor. Table layouts with unusual hand positions may need layout tuning.
- Each starter pool is generated once per player record. There is not yet an admin reset or pool-regeneration command.
- Campaign state persists card metadata, selections, coins, upgrades, and progression fields. Physical cards are saved by TTS itself; the campaign data does not depend on their GUIDs.
- The first test should be a two-player local game with a publicly hosted catalog URL. Verify catalog loading, both players selecting different pairs, 20 cards spawning for each, and campaign state surviving save/reload.

## Configuration

At the top of `Global.lua`:

- `CATALOG_URL`: required HTTPS URL to `tts_catalog.json`
- `CARDS_PER_COLOR`: defaults to 10
- `MAX_COPIES_PER_ORACLE_ID`: defaults to 4
- `CARD_BACK_URL`: optional custom card-back image URL
