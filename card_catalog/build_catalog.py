#!/usr/bin/env python3
"""Build the Rogue's Passage card catalog from Scryfall bulk data.

Uses only the Python standard library. The Scryfall Default Cards bulk file is
downloaded once and cached locally; no per-card API requests are made.
"""
from __future__ import annotations

import argparse
import gzip
import json
import logging
import random
import re
import sys
import urllib.error
import urllib.request
from collections import Counter, defaultdict
from datetime import date
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = Path(__file__).with_name("config.json")
CACHE_DIR = Path(__file__).with_name("cache")
DEFAULT_CATALOG = Path(__file__).with_name("catalog.json")
DEFAULT_REPORT = Path(__file__).with_name("pool_report.json")
DEFAULT_LOG = Path(__file__).with_name("build.log")
DEFAULT_TTS_CATALOG = Path(__file__).with_name("tts_catalog.json")
BULK_METADATA_URL = "https://api.scryfall.com/bulk-data"
USER_AGENT = "RoguesPassageCardCatalog/0.1 (local hobby project)"
ACCEPT = "application/json;q=0.9,*/*;q=0.8"

COLOR_NAMES = {
    "W": "white",
    "U": "blue",
    "B": "black",
    "R": "red",
    "G": "green",
}
COLOR_PAIRS = [(a, b) for i, a in enumerate(COLOR_NAMES) for b in list(COLOR_NAMES)[i + 1:]]


def setup_logging(log_path: Path) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.StreamHandler(sys.stdout), logging.FileHandler(log_path, encoding="utf-8")],
        force=True,
    )


def request_json(url: str) -> Any:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": ACCEPT})
    with urllib.request.urlopen(req, timeout=60) as response:
        return json.load(response)


