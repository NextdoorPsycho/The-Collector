#!/usr/bin/env python3
"""Build the scanner's public metadata and visual package from Scryfall bulk data."""

import argparse
import concurrent.futures
import gzip
import hashlib
import io
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request

from PIL import Image, ImageChops, ImageOps, ImageStat

SCHEMA = "rgb-gradient-8x8-v1"
REFERENCE_SCHEMA = "gray48-bt601-cg-high-v1"
HEADERS = {"User-Agent": "TheCollector/1.0 (card collection app)", "Accept": "application/json"}
MAX_IMAGE_BYTES = 4 * 1024 * 1024
MAX_SHARD_BYTES = 4 * 1024 * 1024


def fetch(url, limit, accept="application/json"):
    request = urllib.request.Request(url, headers={**HEADERS, "Accept": accept, "Accept-Encoding": "identity"})
    with urllib.request.urlopen(request, timeout=30) as response:
        value = response.read(limit + 1)
    if len(value) > limit:
        raise ValueError("Response exceeds its limit")
    return value


def download_bulk(destination):
    metadata = json.loads(fetch("https://api.scryfall.com/bulk-data", 1024 * 1024))
    selected = next(record for record in metadata["data"] if record["type"] == "default_cards")
    uri = selected["jsonl_download_uri"]
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme != "https" or parsed.hostname not in {"data.scryfall.io", "bulk.scryfall.com"}:
        raise ValueError("Unexpected bulk download host")
    if not destination.exists():
        temporary = destination.with_suffix(".download")
        request = urllib.request.Request(uri, headers={**HEADERS, "Accept-Encoding": "identity"})
        with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as output:
            total = 0
            while block := response.read(1024 * 1024):
                total += len(block)
                if total > 2 * 1024 * 1024 * 1024:
                    raise ValueError("Bulk source exceeds its limit")
                output.write(block)
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(destination)
    return selected


def stream_cards(path):
    if path.name.endswith(".jsonl.gz") or path.name.endswith(".jsonl"):
        opener = gzip.open if path.name.endswith(".gz") else open
        with opener(path, "rt", encoding="utf-8") as source:
            for line in source:
                if len(line) > 8 * 1024 * 1024:
                    raise ValueError("Oversized bulk card record")
                card = json.loads(line)
                if not isinstance(card, dict) or card.get("object") != "card":
                    raise ValueError("Invalid bulk card record")
                yield card
        return
    decoder = json.JSONDecoder()
    with path.open("r", encoding="utf-8") as source:
        buffer = ""
        ended = False
        started = False
        while not ended:
            block = source.read(1024 * 1024)
            buffer += block
            offset = 0
            while True:
                while offset < len(buffer) and buffer[offset].isspace():
                    offset += 1
                if not started:
                    if offset >= len(buffer):
                        break
                    if buffer[offset] != "[":
                        raise ValueError("Bulk data must be a JSON array")
                    started = True
                    offset += 1
                    continue
                if offset < len(buffer) and buffer[offset] == ",":
                    offset += 1
                    continue
                if offset < len(buffer) and buffer[offset] == "]":
                    ended = True
                    offset += 1
                    break
                try:
                    card, end = decoder.raw_decode(buffer, offset)
                except json.JSONDecodeError:
                    break
                if not isinstance(card, dict) or card.get("object") != "card":
                    raise ValueError("Invalid bulk card record")
                yield card
                offset = end
            buffer = buffer[offset:]
            if len(buffer) > 8 * 1024 * 1024:
                raise ValueError("Oversized bulk card record")
            if not block and not ended:
                raise ValueError("Truncated bulk data")
        if buffer.strip() or source.read().strip():
            raise ValueError("Data follows the bulk array")


def descriptor(image_bytes):
    with Image.open(io.BytesIO(image_bytes)) as image:
        image = ImageOps.exif_transpose(image).convert("RGB").resize((64, 64), Image.Resampling.LANCZOS)
        image.load()
    if max(high - low for low, high in image.getextrema()) <= 12:
        raise ValueError("Artwork has no usable variation")
    horizontal = Image.new("RGB", (64, 64))
    horizontal.paste(ImageChops.difference(image.crop((0, 0, 63, 64)), image.crop((1, 0, 64, 64))))
    vertical = Image.new("RGB", (64, 64))
    vertical.paste(ImageChops.difference(image.crop((0, 0, 64, 63)), image.crop((0, 1, 64, 64))))
    vector = []
    for cell_y in range(8):
        for cell_x in range(8):
            region = (cell_x * 8, cell_y * 8, (cell_x + 1) * 8, (cell_y + 1) * 8)
            vector.extend(value / 255 for value in ImageStat.Stat(image.crop(region)).mean)
            gradient = sum(ImageStat.Stat(horizontal.crop(region)).sum) + sum(ImageStat.Stat(vertical.crop(region)).sum)
            vector.append(gradient / (765 * 128))
    if len(vector) != 256 or any(not math.isfinite(value) or not 0 <= value <= 1 for value in vector):
        raise ValueError("Invalid artwork descriptor")
    return bytes(round(value * 255) for value in vector)


