#!/usr/bin/env python3

import os
import plistlib
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "scripts" / "verify_cloud_entitlements.py"


def write_plist(path: Path, value: dict) -> None:
    with path.open("wb") as handle:
        plistlib.dump(value, handle)


def run(entitlements: dict, profile: dict | None = None) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        entitlements_path = root / "entitlements.plist"
        write_plist(entitlements_path, entitlements)
        command = [
            "python3", str(VALIDATOR),
            "--entitlements", str(entitlements_path),
            "--environment", "Production",
            "--bundle-id", "com.muesli.app",
            "--container", "iCloud.com.mueslihq.muesli",
            "--aps-environment", "production",
        ]
        if profile is not None:
            profile_path = root / "profile.plist"
            write_plist(profile_path, profile)
            command.extend(["--profile", str(profile_path)])
        return subprocess.run(command, text=True, capture_output=True, check=False)


base_entitlements = {
    "com.apple.application-identifier": "58W55QJ567.com.muesli.app",
    "com.apple.developer.team-identifier": "58W55QJ567",
    "com.apple.developer.icloud-container-environment": "Production",
    "com.apple.developer.icloud-container-identifiers": ["iCloud.com.mueslihq.muesli"],
    "com.apple.developer.icloud-services": ["CloudKit"],
    "com.apple.developer.aps-environment": "production",
}
base_profile = {
    "Entitlements": {
        "com.apple.application-identifier": "58W55QJ567.com.muesli.app",
        "com.apple.developer.team-identifier": "58W55QJ567",
        "com.apple.developer.aps-environment": "production",
        "com.apple.developer.icloud-container-environment": ["Development", "Production"],
        "com.apple.developer.icloud-container-identifiers": ["iCloud.com.mueslihq.muesli"],
    }
}

assert run(base_entitlements, base_profile).returncode == 0

for key, bad_value in (
    ("com.apple.developer.icloud-container-environment", "Development"),
    ("com.apple.developer.aps-environment", "development"),
    ("com.apple.developer.icloud-container-identifiers", ["iCloud.example.wrong"]),
    ("com.apple.developer.icloud-services", ["Documents"]),
):
    candidate = dict(base_entitlements)
    candidate[key] = bad_value
    result = run(candidate, base_profile)
    assert result.returncode != 0, (key, result.stdout, result.stderr)

missing_environment = dict(base_entitlements)
missing_environment.pop("com.apple.developer.icloud-container-environment")
assert run(missing_environment, base_profile).returncode != 0

wrong_profile = {
    "Entitlements": {
        "com.apple.application-identifier": "58W55QJ567.com.muesli.app",
        "com.apple.developer.team-identifier": "58W55QJ567",
        "com.apple.developer.aps-environment": "production",
        "com.apple.developer.icloud-container-environment": "Development",
        "com.apple.developer.icloud-container-identifiers": ["iCloud.com.mueslihq.muesli"],
    }
}
assert run(base_entitlements, wrong_profile).returncode != 0

for key, bad_value in (
    ("com.apple.application-identifier", "58W55QJ567.com.example.wrong"),
    ("com.apple.developer.team-identifier", "DIFFERENT01"),
    ("com.apple.developer.aps-environment", "development"),
):
    candidate_profile = {"Entitlements": dict(base_profile["Entitlements"])}
    candidate_profile["Entitlements"][key] = bad_value
    result = run(base_entitlements, candidate_profile)
    assert result.returncode != 0, (key, result.stdout, result.stderr)

for missing_key in (
    "com.apple.application-identifier",
    "com.apple.developer.team-identifier",
    "com.apple.developer.aps-environment",
):
    candidate_profile = {"Entitlements": dict(base_profile["Entitlements"])}
    candidate_profile["Entitlements"].pop(missing_key)
    result = run(base_entitlements, candidate_profile)
    assert result.returncode != 0, (missing_key, result.stdout, result.stderr)

stable_release = (ROOT / "scripts" / "release.sh").read_text(encoding="utf-8")
preprod_release = (ROOT / "scripts" / "release-preprod.sh").read_text(encoding="utf-8")
build_script = (ROOT / "scripts" / "build_native_app.sh").read_text(encoding="utf-8")
dev_test_script = (ROOT / "scripts" / "dev-test.sh").read_text(encoding="utf-8")
assert 'MUESLI_ICLOUD_CONTAINER_ENVIRONMENT="Production"' in stable_release
assert 'MUESLI_ICLOUD_CONTAINER_ENVIRONMENT="Production"' in preprod_release
assert 'MUESLI_ICLOUD_CONTAINER_ENVIRONMENT="Development"' in dev_test_script
assert stable_release.count("verify_signed_cloud_entitlements.sh") >= 2
assert preprod_release.count("verify_signed_cloud_entitlements.sh") >= 2
assert "CloudKit provisioning profiles require an explicit" in build_script

