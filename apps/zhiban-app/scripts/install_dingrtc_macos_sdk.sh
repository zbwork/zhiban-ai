#!/usr/bin/env bash
set -euo pipefail

SDK_VERSION="3_9_0"
SDK_DIR_NAME="DingRTC_macOS_SDK_${SDK_VERSION}"
SDK_ZIP="${SDK_DIR_NAME}.zip"
SDK_URL="https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/mac/3.9.0/${SDK_ZIP}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FRAMEWORKS_DIR="${APP_DIR}/macos/Frameworks"
VENDOR_DIR="${FRAMEWORKS_DIR}/DingRTC"

mkdir -p "${VENDOR_DIR}"
cd "${FRAMEWORKS_DIR}"

if [[ ! -f "${SDK_ZIP}" ]]; then
  echo "Downloading DingRTC macOS SDK ${SDK_VERSION}..."
  curl -fL --retry 3 --retry-delay 2 -o "${SDK_ZIP}" "${SDK_URL}"
fi

rm -rf "${SDK_DIR_NAME}"
unzip -q -o "${SDK_ZIP}"

rm -rf "${VENDOR_DIR}/DingRTC.framework" "${VENDOR_DIR}/libffmpeg.dylib" \
       "${VENDOR_DIR}/MoziWhiteboard.framework" "${VENDOR_DIR}/libhbal_se.dylib" "${VENDOR_DIR}/model"
cp -R "${SDK_DIR_NAME}/DingRTC.framework" "${VENDOR_DIR}/"
cp "${SDK_DIR_NAME}/libffmpeg.dylib" "${VENDOR_DIR}/"
# F16 v0.7 会议能力扩展: 互动白板框架 + 智能降噪 dylib/模型 (podspec 同步引用)。
cp -R "${SDK_DIR_NAME}/MoziWhiteboard.framework" "${VENDOR_DIR}/"
cp "${SDK_DIR_NAME}/libhbal_se.dylib" "${VENDOR_DIR}/"
mkdir -p "${VENDOR_DIR}/model"
cp "${SDK_DIR_NAME}/model/"*.nn "${VENDOR_DIR}/model/"

echo "Installed DingRTC SDK into ${VENDOR_DIR}"
echo "Running pod install..."
cd "${APP_DIR}/macos"
LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}" pod install
