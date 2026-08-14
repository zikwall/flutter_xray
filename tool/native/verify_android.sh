#!/usr/bin/env bash

set -euo pipefail

native_tool_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=common.sh
source "$native_tool_directory/common.sh"

artifact_root=${1:-$native_output_root}
android_sdk_root=$(resolve_android_sdk)
android_ndk_root=$(resolve_android_ndk "$android_sdk_root")
llvm_objdump=$android_ndk_root/toolchains/llvm/prebuilt
llvm_objdump=$(find "$llvm_objdump" -type f -name llvm-objdump -perm -111 | head -n 1)
[[ -n "$llvm_objdump" ]] || fail "llvm-objdump was not found in $android_ndk_root"

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

check_elf() {
  local library=$1
  local load_segments

  load_segments=$("$llvm_objdump" -p "$library" | awk '/^[[:space:]]+LOAD off/')
  [[ -n "$load_segments" ]] || fail "No ELF LOAD segments found: $library"
  if printf '%s\n' "$load_segments" |
    grep -Ev 'align 2\*\*(1[4-9]|[2-9][0-9])' >/dev/null; then
    echo "ELF is not 16 KB aligned: $library" >&2
    printf '%s\n' "$load_segments" >&2
    return 1
  fi
  echo "16 KB ELF: ${library#"$artifact_root/"}"
}

checked=0
if [[ -f "$artifact_root/xray/libv2ray.aar" ]]; then
  unzip -q "$artifact_root/xray/libv2ray.aar" 'jni/*/*.so' -d "$temporary_directory/xray"
fi

while IFS= read -r -d '' library; do
  case "$library" in
  */arm64-v8a/* | */x86_64/*)
    check_elf "$library"
    checked=$((checked + 1))
    ;;
  esac
done < <(find "$artifact_root" "$temporary_directory/xray" -type f -name '*.so' -print0 2>/dev/null)

[[ $checked -gt 0 ]] || fail "No 64-bit native artifacts found under $artifact_root"
echo "Verified $checked 64-bit native artifacts."
