#!/usr/bin/env bash
set -euo pipefail

docs_only=true
app_source=false
release_surface=false
workflow=false
ci_config=false
site_or_metadata=false
repo_policy=false
unknown=false
count=0

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  count=$((count + 1))

  case "$file" in
    native/*)
      app_source=true
      docs_only=false
      ;;

    assets/sponsors/*|assets/repository-open-graph*|assets/muesli-readme-og.jpg|assets/muesli-github-ss.png)
      site_or_metadata=true
      ;;

    assets/*)
      app_source=true
      docs_only=false
      ;;

    scripts/classify_changed_files.sh|scripts/test_classify_changed_files.sh)
      ci_config=true
      docs_only=false
      ;;

    scripts/build_native_app.sh|scripts/release*.sh|scripts/notarize_app.sh|scripts/test_packaged_cli.sh|scripts/verify_update_flow.sh|scripts/run_ci_test_shard.sh|scripts/muesli_spm_cache.sh)
      release_surface=true
      docs_only=false
      ;;

    scripts/*)
      release_surface=true
      docs_only=false
      ;;

    .github/workflows/*)
      workflow=true
      docs_only=false
      case "$file" in
        .github/workflows/ci.yml|.github/workflows/claude-code-review.yml)
          ci_config=true
          ;;
      esac
      ;;

    .github/FUNDING.yml|README.md|LICENSE|docs/*.md|docs/reports/*|docs/plans/*|Context/*)
      ;;

    docs/appcast*.xml|docs/index.html|docs/download/*|docs/llms.txt)
      release_surface=true
      site_or_metadata=true
      docs_only=false
      ;;

    docs/privacy.html|docs/terms.html|docs/*)
      site_or_metadata=true
      ;;

    AGENTS.md|CLAUDE.md|CONTRIBUTING.md|REVIEW.md|.openhands/*)
      repo_policy=true
      ;;

    *)
      unknown=true
      docs_only=false
      ;;
  esac
done

if [[ "$count" -eq 0 ]]; then
  unknown=true
  docs_only=false
fi

source_or_release=false
full_ci=false
workflow_ci=false
review_worthy=false

if [[ "$app_source" == true || "$release_surface" == true ]]; then
  source_or_release=true
fi

if [[ "$source_or_release" == true || "$ci_config" == true || "$unknown" == true ]]; then
  full_ci=true
fi

if [[ "$workflow" == true && "$full_ci" == false ]]; then
  workflow_ci=true
fi

if [[ "$source_or_release" == true || "$workflow" == true || "$ci_config" == true || "$repo_policy" == true || "$unknown" == true ]]; then
  review_worthy=true
fi

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

emit docs_only "$docs_only"
emit app_source "$app_source"
emit release_surface "$release_surface"
emit workflow "$workflow"
emit ci_config "$ci_config"
emit site_or_metadata "$site_or_metadata"
emit repo_policy "$repo_policy"
emit unknown "$unknown"
emit source_or_release "$source_or_release"
emit full_ci "$full_ci"
emit workflow_ci "$workflow_ci"
emit review_worthy "$review_worthy"
emit native_or_packaging "$full_ci"