def download_file(url: str, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_suffix(path.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": ACCEPT})
    logging.info("Downloading Scryfall bulk data to %s", path)
    try:
        with urllib.request.urlopen(req, timeout=120) as response, open(temp_path, "wb") as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
        temp_path.replace(path)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


def get_bulk_download_url(cache_dir: Path) -> tuple[str, str]:
    """Discover current Default Cards URL; supports JSON and JSONL gzip exports."""
    metadata_cache = cache_dir / "bulk_metadata.json"
    try:
        metadata = request_json(BULK_METADATA_URL)
        metadata_cache.parent.mkdir(parents=True, exist_ok=True)
        metadata_cache.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    except Exception as exc:
        if metadata_cache.exists():
            logging.warning("Could not fetch bulk metadata (%s); trying cached metadata.", exc)
            metadata = json.loads(metadata_cache.read_text(encoding="utf-8"))
        else:
            raise RuntimeError(f"Unable to retrieve Scryfall bulk metadata: {exc}") from exc

    items = metadata.get("data", [])
    item = next((x for x in items if x.get("type") == "default_cards"), None)
    if not item:
        raise RuntimeError("Scryfall bulk metadata did not contain a Default Cards dataset.")
    # Current API generally provides download_uri. jsonl_download_uri is accepted
    # defensively for possible bulk format changes.
    # Prefer compressed JSONL when Scryfall exposes it: it is smaller and can
    # be processed one card per line. Fall back to the traditional JSON export.
    url = item.get("jsonl_download_uri") or item.get("download_uri")
    if not url:
        raise RuntimeError("Default Cards metadata did not include a download URL.")
    return url, str(item.get("updated_at", "unknown"))


def iter_bulk_cards(path: Path) -> Iterable[dict[str, Any]]:
    """Yield cards from a JSON array or newline-delimited JSON, compressed or plain."""
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8") as handle:
        first = ""
        while not first:
            pos = handle.tell()
            char = handle.read(1)
            if not char:
                return
            if not char.isspace():
                handle.seek(pos)
                first = char
        if first == "[":
            # Bulk data traditionally ships as a JSON array. Stream array members
            # without loading the entire multi-gigabyte decoded document at once.
            decoder = json.JSONDecoder()
            buffer = ""
            started = False
            eof = False
            while True:
                if not eof and len(buffer) < 1024 * 1024:
                    chunk = handle.read(1024 * 1024)
                    if chunk:
                        buffer += chunk
                    else:
                        eof = True
                if not started:
                    bracket = buffer.find("[")
                    if bracket >= 0:
                        buffer = buffer[bracket + 1:]
                        started = True
                buffer = buffer.lstrip()
                if buffer.startswith(","):
                    buffer = buffer[1:].lstrip()
                if buffer.startswith("]"):
                    break
                if not buffer:
                    if eof:
                        break
                    continue
                try:
                    obj, end = decoder.raw_decode(buffer)
                except json.JSONDecodeError:
                    if eof:
                        raise
                    continue
                if isinstance(obj, dict):
                    yield obj
                buffer = buffer[end:]
        else:
            # JSONL bulk data: each line is a complete card object.
            # The stream was rewound to the first non-whitespace character.
            # Read the whole first line from there (prefixing `first` again
            # would duplicate the first character and corrupt the JSON).
            if first:
                line = handle.readline()
                if line.strip():
                    yield json.loads(line)
            for line in handle:
                if line.strip():
                    yield json.loads(line)


def get_card_colors(card: dict[str, Any]) -> list[str]:
    """Return actual card colors, deliberately ignoring color_identity.

    Rogue's Passage uses card color for starter eligibility. Off-color costs in
    activated abilities, kicker, flashback, and similar text do not disqualify
    an otherwise single-color card.
    """
    colors = card.get("colors")
    if colors is not None:
        return list(colors)
    faces = card.get("card_faces") or []
    merged = set()
    for face in faces:
        merged.update(face.get("colors") or [])
    return sorted(merged)


def get_oracle_text(card: dict[str, Any]) -> str:
    if card.get("oracle_text"):
        return str(card["oracle_text"])
    return "\n".join(str(face.get("oracle_text", "")) for face in card.get("card_faces") or [])


def card_is_land(card: dict[str, Any]) -> bool:
    type_line = str(card.get("type_line", ""))
    if "Land" in type_line.split("—")[0].split():
        return True
    return any("Land" in str(face.get("type_line", "")).split("—")[0].split()
               for face in card.get("card_faces") or [])


def card_is_eligible_printing(card: dict[str, Any], config: dict[str, Any]) -> tuple[bool, str | None]:
    if not card.get("oracle_id") or not card.get("name"):
        return False, "missing_identity"
    if card.get("lang", "en") != "en":
        return False, "non_english"
    if card.get("digital", False) and "paper" not in card.get("games", []):
        return False, "digital_only"
    if config.get("require_paper_game", True) and "paper" not in card.get("games", []):
        return False, "not_paper"
    if card.get("layout") in config.get("excluded_layouts", []):
        return False, "excluded_layout"
    if card.get("rarity") not in config.get("eligible_rarities", ["common", "uncommon"]):
        return False, "rarity"
    if card.get("frame") not in config.get("eligible_frame_values", ["2003", "2015", "future"]):
        return False, "frame"
    released_at = str(card.get("released_at", ""))
    if released_at < str(config.get("mirrodin_release_date", "2003-10-02")):
        return False, "release_date"
    # Preview/upcoming cards are intentionally eligible by default. Set
    # allow_future_printings=false to enforce a build-date upper cutoff.
    if not config.get("allow_future_printings", True):
        build_date = str(config.get("build_date") or date.today().isoformat())
        if released_at > build_date:
            return False, "future_release_date"
    if card.get("border_color") in config.get("excluded_border_colors", ["silver", "gold"]):
        return False, "border_color"
    if config.get("exclude_funny_sets", True):
        # Card objects do not consistently include set_type, so use known
        # silver-border/acorn markers plus configurable set-code exclusions.
        funny_set_codes = {str(code).lower() for code in config.get("excluded_set_codes", [])}
        if str(card.get("set", "")).lower() in funny_set_codes:
            return False, "funny_set"
        if card.get("security_stamp") == "acorn":
            return False, "acorn_card"
        if card.get("set_type") == "funny":
            return False, "funny_set"
    if config.get("exclude_tokens", True) and (
        card.get("set_type") == "token" or card.get("layout") in {"token", "double_faced_token"}
        or "Token" in str(card.get("type_line", ""))
    ):
        return False, "token"
    if card_is_land(card):
        return False, "land"
    colors = get_card_colors(card)
    if len(colors) != 1 or colors[0] not in config.get("eligible_colors", list(COLOR_NAMES)):
        return False, "not_single_chosen_color"
    text = get_oracle_text(card)
    for pattern in config.get("excluded_oracle_text_regex", []):
        if re.search(pattern, text):
            return False, "playability_exclusion"
    # Exclude cards that are explicitly marked as non-gameplay extras.
    if card.get("promo_types") and any(p in {"playtest", "memorabilia"} for p in card["promo_types"]):
        return False, "non_gameplay_promo"
    return True, None


def compact_printing(card: dict[str, Any]) -> dict[str, Any]:
    image_uris = card.get("image_uris") or {}
    if not image_uris and card.get("card_faces"):
        image_uris = next((face.get("image_uris", {}) for face in card["card_faces"] if face.get("image_uris")), {})
    return {
        "scryfall_id": card.get("id"),
        "set": card.get("set"),
        "set_name": card.get("set_name"),
        "collector_number": card.get("collector_number"),
        "released_at": card.get("released_at"),
        "rarity": card.get("rarity"),
        "frame": card.get("frame"),
        "border_color": card.get("border_color"),
        "scryfall_uri": card.get("scryfall_uri"),
        "image_uris": {
            key: image_uris[key] for key in ("small", "normal", "large", "png")
            if image_uris.get(key)
        },
    }


def compact_card(card: dict[str, Any], printings: list[dict[str, Any]]) -> dict[str, Any]:
    colors = get_card_colors(card)
    faces = card.get("card_faces") or []
    return {
        "oracle_id": card["oracle_id"],
        "name": card["name"],
        "color": colors[0],
        "mana_cost": card.get("mana_cost") or (faces[0].get("mana_cost") if faces else ""),
        "cmc": card.get("cmc", 0),
        "type_line": card.get("type_line") or (faces[0].get("type_line") if faces else ""),
        "oracle_text": get_oracle_text(card),
        "power": card.get("power"),
        "toughness": card.get("toughness"),
        "keywords": card.get("keywords", []),
        "layout": card.get("layout"),
        "printings": sorted(printings, key=lambda p: (p.get("released_at", ""), p.get("set", ""))),
    }


def build_catalog(cards: Iterable[dict[str, Any]], config: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    by_oracle: dict[str, dict[str, Any]] = {}
    printings_by_oracle: dict[str, list[dict[str, Any]]] = defaultdict(list)
    rejected = Counter()
    printing_count = 0

    for card in cards:
        printing_count += 1
        eligible, reason = card_is_eligible_printing(card, config)
        if not eligible:
            rejected[reason or "unknown"] += 1
            continue
        oid = card["oracle_id"]
        printings_by_oracle[oid].append(compact_printing(card))
        # Keep a representative object with the most useful text/fields.
        if oid not in by_oracle or (
            bool(card.get("image_uris")) and not by_oracle[oid].get("image_uris")
        ):
            by_oracle[oid] = card

    catalog = [
        compact_card(card, printings_by_oracle[oid])
        for oid, card in by_oracle.items()
    ]
    catalog.sort(key=lambda c: (c["color"], c["name"].casefold()))
    future_printings = [
        printing
        for printings in printings_by_oracle.values()
        for printing in printings
        if str(printing.get("released_at", "")) > date.today().isoformat()
    ]
    future_only_cards = sum(
        1 for printings in printings_by_oracle.values()
        if printings and all(str(p.get("released_at", "")) > date.today().isoformat() for p in printings)
    )
    report = {
        "project_name": config.get("project_name", "Rogue's Passage"),
        "source": "Scryfall Default Cards bulk data",
        "color_eligibility_mode": config.get("color_eligibility_mode", "card_color"),
        "allow_future_printings": config.get("allow_future_printings", True),
        "future_dated_eligible_printings": len(future_printings),
        "cards_with_only_future_printings": future_only_cards,
        "printings_examined": printing_count,
        "unique_eligible_cards": len(catalog),
        "eligible_by_color": {
            color: sum(1 for c in catalog if c["color"] == color)
            for color in config.get("eligible_colors", list(COLOR_NAMES))
        },
        "rejected_printings_by_reason": dict(sorted(rejected.items())),
    }
    return catalog, report


def generate_pool(catalog: list[dict[str, Any]], colors: tuple[str, str], config: dict[str, Any],
                  rng: random.Random) -> dict[str, Any]:
    count = int(config.get("starter_cards_per_color", 10))
    max_copies = int(config.get("max_copies_per_card_in_pool", 4))
    result: list[dict[str, Any]] = []
    for color in colors:
        eligible = [c for c in catalog if c["color"] == color]
        if not eligible:
            raise ValueError(f"No eligible cards available for color {color}.")
        # Sampling with replacement is capped per Oracle ID, so duplicates can
        # occur but never exceed the configured limit.
        chosen: list[dict[str, Any]] = []
        copies: Counter[str] = Counter()
        while len(chosen) < count:
            available = [c for c in eligible if copies[c["oracle_id"]] < max_copies]
            if not available:
                raise ValueError(
                    f"Cannot fill {count} cards for {color}: only "
                    f"{len(eligible)} eligible identities with max {max_copies} copies."
                )
            card = rng.choice(available)
            copies[card["oracle_id"]] += 1
            chosen.append(card)
        result.extend({**card, "pool_color": color} for card in chosen)
    return {"colors": list(colors), "cards": result}


def build_tts_catalog(catalog: list[dict[str, Any]]) -> dict[str, Any]:
    """Create a small, TTS-friendly catalog with one representative image per card."""
    cards = []
    for card in catalog:
        image_url = None
        representative_printing = None
        for printing in card.get("printings", []):
            image_uris = printing.get("image_uris") or {}
            image_url = image_uris.get("normal") or image_uris.get("large") or image_uris.get("png") or image_uris.get("small")
            if image_url:
                representative_printing = printing
                break
        if not image_url:
            continue
        cards.append({
            "oracle_id": card["oracle_id"],
            "name": card["name"],
            "color": card["color"],
            "mana_cost": card.get("mana_cost", ""),
            "cmc": card.get("cmc", 0),
            "type_line": card.get("type_line", ""),
            "oracle_text": card.get("oracle_text", ""),
            "power": card.get("power"),
            "toughness": card.get("toughness"),
            "image_url": image_url,
            "scryfall_uri": representative_printing.get("scryfall_uri") if representative_printing else None,
        })
    return {
        "project_name": "Rogue's Passage",
        "schema_version": 1,
        "generated_by": "RoguesPassageCardCatalog/0.3",
        "cards": cards,
    }


def build_tts_color_catalogs(catalog: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Split the compact TTS catalog into independently downloadable color files."""
    return {
        color: {
            **build_tts_catalog([card for card in catalog if card.get("color") == color]),
            "color": color,
        }
        for color in COLOR_NAMES
    }

def validate_all_color_pairs(catalog: list[dict[str, Any]], config: dict[str, Any]) -> list[dict[str, Any]]:
    seed = config.get("random_seed")
    results = []
    for index, pair in enumerate(COLOR_PAIRS):
        rng = random.Random(seed if seed is not None else None)
        try:
            pool = generate_pool(catalog, pair, config, rng)
            counts = Counter(card["color"] for card in pool["cards"])
            results.append({
                "colors": list(pair),
                "status": "ok",
                "total_cards": len(pool["cards"]),
                "cards_by_color": dict(counts),
                "unique_cards": len(set(c["oracle_id"] for c in pool["cards"])),
            })
        except ValueError as exc:
            results.append({"colors": list(pair), "status": "error", "error": str(exc)})
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the Rogue's Passage Scryfall card catalog.")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--catalog-out", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--report-out", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--tts-catalog-dir", type=Path, default=Path(__file__).with_name("tts_catalogs"),
                        help="Output directory for five color-specific TTS catalogs.")
    parser.add_argument("--input", type=Path, help="Optional local Scryfall JSON/JSONL bulk file for offline builds.")
    parser.add_argument("--no-download", action="store_true", help="Use cached bulk data only.")
    args = parser.parse_args()

    config = json.loads(args.config.read_text(encoding="utf-8"))
    setup_logging(DEFAULT_LOG)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_path = CACHE_DIR / "default-cards.json"
    input_path = args.input

    try:
        if input_path:
            source_path = input_path
            updated_at = "local input"
        else:
            if not cache_path.exists() and args.no_download:
                raise RuntimeError(f"No cached bulk file found at {cache_path}; omit --no-download to download it.")
            if not args.no_download:
                url, updated_at = get_bulk_download_url(CACHE_DIR)
                # Preserve the full extension so gzip and JSONL formats are detected.
                if url.endswith(".jsonl.gz"):
                    suffix = ".jsonl.gz"
                elif url.endswith(".json.gz"):
                    suffix = ".json.gz"
                elif url.endswith(".jsonl"):
                    suffix = ".jsonl"
                else:
                    suffix = ".json"
                cache_path = CACHE_DIR / ("default-cards" + suffix)
                download_file(url, cache_path)
            else:
                updated_at = "cached"
            source_path = cache_path

        logging.info("Project: %s", config.get("project_name", "Rogue's Passage"))
        logging.info("Reading bulk file: %s", source_path)
        catalog, report = build_catalog(iter_bulk_cards(source_path), config)
        report["bulk_data_updated_at"] = updated_at
        report["color_pair_validation"] = validate_all_color_pairs(catalog, config)

        args.catalog_out.parent.mkdir(parents=True, exist_ok=True)
        args.report_out.parent.mkdir(parents=True, exist_ok=True)
        args.tts_catalog_dir.mkdir(parents=True, exist_ok=True)
        args.catalog_out.write_text(json.dumps({
            "project_name": config.get("project_name", "Rogue's Passage"),
            "schema_version": 1,
            "generated_by": "RoguesPassageCardCatalog/0.1",
            "cards": catalog,
        }, indent=2, ensure_ascii=False), encoding="utf-8")
        args.report_out.write_text(json.dumps(report, indent=2), encoding="utf-8")
        tts_catalogs = build_tts_color_catalogs(catalog)
        tts_export_count = 0
        for color, color_catalog in tts_catalogs.items():
            output_path = args.tts_catalog_dir / f"tts_catalog_{color}.json"
            output_path.write_text(
                json.dumps(color_catalog, separators=(",", ":"), ensure_ascii=False),
                encoding="utf-8",
            )
            tts_export_count += len(color_catalog["cards"])
            logging.info("TTS %s catalog written: %s (%d cards)", color, output_path, len(color_catalog["cards"]))
        report["tts_export_cards"] = tts_export_count
        report["tts_catalog_files"] = len(tts_catalogs)
        args.report_out.write_text(json.dumps(report, indent=2), encoding="utf-8")

        logging.info("Catalog written: %s (%d unique cards)", args.catalog_out, len(catalog))
        logging.info("Report written: %s", args.report_out)
        failures = [r for r in report["color_pair_validation"] if r["status"] != "ok"]
        if failures:
            logging.warning("%d of 10 color pairs could not produce a valid pool.", len(failures))
            for failure in failures:
                logging.warning("Pair %s: %s", "/".join(failure["colors"]), failure.get("error"))
            return 2
        logging.info("All 10 color pairs passed starter-pool validation.")
        return 0
    except (OSError, json.JSONDecodeError, urllib.error.URLError, RuntimeError, ValueError) as exc:
        logging.error("%s", exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
