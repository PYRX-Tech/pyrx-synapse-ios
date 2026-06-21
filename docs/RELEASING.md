# Releasing PYRXSynapse

Maintainer-only guide for cutting a new SDK release. End users should not need to read this.

The release pipeline publishes to **two** registries:
- **Swift Package Manager** — via a git tag on this repository. SPM consumers point at the GitHub URL and SPM resolves versions from tags directly.
- **CocoaPods Trunk** — via `pod trunk push`. CocoaPods consumers `pod install` from the trunk index.

Both are driven by `.github/workflows/publish.yml`, triggered on push of any `v*` tag.

---

## Prerequisites (one-time setup)

These items must be in place before the very first release. They do not need to be repeated for subsequent releases unless something rotates.

### Apple Developer Program membership

Required for the GitHub Actions runners to build against the full iOS SDK in `pod lib lint`. US$99/yr. Enrol at [developer.apple.com/programs](https://developer.apple.com/programs/).

### CocoaPods Trunk account

The first time you publish, register your maintainer email with CocoaPods Trunk on your local machine:

```bash
pod trunk register your-email@pyrx.tech 'Your Name' --description='laptop'
```

CocoaPods sends a verification email — click the link. After verification, run:

```bash
pod trunk me
```

…to confirm you're authenticated. Copy the **token** value — you'll add it to GitHub as a secret next.

### GitHub repository secret

Add the trunk token to `PYRX-Tech/pyrx-synapse-ios` repository settings:

1. GitHub → Settings → Secrets and variables → Actions → New repository secret.
2. Name: `COCOAPODS_TRUNK_TOKEN`. Value: the token from `pod trunk me`.
3. Also create a repository **variable** named `COCOAPODS_PUBLISH_ENABLED` with value `true` (the publish job is gated on this flag so accidentally-pushed tags don't publish during early testing).

### Push permission for the `PYRXSynapse` pod

Confirm your trunk account is registered as an owner of the existing `PYRXSynapse` pod:

```bash
pod trunk info PYRXSynapse
```

If you're not listed under `Owners`, an existing owner must add you with:

```bash
pod trunk add-owner PYRXSynapse your-email@pyrx.tech
```

---

## Release process

Repeat for each release.

### 1. Final pre-release verification on `main`

```bash
git checkout main
git pull origin main

swift build -c release
swift test
swiftlint --strict
pod lib lint PYRXSynapse.podspec --quick
```

All four must pass. If `pod lib lint --quick` passes but you want the strictest gate the CI runs, run the full lint (slower, builds against the iOS Simulator):

```bash
pod lib lint PYRXSynapse.podspec
```

### 2. Update version metadata

Bump `PYRXSynapse.podspec`:

```ruby
s.version = '1.0.0'   # change to the new version
```

SPM does **not** read a version from `Package.swift` — it uses the git tag directly. There's no `Package.swift` change required for SPM versioning.

### 3. Update the CHANGELOG

Edit `CHANGELOG.md`:

- Move entries from the `[Unreleased]` section under a new `## [1.0.0] - YYYY-MM-DD` heading.
- Add a fresh empty `[Unreleased]` section at the top for future work.
- Keep the format aligned with [Keep a Changelog](https://keepachangelog.com/).

### 4. Commit the version bump

```bash
git add PYRXSynapse.podspec CHANGELOG.md
git commit -m "chore(release): v1.0.0"
git push origin main
```

### 5. Tag the release

```bash
git tag -a v1.0.0 -m "v1.0.0"
git push origin v1.0.0
```

> The leading `v` is required — the `publish.yml` workflow is triggered by `tags: ['v*']`.

### 6. Watch the publish workflow

Open the Actions tab on GitHub. The `Publish` workflow runs three jobs:

1. **verify** — `swift package resolve`, `swift build -c release`, `swift test`, `pod lib lint PYRXSynapse.podspec --allow-warnings`. All must pass before the next two jobs run.
2. **publish-cocoapods** — `pod trunk push PYRXSynapse.podspec`. Gated on `vars.COCOAPODS_PUBLISH_ENABLED == 'true'` and `secrets.COCOAPODS_TRUNK_TOKEN` being set.
3. **github-release** — creates a GitHub Release on the tag with auto-generated release notes.

If any job fails:
- **verify failure** — fix on `main`, push, delete the tag (`git push origin :refs/tags/v1.0.0`), recreate the tag from the new commit, push the tag.
- **publish-cocoapods failure** — the pod is NOT published. Common causes: trunk token expired, network blip. Re-run the job from the Actions UI (it's idempotent — trunk rejects duplicate version pushes safely).
- **github-release failure** — usually a permissions issue. The pod is already published; manually create the release in the GitHub UI as a fallback.

### 7. Verify the published artifacts

**SPM:**

```bash
cd /tmp
swift package init --type executable
# edit Package.swift to add `.package(url: "https://github.com/PYRX-Tech/pyrx-synapse-ios.git", from: "1.0.0")`
swift package resolve
```

The resolve should pull the new tag.

**CocoaPods:**

```bash
pod search PYRXSynapse
```

Wait up to 30 minutes after `pod trunk push` for the search index to update. The CocoaPods page at [cocoapods.org/pods/PYRXSynapse](https://cocoapods.org/pods/PYRXSynapse) reflects new versions within a few minutes.

### 8. Announce

- Update the SDK section of the PYRX developer portal docs.
- If the release adds a customer-facing feature, post in the PYRX changelog feed.

---

## Hotfix releases

For urgent bug fixes (e.g. `1.0.0 → 1.0.1`):

1. Branch from the tag of the broken version: `git checkout -b hotfix/1.0.1 v1.0.0`.
2. Apply the fix + tests.
3. Bump `s.version = '1.0.1'`.
4. PR to `main`, merge.
5. Follow steps 5–8 of the standard release process from `main`.

If `main` has diverged with breaking changes that can't go in a patch, cherry-pick the fix onto a dedicated `release/1.0.x` branch and tag from there. SPM and CocoaPods both honour arbitrary semver tags — they don't require the tag to be on a specific branch.

---

## Rolling back a release

CocoaPods Trunk does NOT allow unpublishing. SPM tags can be deleted but consumers who already resolved against the tag have it cached locally.

If a release is broken:

1. Immediately publish a `1.0.x+1` patch that either fixes the bug or reverts the offending change.
2. Mark the bad version as deprecated in `CHANGELOG.md`.
3. Open a notice in the GitHub Release for the bad version pointing to the fix.

Do NOT delete the tag — that breaks anyone who pinned to the bad version. Always roll forward.

---

## Versioning policy

We follow [Semantic Versioning](https://semver.org/):

- **Major** — breaking public API changes. Document migration in [MIGRATION.md](MIGRATION.md). Cut from `main` after a deprecation cycle in the prior minor.
- **Minor** — additive, backwards-compatible features. Cut from `main`.
- **Patch** — bug fixes, internal cleanup. Cut from `main` or a hotfix branch.

The SDK version is single-sourced in `PYRXSynapse.podspec` (`s.version`). It's surfaced at runtime via `PyrxConstants.sdkVersion` (which currently hard-codes the same string — keep them in sync; we'll automate this in a future release).
