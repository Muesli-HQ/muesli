#!/usr/bin/env python3
"""Validate the privacy-safe CloudKit contract of a signed Muesli app."""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path
from typing import Any


def fail(message: str) -> None:
    raise ValueError(message)


def load_plist(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        fail(f"could not read plist {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"plist root is not a dictionary: {path}")
    return value


def string_value(mapping: dict[str, Any], key: str) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value:
        fail(f"missing string entitlement: {key}")
    return value


def string_list(mapping: dict[str, Any], key: str) -> list[str]:
    value = mapping.get(key)
    if isinstance(value, str):
        return [value]
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return value
    fail(f"missing string-list entitlement: {key}")


def validate(
    entitlements: dict[str, Any],
    expected_environment: str,
    expected_bundle_id: str,
    expected_container: str,
    expected_aps: str,
    profile: dict[str, Any] | None,
) -> None:
    environment_key = "com.apple.developer.icloud-container-environment"
    app_identifier_key = "com.apple.application-identifier"
    if app_identifier_key not in entitlements:
        app_identifier_key = "application-identifier"

    environment = string_value(entitlements, environment_key)
    if environment != expected_environment:
        fail(
            f"signed CloudKit environment is {environment!r}, "
            f"expected {expected_environment!r}"
        )

    app_identifier = string_value(entitlements, app_identifier_key)
    team_id = string_value(entitlements, "com.apple.developer.team-identifier")
    if app_identifier != f"{team_id}.{expected_bundle_id}":
        fail("signed application identifier does not match the team and bundle ID")

    containers = string_list(
        entitlements, "com.apple.developer.icloud-container-identifiers"
    )
    if expected_container not in containers:
        fail("signed app is missing the required iCloud container")

    services = string_list(entitlements, "com.apple.developer.icloud-services")
    if "CloudKit" not in services:
        fail("signed app is missing the CloudKit service entitlement")

    aps = entitlements.get("com.apple.developer.aps-environment")
    if aps is None:
        aps = entitlements.get("aps-environment")
    if aps != expected_aps:
        fail(f"signed APNs environment is {aps!r}, expected {expected_aps!r}")

    if profile is None:
        return
    profile_entitlements = profile.get("Entitlements")
    if not isinstance(profile_entitlements, dict):
        fail("embedded provisioning profile has no Entitlements dictionary")

    profile_app_identifier_key = "com.apple.application-identifier"
    if profile_app_identifier_key not in profile_entitlements:
        profile_app_identifier_key = "application-identifier"
    profile_app_identifier = string_value(
        profile_entitlements, profile_app_identifier_key
    )
    if profile_app_identifier != app_identifier:
        fail("provisioning profile application identifier does not match the signed app")

    profile_team_id = string_value(
        profile_entitlements, "com.apple.developer.team-identifier"
    )
    if profile_team_id != team_id:
        fail("provisioning profile team identifier does not match the signed app")

    profile_aps = profile_entitlements.get("com.apple.developer.aps-environment")
    if profile_aps is None:
        profile_aps = profile_entitlements.get("aps-environment")
    if profile_aps != expected_aps:
        fail(
            f"provisioning profile APNs environment is {profile_aps!r}, "
            f"expected {expected_aps!r}"
        )

    profile_environments = string_list(profile_entitlements, environment_key)
    if expected_environment not in profile_environments:
        fail("provisioning profile does not permit the expected CloudKit environment")
    profile_containers = string_list(
        profile_entitlements, "com.apple.developer.icloud-container-identifiers"
    )
    if expected_container not in profile_containers:
        fail("provisioning profile does not permit the required iCloud container")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--entitlements", type=Path, required=True)
    parser.add_argument("--environment", choices=("Development", "Production"), required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--container", required=True)
    parser.add_argument("--aps-environment", choices=("development", "production"), required=True)
    parser.add_argument("--profile", type=Path)
    args = parser.parse_args()

    try:
        validate(
            load_plist(args.entitlements),
            args.environment,
            args.bundle_id,
            args.container,
            args.aps_environment,
            load_plist(args.profile) if args.profile else None,
        )
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(
        f"CloudKit entitlement contract OK: {args.bundle_id} / {args.environment}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
