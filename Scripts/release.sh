#!/usr/bin/env bash
#
# release.sh — Build, package, and publish OpenSoundSource to Homebrew.
#
# Usage:
#   ./Scripts/release.sh [version] [--major|--minor|--patch]
#
# Examples:
#   ./Scripts/release.sh           # auto-bump patch (0.1.0 → 0.1.1)
#   ./Scripts/release.sh --minor   # auto-bump minor (0.1.1 → 0.2.0)
#   ./Scripts/release.sh --major   # auto-bump major (0.2.0 → 1.0.0)
#   ./Scripts/release.sh 0.3.0     # explicit version
#
# Prerequisites:
#   - Xcode + command-line tools
#   - CMake (brew install cmake)
#   - XcodeGen (brew install xcodegen)
#   - gh CLI (brew install gh) — authenticated
#
# What it does:
#   1. Builds the app (universal: arm64 + x86_64, Release)
#   2. Builds the virtual driver (universal)
#   3. Packages both into OpenSoundSource-<version>.zip
#   4. Creates a GitHub release with the zip attached
#   5. Updates the Homebrew cask formula with the new sha256
#   6. Commits and pushes the homebrew-tap update

set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAP_REPO="${TAP_REPO:-$HOME/development/homebrew-tap}"
TAP_GITHUB_REPO="Highwall2016/homebrew-tap"
BUILD_DIR="$REPO_ROOT/.release-build"

# ─── Args ─────────────────────────────────────────────────────────────────────

bump_version() {
  local ver="$1" part="${2:-patch}"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$ver"
  major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"
  case "$part" in
    major) echo "$(( major + 1 )).0.0" ;;
    minor) echo "${major}.$(( minor + 1 )).0" ;;
    patch) echo "${major}.${minor}.$(( patch + 1 ))" ;;
    *)     echo "${major}.${minor}.$(( patch + 1 ))" ;;
  esac
}

get_latest_version() {
  # Try GitHub releases first, fall back to cask file
  local latest
  latest=$(gh release list --repo "$TAP_GITHUB_REPO" --limit 50 --json tagName --jq '[.[].tagName | select(startswith("opensoundsource-"))][0]' 2>/dev/null || true)
  latest="${latest#opensoundsource-v}"  # strip prefix
  if [[ -z "$latest" ]]; then
    # Fall back to cask file
    local cask_file="$TAP_REPO/Casks/opensoundsource.rb"
    if [[ -f "$cask_file" ]]; then
      latest=$(grep 'version "' "$cask_file" | head -1 | sed 's/.*version "//;s/".*//')
    fi
  fi
  echo "${latest:-0.0.0}"
}

BUMP="patch"
VERSION=""

if [[ $# -ge 1 ]]; then
  case "$1" in
    --major) BUMP="major" ;;
    --minor) BUMP="minor" ;;
    --patch) BUMP="patch" ;;
    -*)
      echo "Unknown flag: $1"
      echo "Usage: $0 [version] [--major|--minor|--patch]"
      exit 1
      ;;
    *)  VERSION="$1" ;;
  esac
fi

if [[ -z "$VERSION" ]]; then
  LATEST=$(get_latest_version)
  VERSION=$(bump_version "$LATEST" "$BUMP")
  echo "==> Latest version: v${LATEST}"
  echo "==> Bumping ${BUMP}: v${LATEST} → v${VERSION}"
  echo ""
  read -r -p "    Continue with v${VERSION}? [Y/n] " confirm
  if [[ "$confirm" =~ ^[Nn] ]]; then
    echo "Aborted."
    exit 0
  fi
fi
ZIP_NAME="OpenSoundSource-${VERSION}.zip"

echo "==> Releasing OpenSoundSource v${VERSION}"
echo ""

# ─── Clean ────────────────────────────────────────────────────────────────────

echo "==> Cleaning previous build artifacts..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/staging"

# ─── Generate Xcode project ──────────────────────────────────────────────────

echo "==> Generating Xcode project..."
cd "$REPO_ROOT"
xcodegen generate --quiet 2>/dev/null || xcodegen generate

# ─── Build App (universal) ───────────────────────────────────────────────────

echo "==> Building OpenSoundSource.app (Release, universal)..."
xcodebuild \
  -project "$REPO_ROOT/OpenSoundSource.xcodeproj" \
  -scheme OpenSoundSource \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  -arch arm64 -arch x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  clean build 2>&1 | tail -5

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/OpenSoundSource.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: App build failed — $APP_PATH not found"
  exit 1
fi

echo "    ✓ App built at $APP_PATH"

