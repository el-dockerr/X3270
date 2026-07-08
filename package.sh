#!/usr/bin/env bash
# package.sh — Build DX3270 in Release mode and wrap it in a distributable DMG.
#
# Usage:
#   ./package.sh               # uses BUILD_NUMBER=1 (default)
#   BUILD_NUMBER=42 ./package.sh
#
# Output:
#   dist/DX3270-<version>-build<BUILD_NUMBER>.dmg

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
APP_NAME="DX3270"
VERSION="1.7.4"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DMG_NAME="${APP_NAME}-${VERSION}-build${BUILD_NUMBER}"
BUILD_DIR="$(pwd)/build_release"
DIST_DIR="$(pwd)/dist"
STAGING_DIR="$(mktemp -d)"

echo "==> Building ${DMG_NAME}"
echo "    Build dir : ${BUILD_DIR}"
echo "    Output    : ${DIST_DIR}/${DMG_NAME}.dmg"
echo ""

# ── 1. Configure & build ──────────────────────────────────────────────────────
cmake \
    -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_NUMBER="${BUILD_NUMBER}"

cmake --build "${BUILD_DIR}" --config Release --parallel "$(sysctl -n hw.logicalcpu)"

APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
if [ ! -d "${APP_PATH}" ]; then
    echo "ERROR: ${APP_PATH} not found after build" >&2
    exit 1
fi

# ── 2. Stage the DMG contents ─────────────────────────────────────────────────
echo ""
echo "==> Staging DMG contents"
cp -R "${APP_PATH}" "${STAGING_DIR}/${APP_NAME}.app"
# Symlink to /Applications for drag-install UX
ln -s /Applications "${STAGING_DIR}/Applications"

# ── 2b. Code-sign the *whole* app bundle ──────────────────────────────────────
# The linker only ad-hoc-signs the raw executable. Once CMake adds the icon,
# fonts and Info.plist, that seal no longer matches the bundle, so a downloaded
# (quarantined) copy is rejected by Gatekeeper as "damaged and can't be opened".
# Re-signing the assembled bundle produces a valid _CodeSignature seal.
#
# Set CODESIGN_IDENTITY to a "Developer ID Application: …" identity to sign for
# distribution (recommended — pair with notarization for a warning-free launch).
# Otherwise we fall back to ad-hoc (-), which removes the "damaged" error; users
# then open it once via right-click → Open (or the xattr command in the README).
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
SIGNED_APP="${STAGING_DIR}/${APP_NAME}.app"
echo ""
echo "==> Code-signing app bundle (identity: ${CODESIGN_IDENTITY})"
if [ "${CODESIGN_IDENTITY}" = "-" ]; then
    codesign --force --deep --sign - "${SIGNED_APP}"
else
    codesign --force --deep --options runtime --timestamp \
        --sign "${CODESIGN_IDENTITY}" "${SIGNED_APP}"
fi
codesign --verify --deep --strict --verbose=2 "${SIGNED_APP}"

# ── 3. Create the DMG ─────────────────────────────────────────────────────────
mkdir -p "${DIST_DIR}"

TEMP_DMG="${DIST_DIR}/${DMG_NAME}-rw.dmg"
FINAL_DMG="${DIST_DIR}/${DMG_NAME}.dmg"

echo ""
echo "==> Creating DMG (this may take a moment)"

hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDRW \
    "${TEMP_DMG}" \
    > /dev/null

# Convert to read-only compressed image
hdiutil convert \
    "${TEMP_DMG}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "${FINAL_DMG}" \
    > /dev/null

rm -f "${TEMP_DMG}"
rm -rf "${STAGING_DIR}"

# ── 4. Summary ────────────────────────────────────────────────────────────────
DMG_SIZE=$(du -sh "${FINAL_DMG}" | cut -f1)
echo ""
echo "==> Done"
echo "    ${FINAL_DMG}  (${DMG_SIZE})"
echo ""
echo "    Version     : ${VERSION}"
echo "    Build number: ${BUILD_NUMBER}"
echo ""
echo "To install: open the DMG and drag DX3270 to /Applications"
