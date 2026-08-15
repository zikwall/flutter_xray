#!/usr/bin/env bash

set -euo pipefail

native_tool_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=common.sh
source "$native_tool_directory/common.sh"

component=${1:-all}
case "$component" in
all | xray | hev) ;;
*) fail "Usage: $0 [all|xray|hev]" ;;
esac

require_command find
require_command git
require_command shasum
require_command tar
require_command touch
require_command unzip
require_command zip
check_locked_inputs

if [[ -d "$native_output_root" ]]; then
  find "$native_output_root" -mindepth 1 -depth -delete
fi
mkdir -p "$native_output_root"

android_sdk_root=$(resolve_android_sdk)
android_ndk_root=$(resolve_android_ndk "$android_sdk_root")
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

toolchain_sdk_root=$temporary_directory/android-sdk
mkdir -p "$toolchain_sdk_root/platforms" "$toolchain_sdk_root/build-tools" "$toolchain_sdk_root/ndk"
[[ -d "$android_sdk_root/platforms/android-$ANDROID_COMPILE_SDK" ]] ||
  fail "Android platform $ANDROID_COMPILE_SDK is not installed in $android_sdk_root"
[[ -d "$android_sdk_root/build-tools/$ANDROID_BUILD_TOOLS" ]] ||
  fail "Android build-tools $ANDROID_BUILD_TOOLS are not installed in $android_sdk_root"
ln -s "$android_sdk_root/platforms/android-$ANDROID_COMPILE_SDK" \
  "$toolchain_sdk_root/platforms/android-$ANDROID_COMPILE_SDK"
ln -s "$android_sdk_root/build-tools/$ANDROID_BUILD_TOOLS" \
  "$toolchain_sdk_root/build-tools/$ANDROID_BUILD_TOOLS"
ln -s "$android_ndk_root" "$toolchain_sdk_root/ndk/$ANDROID_NDK_VERSION"

export ANDROID_HOME=$toolchain_sdk_root
export ANDROID_NDK_HOME=$android_ndk_root
export ANDROID_NDK_ROOT=$android_ndk_root
export ANDROID_SDK_ROOT=$toolchain_sdk_root
export SOURCE_DATE_EPOCH=0

mkdir -p "$native_output_root"

build_xray() {
  require_command go
  require_command javac
  export GOTOOLCHAIN="go$GO_VERSION"

  local actual_go_version
  actual_go_version=$(go env GOVERSION)
  [[ "$actual_go_version" == "go$GO_VERSION" ]] ||
    fail "Go version mismatch: expected go$GO_VERSION, got $actual_go_version"
  local actual_java_version
  actual_java_version=$(javac -version 2>&1 | awk '{print $2}')
  [[ "$actual_java_version" == "$JAVA_VERSION" || "$actual_java_version" == "$JAVA_VERSION".* ]] ||
    fail "Java version mismatch: expected $JAVA_VERSION, got $actual_java_version"

  local tools_directory=${NATIVE_TOOLS_ROOT:-$repository_root/native-build/tools}
  local gomobile=$tools_directory/gomobile
  local build_source=/tmp/flutter-xray-native-source/AndroidLibXrayLite
  local raw_aar=$temporary_directory/libv2ray.raw.aar
  [[ ! -L /tmp/flutter-xray-native-source && ! -L "$build_source" ]] ||
    fail "Refusing a symlinked reproducible Xray source directory"
  if [[ -d "$build_source" ]]; then
    find "$build_source" -mindepth 1 -depth -delete
  fi
  mkdir -p "$tools_directory" "$native_output_root/xray" "$build_source"

  git -C "$xray_source_directory" archive "$XRAY_LITE_REVISION" |
    tar -x -C "$build_source"
  while IFS= read -r -d '' overlay; do
    install -m 0644 "$overlay" "$build_source/$(basename "$overlay")"
  done < <(find "$xray_overlay_directory" -type f -name '*.go' -print0)

  local canonical_source=/usr/src/flutter_xray/AndroidLibXrayLite
  local prefix_map="-ffile-prefix-map=$build_source=$canonical_source"
  export CGO_CFLAGS="${CGO_CFLAGS:-} $prefix_map -fdebug-prefix-map=$build_source=$canonical_source"
  export CGO_CPPFLAGS="${CGO_CPPFLAGS:-} $prefix_map -fdebug-prefix-map=$build_source=$canonical_source"
  export CGO_CXXFLAGS="${CGO_CXXFLAGS:-} $prefix_map -fdebug-prefix-map=$build_source=$canonical_source"

  if [[ ! -x "$gomobile" ]]; then
    GOBIN=$tools_directory go install "golang.org/x/mobile/cmd/gomobile@$GOMOBILE_VERSION"
    GOBIN=$tools_directory go install "golang.org/x/mobile/cmd/gobind@$GOMOBILE_VERSION"
  fi

  (
    cd "$build_source"
    PATH="$tools_directory:$PATH" GOFLAGS=-mod=readonly "$gomobile" bind \
      -target=android \
      -androidapi "$ANDROID_API" \
      -trimpath \
      -ldflags="-s -w -buildid= -checklinkname=0 -linkmode=external \
        -extldflags=-Wl,--build-id=none,-z,max-page-size=$ANDROID_PAGE_SIZE,-z,common-page-size=$ANDROID_PAGE_SIZE" \
      -o "$raw_aar" \
      ./
  )

  local normalized_root=$temporary_directory/xray-aar
  local normalized_aar=$temporary_directory/libv2ray.normalized.aar
  mkdir -p "$normalized_root"
  unzip -q "$raw_aar" -d "$normalized_root"
  find "$normalized_root" -exec touch -t 198001010000 {} +
  (
    cd "$normalized_root"
    find . -type f | LC_ALL=C sort | zip -X -q "$normalized_aar" -@
  )
  install -m 0644 "$normalized_aar" "$native_output_root/xray/libv2ray.aar"
}

