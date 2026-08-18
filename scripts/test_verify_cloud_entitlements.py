#!/usr/bin/env python3

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
        "com.apple.developer.icloud-container-environment": "Development",
        "com.apple.developer.icloud-container-identifiers": ["iCloud.com.mueslihq.muesli"],
    }
}
assert run(base_entitlements, wrong_profile).returncode != 0

stable_release = (ROOT / "scripts" / "release.sh").read_text(encoding="utf-8")
preprod_release = (ROOT / "scripts" / "release-preprod.sh").read_text(encoding="utf-8")
build_script = (ROOT / "scripts" / "build_native_app.sh").read_text(encoding="utf-8")
assert 'MUESLI_ICLOUD_CONTAINER_ENVIRONMENT="Production"' in stable_release
assert 'MUESLI_ICLOUD_CONTAINER_ENVIRONMENT="Production"' in preprod_release
assert stable_release.count("verify_signed_cloud_entitlements.sh") >= 2
assert preprod_release.count("verify_signed_cloud_entitlements.sh") >= 2
assert "CloudKit provisioning profiles require an explicit" in build_script

print("CloudKit entitlement validator tests passed.")
