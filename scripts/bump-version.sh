#!/usr/bin/env bash
#
# scripts/bump-version.sh — set every PYRXSynapse version reference in lockstep.
#
# Usage:
#   scripts/bump-version.sh <new-version>
#
# Example:
#   scripts/bump-version.sh 0.2.0
#
# Updates 3 spots:
#   1. PYRXSynapse.podspec                                       (s.version line)
#   2. Sources/PYRXSynapse/PyrxConstants.swift                   (sdkVersion constant)
#   3. Tests/PYRXSynapseTests/PushRegistrationTests.swift        (hardcoded JSON assertion)
#
# Then runs `swift test` to confirm tests still pass with the new version.
#
# Why this script exists: v0.1.x dry-runs caught lockstep drift twice (test
# assertions hardcoded the old version while source was bumped). Manual sed
# is error-prone; one command beats five.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <new-version>"
  echo "Example: $0 0.2.0"
  exit 1
fi

NEW_VERSION="$1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Capture current version so we can do a targeted in-place replacement
CURRENT_VERSION=$(grep -E "public static let sdkVersion" Sources/PYRXSynapse/PyrxConstants.swift | sed -E 's/.*"([^"]+)".*/\1/')

if [[ -z "$CURRENT_VERSION" ]]; then
  echo "ERROR: could not detect current version from Sources/PYRXSynapse/PyrxConstants.swift" >&2
  exit 1
fi

if [[ "$CURRENT_VERSION" == "$NEW_VERSION" ]]; then
  echo "Current version already $NEW_VERSION — nothing to do."
  exit 0
fi

echo "Bumping $CURRENT_VERSION → $NEW_VERSION across 3 source files…"

# 1. podspec
sed -i '' "s/s\.version[[:space:]]*=[[:space:]]*'$CURRENT_VERSION'/s.version          = '$NEW_VERSION'/" PYRXSynapse.podspec

# 2. PyrxConstants.swift
sed -i '' "s/sdkVersion: String = \"$CURRENT_VERSION\"/sdkVersion: String = \"$NEW_VERSION\"/" Sources/PYRXSynapse/PyrxConstants.swift

# 3. PushRegistrationTests.swift  (hardcoded "sdk_version":"x.y.z" inside expected JSON body)
sed -i '' "s/\"sdk_version\":\"$CURRENT_VERSION\"/\"sdk_version\":\"$NEW_VERSION\"/" Tests/PYRXSynapseTests/PushRegistrationTests.swift

# Verify by re-grepping the new value in each file
echo ""
echo "Verification (expect 3 matches for '$NEW_VERSION'):"
grep -nE "s\.version|sdkVersion|\"sdk_version\":\"$NEW_VERSION\"" \
  PYRXSynapse.podspec \
  Sources/PYRXSynapse/PyrxConstants.swift \
  Tests/PYRXSynapseTests/PushRegistrationTests.swift \
  | grep -v "^[[:space:]]*//\|^[[:space:]]*\*"

# Quick test smoke (skip if --no-test passed; not exposed as flag yet but reserved)
echo ""
echo "Running swift test to confirm assertions still pass…"
swift test 2>&1 | tail -5

echo ""
echo "Done. Next: commit + tag:"
echo "  git add -A && git commit -m 'chore(release): v$NEW_VERSION'"
echo "  git tag -a v$NEW_VERSION -m 'v$NEW_VERSION'"
echo "  git push origin main"
echo "  git push origin v$NEW_VERSION"
