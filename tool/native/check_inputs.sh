#!/usr/bin/env bash

set -euo pipefail

native_tool_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=common.sh
source "$native_tool_directory/common.sh"

check_locked_inputs

echo "AndroidLibXrayLite $XRAY_LITE_VERSION ($XRAY_LITE_REVISION)"
echo "hev-socks5-tunnel $HEV_VERSION ($HEV_REVISION)"
echo "Go $GO_VERSION / gomobile $GOMOBILE_VERSION"
echo "Java $JAVA_VERSION"
echo "Android NDK $ANDROID_NDK_VERSION / API $ANDROID_API / compile SDK $ANDROID_COMPILE_SDK"
