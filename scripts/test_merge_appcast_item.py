#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path

from merge_appcast_item import merge_appcast_item


HEADER = """<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Muesli</title>
        <!-- Items are added by generate_appcast or the release script -->
"""
FOOTER = """    </channel>
</rss>
"""
HISTORICAL_ITEM = """        <item>
            <title>0.7.1</title>
            <description><![CDATA[historical notes must remain exact]]></description>
            <sparkle:version>0.7.1</sparkle:version>
            <enclosure url="https://github.com/Muesli-HQ/muesli/releases/download/v0.7.1/Muesli-0.7.1.dmg" length="42" sparkle:edSignature="historical-signature"/>
        </item>
"""
GENERATED_ITEM = """        <item>
            <title>0.8.2</title>
            <description><![CDATA[new release notes]]></description>
            <sparkle:version>0.8.2</sparkle:version>
            <enclosure url="https://muesli-hq.github.io/muesli/Muesli-0.8.2.dmg" length="84" sparkle:edSignature="new-signature"/>
            <sparkle:deltas>
                <enclosure url="unused.delta" sparkle:deltaFrom="0.7.1"/>
            </sparkle:deltas>
        </item>
"""


class MergeAppcastItemTests(unittest.TestCase):
    def test_merges_new_item_without_mutating_history(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            existing = root / "existing.xml"
            generated = root / "generated.xml"
            output = root / "output.xml"
            existing.write_text(HEADER + HISTORICAL_ITEM + FOOTER, encoding="utf-8")
            generated.write_text(HEADER + GENERATED_ITEM + FOOTER, encoding="utf-8")

            merge_appcast_item(existing, generated, "0.8.2", output)

            result = output.read_text(encoding="utf-8")
            self.assertIn(HISTORICAL_ITEM, result)
            self.assertEqual(result.count("<item>"), 2)
            self.assertLess(result.index("<title>0.8.2</title>"), result.index("<title>0.7.1</title>"))
            self.assertIn(
                "https://github.com/Muesli-HQ/muesli/releases/download/v0.8.2/Muesli-0.8.2.dmg",
                result,
            )
            self.assertIn('sparkle:edSignature="new-signature"', result)
            self.assertNotIn("sparkle:deltaFrom", result)
            self.assertEqual(
                existing.read_text(encoding="utf-8"),
                HEADER + HISTORICAL_ITEM + FOOTER,
            )

    def test_rejects_replacing_a_published_version(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            existing = root / "existing.xml"
            generated = root / "generated.xml"
            output = root / "output.xml"
            existing.write_text(HEADER + GENERATED_ITEM + FOOTER, encoding="utf-8")
            generated.write_text(HEADER + GENERATED_ITEM + FOOTER, encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "already contains version 0.8.2"):
                merge_appcast_item(existing, generated, "0.8.2", output)

    def test_rejects_legacy_historical_download_url(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            existing = root / "existing.xml"
            generated = root / "generated.xml"
            output = root / "output.xml"
            legacy_item = HISTORICAL_ITEM.replace(
                "https://github.com/Muesli-HQ/muesli/releases/download/v0.7.1/Muesli-0.7.1.dmg",
                "https://pHequals7.github.io/muesli/Muesli-0.7.1.dmg",
            )
            existing.write_text(HEADER + legacy_item + FOOTER, encoding="utf-8")
            generated.write_text(HEADER + GENERATED_ITEM + FOOTER, encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "canonical GitHub Release URL"):
                merge_appcast_item(existing, generated, "0.8.2", output)


if __name__ == "__main__":
    unittest.main()
