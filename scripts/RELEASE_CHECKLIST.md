# Muesli Release Checklist

Run `./scripts/release.sh [version]` — it automates steps 1-9 and is the only official release path.

Source of truth:
- GitHub Releases hosts the official DMG binaries
- GitHub Pages hosts the Sparkle appcast consumed by the app
- The official `Homebrew/homebrew-cask` cask tracks the verified GitHub Release DMG
- Marketing surfaces may link to those assets, but they are not release authorities

This checklist is for **verification** after the script runs, and for manual recovery if any step fails.

## Pre-release

- [ ] All changes merged to `main`
- [ ] `swift test --package-path native/MuesliNative` — all tests pass
- [ ] Version bumped in `scripts/build_native_app.sh` (CFBundleVersion + CFBundleShortVersionString)
- [ ] No uncommitted changes (`git status` clean)
- [ ] Homebrew installed and updated enough to run post-release `brew livecheck --cask muesli`

## Signing Profiles

Muesli's default entitlements include CloudKit (`iCloud.com.mueslihq.muesli`). Any cloud-entitled build must be signed with a provisioning profile whose app identifier matches the bundle ID and whose certificate matches the signing identity.

- [ ] Dev lane `MuesliDev` / `com.muesli.dev`
  - Use profile: `../muesli-ios/secrets/mueslimacosdevcloudkitcommueslidev.provisionprofile`
  - Use identity: `Apple Development: Pranav Hari Guruvayurappan (59WTZW55XG)`
  - Use `MUESLI_CODESIGN_TIMESTAMP=none`
  - `scripts/dev-test.sh --cloud-entitlements` auto-selects these values when that local profile exists

- [ ] Named dev lanes `com.muesli.dev.a/b/c`
  - Default to local-only entitlements and do not need a CloudKit profile
  - If running with `--cloud-entitlements`, provide a lane-specific profile and matching Apple Development identity

- [ ] Preprod `MuesliPreprod` / `com.muesli.preprod`
  - Export `MUESLI_PROVISIONING_PROFILE=/path/to/com.muesli.preprod.profile`
  - Maintainer local profile: `../muesli-ios/secrets/mueslimacospreproddeveloperidcloudkit.provisionprofile`
  - Use the Developer ID release identity unless intentionally overriding `MUESLI_SIGN_IDENTITY`
  - Verify the embedded profile carries `iCloud.com.mueslihq.muesli`

- [ ] Stable `Muesli` / `com.muesli.app`
  - Export `MUESLI_PROVISIONING_PROFILE=/path/to/com.muesli.app.profile`
  - Maintainer local profile: `../muesli-ios/secrets/mueslimacosproductiondeveloperidcloudkit.provisionprofile`
  - Use `Developer ID Application: Pranav Hari Guruvayurappan (58W55QJ567)`
  - Final app and DMG must be notarized, stapled, and accepted by Gatekeeper

If launch fails with `No matching profile found`, the embedded profile, bundle ID, entitlements, or signing identity do not match.

## Build & Sign

- [ ] `scripts/build_native_app.sh` completes without error
- [ ] App installed to `/Applications/Muesli.app`
- [ ] Verify signature: `codesign -dvvv /Applications/Muesli.app 2>&1 | grep "Authority"`
  - Must show `Developer ID Application: Pranav Hari Guruvayurappan (58W55QJ567)`
- [ ] Verify effective entitlements:
  ```bash
  codesign -d --entitlements :- /Applications/Muesli.app | plutil -p -
  ```
  - Must show CloudKit container `iCloud.com.mueslihq.muesli`
  - Must show CloudKit environment `Production`
  - Must show APNs environment `production` when using the production Developer ID CloudKit profile
- [ ] Verify the built app:
  ```bash
  scripts/verify_signed_cloud_entitlements.sh /Applications/Muesli.app Production com.muesli.app iCloud.com.mueslihq.muesli production
  ```
