#!/usr/bin/env bash
# package_all.sh — Build Apple Silicon (AppKit), Intel (AppKit), and Qt DMGs in one deployment step.
#
# Usage:
#   ./package_all.sh               # uses BUILD_NUMBER=1 (default)
#   BUILD_NUMBER=42 ./package_all.sh
#
# Output (all in dist/):
#   DX3270-<version>-build<BUILD_NUMBER>.dmg          ← Apple Silicon (AppKit)
#   DX3270-<version>-build<BUILD_NUMBER>-Intel.dmg    ← Intel (AppKit)
#   DX3270-Qt-<version>-build<BUILD_NUMBER>.dmg       ← Apple Silicon (Qt6)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export BUILD_NUMBER="${BUILD_NUMBER:-1}"

echo "======================================================"
echo "  DX3270 — Full Deployment Build (build ${BUILD_NUMBER})"
echo "======================================================"
echo ""

# Track DMGs produced so we can print a clean summary at the end.
BEFORE_DMGS=()
if [ -d "${SCRIPT_DIR}/dist" ]; then
    while IFS= read -r -d '' f; do
        BEFORE_DMGS+=("$f")
    done < <(find "${SCRIPT_DIR}/dist" -name "*.dmg" -print0 2>/dev/null)
fi

# ── [1/3] Apple Silicon (arm64 - AppKit) ──────────────────────────────────────
echo "------------------------------------------------------"
echo "  [1/3] Apple Silicon Native (arm64)"
echo "------------------------------------------------------"
"${SCRIPT_DIR}/package.sh"
echo ""

# ── [2/3] Intel (x86_64 - AppKit) ─────────────────────────────────────────────
echo "------------------------------------------------------"
echo "  [2/3] Intel Native (x86_64)"
echo "------------------------------------------------------"
"${SCRIPT_DIR}/package_intel.sh"
echo ""

# ── [3/3] Apple Silicon (arm64 - Qt6) ─────────────────────────────────────────
echo "------------------------------------------------------"
echo "  [3/3] Cross-Platform Build (Qt6)"
echo "------------------------------------------------------"
"${SCRIPT_DIR}/package_qt.sh"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "======================================================"
echo "  Deliverables"
echo "======================================================"

NEW_DMGS=()
while IFS= read -r -d '' f; do
    already_existed=false
    for existing in "${BEFORE_DMGS[@]+"${BEFORE_DMGS[@]}"}"; do
        if [ "${existing}" = "${f}" ]; then
            already_existed=true
            break
        fi
    done
    if ! "${already_existed}"; then
        NEW_DMGS+=("$f")
    fi
done < <(find "${SCRIPT_DIR}/dist" -name "*.dmg" -print0 2>/dev/null)

if [ "${#NEW_DMGS[@]}" -eq 0 ]; then
    while IFS= read -r -d '' f; do
        NEW_DMGS+=("$f")
    done < <(find "${SCRIPT_DIR}/dist" -name "*.dmg" -print0 2>/dev/null)
fi

for dmg in $(printf '%s\n' "${NEW_DMGS[@]}" | sort); do
    SIZE=$(du -sh "${dmg}" | cut -f1)
    printf "  %s  %s\n" "${SIZE}" "$(basename "${dmg}")"
done

echo ""
echo "All DMGs are ready for distribution."
echo "  • DX3270 DMG         → Native AppKit for M-series Macs"
echo "  • DX3270-Intel DMG   → Native AppKit for older Intel Macs"
echo "  • DX3270-Qt DMG      → Multi-platform core (Qt6 Edition)"