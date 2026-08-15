#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
device=""
defines_file=""
backends="badvpn,xray,hev"
background_cycle="false"
sample_resources="true"
quick="false"
declare -a extra_defines=()

for argument in "$@"; do
  case "${argument}" in
    --help)
      echo "Usage: $0 [--device=<adb-id>] [--defines=<ignored.device.local.json>] [--backends=badvpn,xray,hev]"
      echo "          [--quick] [--cycles=N] [--profile-runs=N] [--profile=id]"
      echo "          [--hold-seconds=N] [--require-udp=true|false] [--background-cycle]"
      echo "          [--no-sampling] [--define=NAME=value]"
      exit 0
      ;;
    --device=*) device="${argument#*=}" ;;
    --defines=*) defines_file="${argument#*=}" ;;
    --backends=*) backends="${argument#*=}" ;;
    --background-cycle) background_cycle="true" ;;
    --no-sampling) sample_resources="false" ;;
    --quick) quick="true" ;;
    --cycles=*) extra_defines+=("FLUTTER_XRAY_DEVICE_CYCLES=${argument#*=}") ;;
    --profile-runs=*) extra_defines+=("FLUTTER_XRAY_DEVICE_PROFILE_RUNS=${argument#*=}") ;;
    --profile=*) extra_defines+=("FLUTTER_XRAY_DEVICE_PROFILE_FILTER=${argument#*=}") ;;
    --hold-seconds=*) extra_defines+=("FLUTTER_XRAY_DEVICE_HOLD_SECONDS=${argument#*=}") ;;
    --require-udp=*) extra_defines+=("FLUTTER_XRAY_DEVICE_REQUIRE_UDP=${argument#*=}") ;;
    --define=*) extra_defines+=("${argument#*=}") ;;
    *)
      echo "Unknown argument: ${argument}" >&2
      exit 64
      ;;
  esac
done

flutter_bin="${FLUTTER_BIN:-$(command -v flutter)}"
adb_bin="${ADB_BIN:-$(command -v adb 2>/dev/null || true)}"
if [[ -z "${adb_bin}" && -n "${ANDROID_SDK_ROOT:-}" ]]; then
  adb_bin="${ANDROID_SDK_ROOT}/platform-tools/adb"
fi
if [[ -z "${adb_bin}" && -n "${ANDROID_HOME:-}" ]]; then
  adb_bin="${ANDROID_HOME}/platform-tools/adb"
fi
if [[ ! -x "${adb_bin}" ]]; then
  echo "adb was not found; set ADB_BIN, ANDROID_SDK_ROOT or ANDROID_HOME" >&2
  exit 1
fi

if [[ -z "${device}" ]]; then
  connected_devices=$("${adb_bin}" devices | awk 'NR > 1 && $2 == "device" {print $1}')
  connected_count=$(printf '%s\n' "${connected_devices}" | sed '/^$/d' | wc -l | tr -d ' ')
  if [[ "${connected_count}" != "1" ]]; then
    echo "Expected exactly one connected adb device, found ${connected_count}; pass --device=<adb-id>" >&2
    exit 1
  fi
  device="${connected_devices}"
fi

if [[ -n "${defines_file}" ]]; then
  defines_file="$(cd "$(dirname "${defines_file}")" && pwd)/$(basename "${defines_file}")"
  if ! git -C "${repo_root}" check-ignore -q "${defines_file}"; then
    echo "Refusing a profile file that is not ignored by Git: ${defines_file}" >&2
    exit 1
  fi
elif [[ "${quick}" != "true" ]]; then
  echo "No private profile file supplied; using the credential-free direct plugin smoke." >&2
fi

if [[ "${quick}" == "true" ]]; then
  sample_resources="false"
  extra_defines+=(
    "FLUTTER_XRAY_DEVICE_CYCLES=1"
    "FLUTTER_XRAY_DEVICE_PROFILE_RUNS=1"
    "FLUTTER_XRAY_DEVICE_REQUIRE_UDP=false"
  )
fi

