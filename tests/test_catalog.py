import sys
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
    "excluded_oracle_text_regex": [r"(?i)\\bante\\b"],
    "random_seed": 42,
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

    def test_reports_shortage_when_no_cards_available(self):
        with self.assertRaises(ValueError):
            build_catalog.generate_pool([], ("W", "U"), CONFIG, __import__("random").Random(42))


if __name__ == "__main__":
    unittest.main()
