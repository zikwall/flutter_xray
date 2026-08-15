#!/usr/bin/env bash

set -euo pipefail

native_tool_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=common.sh
source "$native_tool_directory/common.sh"

aar=${1:-$native_output_root/xray/libv2ray.aar}
[[ -f "$aar" ]] || fail "Xray AAR not found: $aar"

require_command jar
require_command javap
require_command unzip

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
aar_inventory=$temporary_directory/aar.txt
unzip -Z1 "$aar" >"$aar_inventory"
unzip -q "$aar" classes.jar -d "$temporary_directory"

class_inventory=$temporary_directory/classes.txt
jar tf "$temporary_directory/classes.jar" >"$class_inventory"
grep -Fqx 'libv2ray/V2RayProtector.class' "$class_inventory" ||
  fail "Generated AAR does not expose V2RayProtector"
grep -Fqx 'libv2ray/CoreController.class' "$class_inventory" ||
  fail "Generated AAR does not expose CoreController"

libv2ray_api=$temporary_directory/libv2ray-api.txt
controller_api=$temporary_directory/controller-api.txt
javap -classpath "$temporary_directory/classes.jar" libv2ray.Libv2ray >"$libv2ray_api"
javap -classpath "$temporary_directory/classes.jar" libv2ray.CoreController >"$controller_api"
grep -Fq 'useProtector(libv2ray.V2RayProtector)' "$libv2ray_api" ||
  fail "Generated AAR is missing useProtector(V2RayProtector)"
grep -Fq 'startLoop(java.lang.String' "$controller_api" ||
  fail "Generated AAR is missing CoreController.startLoop(String, tunFd)"

for abi in $ANDROID_ABIS; do
  grep -Eq "^jni/$abi/[^/]+[.]so$" "$aar_inventory" ||
    fail "Generated AAR is missing a native library for $abi"
done

echo "Verified Xray AAR API and ABI contract: $aar"
