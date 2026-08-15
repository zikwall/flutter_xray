#!/usr/bin/env bash

set -euo pipefail

native_tool_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=common.sh
source "$native_tool_directory/common.sh"

artifact_root=${1:-$native_output_root}
manifest=$artifact_root/MANIFEST.txt
source_aar=$artifact_root/xray/libv2ray.aar
runtime_aar=$repository_root/android/libs/libv2ray.aar

[[ -f "$manifest" ]] || fail "Native manifest not found: $manifest"
grep -Fqx "AndroidLibXrayLite=$XRAY_LITE_VERSION@$XRAY_LITE_REVISION" "$manifest" ||
  fail "Native manifest does not match the locked AndroidLibXrayLite source"
grep -Fqx "AndroidLibXrayLite-overlay=$XRAY_OVERLAY_VERSION" "$manifest" ||
  fail "Native manifest does not match the locked AndroidLibXrayLite overlay"
verify_xray_overlay_manifest "$manifest"
grep -Fqx "java=$JAVA_VERSION" "$manifest" ||
  fail "Native manifest does not match the locked Java version"
grep -Fqx "android_ndk=$ANDROID_NDK_VERSION" "$manifest" ||
  fail "Native manifest does not match the locked Android NDK"
grep -Fqx "android_page_size=$ANDROID_PAGE_SIZE" "$manifest" ||
  fail "Native manifest does not match the locked Android page size"
verify_manifest_artifact "$manifest" "$artifact_root" "$source_aar"

"$native_tool_directory/verify_android.sh" "$artifact_root"
"$native_tool_directory/verify_xray_aar.sh" "$source_aar"
install -m 0644 "$source_aar" "$runtime_aar"

echo "Installed locked Xray AAR into $runtime_aar"
