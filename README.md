# Rogue's Passage

A Magic: The Gathering roguelike campaign for Tabletop Simulator.

This starter repository contains the first milestone: a Python card-catalog builder that downloads Scryfall's bulk card data, filters eligible cards, validates color pools, and exports a compact JSON catalog for Lua.

## Requirements

- Python 3.10+
- Internet access for the initial Scryfall bulk-data download
- No third-party Python packages

## Quick start

From this directory:

```bash
python card_catalog/build_catalog.py
```

The script downloads Scryfall's **Default Cards** bulk file into `card_catalog/cache/`, then writes:

- `card_catalog/catalog.json` — unique eligible cards and qualifying printings
- `card_catalog/pool_report.json` — eligible card counts by color and all 10 color-pair validation results
- `card_catalog/build.log` — build log

To test without downloading anything:

```bash
python -m unittest discover -s tests -v
```

To use a custom configuration:

```bash
python card_catalog/build_catalog.py --config card_catalog/config.json
```

## Current card rules

- The printing must have a release date on or after `2003-10-02` (Mirrodin's release date).
- The printing must use Scryfall frame value `2003`, `2015`, or `future`.
- The printing must be common or uncommon.
- The card must be a single-color card matching one of W/U/B/R/G.
- Colorless cards, multicolored cards, lands, non-paper-only cards, tokens, and nontraditional layouts are excluded.
- The card must have at least one qualifying printing. Multiple qualifying printings are grouped under one Oracle ID.
- Starter generation chooses 10 cards per selected color, with a maximum of four copies of any Oracle ID in a generated pool.
- Playability exclusions are deliberately conservative and configurable. Cards with niche mechanics are not broadly excluded.

## Important implementation note

Scryfall's printing metadata is used for release date, frame, rarity, and printing selection. Oracle ID is used as the card identity, so alternate printings do not count as different cards for duplicate limits.

The frame values and release cutoff are explicit configuration choices. The catalog report makes shortages visible instead of silently weakening the rules.

## Next milestone

Once the catalog has been generated and reviewed, connect the exported JSON to Tabletop Simulator's Lua scripts and implement color selection and starter-pool generation in-game.
