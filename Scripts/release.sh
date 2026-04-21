#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="${ROOT_DIR}/Resources/Info.plist"
PRODUCT_NAME="codex-opero"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
TAG="v${VERSION}"
DMG_PATH="${ROOT_DIR}/dist/${PRODUCT_NAME}.dmg"

"${ROOT_DIR}/Scripts/package_app.sh"

if gh release view "${TAG}" >/dev/null 2>&1; then
    gh release upload "${TAG}" "${DMG_PATH}" --clobber
else
    gh release create "${TAG}" "${DMG_PATH}" \
        --target main \
        --title "${TAG}" \
        --notes "Release ${TAG} of ${PRODUCT_NAME}."
fi

echo "Published ${DMG_PATH} to GitHub Release ${TAG}"
