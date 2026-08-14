#!/usr/bin/env bash

set -euo pipefail

native_tool_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=common.sh
source "$native_tool_directory/common.sh"

artifact_root=${1:-$native_output_root}
manifest=$artifact_root/MANIFEST.txt
runtime_root=$repository_root/android/src/main/jniLibs

[[ -f "$manifest" ]] || fail "Native manifest not found: $manifest"
grep -Fqx "hev-socks5-tunnel=$HEV_VERSION@$HEV_REVISION" "$manifest" ||
  fail "Native manifest does not match the locked HEV source"
grep -Fqx "android_ndk=$ANDROID_NDK_VERSION" "$manifest" ||
  fail "Native manifest does not match the locked Android NDK"
grep -Fqx "android_page_size=$ANDROID_PAGE_SIZE" "$manifest" ||
  fail "Native manifest does not match the locked Android page size"

"$native_tool_directory/verify_android.sh" "$artifact_root"

for abi in $ANDROID_ABIS; do
  source_library=$artifact_root/hev/$abi/libhev-socks5-tunnel.so
  [[ -f "$source_library" ]] || fail "Missing HEV runtime artifact: $source_library"
  mkdir -p "$runtime_root/$abi"
  install -m 0644 "$source_library" "$runtime_root/$abi/libhev-socks5-tunnel.so"
done

echo "Installed locked HEV runtime libraries into $runtime_root"
