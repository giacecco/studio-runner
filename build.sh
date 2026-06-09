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

# Kill any running instance before rebuilding — the bundle is wiped and
# reassembled below, and a live process holding open the old binary
# causes flaky launches afterwards.
if pgrep -x "${APP_NAME}" >/dev/null; then
    echo "==> stopping running ${APP_NAME}"
    pkill -x "${APP_NAME}" || true
    # Wait briefly for clean exit, then force if still alive.
    for _ in 1 2 3 4 5; do
        pgrep -x "${APP_NAME}" >/dev/null || break
        sleep 0.2
    done
    if pgrep -x "${APP_NAME}" >/dev/null; then
        pkill -9 -x "${APP_NAME}" || true
    fi
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
# Stage the bundle in a temp directory and rsync it into place rather than
# rm -rf'ing OUT_DIR. The Dock stores pinned launchers as bookmarks that
# include the bundle directory's inode, so wiping and recreating OUT_DIR
# can make a pinned Dock icon go stale; rsync --delete updates the
# contents while preserving the outer directory's inode.
STAGING_PARENT=$(mktemp -d -t studiorunner-build)
trap 'rm -rf "${STAGING_PARENT}"' EXIT
STAGING="${STAGING_PARENT}/${APP_BUNDLE}"

echo "==> assembling ${OUT_DIR}"
mkdir -p "${STAGING}/Contents/MacOS"
mkdir -p "${STAGING}/Contents/Resources"

cp "${BIN_PATH}" "${STAGING}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${STAGING}/Contents/Info.plist"
if [[ -f Resources/StudioRunner.icns ]]; then
    cp Resources/StudioRunner.icns "${STAGING}/Contents/Resources/"
fi
if [[ -f Resources/StudioRunnerDoc.icns ]]; then
    cp Resources/StudioRunnerDoc.icns "${STAGING}/Contents/Resources/"
fi

# macOS attaches com.apple.provenance xattrs to freshly written files —
# codesign refuses to sign anything that carries Finder-info detritus.
xattr -cr "${STAGING}"
if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "==> codesign with '${SIGN_IDENTITY}'"
    codesign --force --deep --options runtime \
        --sign "${SIGN_IDENTITY}" \
        --entitlements Resources/StudioRunner.entitlements \
        "${STAGING}" 2>&1 | sed 's/^/    /'
else
    echo "==> ad-hoc codesign (set STUDIO_SIGN_IDENTITY for stable TCC identity)"
    codesign --force --deep --sign - \
        --entitlements Resources/StudioRunner.entitlements \
        "${STAGING}" 2>&1 | sed 's/^/    /'
fi

mkdir -p "${OUT_DIR}"
rsync -a --delete "${STAGING}/" "${OUT_DIR}/"

# Mirror the bundle into /Applications so Spotlight and Launchpad pick it
# up. A symlink there is silently ignored by the Spotlight indexer, so
# replace any pre-existing symlink with a real directory before rsyncing.
# Set STUDIO_SKIP_APPLICATIONS=1 to opt out.
INSTALL_DIR=${STUDIO_INSTALL_DIR:-/Applications}
INSTALLED="${INSTALL_DIR}/${APP_BUNDLE}"
if [[ "${STUDIO_SKIP_APPLICATIONS:-}" != "1" ]] && [[ -w "${INSTALL_DIR}" ]]; then
    if [[ -L "${INSTALLED}" ]]; then
        echo "==> removing symlink ${INSTALLED}"
        rm "${INSTALLED}"
    fi
    echo "==> installing to ${INSTALLED}"
    mkdir -p "${INSTALLED}"
    rsync -a --delete "${STAGING}/" "${INSTALLED}/"
    # Nudge Spotlight to reindex the freshly written bundle.
    mdimport "${INSTALLED}" >/dev/null 2>&1 || true
elif [[ "${STUDIO_SKIP_APPLICATIONS:-}" != "1" ]]; then
    echo "==> skipping install to ${INSTALL_DIR} (not writable)"
fi

echo "==> done: ${OUT_DIR}"
echo "    run:  open ${OUT_DIR}"
echo "    tail: log stream --predicate 'process == \"StudioRunner\"' --style compact"
