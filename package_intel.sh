#!/usr/bin/env bash
# package_intel.sh — Cross-compile DX3270 for Intel (x86_64) on Apple Silicon
#                    and wrap it in a distributable DMG.
#
# Prerequisites (one-time setup):
#   1. Rosetta 2 must be installed:
#        softwareupdate --install-rosetta --agree-to-license
#   2. x86_64 Homebrew must exist at /usr/local:
#        arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
#   3. x86_64 OpenSSL must be installed under that Homebrew:
#        arch -x86_64 /usr/local/bin/brew install openssl@3
#
# Usage:
#   ./package_intel.sh               # uses BUILD_NUMBER=1 (default)
#   BUILD_NUMBER=42 ./package_intel.sh
#
# Output:
#   dist/DX3270-<version>-build<BUILD_NUMBER>-Intel.dmg

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
APP_NAME="DX3270"
VERSION="1.7.2"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCH="x86_64"
DMG_NAME="${APP_NAME}-${VERSION}-build${BUILD_NUMBER}-Intel"
BUILD_DIR="$(pwd)/build_release_intel"
DIST_DIR="$(pwd)/dist"
STAGING_DIR="$(mktemp -d)"

# ── Sanity checks ─────────────────────────────────────────────────────────────
# Verify we are running on Apple Silicon (cross-compilation host)
HOST_ARCH="$(uname -m)"
if [ "${HOST_ARCH}" != "arm64" ]; then
    echo "ERROR: This script cross-compiles for Intel from an Apple Silicon Mac." >&2
    echo "       Detected host architecture: ${HOST_ARCH}" >&2
    exit 1
fi

# Verify Rosetta 2 is available
if ! arch -x86_64 true 2>/dev/null; then
    echo "ERROR: Rosetta 2 is not installed. Install it with:" >&2
    echo "  softwareupdate --install-rosetta --agree-to-license" >&2
    exit 1
fi

# ── Locate x86_64 OpenSSL ─────────────────────────────────────────────────────
# x86_64 Homebrew installs to /usr/local on Apple Silicon Macs (Rosetta 2 path)
INTEL_OPENSSL_ROOT=""
for candidate in \
    /usr/local/opt/openssl@3 \
    /usr/local/opt/openssl@1.1 \
    /usr/local/opt/openssl; do
    if [ -f "${candidate}/include/openssl/ssl.h" ]; then
        # Confirm the library is actually x86_64
        LIB_ARCH=$(lipo -archs "${candidate}/lib/libssl.a" 2>/dev/null \
                   || lipo -archs "${candidate}/lib/libssl.dylib" 2>/dev/null \
                   || echo "unknown")
        if [[ "${LIB_ARCH}" == *"x86_64"* ]]; then
            INTEL_OPENSSL_ROOT="${candidate}"
            break
        fi
    fi
done

if [ -z "${INTEL_OPENSSL_ROOT}" ]; then
    echo "ERROR: x86_64 OpenSSL not found under /usr/local/opt/." >&2
    echo "       Install it with:" >&2
    echo "  arch -x86_64 /usr/local/bin/brew install openssl@3" >&2
    exit 1
fi

echo "==> Building ${DMG_NAME}"
echo "    Architecture: ${ARCH} (cross-compiled on ${HOST_ARCH})"
echo "    OpenSSL     : ${INTEL_OPENSSL_ROOT}"
echo "    Build dir   : ${BUILD_DIR}"
echo "    Output      : ${DIST_DIR}/${DMG_NAME}.dmg"
echo ""

# ── 1. Configure & build ──────────────────────────────────────────────────────
cmake \
    -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="${ARCH}" \
    -DOPENSSL_ROOT_DIR="${INTEL_OPENSSL_ROOT}" \
    -DBUILD_NUMBER="${BUILD_NUMBER}"

cmake --build "${BUILD_DIR}" --config Release --parallel "$(sysctl -n hw.logicalcpu)"

APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
if [ ! -d "${APP_PATH}" ]; then
    echo "ERROR: ${APP_PATH} not found after build" >&2
    exit 1
fi

# ── 2. Verify architecture of the produced binary ────────────────────────────
BINARY="${APP_PATH}/Contents/MacOS/${APP_NAME}"
BUILT_ARCH=$(lipo -archs "${BINARY}" 2>/dev/null || echo "unknown")
if [[ "${BUILT_ARCH}" != *"x86_64"* ]]; then
    echo "ERROR: Produced binary does not contain an x86_64 slice." >&2
    echo "       Detected: ${BUILT_ARCH}" >&2
    exit 1
fi
echo "==> Architecture verified: ${BUILT_ARCH}"

# ── 3. Stage the DMG contents ─────────────────────────────────────────────────
echo ""
echo "==> Staging DMG contents"
cp -R "${APP_PATH}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

# ── 4. Create the DMG ─────────────────────────────────────────────────────────
mkdir -p "${DIST_DIR}"

TEMP_DMG="${DIST_DIR}/${DMG_NAME}-rw.dmg"
FINAL_DMG="${DIST_DIR}/${DMG_NAME}.dmg"

echo ""
echo "==> Creating DMG (this may take a moment)"

hdiutil create \
    -volname "${APP_NAME} ${VERSION} (Intel)" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDRW \
    "${TEMP_DMG}" \
    > /dev/null

hdiutil convert \
    "${TEMP_DMG}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${FINAL_DMG}" \
    > /dev/null

rm -f "${TEMP_DMG}"
rm -rf "${STAGING_DIR}"

# ── 5. Summary ────────────────────────────────────────────────────────────────
DMG_SIZE=$(du -sh "${FINAL_DMG}" | cut -f1)
echo ""
echo "==> Done"
echo "    ${FINAL_DMG}  (${DMG_SIZE})"
echo ""
echo "    Architecture: Intel (x86_64)"
echo "    Version     : ${VERSION}"
echo "    Build number: ${BUILD_NUMBER}"
echo ""
echo "To install: open the DMG and drag DX3270 to /Applications"
