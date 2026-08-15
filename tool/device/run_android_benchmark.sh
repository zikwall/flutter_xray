#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package="dev.zikwall.flutter_xray.example"
probe_package="dev.zikwall.flutter_xray.benchmark_probe"
probe_activity="${probe_package}/.BenchmarkProbeActivity"
device=""
defines_file=""
profile_filter=""
benchmark_url=""
egress_url="https://api.ipify.org"
expected_egress=""
rounds=6
warmup_seconds=5
measure_seconds=30
cooldown_seconds=5
concurrency=1
sample_interval_seconds=2
build_mode="profile"
require_unplugged="false"

usage() {
  echo "Usage: $0 --url=<fixed-dev-payload-url> [options]"
  echo "  --expected-egress=<dev-egress-ip> [--egress-url=https://api.ipify.org]"
  echo "  --device=<adb-id> --defines=<ignored.device.local.json> --profile=<id>"
  echo "  --rounds=6 --warmup-seconds=5 --measure-seconds=30 --cooldown-seconds=5"
  echo "  --concurrency=1 --sample-interval-seconds=2 --mode=profile|release"
  echo "  --require-unplugged --quick"
}

for argument in "$@"; do
  case "${argument}" in
    --help) usage; exit 0 ;;
    --device=*) device="${argument#*=}" ;;
    --defines=*) defines_file="${argument#*=}" ;;
    --profile=*) profile_filter="${argument#*=}" ;;
    --url=*) benchmark_url="${argument#*=}" ;;
    --egress-url=*) egress_url="${argument#*=}" ;;
    --expected-egress=*) expected_egress="${argument#*=}" ;;
    --rounds=*) rounds="${argument#*=}" ;;
    --warmup-seconds=*) warmup_seconds="${argument#*=}" ;;
    --measure-seconds=*) measure_seconds="${argument#*=}" ;;
    --cooldown-seconds=*) cooldown_seconds="${argument#*=}" ;;
    --concurrency=*) concurrency="${argument#*=}" ;;
    --sample-interval-seconds=*) sample_interval_seconds="${argument#*=}" ;;
    --mode=*) build_mode="${argument#*=}" ;;
    --require-unplugged) require_unplugged="true" ;;
    --quick)
      rounds=1
      warmup_seconds=1
      measure_seconds=5
      cooldown_seconds=1
      sample_interval_seconds=1
      ;;
    *) echo "Unknown argument: ${argument}" >&2; usage >&2; exit 64 ;;
  esac
done

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

