import gzip
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "card_catalog"))
import build_catalog


def printing(oracle_id, name, color, **overrides):
    card = {
        "oracle_id": oracle_id,
        "id": "printing-" + oracle_id,
        "name": name,
        "lang": "en",
        "games": ["paper"],
        "digital": False,
        "layout": "normal",
        "rarity": "common",
        "frame": "2015",
        "released_at": "2020-01-01",
        "border_color": "black",
        "set_type": "expansion",
        "type_line": "Creature — Test",
        "colors": [color],
        "oracle_text": "A simple test card.",
        "image_uris": {"small": "https://example.test/card.jpg"},
        "set": "tst",
        "set_name": "Test Set",
        "collector_number": "1",
        "scryfall_uri": "https://scryfall.com/card/tst/1",
    }
    card.update(overrides)
    return card


CONFIG = {
    "project_name": "Rogue's Passage",
    "mirrodin_release_date": "2003-10-02",
    "eligible_frame_values": ["2003", "2015", "future"],
    "eligible_rarities": ["common", "uncommon"],
    "eligible_colors": ["W", "U", "B", "R", "G"],
    "starter_cards_per_color": 10,
    "max_copies_per_card_in_pool": 4,
    "require_paper_game": True,
    "exclude_tokens": True,
    "exclude_funny_sets": True,
    "excluded_layouts": ["token", "double_faced_token"],
    "excluded_set_types": ["funny"],
    "excluded_border_colors": ["silver", "gold"],
    "excluded_oracle_text_regex": [r"(?i)\bante\b"],
    "random_seed": 42,
    "color_eligibility_mode": "card_color",
    "allow_future_printings": True,
}


