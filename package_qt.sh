#!/usr/bin/env bash
# package_qt.sh — Build DX3270 (Qt6 version) in Release mode and wrap it in a distributable DMG.
#
# Usage:
#   ./package_qt.sh               # uses BUILD_NUMBER=1 (default)
#   BUILD_NUMBER=42 ./package_qt.sh
#
# Output:
#   dist/DX3270-Qt-<version>-build<BUILD_NUMBER>.dmg

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
APP_NAME="DX3270_Qt"
APP_DISPLAY_NAME="DX3270-Qt"
VERSION="1.7.6"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DMG_NAME="${APP_DISPLAY_NAME}-${VERSION}-build${BUILD_NUMBER}"
BUILD_DIR="$(pwd)/build_release_qt"
DIST_DIR="$(pwd)/dist"
STAGING_DIR="$(mktemp -d)"

QT_PREFIX="/opt/homebrew/opt/qt"
MACDEPLOYQT="${QT_PREFIX}/bin/macdeployqt"

if [ ! -x "${MACDEPLOYQT}" ]; then
    echo "ERROR: macdeployqt not found at ${MACDEPLOYQT}. Is Qt6 installed?" >&2
    exit 1
fi

echo "==> Building ${DMG_NAME}"
echo "    Build dir : ${BUILD_DIR}"
echo "    Output    : ${DIST_DIR}/${DMG_NAME}.dmg"
echo ""

# ── 1. Configure & build ──────────────────────────────────────────────────────
cmake \
    -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_NUMBER="${BUILD_NUMBER}" \
    -DCMAKE_PREFIX_PATH="${QT_PREFIX}"

cmake --build "${BUILD_DIR}" --config Release --target ${APP_NAME} --parallel "$(sysctl -n hw.logicalcpu)"

APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
if [ ! -d "${APP_PATH}" ]; then
    echo "ERROR: ${APP_PATH} not found after build" >&2
    exit 1
fi

# ── 1b. Strip local symbols ───────────────────────────────────────────────────
echo "==> Stripping local symbols to reduce size"
if [ -f "${APP_PATH}/Contents/MacOS/${APP_NAME}" ]; then
    strip -x "${APP_PATH}/Contents/MacOS/${APP_NAME}"
fi

# ── 1c. Deploy Qt Frameworks ──────────────────────────────────────────────────
echo "==> Deploying Qt frameworks into the app bundle (macdeployqt). This may take 1-2 minutes..."
# Inviamo tutto l'output rumoroso a un file di log per mantenere la console pulita senza bloccarla
"${MACDEPLOYQT}" "${APP_PATH}" -always-overwrite > "${BUILD_DIR}/macdeployqt.log" 2>&1 || true

# ── 1d. Prune Bloatware (Fixes warnings & reduces size) ───────────────────────
echo "==> Pruning unnecessary Qt plugins & frameworks..."

# Rimuoviamo i plugin che generano le dipendenze rotte (brotli, webp, pdf, ecc.)
rm -rf "${APP_PATH}/Contents/PlugIns/platforminputcontexts"
rm -rf "${APP_PATH}/Contents/PlugIns/scenegraph"
rm -f "${APP_PATH}/Contents/PlugIns/imageformats/libqpdf.dylib"
rm -f "${APP_PATH}/Contents/PlugIns/imageformats/libqwebp.dylib"
rm -f "${APP_PATH}/Contents/PlugIns/iconengines/libqsvgicon.dylib"

# Rimuoviamo i framework mastodontici che DX3270 non usa
rm -rf "${APP_PATH}/Contents/Frameworks/QtPdf.framework"
rm -rf "${APP_PATH}/Contents/Frameworks/QtVirtualKeyboard.framework"
rm -rf "${APP_PATH}/Contents/Frameworks/QtVirtualKeyboardQml.framework"
rm -rf "${APP_PATH}/Contents/Frameworks/QtQml"*
rm -rf "${APP_PATH}/Contents/Frameworks/QtQuick"*
rm -rf "${APP_PATH}/Contents/Frameworks/QtSvg"*

# ── 2. Stage the DMG contents ─────────────────────────────────────────────────
echo "==> Staging DMG contents"
cp -R "${APP_PATH}" "${STAGING_DIR}/${APP_NAME}.app"

# Symlink to /Applications for drag-install UX
ln -s /Applications "${STAGING_DIR}/Applications"

# ── 2b. Code-sign the *whole* app bundle ──────────────────────────────────────
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
SIGNED_APP="${STAGING_DIR}/${APP_NAME}.app"
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

echo "==> Creating DMG (this may take a moment)"

hdiutil create \
    -volname "${APP_DISPLAY_NAME} ${VERSION}" \
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
echo "    Engine      : Qt6"
echo ""
echo "To install: open the DMG and drag ${APP_NAME} to /Applications"