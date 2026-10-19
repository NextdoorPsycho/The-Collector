import gzip
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

import build_scan_catalog as builder


class CatalogBuilderTest(unittest.TestCase):
    @staticmethod
    def structure(ordered, cache, renderer, output):
        pixels = output / "test-pixels.bin"
        pixels.write_bytes(b"SCGRAY1\0" + struct.pack("<II", 2304, len(ordered)) +
                           b"".join(bytes((position * 7 + index * 13) % 256 for position in range(2304))
                                    for index in range(len(ordered))))
        builder.package_structure(output, ordered, pixels)
        pixels.unlink()

    def test_descriptor_preserves_native_cell_order_and_gradient_math(self):
        image = Image.new("RGB", (64, 64))
        for y in range(64):
            for x in range(64):
                image.putpixel((x, y), ((x * 7) % 256, (y * 11) % 256, ((x + y) * 3) % 256))
        payload = io.BytesIO()
        image.save(payload, format="PNG")
        expected = []
        for cy in range(8):
            for cx in range(8):
                totals = [0, 0, 0]
                gradient = 0
                for y in range(cy * 8, cy * 8 + 8):
                    for x in range(cx * 8, cx * 8 + 8):
                        pixel = image.getpixel((x, y))
                        for channel in range(3):
                            totals[channel] += pixel[channel]
                        if x < 63:
                            gradient += sum(abs(pixel[c] - image.getpixel((x + 1, y))[c]) for c in range(3))
                        if y < 63:
                            gradient += sum(abs(pixel[c] - image.getpixel((x, y + 1))[c]) for c in range(3))
                expected.extend(round(total / 64) for total in totals)
                expected.append(round(gradient / (3 * 128)))
        self.assertEqual(builder.descriptor(payload.getvalue()), bytes(expected))

    def test_streaming_sources_reject_truncation_and_accept_both_bulk_formats(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            card = {"object": "card", "id": "actual-fixture"}
            jsonl = root / "source.jsonl.gz"
            jsonl.write_bytes(gzip.compress((json.dumps(card) + "\n").encode()))
            self.assertEqual(list(builder.stream_cards(jsonl)), [card])
            array = root / "source.json"
            array.write_text(json.dumps([card]))
            self.assertEqual(list(builder.stream_cards(array)), [card])
            array.write_text("[" + json.dumps(card))
            with self.assertRaisesRegex(ValueError, "Truncated"):
                list(builder.stream_cards(array))

    def test_complete_chunk_index_and_partial_visual_version_are_explicit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.jsonl"
            cards = [{"object": "card", "id": f"card-{index}", "name": "Public source fixture",
                      "set": "tst", "collector_number": str(index), "lang": "en",
                      "illustration_id": f"art-{index % 2}",
                      "image_uris": {"art_crop": f"https://cards.scryfall.io/art_crop/{index % 2}.jpg"}}
                     for index in range(205)]
            source.write_text("\n".join(json.dumps(card) for card in cards) + "\n")
            with patch.object(builder, "build_visual", side_effect=lambda ref, cache: (ref[0], bytes([20] * 256), None)), \
                 patch.object(builder, "build_structure", side_effect=self.structure):
                full = builder.build(source, root / "full", root / "cache", {"type": "fixture"}, Path("renderer"))
                partial = builder.build(source, root / "partial", root / "cache", {"type": "fixture"}, Path("renderer"), limit=1)
            self.assertTrue(full["visualComplete"])
            self.assertFalse(partial["visualComplete"])
            self.assertNotEqual(full["version"], partial["version"])
            index = json.loads(gzip.decompress((root / "full/catalog.index.json.gz").read_bytes()))
            self.assertEqual(len(index["entries"]), 205)
            for row in index["entries"]:
                shard = (root / f"full/cards.{row[7]:04}.bin").read_bytes()
                chunk = json.loads(gzip.decompress(shard[row[8]:row[8] + row[9]]))
                self.assertLessEqual(len(chunk), 100)
                self.assertEqual(chunk[row[10]]["id"], row[0])
            vectors = (root / "full/visual.index.bin").read_bytes()
            self.assertEqual(vectors[:8], b"SCVEC01\0")
            self.assertEqual(struct.unpack("<II", vectors[8:16]), (256, 2))
            self.assertEqual(len(vectors), 16 + 2 * 256)
            self.assertEqual(full["schema"], 2)
            self.assertEqual(full["referenceSchema"], builder.REFERENCE_SCHEMA)
            gray_index = json.loads(gzip.decompress((root / "full/visual.gray.index.json.gz").read_bytes()))
            for index, row in enumerate(gray_index["rows"]):
                raw = (root / f"full/visual.gray.{row[0]:04}.bin").read_bytes()
                decoded = gzip.decompress(raw[row[1]:row[1] + row[2]])
                self.assertEqual(decoded, bytes((position * 7 + index * 13) % 256 for position in range(2304)))
                self.assertEqual(len(decoded), 2304)
            for record in full["files"]:
                self.assertEqual(record, builder.file_record(root / "full" / record["name"]))
            with self.assertRaisesRegex(ValueError, "Output directory must be empty"):
                builder.build(source, root / "full", root / "cache", {"type": "fixture"}, Path("renderer"))

    def test_structural_pack_rejects_truncated_suffix_and_wrong_count(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pixels = root / "pixels.bin"
            header = b"SCGRAY1\0" + struct.pack("<II", 2304, 1)
            for payload in [header + bytes(2303), header + bytes(2305),
                            b"SCGRAY1\0" + struct.pack("<II", 2304, 2) + bytes(2304)]:
                pixels.write_bytes(payload)
                with self.assertRaises(ValueError): builder.package_structure(root, ["actual-fixture"], pixels)


if __name__ == "__main__":
    unittest.main()
