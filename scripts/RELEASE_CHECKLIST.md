# Muesli Release Checklist

Run `./scripts/release.sh [version]` — it automates steps 1-9 and is the only official release path.

Source of truth:
- GitHub Releases hosts the official DMG binaries
- GitHub Pages hosts the Sparkle appcast consumed by the app
- `Muesli-HQ/homebrew-muesli` mirrors the verified GitHub Release DMG via the Homebrew tap cask
- Marketing surfaces may link to those assets, but they are not release authorities

This checklist is for **verification** after the script runs, and for manual recovery if any step fails.

## Pre-release

- [ ] All changes merged to `main`
- [ ] `swift test --package-path native/MuesliNative` — all tests pass
- [ ] Version bumped in `scripts/build_native_app.sh` (CFBundleVersion + CFBundleShortVersionString)
- [ ] No uncommitted changes (`git status` clean)

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

- [ ] **Publish the verified draft release**

## Appcast & Docs

- [ ] **Generate appcast on the single Sparkle host:**
  ```bash
  native/MuesliNative/.build/artifacts/sparkle/Sparkle/bin/generate_appcast dist-release/ -o docs/appcast.xml
  ```

- [ ] **Fix appcast enclosure URLs to GitHub Releases** — `generate_appcast` writes GitHub Pages URLs. Replace with GitHub Releases URLs:
  ```
  https://muesli-hq.github.io/muesli/Muesli-X.Y.Z.dmg
  →
  https://github.com/Muesli-HQ/muesli/releases/download/vX.Y.Z/Muesli-X.Y.Z.dmg
  ```

- [ ] **Remove delta entries** from appcast (deltas aren't hosted)

- [ ] **Update download link** in `docs/index.html` (both the `<a>` href and JSON-LD `downloadUrl`)

- [ ] **Verify Sparkle update flow metadata and artifact:**
  ```bash
  scripts/verify_update_flow.sh --version X.Y.Z --dmg dist-release/Muesli-X.Y.Z.dmg --require-notarized
  ```

- [ ] **Push appcast + download link:**
  ```bash
  git add docs/appcast.xml docs/index.html
  git commit -m "Update appcast for vX.Y.Z"
  git push
  ```

## Homebrew Tap

- [ ] **Update the Homebrew tap cask** in `Muesli-HQ/homebrew-muesli`
  - `Casks/m/muesli.rb` must point at the new version and the hosted GitHub Release SHA256
  - Commit message should be `muesli X.Y.Z`
  - The canonical release flow now automates this inside `scripts/release.sh`

- [ ] **Verify the tap install path if the cask changed shape**
  ```bash
  brew tap Muesli-HQ/muesli
  brew install --cask Muesli-HQ/muesli/muesli
  ```

## Post-release

- [ ] Verify GitHub Pages serves appcast: `curl -s https://muesli-hq.github.io/muesli/appcast.xml | head -5`
- [ ] Verify the GitHub Release page exposes the DMG you just uploaded
- [ ] Verify `docs/index.html` and `docs/llms.txt` point to the newly published GitHub Release DMG
- [ ] Optional: install previous version and confirm Sparkle shows update prompt
