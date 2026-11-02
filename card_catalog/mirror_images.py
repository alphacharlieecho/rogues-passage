#!/usr/bin/env python3
"""Mirror selected Scryfall images and rewrite generated TTS JSON to local GitHub URLs.

Run after build_catalog.py. Requires Pillow. Fails closed: JSON is not published
unless every referenced image is successfully downloaded and verified.
"""
import argparse
import io
import json
import logging
import re
import time
import urllib.error
import urllib.request
from pathlib import Path

from PIL import Image, UnidentifiedImageError

ROOT = Path(__file__).resolve().parents[1]
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f-]{27,}$")
HEADERS = {"User-Agent": "RoguesPassageImageMirror/1.0 (hobby project)", "Accept": "image/*"}

def image_id(url):
    name = url.split("?", 1)[0].rsplit("/", 1)[-1]
    stem = name.rsplit(".", 1)[0].lower()
    if not UUID.fullmatch(stem):
        raise ValueError(f"Unexpected Scryfall image filename: {url}")
    return stem

def download_jpg(url, destination, delay):
    if destination.exists():
        try:
            with Image.open(destination) as img:
                img.verify()
            return False
        except (OSError, UnidentifiedImageError):
            destination.unlink()
    for attempt in range(5):
        try:
            request = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(request, timeout=45) as response:
                if not response.headers.get("Content-Type", "").lower().startswith("image/"):
                    raise ValueError(f"Non-image response for {url}")
                data = response.read(12 * 1024 * 1024 + 1)
                if len(data) > 12 * 1024 * 1024:
                    raise ValueError(f"Image too large: {url}")
            with Image.open(io.BytesIO(data)) as image:
                image.load()
                if image.width < 100 or image.height < 100:
                    raise ValueError(f"Image too small: {url}")
                converted = image.convert("RGB")
                destination.parent.mkdir(parents=True, exist_ok=True)
                temporary = destination.with_suffix(".jpg.part")
                converted.save(temporary, format="JPEG", quality=85, optimize=True)
                temporary.replace(destination)
            time.sleep(delay)
            return True
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            if attempt == 4:
                raise RuntimeError(f"Download failed: {url}") from exc
            time.sleep(min(2 ** attempt, 12))
    raise RuntimeError(url)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, help="GitHub owner/repository")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--delay", type=float, default=0.12)
    parser.add_argument("--limit", type=int, default=0, help="Optional dry-run subset; does not rewrite JSON")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
        parser.error("Invalid GitHub repository")
    files = sorted((ROOT / "card_catalog" / "tts_starter_pools").glob("starter_pool_*.json"))
    files += sorted((ROOT / "card_catalog" / "tts_catalogs").glob("tts_catalog_*.json"))
    if not files:
        raise RuntimeError("No generated TTS JSON files found")
    documents = [(path, json.loads(path.read_text(encoding="utf-8"))) for path in files]
    sources = {}
    for _, document in documents:
        for card in document["cards"]:
            url = card.get("image_url")
            if not url:
                raise ValueError(f"Missing image_url for {card.get('name')}")
            if "cards.scryfall.io/" in url:
                sources[image_id(url)] = url
    logging.info("Found %s unique Scryfall images", len(sources))
    count = 0
    for identifier, url in sorted(sources.items()):
        if args.limit and count >= args.limit:
            break
        path = ROOT / "card_catalog" / "images" / f"{identifier}.jpg"
        download_jpg(url, path, args.delay)
        count += 1
        if count % 50 == 0:
            logging.info("Processed %d / %d images", count, len(sources))
    if args.limit:
        logging.info("Sample complete; JSON unchanged")
        return
    prefix = f"https://raw.githubusercontent.com/{args.repo}/{args.branch}/card_catalog/images/"
    for path, document in documents:
        for card in document["cards"]:
            url = card["image_url"]
            if "cards.scryfall.io/" in url:
                card["image_url"] = prefix + image_id(url) + ".jpg"
        path.write_text(json.dumps(document, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    logging.info("Rewrote %d JSON files with mirrored image URLs", len(files))

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    main()