if [[ ! "${benchmark_url}" =~ ^https?:// ]]; then
  echo "An explicit HTTP(S) benchmark URL is required; there is no public default" >&2
  exit 64
fi
if [[ ! "${egress_url}" =~ ^https?:// ]] || [[ -z "${expected_egress}" ]] ||
    [[ ! "${expected_egress}" =~ ^[a-zA-Z0-9.:_-]+$ ]]; then
  echo "An explicit safe expected egress and HTTP(S) egress URL are required" >&2
  exit 64
fi
for value in "${rounds}" "${warmup_seconds}" "${measure_seconds}" "${concurrency}"; do
  is_positive_integer "${value}" || { echo "Expected a positive integer: ${value}" >&2; exit 64; }
done
if [[ ! "${cooldown_seconds}" =~ ^[0-9]+$ ]] ||
    [[ ! "${sample_interval_seconds}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Cooldown must be non-negative and sample interval must be positive" >&2
  exit 64
fi
if (( concurrency > 16 || measure_seconds < 5 )); then
  echo "Concurrency must not exceed 16 and measurement must be at least 5 seconds" >&2
  exit 64
fi
case "${build_mode}" in
  profile|release) ;;
  *) echo "Build mode must be profile or release" >&2; exit 64 ;;
esac
if (( rounds % 6 != 0 )); then
  echo "Warning: only multiples of six use the complete position-balanced design" >&2
fi

flutter_bin="${FLUTTER_BIN:-$(command -v flutter)}"
dart_bin="${DART_BIN:-$(command -v dart)}"
adb_bin="${ADB_BIN:-$(command -v adb 2>/dev/null || true)}"
if ! java -version >/dev/null 2>&1; then
  bundled_jdk="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  if [[ -x "${bundled_jdk}/bin/java" ]]; then
    export JAVA_HOME="${bundled_jdk}"
    export PATH="${JAVA_HOME}/bin:${PATH}"
  else
    echo "A working Java runtime is required to build the benchmark probe" >&2
    exit 1
  fi
fi
if [[ -z "${adb_bin}" && -n "${ANDROID_SDK_ROOT:-}" ]]; then
  adb_bin="${ANDROID_SDK_ROOT}/platform-tools/adb"
fi
if [[ -z "${adb_bin}" && -n "${ANDROID_HOME:-}" ]]; then
  adb_bin="${ANDROID_HOME}/platform-tools/adb"
fi
if [[ -z "${adb_bin}" ]]; then
  adb_bin="/Users/andreykapitonov/Library/Android/sdk/platform-tools/adb"
fi
if [[ ! -x "${adb_bin}" ]]; then
  echo "adb was not found; set ADB_BIN, ANDROID_SDK_ROOT or ANDROID_HOME" >&2
  exit 1
fi

if [[ -z "${device}" ]]; then
  connected_devices=$("${adb_bin}" devices | awk 'NR > 1 && $2 == "device" {print $1}')
  connected_count=$(printf '%s\n' "${connected_devices}" | sed '/^$/d' | wc -l | tr -d ' ')
  if [[ "${connected_count}" != "1" ]]; then
    echo "Expected exactly one connected adb device, found ${connected_count}" >&2
    exit 1
  fi
  device="${connected_devices}"
fi
"${adb_bin}" -s "${device}" get-state | grep -qx device || {
  echo "ADB device is unavailable: ${device}" >&2
  exit 1
}

if [[ -n "${defines_file}" ]]; then
  defines_file="$(cd "$(dirname "${defines_file}")" && pwd)/$(basename "${defines_file}")"
  git -C "${repo_root}" check-ignore -q "${defines_file}" || {
    echo "Refusing a profile file that is not ignored by Git: ${defines_file}" >&2
    exit 1
  }
  if [[ -z "${profile_filter}" ]]; then
    echo "--profile=<id> is required with a private profile set" >&2
    exit 64
  fi
elif [[ -n "${profile_filter}" ]]; then
  echo "--profile requires --defines" >&2
  exit 64
fi

design=(
  "badvpn,xray,hev"
  "xray,hev,badvpn"
  "hev,badvpn,xray"
  "hev,xray,badvpn"
  "xray,badvpn,hev"
  "badvpn,hev,xray"
)
schedule=""
for ((round = 0; round < rounds; round += 1)); do
  [[ -z "${schedule}" ]] || schedule+=","
  schedule+="${design[$((round % ${#design[@]}))]}"
done

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_root="${repo_root}/tool/device/results/benchmark-${timestamp}"
mkdir -p "${result_root}"
drive_log="${result_root}/drive.log"
logcat_file="${result_root}/logcat.full.txt"
metrics_file="${result_root}/metrics.tsv"
environment_file="${result_root}/environment.txt"
sampler_log="${result_root}/sampler.log"
touch "${drive_log}" "${logcat_file}"
printf '%s\n' \
  $'record_type\tphase_id\tsample_ms\tuid\tpid\tppid\tstart_ticks\tcpu_ticks\tname\tpss_kb\trss_kb\tthermal_status\tbattery_temp_deci_c\tcharge_uah\twifi_rssi' \
  >"${metrics_file}"

original_stay_awake=$("${adb_bin}" -s "${device}" shell settings get global \
  stay_on_while_plugged_in 2>/dev/null | tr -d '\r')
original_screen_timeout=$("${adb_bin}" -s "${device}" shell settings get system \
  screen_off_timeout 2>/dev/null | tr -d '\r')
logcat_pid=""
sampler_pid=""
permission_pid=""
probe_launcher_pid=""
drive_pid=""
probe_installed="false"

cleanup() {
  local pid
  for pid in "${drive_pid}" "${permission_pid}" "${probe_launcher_pid}" "${sampler_pid}" "${logcat_pid}"; do
    if [[ -n "${pid}" ]]; then
      kill "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" >/dev/null 2>&1 || true
    fi
  done
  "${adb_bin}" -s "${device}" shell am force-stop "${package}" \
    >/dev/null 2>&1 || true
  if [[ "${probe_installed}" == "true" ]]; then
    "${adb_bin}" -s "${device}" shell am force-stop "${probe_package}" \
      >/dev/null 2>&1 || true
    "${adb_bin}" -s "${device}" uninstall "${probe_package}" \
      >/dev/null 2>&1 || true
  fi
  if [[ "${original_stay_awake}" =~ ^[0-9]+$ ]]; then
    "${adb_bin}" -s "${device}" shell settings put global \
      stay_on_while_plugged_in "${original_stay_awake}" >/dev/null 2>&1 || true
  fi
  if [[ "${original_screen_timeout}" =~ ^[0-9]+$ ]]; then
    "${adb_bin}" -s "${device}" shell settings put system \
      screen_off_timeout "${original_screen_timeout}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"${adb_bin}" -s "${device}" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
"${adb_bin}" -s "${device}" shell wm dismiss-keyguard >/dev/null 2>&1 || true
if "${adb_bin}" -s "${device}" shell dumpsys window policy 2>/dev/null |
  grep -Eq '(^|[[:space:]])m?[Ii]nputRestricted=true'; then
  echo "Device is securely locked; unlock it before running the benchmark" >&2
  exit 1
fi
"${adb_bin}" -s "${device}" shell svc power stayon true >/dev/null 2>&1 || true
"${adb_bin}" -s "${device}" shell settings put system screen_off_timeout 1800000 \
  >/dev/null 2>&1 || true

powered=$("${adb_bin}" -s "${device}" shell dumpsys battery 2>/dev/null |
  awk '/AC powered:|USB powered:|Wireless powered:/ && $3 == "true" {powered=1} END {print powered+0}')
if [[ "${require_unplugged}" == "true" && "${powered}" != "0" ]]; then
  echo "Battery benchmark requires a device with no reported external power" >&2
  exit 1
fi

clock_ticks=$("${adb_bin}" -s "${device}" shell getconf CLK_TCK 2>/dev/null | tr -d '\r')
is_positive_integer "${clock_ticks}" || {
  echo "Could not read Android CLK_TCK" >&2
  exit 1
}

{
  echo "timestamp_utc=${timestamp}"
  echo "device_serial=${device}"
  echo "model=$("${adb_bin}" -s "${device}" shell getprop ro.product.model | tr -d '\r')"
  echo "android_release=$("${adb_bin}" -s "${device}" shell getprop ro.build.version.release | tr -d '\r')"
  echo "android_sdk=$("${adb_bin}" -s "${device}" shell getprop ro.build.version.sdk | tr -d '\r')"
  echo "build_fingerprint=$("${adb_bin}" -s "${device}" shell getprop ro.build.fingerprint | tr -d '\r')"
  echo "abi=$("${adb_bin}" -s "${device}" shell getprop ro.product.cpu.abi | tr -d '\r')"
  echo "cpu_cores=$("${adb_bin}" -s "${device}" shell nproc | tr -d '\r')"
  echo "clock_ticks=${clock_ticks}"
  echo "build_mode=${build_mode}"
  echo "benchmark_url=${benchmark_url}"
  echo "egress_url=${egress_url}"
  echo "expected_egress=${expected_egress}"
  echo "probe_package=${probe_package}"
  echo "profile=${profile_filter:-direct}"
  echo "rounds=${rounds}"
  echo "schedule=${schedule}"
  echo "warmup_seconds=${warmup_seconds}"
  echo "measure_seconds=${measure_seconds}"
  echo "cooldown_seconds=${cooldown_seconds}"
  echo "concurrency=${concurrency}"
  echo "sample_interval_seconds=${sample_interval_seconds}"
  echo "externally_powered=${powered}"
  "${adb_bin}" -s "${device}" shell dumpsys battery 2>/dev/null |
    grep -E 'AC powered:|USB powered:|Wireless powered:|Charge counter:|level:|voltage:|temperature:' || true
  "${adb_bin}" -s "${device}" shell cmd wifi status 2>/dev/null |
    grep -m1 'WifiInfo:' |
    sed -E 's/SSID: "[^"]*", BSSID: [^,]*, MAC: [^,]*, /SSID: <redacted>, BSSID: <redacted>, MAC: <redacted>, /' || true
  "${adb_bin}" -s "${device}" shell dumpsys thermalservice 2>/dev/null |
    grep -E 'Thermal Status:|Temperature\{mValue=.*mName=(battery|skin-thmzone|soc-thmzone)' |
    head -n 8 || true
} >"${environment_file}"

active_phase() {
  local marker
  marker=$(grep 'DEVICE_BENCHMARK PHASE_' "${logcat_file}" 2>/dev/null | tail -n 1 || true)
  [[ "${marker}" == *"DEVICE_BENCHMARK PHASE_BEGIN "* ]] || return 0
  printf '%s\n' "${marker}" | sed -n 's/.*phase_id=\([^ ]*\).*/\1/p'
}

read_environment_sample() {
  local thermal battery_dump battery_temperature charge wifi_status wifi_rssi
  thermal=$("${adb_bin}" -s "${device}" shell dumpsys thermalservice 2>/dev/null |
    sed -n 's/.*Thermal Status: *\([0-9][0-9]*\).*/\1/p' | head -n 1)
  battery_dump=$("${adb_bin}" -s "${device}" shell dumpsys battery 2>/dev/null || true)
  battery_temperature=$(printf '%s\n' "${battery_dump}" |
    sed -n 's/.*temperature: *\(-*[0-9][0-9]*\).*/\1/p' | head -n 1)
  charge=$(printf '%s\n' "${battery_dump}" |
    sed -n 's/.*Charge counter: *\(-*[0-9][0-9]*\).*/\1/p' | head -n 1)
  wifi_status=$("${adb_bin}" -s "${device}" shell cmd wifi status 2>/dev/null || true)
  wifi_rssi=$(printf '%s\n' "${wifi_status}" |
    sed -n 's/.*RSSI: *\(-*[0-9][0-9]*\).*/\1/p' | head -n 1)
  printf '%s|%s|%s|%s\n' "${thermal:-0}" "${battery_temperature:-0}" \
    "${charge}" "${wifi_rssi}"
}

sample_processes() {
  set +e
  local phase_id sample_ms app_uid probe_uid environment thermal battery_temperature charge wifi_rssi
  local ps_rows uid pid ppid name stat_line stat_tail cpu_ticks start_ticks status rss
  local sample_buffer process_line
  echo "sampler_started" >>"${sampler_log}"
  while [[ -n "${drive_pid}" ]] && kill -0 "${drive_pid}" 2>/dev/null; do
    phase_id=$(active_phase)
    if [[ -z "${phase_id}" ]]; then
      sleep 0.2
      continue
    fi
    echo "phase=${phase_id}" >>"${sampler_log}"
    app_uid=$("${adb_bin}" -s "${device}" shell cmd package list packages \
      -U "${package}" 2>/dev/null |
      sed -n "s/^package:${package} uid:\([0-9][0-9]*\)$/\1/p" | head -n 1)
    probe_uid=$("${adb_bin}" -s "${device}" shell cmd package list packages \
      -U "${probe_package}" 2>/dev/null |
      sed -n "s/^package:${probe_package} uid:\([0-9][0-9]*\)$/\1/p" | head -n 1)
    if [[ -z "${app_uid}" || -z "${probe_uid}" ]]; then
      sleep 0.2
      continue
    fi
    sample_ms=$("${adb_bin}" -s "${device}" shell date +%s%3N 2>/dev/null | tr -d '\r')
    environment=$(read_environment_sample)
    IFS='|' read -r thermal battery_temperature charge wifi_rssi <<<"${environment}"
    sample_buffer=$(printf 'environment\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "${phase_id}" "${sample_ms}" "" "" "" "" "" "" "" "" \
      "${thermal}" "${battery_temperature}" "${charge}" "${wifi_rssi}")
    ps_rows=$("${adb_bin}" -s "${device}" shell ps -A -o UID,PID,PPID,NAME 2>/dev/null |
      awk -v app_uid="${app_uid}" -v probe_uid="${probe_uid}" \
        'NR > 1 && ($1 == app_uid || $1 == probe_uid) {print $1, $2, $3, $4}')
    printf '%s\n' "${ps_rows}" | sed '/^$/d; s/^/process_row=/' >>"${sampler_log}"
    while read -r uid pid ppid name; do
      [[ -n "${pid:-}" ]] || continue
      stat_line=$("${adb_bin}" -s "${device}" shell cat "/proc/${pid}/stat" \
        </dev/null 2>/dev/null || true)
      [[ "${stat_line}" == *") "* ]] || continue
      stat_tail="${stat_line##*) }"
      cpu_ticks=$(printf '%s\n' "${stat_tail}" | awk '{print $12 + $13}')
      start_ticks=$(printf '%s\n' "${stat_tail}" | awk '{print $20}')
      # /proc is intentionally used instead of `dumpsys meminfo`: the latter
      # can request a GC and perturb the throughput phase it is measuring.
      status=$("${adb_bin}" -s "${device}" shell cat "/proc/${pid}/status" \
        </dev/null 2>/dev/null || true)
      rss=$(printf '%s\n' "${status}" | awk '/^VmRSS:/ {print $2; exit}')
      process_line=$(printf 'process\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "${phase_id}" "${sample_ms}" "${uid}" "${pid}" "${ppid}" \
        "${start_ticks}" "${cpu_ticks}" "${name//$'\t'/_}" "-1" "${rss:--1}" \
        "${thermal}" "${battery_temperature}" "${charge}" "${wifi_rssi}")
      sample_buffer+=$'\n'"${process_line}"
    done <<<"${ps_rows}"
    if [[ "$(active_phase)" == "${phase_id}" ]]; then
      printf '%s\n' "${sample_buffer}" >>"${metrics_file}"
    else
      echo "discarded_edge_sample=${phase_id}" >>"${sampler_log}"
    fi
    sleep "${sample_interval_seconds}"
  done
}

launch_external_probes() {
  set +e
  local seen_file="${result_root}/probe-phases.seen"
  local line phase_id profile backend round position callback_port
  local url_b64 egress_url_b64
  : >"${seen_file}"
  url_b64=$(printf '%s' "${benchmark_url}" | base64 | tr -d '\r\n')
  egress_url_b64=$(printf '%s' "${egress_url}" | base64 | tr -d '\r\n')
  while [[ -n "${drive_pid}" ]] && kill -0 "${drive_pid}" 2>/dev/null; do
    while IFS= read -r line; do
      phase_id=$(printf '%s\n' "${line}" | sed -n 's/.* phase_id=\([^ ]*\).*/\1/p')
      [[ -n "${phase_id}" ]] || continue
      grep -Fxq "${phase_id}" "${seen_file}" && continue
      profile=$(printf '%s\n' "${line}" | sed -n 's/.* profile=\([^ ]*\).*/\1/p')
      backend=$(printf '%s\n' "${line}" | sed -n 's/.* backend=\([^ ]*\).*/\1/p')
      round=$(printf '%s\n' "${line}" | sed -n 's/.* round=\([0-9]*\).*/\1/p')
      position=$(printf '%s\n' "${line}" | sed -n 's/.* position=\([0-9]*\).*/\1/p')
      callback_port=$(printf '%s\n' "${line}" | sed -n 's/.* callback_port=\([0-9]*\).*/\1/p')
      if [[ -z "${profile}" || -z "${backend}" || -z "${round}" ||
          -z "${position}" || -z "${callback_port}" ]]; then
        continue
      fi
      printf '%s\n' "${phase_id}" >>"${seen_file}"
      "${adb_bin}" -s "${device}" shell am force-stop "${probe_package}" \
        </dev/null >/dev/null 2>&1 || true
      "${adb_bin}" -s "${device}" shell am start --user 0 \
        --activity-clear-task -n "${probe_activity}" \
        --es phase_id "${phase_id}" \
        --es profile "${profile}" \
        --es backend "${backend}" \
        --ei round "${round}" \
        --ei position "${position}" \
        --ei concurrency "${concurrency}" \
        --ei warmup_seconds "${warmup_seconds}" \
        --ei measure_seconds "${measure_seconds}" \
        --ei callback_port "${callback_port}" \
        --es url_b64 "${url_b64}" \
        --es egress_url_b64 "${egress_url_b64}" \
        --es expected_egress "${expected_egress}" \
        </dev/null >>"${sampler_log}" 2>&1
    done < <(grep 'DEVICE_BENCHMARK PROBE_READY ' "${logcat_file}" 2>/dev/null || true)
    sleep 0.2
  done
}

accept_vpn_permission() {
  local dialog_xml bounds x1 y1 x2 y2
  while [[ -n "${drive_pid}" ]] && kill -0 "${drive_pid}" 2>/dev/null; do
    if "${adb_bin}" -s "${device}" shell pm path "${package}" >/dev/null 2>&1; then
      "${adb_bin}" -s "${device}" shell appops set "${package}" ACTIVATE_VPN allow \
        >/dev/null 2>&1 || true
    fi
    if "${adb_bin}" -s "${device}" shell dumpsys window 2>/dev/null |
      grep -q 'com.android.vpndialogs.*ConfirmDialog'; then
      "${adb_bin}" -s "${device}" shell uiautomator dump \
        /data/local/tmp/flutter_xray_vpn_dialog.xml >/dev/null 2>&1 || true
      dialog_xml=$("${adb_bin}" -s "${device}" shell cat \
        /data/local/tmp/flutter_xray_vpn_dialog.xml 2>/dev/null || true)
      bounds=$(printf '%s\n' "${dialog_xml}" | sed 's/></>\n</g' |
        sed -n 's/.*resource-id="android:id\/button1".*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' |
        head -n 1)
      if [[ -n "${bounds}" ]]; then
        read -r x1 y1 x2 y2 <<<"${bounds}"
        "${adb_bin}" -s "${device}" shell input tap \
          "$(((x1 + x2) / 2))" "$(((y1 + y2) / 2))" >/dev/null 2>&1 || true
      fi
      "${adb_bin}" -s "${device}" shell rm -f \
        /data/local/tmp/flutter_xray_vpn_dialog.xml >/dev/null 2>&1 || true
    fi
    sleep 0.5
  done
}

"${adb_bin}" -s "${device}" logcat -c || true
"${adb_bin}" -s "${device}" logcat -v threadtime >"${logcat_file}" 2>&1 &
logcat_pid=$!

(
  cd "${repo_root}/example/android"
  ./gradlew :benchmark_probe:assembleRelease
)
probe_apk="${repo_root}/example/build/benchmark_probe/outputs/apk/release/benchmark_probe-release.apk"
if [[ ! -f "${probe_apk}" ]]; then
  echo "Benchmark probe APK was not produced: ${probe_apk}" >&2
  exit 1
fi
"${adb_bin}" -s "${device}" install -r "${probe_apk}" >/dev/null
probe_installed="true"

drive_arguments=(
  drive
  --"${build_mode}"
  --no-enable-dart-profiling
  --no-track-widget-creation
  --driver=test_driver/integration_test.dart
  --target=integration_test/android_benchmark_test.dart
  -d "${device}"
  "--dart-define=FLUTTER_XRAY_BENCHMARK_URL=${benchmark_url}"
  "--dart-define=FLUTTER_XRAY_BENCHMARK_SCHEDULE=${schedule}"
  "--dart-define=FLUTTER_XRAY_BENCHMARK_WARMUP_SECONDS=${warmup_seconds}"
  "--dart-define=FLUTTER_XRAY_BENCHMARK_MEASURE_SECONDS=${measure_seconds}"
  "--dart-define=FLUTTER_XRAY_BENCHMARK_COOLDOWN_SECONDS=${cooldown_seconds}"
  "--dart-define=FLUTTER_XRAY_BENCHMARK_CONCURRENCY=${concurrency}"
)
if [[ -n "${defines_file}" ]]; then
  drive_arguments+=("--dart-define-from-file=${defines_file}")
  drive_arguments+=("--dart-define=FLUTTER_XRAY_DEVICE_PROFILE_FILTER=${profile_filter}")
fi

(
  set -o pipefail
  cd "${repo_root}/example"
  "${flutter_bin}" "${drive_arguments[@]}" 2>&1 | tee "${drive_log}"
) &
drive_pid=$!
sample_processes &
sampler_pid=$!
launch_external_probes &
probe_launcher_pid=$!
accept_vpn_permission &
permission_pid=$!

set +e
wait "${drive_pid}"
drive_status=$?
set -e
sleep 2
for pid in "${permission_pid}" "${probe_launcher_pid}" "${sampler_pid}" "${logcat_pid}"; do
  if [[ -n "${pid}" ]]; then
    kill "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
done
permission_pid=""
probe_launcher_pid=""
sampler_pid=""
logcat_pid=""

fgs_failure_pattern='ForegroundServiceDidNotStartInTimeException|ForegroundServiceStartNotAllowedException|CannotPostForegroundServiceNotificationException|Context.startForegroundService\(\) did not then call Service.startForeground\(\)|startForegroundService\(\) not allowed|Bad notification for startForeground|set service .* to foreground failed|Failed to promote .* service to .*foreground|Exception starting .*foreground service'
foreground_service_failures=$(grep -E \
  "${package}|V2rayVPNService|V2rayProxyOnlyService" "${logcat_file}" |
  grep -Ec "${fgs_failure_pattern}" || true)
daemon_crashes=$(grep -c "Process: ${package}:RunSoLibV2RayDaemon" "${logcat_file}" || true)
transfer_error_events=$(grep -c 'DEVICE_BENCHMARK TRANSFER_ERROR ' "${logcat_file}" || true)
grep 'DEVICE_BENCHMARK' "${logcat_file}" >"${result_root}/evidence.txt" || true
expected_phases=$((rounds * 3))
actual_phases=$(grep -c 'DEVICE_BENCHMARK RESULT ' "${logcat_file}" || true)

report_status=0
if ! "${dart_bin}" run "${repo_root}/tool/device/benchmark_report.dart" \
  "--log=${logcat_file}" \
  "--metrics=${metrics_file}" \
  "--output=${result_root}" \
  "--package=${package}" \
  "--probe-package=${probe_package}" \
  "--clock-ticks=${clock_ticks}"; then
  report_status=1
fi

{
  echo "drive_exit_code=${drive_status}"
  echo "report_exit_code=${report_status}"
  echo "expected_phases=${expected_phases}"
  echo "actual_phases=${actual_phases}"
  echo "foreground_service_failures=${foreground_service_failures}"
  echo "daemon_crashes=${daemon_crashes}"
  echo "transfer_error_events=${transfer_error_events}"
  echo "result_directory=${result_root}"
} | tee "${result_root}/acceptance.txt"

if [[ "${drive_status}" != "0" || "${report_status}" != "0" ||
    "${actual_phases}" != "${expected_phases}" ||
    "${foreground_service_failures}" != "0" || "${daemon_crashes}" != "0" ]]; then
  exit 1
fi