dev_production_environment = dict(os.environ)
dev_production_environment["MUESLI_ICLOUD_CONTAINER_ENVIRONMENT"] = "Production"
dev_production_result = subprocess.run(
    ["bash", str(ROOT / "scripts" / "dev-test.sh"), "--cloud-entitlements"],
    text=True,
    capture_output=True,
    check=False,
    env=dev_production_environment,
)
assert dev_production_result.returncode == 2
assert "must use the CloudKit Development environment" in dev_production_result.stderr

metadata_marker = (
    "# --- Step 11: Validate appcast metadata and open its PR while release stays draft ---"
)
publication_marker = (
    "# --- Step 12: Publish only after appcast validation and metadata PR creation ---"
)
metadata_section = stable_release.split(metadata_marker, maxsplit=1)[1].split(
    publication_marker,
    maxsplit=1,
)[0]
publication_section = stable_release.split(publication_marker, maxsplit=1)[1].split(
    "# --- Step 13:",
    maxsplit=1,
)[0]
assert 'RELEASE_METADATA_BRANCH="${MUESLI_RELEASE_METADATA_BRANCH:-codex/release-${VERSION}-appcast}"' in stable_release
assert "gh pr create" in metadata_section
assert "--base main" in metadata_section
assert "git push origin main" not in metadata_section
assert "verify_update_flow.sh" in metadata_section
assert "gh release edit" not in metadata_section
assert "gh release edit" in publication_section
assert "muesli_require_release_publication_ready" in publication_section
assert "RELEASE_METADATA_PR_URL" in publication_section
assert "resume_existing_release_publication()" in stable_release
assert "Existing release metadata branch found" in stable_release
assert "Expected zero or one open metadata PR" in stable_release
assert '--appcast "$metadata_appcast"' in stable_release
assert '"$ROOT/scripts/verify_signed_cloud_entitlements.sh"' in stable_release
assert "Existing release metadata or hosted artifact failed update-flow validation" in stable_release
assert "Existing hosted app failed Production CloudKit entitlement validation" in stable_release
assert "Recreated missing release metadata PR" in stable_release
assert "resume_existing_release_publication" in stable_release.split(
    '# --- Step 0: Update version in build script ---',
    maxsplit=1,
)[0]
assert "Remote release metadata branch already exists" not in stable_release

ordered_release_gates = (
    '"$GENERATE_APPCAST"',
    'python3 "$UPDATE_APPCAST_RELEASE_NOTES"',
    'python3 "$MERGE_APPCAST_ITEM"',
    '"$ROOT/scripts/verify_update_flow.sh"',
    "git commit --signoff",
    "git push -u origin",
    "gh pr create",
    "gh release edit",
)
release_finalization = metadata_section + publication_section
gate_offsets = [release_finalization.index(gate) for gate in ordered_release_gates]
assert gate_offsets == sorted(gate_offsets), gate_offsets

publication_gate = ROOT / "scripts" / "release_publication_gate.sh"
failed_validation_probe = subprocess.run(
    [
        "bash",
        "-c",
        f'''set -euo pipefail
source "{publication_gate}"
published=0
publish() {{ published=1; }}
if muesli_require_release_publication_ready 0 "https://example.invalid/pr/1"; then
  publish
fi
[[ "$published" == "0" ]]
''',
    ],
    text=True,
    capture_output=True,
    check=False,
)
assert failed_validation_probe.returncode == 0, failed_validation_probe.stderr

missing_pr_probe = subprocess.run(
    ["bash", "-c", f'source "{publication_gate}"; muesli_require_release_publication_ready 1 ""'],
    text=True,
    capture_output=True,
    check=False,
)
assert missing_pr_probe.returncode != 0

ready_probe = subprocess.run(
    [
        "bash",
        "-c",
        f'source "{publication_gate}"; muesli_require_release_publication_ready 1 "https://example.invalid/pr/1"',
    ],
    text=True,
    capture_output=True,
    check=False,
)
assert ready_probe.returncode == 0, ready_probe.stderr

print("CloudKit entitlement validator tests passed.")