package="dev.zikwall.flutter_xray.example"
fgs_failure_pattern='ForegroundServiceDidNotStartInTimeException|ForegroundServiceStartNotAllowedException|CannotPostForegroundServiceNotificationException|Context.startForegroundService\(\) did not then call Service.startForeground\(\)|startForegroundService\(\) not allowed|Bad notification for startForeground|set service .* to foreground failed|Failed to promote .* service to .*foreground|Exception starting .*foreground service'
result_root="${repo_root}/tool/device/results/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${result_root}"

if ! "${adb_bin}" -s "${device}" get-state | grep -qx device; then
  echo "ADB device is unavailable: ${device}" >&2
  exit 1
fi

original_stay_awake=$("${adb_bin}" -s "${device}" shell settings get global \
  stay_on_while_plugged_in 2>/dev/null | tr -d '\r')
original_screen_timeout=$("${adb_bin}" -s "${device}" shell settings get system \
  screen_off_timeout 2>/dev/null | tr -d '\r')
restore_device_power_settings() {
  if [[ "${original_stay_awake}" =~ ^[0-9]+$ ]]; then
    "${adb_bin}" -s "${device}" shell settings put global \
      stay_on_while_plugged_in "${original_stay_awake}" >/dev/null 2>&1 || true
  fi
  if [[ "${original_screen_timeout}" =~ ^[0-9]+$ ]]; then
    "${adb_bin}" -s "${device}" shell settings put system \
      screen_off_timeout "${original_screen_timeout}" >/dev/null 2>&1 || true
  fi
}
trap restore_device_power_settings EXIT
"${adb_bin}" -s "${device}" shell svc power stayon true >/dev/null 2>&1 || true
"${adb_bin}" -s "${device}" shell settings put system screen_off_timeout 1800000 \
  >/dev/null 2>&1 || true

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
  local daemon_pid process_ids process_id
  while kill -0 "${test_pid}" 2>/dev/null; do
    daemon_pid=$("${adb_bin}" -s "${device}" shell pidof \
      "${package}:RunSoLibV2RayDaemon" 2>/dev/null | tr -d '\r' || true)
    if [[ -z "${daemon_pid}" ]]; then
      sleep 1
      continue
    fi
    {
      echo "sample_unix_ms=$(($(date +%s) * 1000))"
      process_ids=$("${adb_bin}" -s "${device}" shell pidof \
        "${package}" "${package}:RunSoLibV2RayDaemon" 2>/dev/null | tr -d '\r' || true)
      for process_id in ${process_ids}; do
        "${adb_bin}" -s "${device}" shell top -b -n 1 -p "${process_id}" 2>/dev/null \
          | awk -v expected_pid="${process_id}" \
            '$1 == expected_pid {printf "process pid=%s cpu_pct=%s res=%s name=%s\n", $1, $9, $6, $12}'
        "${adb_bin}" -s "${device}" shell dumpsys meminfo "${process_id}" 2>/dev/null \
          | awk -v expected_pid="${process_id}" \
            '/TOTAL PSS:/ {printf "memory pid=%s pss_kb=%s rss_kb=%s\n", expected_pid, $3, $6}'
      done
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

wake_device() {
  "${adb_bin}" -s "${device}" shell input keyevent KEYCODE_WAKEUP \
    >/dev/null 2>&1 || true
  "${adb_bin}" -s "${device}" shell wm dismiss-keyguard \
    >/dev/null 2>&1 || true
  if "${adb_bin}" -s "${device}" shell dumpsys window policy 2>/dev/null |
    grep -Eq '(^|[[:space:]])m?[Ii]nputRestricted=true'; then
    echo "Device is securely locked; unlock it before running device tests" >&2
    return 1
  fi
}

IFS=',' read -r -a backend_list <<<"${backends}"
overall_status=0
for backend in "${backend_list[@]}"; do
  backend="$(echo "${backend}" | tr -d '[:space:]')"
  case "${backend}" in
    hev|xray|badvpn) ;;
    *) echo "Unsupported backend: ${backend}" >&2; exit 64 ;;
  esac

  log_file="${result_root}/${backend}.log"
  metrics_file="${result_root}/${backend}.metrics.txt"
  summary_file="${result_root}/${backend}.summary.txt"
  wake_device || exit 1
  "${adb_bin}" -s "${device}" logcat -c || true
  flutter_arguments=(
    test
    integration_test/hev_device_test.dart
    -d "${device}"
  )
  if [[ -n "${defines_file}" ]]; then
    flutter_arguments+=("--dart-define-from-file=${defines_file}")
  fi
  flutter_arguments+=("--dart-define=FLUTTER_XRAY_DEVICE_BACKEND=${backend}")
  for define in "${extra_defines[@]}"; do
    flutter_arguments+=("--dart-define=${define}")
  done
  (
    cd "${repo_root}/example"
    "${flutter_bin}" "${flutter_arguments[@]}"
  ) 2>&1 | tee "${log_file}" &
  test_pid=$!
  accept_vpn_permission "${test_pid}" &
  permission_pid=$!
  if [[ "${sample_resources}" == "true" ]]; then
    sample_device "${test_pid}" "${metrics_file}" &
    sampler_pid=$!
  else
    sampler_pid=""
  fi
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
  [[ -z "${sampler_pid}" ]] || wait "${sampler_pid}" 2>/dev/null || true
  [[ -z "${background_pid}" ]] || wait "${background_pid}" 2>/dev/null || true
  full_logcat="${result_root}/${backend}.logcat.full.tmp"
  logcat_capture_failures=0
  if ! "${adb_bin}" -s "${device}" logcat -d -v threadtime \
      >"${full_logcat}" 2>&1; then
    logcat_capture_failures=1
  fi
  grep -E \
    "${package}|GoLog|V2rayCoreManager|V2rayVPNService|VPN_SERVICE|HevTunnelBackend|BadVpnTunnelBackend|XrayTunBackend|${fgs_failure_pattern}" \
    "${full_logcat}" >"${result_root}/${backend}.logcat.txt" || true
  foreground_service_failures=$(grep -Ec "${fgs_failure_pattern}" \
    "${full_logcat}" || true)
  daemon_crashes=$(grep -c \
    "Process: ${package}:RunSoLibV2RayDaemon" "${full_logcat}" || true)
  rm -f "${full_logcat}"
  if [[ "${foreground_service_failures}" != "0" || "${daemon_crashes}" != "0" \
      || "${logcat_capture_failures}" != "0" ]]; then
    status=1
  fi
  grep 'DEVICE_EVIDENCE' "${log_file}" >"${result_root}/${backend}.evidence.txt" || true
  if [[ -f "${metrics_file}" ]]; then
    cpu_mean_pct=$(awk '
      /^sample_unix_ms=/ {split($0,a,"="); current=a[2]; seen[current]=1}
      /^process / {for(i=1;i<=NF;i++) if($i ~ /^cpu_pct=/){split($i,a,"="); cpu[current]+=a[2]}}
      END {for(s in seen){sum+=cpu[s]; n++} if(n) printf "%.2f",sum/n; else print "n/a"}
    ' "${metrics_file}")
    pss_mean_kb=$(awk '
      /^sample_unix_ms=/ {split($0,a,"="); current=a[2]; seen[current]=1}
      /^memory / {for(i=1;i<=NF;i++) if($i ~ /^pss_kb=/){split($i,a,"="); pss[current]+=a[2]}}
      END {for(s in seen){sum+=pss[s]; n++} if(n) printf "%.0f",sum/n; else print "n/a"}
    ' "${metrics_file}")
    rss_mean_kb=$(awk '
      /^sample_unix_ms=/ {split($0,a,"="); current=a[2]; seen[current]=1}
      /^memory / {for(i=1;i<=NF;i++) if($i ~ /^rss_kb=/){split($i,a,"="); rss[current]+=a[2]}}
      END {for(s in seen){sum+=rss[s]; n++} if(n) printf "%.0f",sum/n; else print "n/a"}
    ' "${metrics_file}")
    charge_delta_uah=$(awk '
      /Charge counter:/ {if(!seen){first=$3; seen=1} last=$3}
      END {if(seen) print last-first; else print "n/a"}
    ' "${metrics_file}")
  else
    cpu_mean_pct="n/a"
    pss_mean_kb="n/a"
    rss_mean_kb="n/a"
    charge_delta_uah="n/a"
  fi
  {
    echo "backend=${backend}"
    echo "exit_code=${status}"
    echo "core=$(grep 'DEVICE_EVIDENCE CORE version=' "${log_file}" | tail -n 1 | sed 's/^.*version=//')"
    echo "profiles_passed=$(grep -c 'PROFILE .*passed=true' "${log_file}" || true)"
    echo "profiles_failed=$(grep -c 'PROFILE .*passed=false' "${log_file}" || true)"
    echo "reconnects_passed=$(grep -c 'RECONNECT .*passed=true' "${log_file}" || true)"
    echo "ipv4_tcp_passed=$(grep -c 'IPV4_TCP .*bytes=' "${log_file}" || true)"
    echo "ipv6_tcp_passed=$(grep -c 'IPV6_TCP .*bytes=' "${log_file}" || true)"
    echo "udp_probes_passed=$(grep -Ec 'UDP_(DNS|ECHO) .*latency_ms=' "${log_file}" || true)"
    echo "dns_tunnel_passed=$(grep -c 'DNS_TUNNEL .*latency_ms=' "${log_file}" || true)"
    echo "dns_source_passed=$(grep -c 'DNS_SOURCE .*matches_tunnel=true' "${log_file}" || true)"
    echo "blocked_apps_passed=$(grep -c 'BLOCKED_APPS passed=true' "${log_file}" || true)"
    echo "throughput_samples=$(grep -c 'THROUGHPUT .*mbps=' "${log_file}" || true)"
    echo "throughput_mean_mbps=$(awk '/DEVICE_EVIDENCE THROUGHPUT/ {for (i=1;i<=NF;i++) if ($i ~ /^mbps=/) {split($i,a,"="); sum+=a[2]; n++}} END {if (n) printf "%.2f", sum/n; else print "n/a"}' "${log_file}")"
    echo "foreground_service_failures=${foreground_service_failures}"
    echo "daemon_crashes=${daemon_crashes}"
    echo "logcat_capture_failures=${logcat_capture_failures}"
    echo "cpu_mean_pct=${cpu_mean_pct}"
    echo "pss_mean_kb=${pss_mean_kb}"
    echo "rss_mean_kb=${rss_mean_kb}"
    echo "charge_delta_uah=${charge_delta_uah}"
  } >"${summary_file}"
  cat "${summary_file}"
  if [[ "${status}" != "0" ]]; then
    overall_status="${status}"
  fi
done

comparison_file="${result_root}/comparison.tsv"
{
  printf 'backend\texit_code\tprofiles_passed\treconnects_passed\tipv4_tcp\tipv6_tcp\tudp\tdns_tunnel\tdns_source\tblocked_apps\tthroughput_mean_mbps\tcpu_mean_pct\tpss_mean_kb\trss_mean_kb\tcharge_delta_uah\tfgs_failures\tdaemon_crashes\tlogcat_failures\n'
  for backend in "${backend_list[@]}"; do
    backend="$(echo "${backend}" | tr -d '[:space:]')"
    summary_file="${result_root}/${backend}.summary.txt"
    value() { sed -n "s/^$1=//p" "${summary_file}" | tail -n 1; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${backend}" "$(value exit_code)" "$(value profiles_passed)" \
      "$(value reconnects_passed)" "$(value ipv4_tcp_passed)" \
      "$(value ipv6_tcp_passed)" "$(value udp_probes_passed)" \
      "$(value dns_tunnel_passed)" "$(value dns_source_passed)" \
      "$(value blocked_apps_passed)" "$(value throughput_mean_mbps)" \
      "$(value cpu_mean_pct)" "$(value pss_mean_kb)" \
      "$(value rss_mean_kb)" "$(value charge_delta_uah)" \
      "$(value foreground_service_failures)" "$(value daemon_crashes)" \
      "$(value logcat_capture_failures)"
  done
} >"${comparison_file}"
cat "${comparison_file}"

echo "Device evidence: ${result_root}"
exit "${overall_status}"
