#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT_DIR/scripts/classify_changed_files.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

run_case() {
  local name="$1"
  local files="$2"
  shift 2

  local output="$tmpdir/$name.out"
  local expected_file="$tmpdir/$name.expected"
  printf '%s\n' "$files" | "$CLASSIFIER" > "$output"
  printf '%s\n' "$@" > "$expected_file"

  if ! diff -u "$expected_file" "$output"; then
    echo "FAIL $name"
    exit 1
  fi
}

run_case readme_docs_only \
  "README.md" \
  "docs_only=true" \
  "app_source=false" \
  "release_surface=false" \
  "workflow=false" \
  "ci_config=false" \
  "site_or_metadata=false" \
  "repo_policy=false" \
  "unknown=false" \
  "source_or_release=false" \
  "full_ci=false" \
  "workflow_ci=false" \
  "review_worthy=false" \
  "native_or_packaging=false"

run_case docs_report_only \
  "docs/reports/ci.md" \
  "docs_only=true" \
  "app_source=false" \
  "release_surface=false" \
  "workflow=false" \
  "ci_config=false" \
  "site_or_metadata=false" \
  "repo_policy=false" \
  "unknown=false" \
  "source_or_release=false" \
  "full_ci=false" \
  "workflow_ci=false" \
  "review_worthy=false" \
  "native_or_packaging=false"

run_case native_source \
  "native/MuesliNative/Sources/App.swift" \
  "docs_only=false" \
  "app_source=true" \
  "release_surface=false" \
  "workflow=false" \
  "ci_config=false" \
  "site_or_metadata=false" \
  "repo_policy=false" \
  "unknown=false" \
  "source_or_release=true" \
  "full_ci=true" \
  "workflow_ci=false" \
  "review_worthy=true" \
  "native_or_packaging=true"

run_case sponsor_asset \
  "assets/sponsors/acme.svg" \
  "docs_only=true" \
  "app_source=false" \
  "release_surface=false" \
  "workflow=false" \
  "ci_config=false" \
  "site_or_metadata=true" \
  "repo_policy=false" \
  "unknown=false" \
  "source_or_release=false" \
  "full_ci=false" \
  "workflow_ci=false" \
  "review_worthy=false" \
  "native_or_packaging=false"

run_case bundled_asset \
  "assets/AppIcon.iconset/icon_512x512.png" \
  "docs_only=false" \
  "app_source=true" \
  "release_surface=false" \
  "workflow=false" \
  "ci_config=false" \
  "site_or_metadata=false" \
  "repo_policy=false" \
  "unknown=false" \
  "source_or_release=true" \
  "full_ci=true" \
  "workflow_ci=false" \
  "review_worthy=true" \
  "native_or_packaging=true"

run_case ci_workflow \
  ".github/workflows/ci.yml" \
  "docs_only=false" \
  "app_source=false" \
  "release_surface=false" \
  "workflow=true" \
  "ci_config=true" \
  "site_or_metadata=false" \
  "repo_policy=false" \
  "unknown=false" \
  "source_or_release=false" \
  "full_ci=true" \
  "workflow_ci=false" \
  "review_worthy=true" \
  "native_or_packaging=true"

run_case non_ci_workflow \
  ".github/workflows/claude.yml" \
  "docs_only=false" \
  "app_source=false" \
  "release_surface=false" \
  "workflow=true" \
  "ci_config=false" \
  "site_or_metadata=false" \
  "repo_policy=false" \
  "unknown=false" \
  "source_or_release=false" \
  "full_ci=false" \
  "workflow_ci=true" \
  "review_worthy=true" \
  "native_or_packaging=false"

run_case release_script \
  "scripts/build_native_app.sh" \
  "docs_only=false" \
  "app_source=false" \
  "release_surface=true" \
  "workflow=false" \
  "ci_config=false" \
  "site_or_metadata=false" \
  "repo_policy=false" \
  "unknown=false" \
  "source_or_release=true" \
  "full_ci=true" \
  "workflow_ci=false" \
  "review_worthy=true" \
  "native_or_packaging=true"

run_case classifier_script \
  "scripts/classify_changed_files.sh" \
  "docs_only=false" \
  "app_source=false" \
  "release_surface=false" \
  "workflow=false" \
  "ci_config=true" \
  "site_or_metadata=false" \
  "repo_policy=false" \
  "unknown=false" \
  "source_or_release=false" \
  "full_ci=true" \
  "workflow_ci=false" \
  "review_worthy=true" \
  "native_or_packaging=true"

run_case unknown_path \
  "tools/new-helper.sh" \
  "docs_only=false" \
  "app_source=false" \
  "release_surface=false" \
  "workflow=false" \
  "ci_config=false" \
  "site_or_metadata=false" \
  "repo_policy=false" \
  "unknown=true" \
  "source_or_release=false" \
  "full_ci=true" \
  "workflow_ci=false" \
  "review_worthy=true" \
  "native_or_packaging=true"

run_case appcast_metadata \
  "docs/appcast.xml" \
  "docs_only=false" \
  "app_source=false" \
  "release_surface=true" \
  "workflow=false" \
  "ci_config=false" \
  "site_or_metadata=true" \
  "repo_policy=false" \
  "unknown=false" \
  "source_or_release=true" \
  "full_ci=true" \
  "workflow_ci=false" \
  "review_worthy=true" \
  "native_or_packaging=true"

run_case empty_input \
  "" \
  "docs_only=false" \
  "app_source=false" \
  "release_surface=false" \
  "workflow=false" \
  "ci_config=false" \
  "site_or_metadata=false" \
  "repo_policy=false" \
  "unknown=true" \
  "source_or_release=false" \
  "full_ci=true" \
  "workflow_ci=false" \
  "review_worthy=true" \
  "native_or_packaging=true"

run_case repo_policy \
  "CONTRIBUTING.md" \
  "docs_only=true" \
  "app_source=false" \
  "release_surface=false" \
  "workflow=false" \
  "ci_config=false" \
  "site_or_metadata=false" \
  "repo_policy=true" \
  "unknown=false" \
  "source_or_release=false" \
  "full_ci=false" \
  "workflow_ci=false" \
  "review_worthy=true" \
  "native_or_packaging=false"

run_case mixed_docs_and_source \
  $'README.md\nnative/MuesliNative/Sources/App.swift' \
  "docs_only=false" \
  "app_source=true" \
  "release_surface=false" \
  "workflow=false" \
  "ci_config=false" \
  "site_or_metadata=false" \
  "repo_policy=false" \
  "unknown=false" \
  "source_or_release=true" \
  "full_ci=true" \
  "workflow_ci=false" \
  "review_worthy=true" \
  "native_or_packaging=true"

echo "classifier tests passed"
