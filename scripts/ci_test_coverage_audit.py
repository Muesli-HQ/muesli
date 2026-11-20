#!/usr/bin/env python3
"""Check the built test inventory and one shard's Swift Testing xUnit results."""
import argparse
from collections import Counter
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
SHARDS = ("core", "dictation-transcription", "meetings")


def assignments():
    owners = {}
    for shard in SHARDS:
        names = subprocess.check_output(
            ["bash", str(ROOT / "scripts/run_ci_test_shard.sh"), "--list-qualified", shard], text=True
        ).splitlines()
        for key in names:
            if key in owners:
                raise ValueError(f"{key} assigned twice: {owners[key]} and {shard}")
            owners[key] = shard
    return owners


def compare(expected, observed, label):
    missing = sorted(expected - observed)
    extra = sorted(observed - expected)
    if missing or extra:
        raise ValueError(f"{label}: missing {len(missing)} {missing}; unexpected {len(extra)} {extra}")


def expected_tests(lines, owners, exempt, shard):
    identifiers = set(lines)
    if not identifiers or any("/" not in name for name in identifiers):
        raise ValueError("Empty or unrecognized swift test list output")
    if exempt & owners.keys():
        raise ValueError(f"Assigned suites still exempt: {sorted(exempt & owners.keys())}")
    suites = {name.split("/", 1)[0] for name in identifiers}
    compare(set(owners) | exempt, suites, "Discovery vs assigned and exempt suites")
    return {name for name in identifiers if owners.get(name.split("/", 1)[0]) == shard}


def recorded_tests(paths):
    statuses = {}
    for path in paths:
        for case in ET.parse(path).getroot().iter("testcase"):
            identifier = f"{case.attrib['classname']}/{case.attrib['name']}"
            if identifier in statuses:
                raise ValueError(f"Duplicate result: {identifier}")
            if case.find("failure") is not None or case.find("error") is not None:
                statuses[identifier] = "failed"
            elif case.find("skipped") is not None:
                statuses[identifier] = "skipped"
            else:
                statuses[identifier] = "passed"
    return statuses


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("shard", choices=SHARDS)
    parser.add_argument("inventory", type=Path)
    parser.add_argument("results", nargs="+", type=Path)
    args = parser.parse_args()
    baseline = (ROOT / "scripts/ci_unsharded_test_suites.txt").read_text().splitlines()
    exempt = {f"MuesliTests.{name.strip()}" for name in baseline if name.strip() and not name.startswith("#")}
    expected = expected_tests(args.inventory.read_text().splitlines(), assignments(), exempt, args.shard)
    actual = recorded_tests(args.results)
    compare(expected, set(actual), args.shard)
    counts = Counter(actual.values())
    print(f"{args.shard}: verified {len(expected)} discovered methods, "
          f"{counts['passed']} passed, {counts['skipped']} explicitly skipped, {counts['failed']} failed")
    if counts["failed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError, ET.ParseError) as error:
        raise SystemExit(str(error))
