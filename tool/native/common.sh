#!/usr/bin/env bash

set -euo pipefail

native_tool_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd "$native_tool_directory/../.." && pwd)

# shellcheck source=versions.env
source "$native_tool_directory/versions.env"

native_output_root=${NATIVE_OUTPUT_ROOT:-$repository_root/native-build/android}
xray_source_directory=$repository_root/native/AndroidLibXrayLite
xray_overlay_directory=$repository_root/native/overlays/AndroidLibXrayLite
hev_source_directory=$repository_root/native/hev-socks5-tunnel

fail() {
  echo "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_revision() {
  local source_directory=$1
  local expected_revision=$2
  local label=$3
  local actual_revision

  [[ -e "$source_directory/.git" ]] ||
    fail "$label submodule is not initialized. Run: git submodule update --init --recursive"
  actual_revision=$(git -C "$source_directory" rev-parse HEAD)
  [[ "$actual_revision" == "$expected_revision" ]] ||
    fail "$label revision mismatch: expected $expected_revision, got $actual_revision"
}

resolve_android_sdk() {
  local sdk_root=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
  [[ -n "$sdk_root" ]] ||
    fail "Set ANDROID_SDK_ROOT or ANDROID_HOME to the Android SDK directory"
  [[ -d "$sdk_root" ]] || fail "Android SDK not found: $sdk_root"
  printf '%s\n' "$sdk_root"
}

resolve_android_ndk() {
  local sdk_root=$1
  local ndk_root=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-$sdk_root/ndk/$ANDROID_NDK_VERSION}}
  [[ -x "$ndk_root/ndk-build" ]] ||
    fail "Android NDK $ANDROID_NDK_VERSION not found at $ndk_root"
  printf '%s\n' "$ndk_root"
}

check_locked_inputs() {
  require_command git
  require_revision "$xray_source_directory" "$XRAY_LITE_REVISION" AndroidLibXrayLite
  [[ -f "$xray_overlay_directory/protector_android.go" ]] ||
    fail "AndroidLibXrayLite protector overlay is missing"
  require_revision "$hev_source_directory" "$HEV_REVISION" hev-socks5-tunnel
  git -C "$hev_source_directory" submodule status --recursive |
    grep -Eq '^[+-]' &&
    fail "Nested HEV submodules are missing or differ from the pinned revision"
  return 0
}

verify_xray_overlay_manifest() {
  local manifest=$1
  local overlay
  local relative_path
  local digest

  require_command shasum
  while IFS= read -r overlay; do
    relative_path=${overlay#"$repository_root/"}
    digest=$(shasum -a 256 "$overlay" | awk '{print $1}')
    grep -Fqx "overlay_sha256=$digest  $relative_path" "$manifest" ||
      fail "Native manifest does not match overlay file: $relative_path"
  done < <(find "$xray_overlay_directory" -type f -name '*.go' | sort)
}

verify_manifest_artifact() {
  local manifest=$1
  local artifact_root=$2
  local artifact=$3
  local relative_path=${artifact#"$artifact_root/"}
  local digest

  [[ -f "$artifact" ]] || fail "Native artifact is missing: $artifact"
  require_command shasum
  digest=$(shasum -a 256 "$artifact" | awk '{print $1}')
  grep -Fqx "$digest  $relative_path" "$manifest" ||
    fail "Native artifact checksum does not match MANIFEST.txt: $relative_path"
}
