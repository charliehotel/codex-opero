#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="${ROOT_DIR}/Resources/Info.plist"
PRODUCT_NAME="codex-opero"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
TAG="v${VERSION}"
DMG_PATH="${ROOT_DIR}/dist/${PRODUCT_NAME}.dmg"
NOTES_PATH="${ROOT_DIR}/ReleaseNotes/${TAG}.md"

"${ROOT_DIR}/Scripts/package_app.sh"

if gh release view "${TAG}" >/dev/null 2>&1; then
    gh release upload "${TAG}" "${DMG_PATH}" --clobber
else
    if [[ -f "${NOTES_PATH}" ]]; then
        gh release create "${TAG}" "${DMG_PATH}" \
            --target main \
            --title "${TAG}" \
            --notes-file "${NOTES_PATH}"
    else
        gh release create "${TAG}" "${DMG_PATH}" \
            --target main \
            --title "${TAG}" \
            --notes "Release ${TAG} of ${PRODUCT_NAME}."
    fi
fi

echo "Published ${DMG_PATH} to GitHub Release ${TAG}"