class CatalogTests(unittest.TestCase):
    def test_accepts_valid_single_color_common(self):
        ok, reason = build_catalog.card_is_eligible_printing(printing("a", "Card A", "R"), CONFIG)
        self.assertTrue(ok)
        self.assertIsNone(reason)

    def test_rejects_colorless_multicolor_lands_and_rare(self):
        cases = [
            printing("a", "Colorless", None, colors=[]),
            printing("b", "Multicolor", "R", colors=["R", "G"]),
            printing("c", "Land", "G", type_line="Basic Land — Forest"),
            printing("d", "Rare", "U", rarity="rare"),
        ]
        for card in cases:
            ok, _ = build_catalog.card_is_eligible_printing(card, CONFIG)
            self.assertFalse(ok, card["name"])

    def test_rejects_old_frame_and_pre_mirrodin_printing(self):
        self.assertFalse(build_catalog.card_is_eligible_printing(
            printing("a", "Old Frame", "W", frame="1997"), CONFIG)[0])
        self.assertFalse(build_catalog.card_is_eligible_printing(
            printing("b", "Old Set", "W", released_at="2001-01-01"), CONFIG)[0])

    def test_card_color_mode_ignores_off_color_identity(self):
        card = printing(
            "off-color-ability", "Off-color Ability", "B",
            color_identity=["B", "G"],
            oracle_text="{G}: This creature gets +1/+1 until end of turn.",
        )
        self.assertTrue(build_catalog.card_is_eligible_printing(card, CONFIG)[0])

    def test_multicolor_card_is_still_rejected_in_card_color_mode(self):
        card = printing(
            "multi", "Multicolor Card", "B",
            colors=["B", "G"], color_identity=["B", "G"],
        )
        self.assertEqual(
            build_catalog.card_is_eligible_printing(card, CONFIG),
            (False, "not_single_chosen_color"),
        )

    def test_future_preview_printings_are_allowed_by_default(self):
        card = printing("future", "Preview Card", "U", released_at="2099-12-31")
        self.assertTrue(build_catalog.card_is_eligible_printing(card, CONFIG)[0])

    def test_future_printings_can_be_disabled_explicitly(self):
        config = {**CONFIG, "allow_future_printings": False, "build_date": "2026-10-30"}
        future = printing("future", "Future Card", "U", released_at="2026-11-13")
        current = printing("current", "Current Card", "U", released_at="2026-10-30")
        self.assertEqual(
            build_catalog.card_is_eligible_printing(future, config),
            (False, "future_release_date"),
        )
        self.assertTrue(build_catalog.card_is_eligible_printing(current, config)[0])

    def test_groups_printings_by_oracle_id(self):
        cards = [
            printing("same", "Same Card", "G", set="one"),
            printing("same", "Same Card", "G", set="two", collector_number="2"),
        ]
        catalog, report = build_catalog.build_catalog(cards, CONFIG)
        self.assertEqual(len(catalog), 1)
        self.assertEqual(len(catalog[0]["printings"]), 2)
        self.assertEqual(report["unique_eligible_cards"], 1)

    def test_pool_respects_per_color_count_and_duplicate_cap(self):
        catalog = []
        for color in ("W", "U"):
            for i in range(5):
                card = printing(f"{color}{i}", f"{color} Card {i}", color)
                catalog.append(build_catalog.compact_card(card, [build_catalog.compact_printing(card)]))
        pool = build_catalog.generate_pool(catalog, ("W", "U"), CONFIG, __import__("random").Random(42))
        self.assertEqual(len(pool["cards"]), 20)
        for color in ("W", "U"):
            matching = [c for c in pool["cards"] if c["color"] == color]
            self.assertEqual(len(matching), 10)
            from collections import Counter
            self.assertLessEqual(max(Counter(c["oracle_id"] for c in matching).values()), 4)

    def test_configured_oracle_exclusions_match_word_boundaries(self):
        config_path = Path(__file__).resolve().parents[1] / "card_catalog" / "config.json"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        banned = printing("banned", "Ante Card", "B", oracle_text="Each player must ante a card.")
        allowed = printing("allowed", "Advantage Card", "B", oracle_text="Gain an advantage.")
        self.assertEqual(build_catalog.card_is_eligible_printing(banned, config), (False, "playability_exclusion"))
        self.assertTrue(build_catalog.card_is_eligible_printing(allowed, config)[0])

    def test_iter_bulk_cards_reads_json_array_jsonl_and_gzip(self):
        cards = [{"name": "One"}, {"name": "Two"}]
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            array_path = temp_path / "cards.json"
            array_path.write_text(json.dumps(cards), encoding="utf-8")
            self.assertEqual(list(build_catalog.iter_bulk_cards(array_path)), cards)

            jsonl_path = temp_path / "cards.jsonl"
            jsonl_path.write_text("\n".join(json.dumps(card) for card in cards) + "\n", encoding="utf-8")
            self.assertEqual(list(build_catalog.iter_bulk_cards(jsonl_path)), cards)

            gzip_path = temp_path / "cards.jsonl.gz"
            with gzip.open(gzip_path, "wt", encoding="utf-8") as handle:
                handle.write("\n".join(json.dumps(card) for card in cards) + "\n")
            self.assertEqual(list(build_catalog.iter_bulk_cards(gzip_path)), cards)

    def test_builds_compact_tts_catalog_with_representative_image(self):
        source = {
            "oracle_id": "card-1",
            "name": "TTS Test Card",
            "color": "W",
            "mana_cost": "{W}",
            "cmc": 1,
            "type_line": "Creature — Test",
            "oracle_text": "A test ability.",
            "power": "1",
            "toughness": "1",
            "printings": [{
                "scryfall_uri": "https://scryfall.com/card/tst/1",
                "image_uris": {"small": "https://example.test/front.jpg"},
            }],
        }
        result = build_catalog.build_tts_catalog([source])
        self.assertEqual(result["schema_version"], 1)
        self.assertEqual(len(result["cards"]), 1)
        card = result["cards"][0]
        self.assertEqual(card["oracle_id"], "card-1")
        self.assertEqual(card["image_url"], "https://example.test/front.jpg")
        self.assertNotIn("printings", card)

    def test_builds_five_separate_color_catalogs(self):
        source = []
        for color in ("W", "U", "B", "R", "G"):
            source.append({
                "oracle_id": "card-" + color,
                "name": color + " Card",
                "color": color,
                "mana_cost": "{" + color + "}",
                "cmc": 1,
                "type_line": "Creature — Test",
                "oracle_text": "A test ability.",
                "power": "1",
                "toughness": "1",
                "printings": [{
                    "scryfall_uri": "https://scryfall.com/card/tst/1",
                    "image_uris": {"normal": "https://example.test/" + color + ".jpg"},
                }],
            })
        catalogs = build_catalog.build_tts_color_catalogs(source)
        self.assertEqual(set(catalogs), {"W", "U", "B", "R", "G"})
        for color, result in catalogs.items():
            self.assertEqual(result["color"], color)
            self.assertEqual(len(result["cards"]), 1)
            self.assertEqual(result["cards"][0]["color"], color)

    def test_builds_small_tts_starter_pool_variants(self):
        source = []
        for color in ("W", "U", "B", "R", "G"):
            for index in range(12):
                source.append({
                    "oracle_id": f"{color}-{index}",
                    "name": f"{color} Card {index}",
                    "color": color,
                    "mana_cost": "{" + color + "}",
                    "cmc": 1,
                    "type_line": "Creature — Test",
                    "oracle_text": "A test ability.",
                    "power": "1",
                    "toughness": "1",
                    "printings": [{
                        "scryfall_uri": f"https://scryfall.com/card/tst/{color}{index}",
                        "image_uris": {"normal": f"https://example.test/{color}{index}.jpg"},
                    }],
                })
        pools = build_catalog.build_tts_starter_pools(
            source, CONFIG, variants_per_color=3
        )
        self.assertEqual(set(pools), {"W", "U", "B", "R", "G"})
        for color, variants in pools.items():
            self.assertEqual(len(variants), 3)
            for expected_variant, pool in enumerate(variants, start=1):
                self.assertEqual(pool["color"], color)
                self.assertEqual(pool["variant"], expected_variant)
                self.assertEqual(len(pool["cards"]), 10)
                self.assertTrue(all(card["color"] == color for card in pool["cards"]))
                from collections import Counter
                self.assertLessEqual(
                    max(Counter(card["oracle_id"] for card in pool["cards"]).values()),
                    4,
                )

    def test_reports_shortage_when_no_cards_available(self):
        with self.assertRaises(ValueError):
            build_catalog.generate_pool([], ("W", "U"), CONFIG, __import__("random").Random(42))


if __name__ == "__main__":
    unittest.main()
