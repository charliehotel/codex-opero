#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT_NAME="codex-opero"
APP_NAME="${PRODUCT_NAME}.app"
BUILD_DIR="${ROOT_DIR}/.build"
RELEASE_DIR="${BUILD_DIR}/release"
APP_DIR="${ROOT_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
SOURCE_PLIST="${ROOT_DIR}/Resources/Info.plist"
TARGET_PLIST="${CONTENTS_DIR}/Info.plist"
EXECUTABLE_PATH="${RELEASE_DIR}/${PRODUCT_NAME}"

echo "Building ${PRODUCT_NAME} in release mode..."
swift build -c release --product "${PRODUCT_NAME}"

if [[ ! -x "${EXECUTABLE_PATH}" ]]; then
    echo "Expected executable not found: ${EXECUTABLE_PATH}" >&2
    exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${EXECUTABLE_PATH}" "${MACOS_DIR}/${PRODUCT_NAME}"
cp "${SOURCE_PLIST}" "${TARGET_PLIST}"

chmod +x "${MACOS_DIR}/${PRODUCT_NAME}"

echo "Packaged ${APP_DIR}"
echo "Run with:"
echo "  open \"${APP_DIR}\""