# ─── Build Virtual Driver (universal) ────────────────────────────────────────

echo "==> Building VirtualDriver (Release, universal)..."
DRIVER_BUILD="$BUILD_DIR/driver-build"
mkdir -p "$DRIVER_BUILD"
cd "$DRIVER_BUILD"
cmake "$REPO_ROOT/VirtualDriver" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  2>&1 | tail -3
make -j"$(sysctl -n hw.ncpu)" 2>&1 | tail -3

DRIVER_PATH="$DRIVER_BUILD/OpenSoundSourceDriver.driver"

if [[ ! -d "$DRIVER_PATH" ]]; then
  echo "WARNING: Driver build failed — $DRIVER_PATH not found"
  echo "         Continuing without the virtual driver."
  DRIVER_PATH=""
fi

if [[ -n "$DRIVER_PATH" ]]; then
  echo "    ✓ Driver built at $DRIVER_PATH"
fi

# ─── Stage ────────────────────────────────────────────────────────────────────

echo "==> Staging release artifacts..."
STAGING="$BUILD_DIR/staging"
cp -R "$APP_PATH" "$STAGING/"

if [[ -n "$DRIVER_PATH" ]]; then
  cp -R "$DRIVER_PATH" "$STAGING/"
fi

# ─── Package ──────────────────────────────────────────────────────────────────

echo "==> Creating $ZIP_NAME..."
cd "$STAGING"
zip -r -y -q "$BUILD_DIR/$ZIP_NAME" .
cd "$REPO_ROOT"

SHA256=$(shasum -a 256 "$BUILD_DIR/$ZIP_NAME" | awk '{print $1}')
SIZE=$(du -h "$BUILD_DIR/$ZIP_NAME" | awk '{print $1}')

echo "    ✓ $ZIP_NAME ($SIZE, sha256: $SHA256)"

# ─── GitHub Release ──────────────────────────────────────────────────────────

TAG="opensoundsource-v${VERSION}"
echo "==> Creating GitHub release ${TAG}..."

# Check if release already exists
if gh release view "${TAG}" --repo "$TAP_GITHUB_REPO" &>/dev/null; then
  echo "    Release ${TAG} already exists. Deleting and recreating..."
  gh release delete "${TAG}" --repo "$TAP_GITHUB_REPO" --yes --cleanup-tag 2>/dev/null || true
fi

gh release create "${TAG}" \
  "$BUILD_DIR/$ZIP_NAME" \
  --repo "$TAP_GITHUB_REPO" \
  --title "OpenSoundSource v${VERSION}" \
  --notes "## OpenSoundSource v${VERSION}

### Installation

\`\`\`bash
brew tap Highwall2016/tap
brew install opensoundsource
\`\`\`

### What's Included

- **OpenSoundSource.app** — Per-app audio routing menu bar app
- **OpenSoundSourceDriver.driver** — Virtual audio driver (installed automatically)

### Requirements

- macOS 14.2+ (Sonoma)
- Screen Recording permission (prompted on first launch)

### SHA256

\`${SHA256}\`"

echo "    ✓ GitHub release v${VERSION} created"

# ─── Update Homebrew Cask ─────────────────────────────────────────────────────

echo "==> Updating Homebrew cask formula..."
CASK_FILE="$TAP_REPO/Casks/opensoundsource.rb"

if [[ ! -f "$CASK_FILE" ]]; then
  echo "ERROR: Cask file not found at $CASK_FILE"
  echo "       Make sure the homebrew-tap repo is at $TAP_REPO"
  exit 1
fi

# Update version
sed -i '' "s/version \".*\"/version \"${VERSION}\"/" "$CASK_FILE"

# Update sha256
sed -i '' "s/sha256 \".*\"/sha256 \"${SHA256}\"/" "$CASK_FILE"

echo "    ✓ Updated $CASK_FILE"

# ─── Commit & Push Tap ───────────────────────────────────────────────────────

echo "==> Committing and pushing homebrew-tap..."
cd "$TAP_REPO"
git add Casks/opensoundsource.rb README.md 2>/dev/null || true
git add Casks/opensoundsource.rb
git commit -m "opensoundsource: update to v${VERSION}" || echo "    (no changes to commit)"
git push

echo ""
echo "==> Done! OpenSoundSource v${VERSION} released."
echo ""
echo "    Users can install with:"
echo "      brew tap Highwall2016/tap"
echo "      brew install opensoundsource"
echo ""
echo "    Or update with:"
echo "      brew update"
echo "      brew upgrade opensoundsource"
