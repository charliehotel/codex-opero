#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT_NAME="codex-opero"
APP_NAME="${PRODUCT_NAME}.app"
BUILD_DIR="${ROOT_DIR}/.build"
RELEASE_DIR="${BUILD_DIR}/release"
APP_DIR="${ROOT_DIR}/${APP_NAME}"
DIST_DIR="${ROOT_DIR}/dist"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
SOURCE_PLIST="${ROOT_DIR}/Resources/Info.plist"
TARGET_PLIST="${CONTENTS_DIR}/Info.plist"
EXECUTABLE_PATH="${RELEASE_DIR}/${PRODUCT_NAME}"
ICON_SOURCE="${ROOT_DIR}/icon.png"
TRAY_ICON_SOURCES=("${ROOT_DIR}"/Resources/TrayIcon-*.png)
ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"
ICON_FILE="${RESOURCES_DIR}/AppIcon.icns"
STAGING_DIR="${BUILD_DIR}/dmg-staging"
DMG_PATH="${DIST_DIR}/${PRODUCT_NAME}.dmg"
APP_ARCHIVE_PATH="${DIST_DIR}/${APP_NAME}"

create_iconset() {
    rm -rf "${ICONSET_DIR}"
    mkdir -p "${ICONSET_DIR}"

    sips -z 16 16 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
    sips -z 32 32 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
    sips -z 64 64 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
    sips -z 256 256 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
    sips -z 512 512 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null
}

build_app_bundle() {
    echo "Building ${PRODUCT_NAME} in release mode..."
    swift build -c release --product "${PRODUCT_NAME}"

    if [[ ! -x "${EXECUTABLE_PATH}" ]]; then
        echo "Expected executable not found: ${EXECUTABLE_PATH}" >&2
        exit 1
    fi

    if [[ ! -f "${ICON_SOURCE}" ]]; then
        echo "Expected icon not found: ${ICON_SOURCE}" >&2
        exit 1
    fi

    create_iconset

    rm -rf "${APP_DIR}"
    mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

    cp "${EXECUTABLE_PATH}" "${MACOS_DIR}/${PRODUCT_NAME}"
    cp "${SOURCE_PLIST}" "${TARGET_PLIST}"
    iconutil -c icns "${ICONSET_DIR}" -o "${ICON_FILE}"
    for tray_icon in "${TRAY_ICON_SOURCES[@]}"; do
        if [[ -f "${tray_icon}" ]]; then
            cp "${tray_icon}" "${RESOURCES_DIR}/"
        fi
    done

    chmod +x "${MACOS_DIR}/${PRODUCT_NAME}"
}

build_dmg() {
    mkdir -p "${DIST_DIR}"
    find "${DIST_DIR}" -name ".DS_Store" -delete 2>/dev/null || true
    rm -rf "${APP_ARCHIVE_PATH}"
    rm -rf "${STAGING_DIR}"
    mkdir -p "${STAGING_DIR}"

    cp -R "${APP_DIR}" "${APP_ARCHIVE_PATH}"
    cp -R "${APP_DIR}" "${STAGING_DIR}/${APP_NAME}"
    ln -s /Applications "${STAGING_DIR}/Applications"

    rm -f "${DMG_PATH}"
    hdiutil create \
        -volname "${PRODUCT_NAME}" \
        -srcfolder "${STAGING_DIR}" \
        -ov \
        -format UDZO \
        "${DMG_PATH}" >/dev/null

    find "${DIST_DIR}" -name ".DS_Store" -delete 2>/dev/null || true
}

build_app_bundle
build_dmg

echo "Packaged ${APP_DIR}"
echo "Copied app to ${APP_ARCHIVE_PATH}"
echo "Created DMG at ${DMG_PATH}"
echo "Run with:"
echo "  open \"${APP_DIR}\""