build_hev() {
  local project_directory=$temporary_directory/hev-project
  local libraries_directory=$temporary_directory/hev-libs
  local objects_directory=$temporary_directory/hev-obj
  mkdir -p "$project_directory/jni" "$native_output_root/hev"
  ln -s "$hev_source_directory" "$project_directory/jni/hev-socks5-tunnel"
  printf '%s\n' 'include $(call all-subdir-makefiles)' >"$project_directory/jni/Android.mk"

  "$android_ndk_root/ndk-build" \
    NDK_PROJECT_PATH="$project_directory" \
    APP_BUILD_SCRIPT="$project_directory/jni/Android.mk" \
    APP_MODULES=hev-socks5-tunnel \
    "APP_ABI=$ANDROID_ABIS" \
    APP_PLATFORM="android-$ANDROID_API" \
    NDK_LIBS_OUT="$libraries_directory" \
    NDK_OUT="$objects_directory" \
    "APP_CFLAGS=-O3 -ffile-prefix-map=$project_directory=/usr/src/flutter_xray \
      -fmacro-prefix-map=$project_directory=/usr/src/flutter_xray \
      -DPKGNAME=dev/zikwall/flutter_xray/tunnel -DCLSNAME=HevNative" \
    'APP_LDFLAGS=-Wl,--build-id=none -Wl,--hash-style=gnu'

  local abi
  for abi in $ANDROID_ABIS; do
    mkdir -p "$native_output_root/hev/$abi"
    cp "$libraries_directory/$abi/libhev-socks5-tunnel.so" \
      "$native_output_root/hev/$abi/libhev-socks5-tunnel.so"
  done
}

write_manifest() {
  local manifest=$native_output_root/MANIFEST.txt
  {
    echo "AndroidLibXrayLite=$XRAY_LITE_VERSION@$XRAY_LITE_REVISION"
    echo "AndroidLibXrayLite-overlay=$XRAY_OVERLAY_VERSION"
    echo "hev-socks5-tunnel=$HEV_VERSION@$HEV_REVISION"
    echo "go=$GO_VERSION"
    echo "gomobile=$GOMOBILE_VERSION"
    echo "java=$JAVA_VERSION"
    echo "android_ndk=$ANDROID_NDK_VERSION"
    echo "android_api=$ANDROID_API"
    echo "android_compile_sdk=$ANDROID_COMPILE_SDK"
    echo "android_build_tools=$ANDROID_BUILD_TOOLS"
    echo "android_page_size=$ANDROID_PAGE_SIZE"
    echo "android_abis=$ANDROID_ABIS"
    while IFS= read -r overlay; do
      printf 'overlay_sha256=%s  %s\n' \
        "$(shasum -a 256 "$overlay" | awk '{print $1}')" \
        "${overlay#"$repository_root/"}"
    done < <(find "$xray_overlay_directory" -type f -name '*.go' | sort)
    echo
    echo "SHA-256"
  } >"$manifest"

  while IFS= read -r artifact; do
    local relative_path=${artifact#"$native_output_root/"}
    printf '%s  %s\n' "$(shasum -a 256 "$artifact" | awk '{print $1}')" "$relative_path" \
      >>"$manifest"
  done < <(find "$native_output_root" -type f \( -name '*.aar' -o -name '*.so' \) | sort)
}

if [[ "$component" == all || "$component" == xray ]]; then
  build_xray
fi
if [[ "$component" == all || "$component" == hev ]]; then
  build_hev
fi

write_manifest
"$native_tool_directory/verify_android.sh" "$native_output_root"

echo "Native Android artifacts: $native_output_root"
