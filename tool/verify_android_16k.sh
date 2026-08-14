#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

find_android_tool() {
  local tool_name=$1
  local configured_tool=$2
  local sdk_root=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}

  if [[ -n "$configured_tool" && -x "$configured_tool" ]]; then
    printf '%s\n' "$configured_tool"
    return
  fi
  if command -v "$tool_name" >/dev/null 2>&1; then
    command -v "$tool_name"
    return
  fi
  if [[ -n "$sdk_root" ]]; then
    find "$sdk_root" -type f -name "$tool_name" -perm -111 2>/dev/null |
      sort |
      tail -n 1
  fi
}

llvm_objdump=$(find_android_tool llvm-objdump "${LLVM_OBJDUMP:-}")
if [[ -z "$llvm_objdump" ]]; then
  echo "llvm-objdump was not found; set LLVM_OBJDUMP or ANDROID_SDK_ROOT" >&2
  exit 2
fi

check_elf() {
  local library=$1
  local load_segments

  load_segments=$("$llvm_objdump" -p "$library" | awk '/^[[:space:]]+LOAD off/')
  if [[ -z "$load_segments" ]]; then
    echo "No ELF LOAD segments found: $library" >&2
    return 1
  fi
  if printf '%s\n' "$load_segments" |
    grep -Ev 'align 2\*\*(1[4-9]|[2-9][0-9])' >/dev/null; then
    echo "ELF is not 16 KB aligned: $library" >&2
    printf '%s\n' "$load_segments" >&2
    return 1
  fi
  echo "16 KB ELF: $library"
}

unzip -q "$repository_root/android/libs/libv2ray.aar" 'jni/*/*.so' \
  -d "$temporary_directory/aar"

checked=0
while IFS= read -r -d '' library; do
  check_elf "$library"
  checked=$((checked + 1))
done < <(
  find \
    "$repository_root/android/src/main/jniLibs/arm64-v8a" \
    "$repository_root/android/src/main/jniLibs/x86_64" \
    "$temporary_directory/aar/jni/arm64-v8a" \
    "$temporary_directory/aar/jni/x86_64" \
    -type f -name '*.so' -print0
)

if [[ $# -gt 0 ]]; then
  apk=$1
  if [[ ! -f "$apk" ]]; then
    echo "APK not found: $apk" >&2
    exit 2
  fi

  zipalign=$(find_android_tool zipalign "${ZIPALIGN:-}")
  if [[ -z "$zipalign" ]]; then
    echo "zipalign was not found; set ZIPALIGN or ANDROID_SDK_ROOT" >&2
    exit 2
  fi
  "$zipalign" -c -P 16 4 "$apk"

  unzip -q "$apk" 'lib/arm64-v8a/*.so' -d "$temporary_directory/apk"
  while IFS= read -r -d '' library; do
    check_elf "$library"
    checked=$((checked + 1))
  done < <(
    find "$temporary_directory/apk/lib/arm64-v8a" \
      -type f -name '*.so' -print0
  )
fi

echo "Verified $checked native libraries."