- [ ] Mount the local DMG, then verify its app:
  ```bash
  scripts/verify_signed_cloud_entitlements.sh /Volumes/Muesli/Muesli.app Production com.muesli.app iCloud.com.mueslihq.muesli production
  ```
- [ ] Re-download and mount the GitHub release DMG, then verify its app with the same command:
  ```bash
  scripts/verify_signed_cloud_entitlements.sh /Volumes/Muesli/Muesli.app Production com.muesli.app iCloud.com.mueslihq.muesli production
  ```
- [ ] Stable and pre-production builds explicitly set `MUESLI_ICLOUD_CONTAINER_ENVIRONMENT=Production`; omission must fail closed.
- [ ] The stable release creates a dedicated `codex/release-<version>-appcast` PR for `docs/appcast.xml`, `docs/index.html`, and `docs/llms.txt`; it must not push those files directly to `main`.
- [ ] Merge the release metadata PR only after confirming its Sparkle enclosure URL, length, EdDSA signature, version, and release notes match the verified GitHub Release asset.

## Notarize & Staple (CRITICAL ORDER)

**The app bundle must be stapled BEFORE the DMG is created. Failure to do this causes "damaged app" errors.**

- [ ] **Step 1: Notarize the app bundle**
  ```bash
  ditto -c -k --keepParent /Applications/Muesli.app Muesli-app.zip
  xcrun notarytool submit Muesli-app.zip --keychain-profile MuesliNotary --wait
  ```
  - Must show `status: Accepted`

- [ ] **Step 2: Staple the app bundle**
  ```bash
  xcrun stapler staple /Applications/Muesli.app
  ```
  - Must show `The staple and validate action worked!`

- [ ] **Step 3: Create DMG from the STAPLED app**
  ```bash
  ./scripts/create_dmg.sh /Applications/Muesli.app dist-release
  ```

- [ ] **Step 4: Notarize the DMG**
  ```bash
  xcrun notarytool submit dist-release/Muesli-X.Y.Z.dmg --keychain-profile MuesliNotary --wait
  ```
  - Must show `status: Accepted`

- [ ] **Step 5: Staple the DMG**
  ```bash
  xcrun stapler staple dist-release/Muesli-X.Y.Z.dmg
  ```

## Verify (DO NOT SKIP)

- [ ] **Mount the DMG and test the app inside it:**
  ```bash
  hdiutil attach dist-release/Muesli-X.Y.Z.dmg
  spctl -a -vv "/Volumes/Muesli/Muesli.app"
  ```
  - Must show `accepted` and `source=Notarized Developer ID`
  - If it shows `rejected` — the app wasn't stapled before DMG creation. Go back to step 2.

- [ ] **Verify DMG has hardened runtime:**
  ```bash
  codesign -dvvv dist-release/Muesli-X.Y.Z.dmg 2>&1 | grep "flags"
  ```
  - Must show `flags=0x10000(runtime)` — if missing, `create_dmg.sh` is broken

- [ ] **Install and launch:**
  ```bash
  cp -R "/Volumes/Muesli/Muesli.app" /Applications/Muesli.app
  open /Applications/Muesli.app
  ```
  - No Gatekeeper warnings
  - App launches normally
  - Existing data (dictations, meetings) is intact

- [ ] **Verify version:**
  ```bash
  defaults read /Applications/Muesli.app/Contents/Info.plist CFBundleShortVersionString
  ```

## Release Staging

- [ ] **Create a draft GitHub Release and upload the DMG**
- [ ] **Re-download the hosted draft DMG and verify it matches the local artifact**
  ```bash
  gh release download vX.Y.Z -p "Muesli-X.Y.Z.dmg" -D /tmp/muesli-release-verify --clobber
  shasum -a 256 dist-release/Muesli-X.Y.Z.dmg /tmp/muesli-release-verify/Muesli-X.Y.Z.dmg
  spctl -a -vv -t open --context context:primary-signature /tmp/muesli-release-verify/Muesli-X.Y.Z.dmg
  xcrun stapler validate /tmp/muesli-release-verify/Muesli-X.Y.Z.dmg
  ```
  - The local and hosted SHA256 hashes must match exactly
  - Must show `accepted` and `The validate action worked!`

