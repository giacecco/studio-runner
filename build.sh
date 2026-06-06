#!/usr/bin/env bash
# Build StudioRunner.app from the SwiftPM target.
#
# Usage:
#   ./build.sh                                                    # ad-hoc signature
#   STUDIO_SIGN_IDENTITY="Developer ID Application: <Name>" ./build.sh
#   CONFIG=debug ./build.sh                                       # debug build
#
# A Developer ID signature gives the bundle a stable code identity, so
# macOS Privacy & Security remembers granted permissions across rebuilds.
# Without it (ad-hoc fallback) the OS re-prompts for Microphone / Screen
# Recording every time the binary's hash changes.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${CONFIG:-release}
APP_NAME="StudioRunner"
APP_BUNDLE="${APP_NAME}.app"

# Prefer an explicit override, then auto-detect the first Developer ID Application cert.
if [[ -n "${STUDIO_SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="${STUDIO_SIGN_IDENTITY}"
else
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"') || true
fi

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_DIR=$(swift build -c "${CONFIG}" --show-bin-path)
BIN_PATH="${BIN_DIR}/${APP_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "error: expected binary at ${BIN_PATH}" >&2
    exit 1
fi

OUT_DIR=".build/${APP_BUNDLE}"
echo "==> assembling ${OUT_DIR}"
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}/Contents/MacOS"
mkdir -p "${OUT_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${OUT_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${OUT_DIR}/Contents/Info.plist"
if [[ -f Resources/StudioRunner.icns ]]; then
    cp Resources/StudioRunner.icns "${OUT_DIR}/Contents/Resources/"
fi

if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "==> codesign with '${SIGN_IDENTITY}'"
    codesign --force --deep --options runtime \
        --sign "${SIGN_IDENTITY}" \
        --entitlements Resources/StudioRunner.entitlements \
        "${OUT_DIR}" 2>&1 | sed 's/^/    /'
else
    echo "==> ad-hoc codesign (set STUDIO_SIGN_IDENTITY for stable TCC identity)"
    codesign --force --deep --sign - \
        --entitlements Resources/StudioRunner.entitlements \
        "${OUT_DIR}" 2>&1 | sed 's/^/    /'
fi

echo "==> done: ${OUT_DIR}"
echo "    run:  open ${OUT_DIR}"
echo "    tail: log stream --predicate 'process == \"StudioRunner\"' --style compact"
