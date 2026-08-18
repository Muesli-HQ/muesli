#!/usr/bin/env python3
import argparse
import os
import tempfile
from pathlib import Path
from xml.dom import Node, minidom


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
INSERTION_MARKER = "        <!-- Items are added by generate_appcast or the release script -->\n"


def item_version(item: minidom.Element) -> str:
    versions = item.getElementsByTagNameNS(SPARKLE_NAMESPACE, "version")
    if len(versions) != 1 or versions[0].firstChild is None:
        raise ValueError("appcast item must contain exactly one sparkle:version")
    return versions[0].firstChild.nodeValue.strip()


def appcast_items(document: minidom.Document) -> list[minidom.Element]:
    return [
        node
        for node in document.getElementsByTagName("item")
        if node.nodeType == Node.ELEMENT_NODE
    ]


def canonical_enclosure_url(version: str) -> str:
    return f"https://github.com/Muesli-HQ/muesli/releases/download/v{version}/Muesli-{version}.dmg"


def full_enclosures(item: minidom.Element) -> list[minidom.Element]:
    return [
        enclosure
        for enclosure in item.getElementsByTagName("enclosure")
        if not enclosure.hasAttributeNS(SPARKLE_NAMESPACE, "deltaFrom")
    ]


def validate_existing_history(items: list[minidom.Element]) -> None:
    for item in items:
        version = item_version(item)
        enclosures = full_enclosures(item)
        if len(enclosures) != 1:
            raise ValueError(
                f"existing appcast item {version} must contain exactly one full enclosure"
            )
        expected_url = canonical_enclosure_url(version)
        if enclosures[0].getAttribute("url") != expected_url:
            raise ValueError(
                f"existing appcast item {version} does not use its canonical GitHub Release URL"
            )


def prepare_generated_item(item: minidom.Element, version: str) -> str:
    enclosures = list(item.getElementsByTagName("enclosure"))
    for enclosure in enclosures:
        if enclosure.hasAttributeNS(SPARKLE_NAMESPACE, "deltaFrom"):
            enclosure.parentNode.removeChild(enclosure)

    enclosures = full_enclosures(item)
    if len(enclosures) != 1:
        raise ValueError("generated appcast item must contain exactly one full enclosure")

    enclosures[0].setAttribute("url", canonical_enclosure_url(version))
    return "        " + item.toxml()


def merge_appcast_item(
    existing_path: Path,
    generated_path: Path,
    version: str,
    output_path: Path,
) -> None:
    existing_text = existing_path.read_text(encoding="utf-8")
    existing_document = minidom.parseString(existing_text)
    existing_items = appcast_items(existing_document)
    existing_versions = [item_version(item) for item in existing_items]
    if len(existing_versions) != len(set(existing_versions)):
        raise ValueError("existing appcast contains duplicate sparkle:version entries")
    if version in existing_versions:
        raise ValueError(f"existing appcast already contains version {version}")
    validate_existing_history(existing_items)

    generated_document = minidom.parse(str(generated_path))
    generated_matches = [
        item for item in appcast_items(generated_document) if item_version(item) == version
    ]
    if len(generated_matches) != 1:
        raise ValueError(f"generated appcast must contain exactly one item for {version}")

    if existing_text.count(INSERTION_MARKER) != 1:
        raise ValueError("existing appcast is missing the unique release-item insertion marker")

    new_item = prepare_generated_item(generated_matches[0], version)
    merged_text = existing_text.replace(
        INSERTION_MARKER,
        f"{INSERTION_MARKER}{new_item}\n",
        1,
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=output_path.parent,
        delete=False,
    ) as handle:
        handle.write(merged_text)
        temporary_path = Path(handle.name)
    os.replace(temporary_path, output_path)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Merge one generated Sparkle item into the canonical appcast."
    )
    parser.add_argument("--existing", required=True, type=Path)
    parser.add_argument("--generated", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    try:
        merge_appcast_item(
            existing_path=args.existing,
            generated_path=args.generated,
            version=args.version,
            output_path=args.output,
        )
    except (OSError, ValueError) as error:
        raise SystemExit(f"ERROR: {error}") from error
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