## Appcast & Docs

- [ ] **Generate the new release item without replacing appcast history:**
  ```bash
  generated_appcast="$(mktemp)"
  native/MuesliNative/.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    dist-release/ -o "$generated_appcast"
  python3 scripts/update_appcast_release_notes.py \
    "$generated_appcast" \
    --sparkle-version X.Y.Z \
    --short-version X.Y.Z \
    < docs/release-notes/X.Y.Z.md
  python3 scripts/merge_appcast_item.py \
    --existing docs/appcast.xml \
    --generated "$generated_appcast" \
    --version X.Y.Z \
    --output docs/appcast.xml
  rm "$generated_appcast"
  ```

- [ ] **Confirm historical items are unchanged.** `merge_appcast_item.py` rejects
  duplicate versions and noncanonical historical URLs, normalizes the new item
  to GitHub Releases, and removes unhosted delta enclosures.

- [ ] **Update download link** in `docs/index.html` (both the `<a>` href and JSON-LD `downloadUrl`)

- [ ] **Verify Sparkle update flow metadata and artifact:**
  ```bash
  scripts/verify_update_flow.sh --version X.Y.Z --dmg dist-release/Muesli-X.Y.Z.dmg --require-notarized
  ```

- [ ] **Push the appcast + download-link metadata branch:**
  ```bash
  git switch -c codex/release-X.Y.Z-appcast
  git add docs/appcast.xml docs/index.html
  git add docs/llms.txt
  git commit -m "Update appcast for vX.Y.Z"
  git push -u origin codex/release-X.Y.Z-appcast
  ```

- [ ] **Open the release-metadata PR while the GitHub Release remains a draft.**

  If the final GitHub publication call fails after this point, rerun the same
  `release.sh X.Y.Z` command from exact `origin/main`. The pipeline recognizes
  the existing versioned metadata branch and open PR, revalidates the hosted
  notarized artifact, Production CloudKit entitlements, and appcast, then safely
  resumes publication without recreating release metadata.
  - If appcast generation, release-note injection, validation, commit, push, or PR creation fails, stop and leave the GitHub Release as a draft.

- [ ] **Publish the verified draft release only after the metadata PR exists.**

## Homebrew Cask

- [ ] **Verify the official Homebrew cask autobump path**
  - The canonical release flow runs `brew livecheck --cask muesli` after the GitHub Release is published
  - It also runs `brew bump --cask --no-pull-requests muesli` to confirm BrewTestBot owns update PRs
  - Homebrew's BrewTestBot owns official cask bump PRs for `muesli` and opens them automatically about every 3 hours
  - If a PR does not appear after the next autobump cycle, investigate livecheck/autobump rather than using `brew bump-cask-pr`
  - Set `MUESLI_SKIP_HOMEBREW_CHECK=1` only when intentionally skipping the release-time livecheck

- [ ] **Verify the official cask install path if the cask changed shape**
  ```bash
  brew install --cask muesli
  ```

- [ ] **Verify the Homebrew CLI alias when the cask exposes the bundled binary**
  ```bash
  brew install muesli
  command -v muesli
  muesli transcribe --help
  ```

## Post-release

- [ ] Verify GitHub Pages serves appcast: `curl -s https://muesli-hq.github.io/muesli/appcast.xml | head -5`
- [ ] Verify the GitHub Release page exposes the DMG you just uploaded
- [ ] Verify `docs/index.html` and `docs/llms.txt` point to the newly published GitHub Release DMG
- [ ] Optional: install previous version and confirm Sparkle shows update prompt