def build_visual(reference, cache):
    identity, uri = reference
    key = hashlib.sha256(identity.encode()).hexdigest()
    vector_path = cache / f"{key}.vec"
    if vector_path.exists() and vector_path.stat().st_size == 256:
        return identity, vector_path.read_bytes(), None
    image_path = cache / f"{key}.jpg"
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme != "https" or parsed.hostname != "cards.scryfall.io":
        return identity, None, "Invalid artwork host"
    failure = None
    for attempt in range(3):
        try:
            payload = image_path.read_bytes() if image_path.exists() else fetch(uri, MAX_IMAGE_BYTES, "image/jpeg")
            vector = descriptor(payload)
            image_path.write_bytes(payload)
            temporary = vector_path.with_suffix(".pending")
            temporary.write_bytes(vector)
            temporary.replace(vector_path)
            return identity, vector, None
        except Exception as error:
            failure = type(error).__name__
            if image_path.exists():
                image_path.unlink()
            time.sleep(min(8, 2 ** attempt))
    return identity, None, failure


def write_json(path, value):
    payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
    path.write_bytes(gzip.compress(payload, compresslevel=6, mtime=0))


def file_record(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return {"name": path.name, "bytes": path.stat().st_size, "sha256": digest.hexdigest()}


def package_structure(output, ordered, pixels):
    rows = []
    shard_number = 0
    shard = (output / "visual.gray.0000.bin").open("wb")
    shard.write(b"SCGRSH2\0")
    try:
        with pixels.open("rb") as source:
            header = source.read(16)
            if (len(header) != 16 or header[:8] != b"SCGRAY1\0" or
                    struct.unpack("<II", header[8:]) != (2304, len(ordered))):
                raise ValueError("Invalid reference pixel source")
            for _ in ordered:
                frame = source.read(2304)
                if len(frame) != 2304:
                    raise ValueError("Truncated reference pixels")
                payload = gzip.compress(frame, 6, mtime=0)
                if shard.tell() + len(payload) > MAX_SHARD_BYTES:
                    shard.close()
                    shard_number += 1
                    shard = (output / f"visual.gray.{shard_number:04}.bin").open("wb")
                    shard.write(b"SCGRSH2\0")
                rows.append([shard_number, shard.tell(), len(payload), hashlib.sha256(frame).hexdigest()])
                shard.write(payload)
            if source.read(1):
                raise ValueError("Unexpected reference pixel suffix")
    finally:
        shard.close()
    write_json(output / "visual.gray.index.json.gz", {
        "schema": REFERENCE_SCHEMA, "bytesPerReference": 2304, "rows": rows,
    })


def build_structure(ordered, cache, renderer, output):
    jobs = [{"id": identity, "imagePath": str((cache / f"{hashlib.sha256(identity.encode()).hexdigest()}.jpg").resolve())}
            for identity in ordered]
    if any(not Path(job["imagePath"]).is_file() for job in jobs):
        raise ValueError("A cached reference image is missing")
    with tempfile.TemporaryDirectory(prefix="collector-structure-") as temporary:
        root = Path(temporary)
        source = root / "jobs.json"
        source.write_text(json.dumps(jobs))
        pixels = root / "pixels.bin"
        if jobs:
            subprocess.run([str(renderer), str(source), str(pixels)], check=True)
        else:
            pixels.write_bytes(b"SCGRAY1\0" + struct.pack("<II", 2304, 0))
        package_structure(output, ordered, pixels)


def build(source, output, cache, source_metadata, renderer, workers=4, metadata_only=False, limit=None):
    if output.exists() and any(output.iterdir()):
        raise ValueError("Output directory must be empty")
    output.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    entries = []
    oracle_rows = {}
    references = {}
    chunk = []
    shard_number = 0
    shard = (output / f"cards.{shard_number:04}.bin").open("wb")

    def flush():
        nonlocal shard, shard_number, chunk
        if not chunk:
            return
        payload = gzip.compress(json.dumps(chunk, ensure_ascii=False, separators=(",", ":")).encode(), 6, mtime=0)
        if shard.tell() and shard.tell() + len(payload) > MAX_SHARD_BYTES:
            shard.close()
            shard_number += 1
            shard = (output / f"cards.{shard_number:04}.bin").open("wb")
        offset = shard.tell()
        shard.write(payload)
        for position, card in enumerate(chunk):
            faces = card.get("card_faces", [])
            illustrations = []
            for face in [card, *faces]:
                illustration = face.get("illustration_id")
                image = face.get("image_uris", {}).get("art_crop")
                if illustration and image:
                    references.setdefault(illustration, image)
                    illustrations.append(illustration)
            aliases = list(dict.fromkeys([card["name"], *[face["name"] for face in faces],
                                         *[face["printed_name"] for face in [card, *faces] if face.get("printed_name")]]))
            oracle = card.get("oracle_id") or card["id"]
            oracle_rows.setdefault(oracle, [card.get("type_line", ""),
                                           "\n".join(face.get("oracle_text", "") for face in [card, *faces])])
            entries.append([card["id"], card["name"], card["set"], card["collector_number"],
                            card["lang"], oracle, list(dict.fromkeys(illustrations)),
                            shard_number, offset, len(payload), position, aliases])
        chunk = []

    ids = set()
    for card in stream_cards(source):
        if card["id"] in ids:
            raise ValueError("Duplicate printing ID in bulk data")
        ids.add(card["id"])
        chunk.append(card)
        if len(chunk) == 100:
            flush()
    flush()
    shard.close()
    if not entries:
        raise ValueError("Empty metadata catalog")
    write_json(output / "catalog.index.json.gz", {"schema": 1, "entries": entries, "oracleRows": oracle_rows})
    selected = list(references.items())
    if limit is not None:
        selected = selected[:limit]
    vectors = {}
    failed = {}
    if not metadata_only:
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            waiting = {}
            iterator = iter(selected)
            for _ in range(workers):
                reference = next(iterator, None)
                if reference is not None:
                    waiting[pool.submit(build_visual, reference, cache)] = reference[0]
            while waiting:
                done, _ = concurrent.futures.wait(waiting, return_when=concurrent.futures.FIRST_COMPLETED)
                for task in done:
                    waiting.pop(task)
                    identity, vector, failure = task.result()
                    if vector is not None:
                        vectors[identity] = vector
                    else:
                        failed[identity] = failure
                    reference = next(iterator, None)
                    if reference is not None:
                        waiting[pool.submit(build_visual, reference, cache)] = reference[0]
                processed = len(vectors) + len(failed)
                if processed % 100 == 0 or not waiting:
                    print(f"artwork {processed}/{len(selected)}; failed {len(failed)}", flush=True)
    ordered = sorted(vectors)
    with (output / "visual.index.bin").open("wb") as visual:
        visual.write(b"SCVEC01\0")
        visual.write(struct.pack("<II", 256, len(ordered)))
        for identity in ordered:
            visual.write(vectors[identity])
    write_json(output / "visual.ids.json.gz", ordered)
    build_structure(ordered, cache, renderer, output)
    source_digest = hashlib.sha256()
    with source.open("rb") as source_file:
        while block := source_file.read(1024 * 1024):
            source_digest.update(block)
    runtime_files = [path for path in sorted(output.iterdir())
                     if path.name.startswith(("cards.", "visual.gray.")) or path.name in
                     {"catalog.index.json.gz", "visual.index.bin", "visual.ids.json.gz"}]
    records = [file_record(path) for path in runtime_files]
    package_digest = hashlib.sha256(source_digest.digest() + SCHEMA.encode() +
                                    REFERENCE_SCHEMA.encode() + json.dumps(records, sort_keys=True).encode())
    manifest = {
        "schema": 2, "descriptorSchema": SCHEMA, "referenceSchema": REFERENCE_SCHEMA,
        "version": package_digest.hexdigest()[:24],
        "source": source_metadata,
        "metadataComplete": True, "cardCount": len(entries),
        "illustrationCount": len(references), "visualCount": len(ordered),
        "visualComplete": len(ordered) == len(references),
        "files": records,
    }
    temporary = output / "manifest.pending"
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    temporary.replace(output / "manifest.json")
    (output / "failed_images.json").write_text(json.dumps(failed, indent=2) + "\n")
    print(json.dumps({key: manifest[key] for key in
                      ["cardCount", "illustrationCount", "visualCount", "visualComplete"]}), flush=True)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--image-cache", type=Path)
    parser.add_argument("--structure-renderer", type=Path, required=True)
    parser.add_argument("--workers", type=int, choices=range(1, 5), default=4)
    parser.add_argument("--metadata-only", action="store_true")
    parser.add_argument("--limit-illustrations", type=int)
    options = parser.parse_args()
    if options.limit_illustrations is not None and options.limit_illustrations < 1:
        parser.error("--limit-illustrations must be positive (produces an explicitly partial package)")
    source = options.source or options.output.parent / "bulk-default.jsonl.gz"
    source.parent.mkdir(parents=True, exist_ok=True)
    metadata = {"type": "provided_bulk", "filename": source.name}
    if options.source is None:
        metadata = download_bulk(source)
    build(source, options.output, options.image_cache or options.output.parent / "artwork-cache",
          metadata, options.structure_renderer, options.workers, options.metadata_only, options.limit_illustrations)


if __name__ == "__main__":
    main()
