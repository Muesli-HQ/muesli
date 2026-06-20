#!/usr/bin/env python3
import argparse
import html
import re
import sys


def inline_markdown(text: str) -> str:
    escaped = html.escape(text, quote=False)
    return re.sub(r"`([^`]+)`", lambda match: f"<code>{match.group(1)}</code>", escaped)


def markdown_to_html(markdown: str) -> str:
    lines = markdown.strip().splitlines()
    output: list[str] = []
    in_list = False

    def close_list() -> None:
        nonlocal in_list
        if in_list:
            output.append("</ul>")
            in_list = False

    for raw_line in lines:
        line = raw_line.rstrip()
        stripped = line.strip()
        if not stripped:
            close_list()
            continue

        if stripped.startswith("### "):
            close_list()
            output.append(f"<h3>{inline_markdown(stripped[4:])}</h3>")
        elif stripped.startswith("## "):
            close_list()
            output.append(f"<h2>{inline_markdown(stripped[3:])}</h2>")
        elif stripped.startswith("- "):
            if not in_list:
                output.append("<ul>")
                in_list = True
            output.append(f"<li>{inline_markdown(stripped[2:])}</li>")
        elif re.match(r"^\d+\.\s+", stripped):
            if not in_list:
                output.append("<ul>")
                in_list = True
            item_text = re.sub(r"^\d+\.\s+", "", stripped)
            output.append(f"<li>{inline_markdown(item_text)}</li>")
        else:
            close_list()
            output.append(f"<p>{inline_markdown(stripped)}</p>")

    close_list()
    return "\n".join(output)


def cdata(text: str) -> str:
    return "<![CDATA[\n" + text.replace("]]>", "]]]]><![CDATA[>") + "\n]]>"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Inject item-level Sparkle release notes into an appcast."
    )
    parser.add_argument("appcast")
    parser.add_argument("--sparkle-version", required=True)
    parser.add_argument("--short-version", required=True)
    args = parser.parse_args()

    release_notes = sys.stdin.read()
    if not release_notes.strip():
        raise SystemExit("ERROR: release notes input is empty")

    with open(args.appcast, encoding="utf-8") as handle:
        text = handle.read()

    item_re = re.compile(r"(?P<indent>[ \t]*)<item>\n(?P<body>.*?)(?P=indent)</item>", re.S)
    target_match = None
    for match in item_re.finditer(text):
        block = match.group(0)
        if (
            f"<sparkle:version>{args.sparkle_version}</sparkle:version>" in block
            and f"<sparkle:shortVersionString>{args.short_version}</sparkle:shortVersionString>" in block
        ):
            target_match = match
            break

    if target_match is None:
        raise SystemExit(
            f"ERROR: appcast item not found for {args.short_version} ({args.sparkle_version})"
        )

    block = target_match.group(0)
    indent = target_match.group("indent")
    child_indent = indent + "    "
    notes_html = markdown_to_html(release_notes)
    description = f"{child_indent}<description>{cdata(notes_html)}</description>\n"

    block_without_description = re.sub(
        r"\n[ \t]*<description>(?:<!\[CDATA\[.*?\]\]>|.*?)</description>\n",
        "\n",
        block,
        flags=re.S,
    )

    pubdate_re = re.compile(r"(\n[ \t]*<pubDate>.*?</pubDate>\n)", re.S)
    if pubdate_re.search(block_without_description):
        updated_block = pubdate_re.sub(r"\1" + description, block_without_description, count=1)
    else:
        updated_block = block_without_description.replace(
            f"{indent}<item>\n", f"{indent}<item>\n{description}", 1
        )

    updated_text = text[: target_match.start()] + updated_block + text[target_match.end() :]
    with open(args.appcast, "w", encoding="utf-8") as handle:
        handle.write(updated_text)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
