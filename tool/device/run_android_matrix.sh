#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
device=""
defines_file=""
backends="hev,badvpn"
background_cycle="false"

for argument in "$@"; do
  case "${argument}" in
    --device=*) device="${argument#*=}" ;;
    --defines=*) defines_file="${argument#*=}" ;;
    --backends=*) backends="${argument#*=}" ;;
    --background-cycle) background_cycle="true" ;;
    *)
      echo "Unknown argument: ${argument}" >&2
      exit 64
      ;;
  esac
done

if [[ -z "${device}" || -z "${defines_file}" ]]; then
  echo "Usage: $0 --device=<adb-id> --defines=<file.device.local.json> [--backends=hev,badvpn] [--background-cycle]" >&2
  exit 64
fi

defines_file="$(cd "$(dirname "${defines_file}")" && pwd)/$(basename "${defines_file}")"
if ! git -C "${repo_root}" check-ignore -q "${defines_file}"; then
  echo "Refusing a profile file that is not ignored by Git: ${defines_file}" >&2
  exit 1
fi

flutter_bin="${FLUTTER_BIN:-$(command -v flutter)}"
adb_bin="${ADB_BIN:-$(command -v adb)}"
package="dev.zikwall.flutter_xray.example"
result_root="${repo_root}/tool/device/results/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${result_root}"

if ! "${adb_bin}" -s "${device}" get-state | grep -qx device; then
  echo "ADB device is unavailable: ${device}" >&2
  exit 1
fi

accept_vpn_permission() {
  local test_pid="$1"
  while kill -0 "${test_pid}" 2>/dev/null; do
    if "${adb_bin}" -s "${device}" shell pm path "${package}" >/dev/null 2>&1; then
      "${adb_bin}" -s "${device}" shell appops set "${package}" ACTIVATE_VPN allow \
        >/dev/null 2>&1 || true
    fi
    if "${adb_bin}" -s "${device}" shell dumpsys window 2>/dev/null \
      | grep -q 'com.android.vpndialogs.*ConfirmDialog'; then
      "${adb_bin}" -s "${device}" shell input keyevent 22 >/dev/null 2>&1 || true
      "${adb_bin}" -s "${device}" shell input keyevent 66 >/dev/null 2>&1 || true
    fi
    sleep 0.5
  done
}

sample_device() {
  local test_pid="$1"
  local output="$2"
  while kill -0 "${test_pid}" 2>/dev/null; do
    {
      echo "sample_unix_ms=$(($(date +%s) * 1000))"
      "${adb_bin}" -s "${device}" shell top -b -n 1 2>/dev/null \
        | grep "${package}" || true
      "${adb_bin}" -s "${device}" shell dumpsys meminfo "${package}" 2>/dev/null \
        | grep -E 'TOTAL PSS:|TOTAL RSS:' || true
      "${adb_bin}" -s "${device}" shell dumpsys battery 2>/dev/null \
        | grep -E 'AC powered:|USB powered:|Charge counter:|level:|voltage:|temperature:' || true
    } >>"${output}"
    sleep 2
  done
}

exercise_background() {
  local test_pid="$1"
  for _ in $(seq 1 90); do
    kill -0 "${test_pid}" 2>/dev/null || return 0
    if "${adb_bin}" -s "${device}" shell pidof "${package}:RunSoLibV2RayDaemon" \
      >/dev/null 2>&1; then
      sleep 5
      "${adb_bin}" -s "${device}" shell input keyevent KEYCODE_HOME
      sleep 5
      "${adb_bin}" -s "${device}" shell input keyevent KEYCODE_SLEEP
      sleep 10
      "${adb_bin}" -s "${device}" shell input keyevent KEYCODE_WAKEUP
      "${adb_bin}" -s "${device}" shell wm dismiss-keyguard >/dev/null 2>&1 || true
      return 0
    fi
    sleep 1
  done
}

IFS=',' read -r -a backend_list <<<"${backends}"
overall_status=0
for backend in "${backend_list[@]}"; do
  backend="$(echo "${backend}" | tr -d '[:space:]')"
  case "${backend}" in
    hev|badvpn) ;;
    *) echo "Unsupported backend: ${backend}" >&2; exit 64 ;;
  esac

  log_file="${result_root}/${backend}.log"
  metrics_file="${result_root}/${backend}.metrics.txt"
  "${adb_bin}" -s "${device}" logcat -c || true
  (
    cd "${repo_root}/example"
    "${flutter_bin}" test integration_test/hev_device_test.dart \
      -d "${device}" \
      --dart-define-from-file="${defines_file}" \
      --dart-define="FLUTTER_XRAY_DEVICE_BACKEND=${backend}"
  ) 2>&1 | tee "${log_file}" &
  test_pid=$!
  accept_vpn_permission "${test_pid}" &
  permission_pid=$!
  sample_device "${test_pid}" "${metrics_file}" &
  sampler_pid=$!
  if [[ "${background_cycle}" == "true" ]]; then
    exercise_background "${test_pid}" &
    background_pid=$!
  else
    background_pid=""
  fi

  set +e
  wait "${test_pid}"
  status=$?
  set -e
  wait "${permission_pid}" 2>/dev/null || true
  wait "${sampler_pid}" 2>/dev/null || true
  [[ -z "${background_pid}" ]] || wait "${background_pid}" 2>/dev/null || true
  "${adb_bin}" -s "${device}" logcat -d -v threadtime \
    GoLog:V V2rayCoreManager:V V2rayVPNService:V VPN_SERVICE:V \
    HevTunnelBackend:V BadVpnTunnelBackend:V '*:S' \
    >"${result_root}/${backend}.logcat.txt" 2>&1 || true
  grep 'DEVICE_EVIDENCE' "${log_file}" >"${result_root}/${backend}.evidence.txt" || true
  if [[ "${status}" != "0" ]]; then
    overall_status="${status}"
  fi
done

echo "Device evidence: ${result_root}"
exit "${overall_status}"
