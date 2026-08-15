import 'package:flutter_test/flutter_test.dart';

import '../tool/device/benchmark_report.dart';

void main() {
  test('includes standalone BadVPN process in UID and VPN runtime metrics', () {
    const packageName = 'dev.zikwall.flutter_xray.example';
    final log = ['badvpn', 'xray', 'hev'].asMap().entries.map((entry) {
      final position = entry.key + 1;
      final backend = entry.value;
      return 'DEVICE_BENCHMARK RESULT phase_id=p-$backend profile=direct '
          'backend=$backend round=1 position=$position concurrency=1 '
          'bytes=1000000 elapsed_ms=1000 mbps=8.000 requests=1 errors=0';
    }).join('\n');
    final metrics = StringBuffer()
      ..writeln(
        'record_type\tphase_id\tsample_ms\tuid\tpid\tppid\tstart_ticks\t'
        'cpu_ticks\tname\tpss_kb\trss_kb\tthermal_status\t'
        'battery_temp_deci_c\tcharge_uah\twifi_rssi',
      );
    for (final backend in const ['badvpn', 'xray', 'hev']) {
      final phase = 'p-$backend';
      for (final timestamp in const [1000, 2000]) {
        metrics
          ..writeln(
            'environment\t$phase\t$timestamp\t\t\t\t\t\t\t\t\t0\t280\t'
            '${timestamp == 1000 ? 4000000 : 3999999}\t-50',
          )
          ..writeln(
            'process\t$phase\t$timestamp\t10123\t10\t1\t100\t'
            '${timestamp == 1000 ? 100 : 110}\t$packageName\t100\t200\t'
            '0\t280\t4000000\t-50',
          )
          ..writeln(
            'process\t$phase\t$timestamp\t10123\t11\t10\t200\t'
            '${timestamp == 1000 ? 200 : 220}\t$packageName:RunSoLibV2RayDaemon\t'
            '50\t80\t0\t280\t4000000\t-50',
          );
        if (backend == 'badvpn') {
          metrics.writeln(
            'process\t$phase\t$timestamp\t10123\t12\t11\t300\t'
            '${timestamp == 1000 ? 300 : 330}\tlibtun2socks.so\t20\t30\t'
            '0\t280\t4000000\t-50',
          );
        }
      }
    }

    final report = buildBenchmarkReport(
      logContent: log,
      metricsContent: metrics.toString(),
      packageName: packageName,
      clockTicksPerSecond: 100,
    );
    final badVpn = report.phases.firstWhere(
      (phase) => phase.result.backend == 'badvpn',
    );

    expect(badVpn.uidCpuPercent, closeTo(60, 0.001));
    expect(badVpn.runtimeCpuPercent, closeTo(50, 0.001));
    expect(badVpn.uidPssMeanKb, 170);
    expect(badVpn.runtimePssMeanKb, 70);
    expect(badVpn.processNames, contains('libtun2socks.so'));
  });

  test('rejects an unbalanced backend comparison', () {
    const log = 'DEVICE_BENCHMARK RESULT phase_id=p-badvpn profile=direct '
        'backend=badvpn round=1 position=1 concurrency=1 bytes=1000000 '
        'elapsed_ms=1000 mbps=8.000 requests=1 errors=0';
    const metrics = '''
record_type\tphase_id\tsample_ms\tuid\tpid\tppid\tstart_ticks\tcpu_ticks\tname\tpss_kb\trss_kb\tthermal_status\tbattery_temp_deci_c\tcharge_uah\twifi_rssi
environment\tp-badvpn\t1000\t\t\t\t\t\t\t\t\t0\t280\t4000000\t-50
process\tp-badvpn\t1000\t10123\t10\t1\t100\t100\tapp\t100\t200\t0\t280\t4000000\t-50
environment\tp-badvpn\t2000\t\t\t\t\t\t\t\t\t0\t280\t3999999\t-50
process\tp-badvpn\t2000\t10123\t10\t1\t100\t110\tapp\t100\t200\t0\t280\t3999999\t-50
''';

    expect(
      () => buildBenchmarkReport(
        logContent: log,
        metricsContent: metrics,
        packageName: 'app',
        clockTicksPerSecond: 100,
      ),
      throwsFormatException,
    );
  });

  test('accepts RSS-only samples without printing NaN for unavailable PSS', () {
    const packageName = 'dev.zikwall.flutter_xray.example';
    final log = ['badvpn', 'xray', 'hev'].asMap().entries.map((entry) {
      final backend = entry.value;
      return 'DEVICE_BENCHMARK RESULT phase_id=p-$backend profile=direct '
          'backend=$backend round=1 position=${entry.key + 1} concurrency=1 '
          'bytes=1000000 elapsed_ms=1000 mbps=8.000 requests=1 errors=0';
    }).join('\n');
    final metrics = StringBuffer()
      ..writeln(
        'record_type\tphase_id\tsample_ms\tuid\tpid\tppid\tstart_ticks\t'
        'cpu_ticks\tname\tpss_kb\trss_kb\tthermal_status\t'
        'battery_temp_deci_c\tcharge_uah\twifi_rssi',
      );
    for (final backend in const ['badvpn', 'xray', 'hev']) {
      for (final timestamp in const [1000, 2000]) {
        metrics
          ..writeln(
            'environment\tp-$backend\t$timestamp\t\t\t\t\t\t\t\t\t0\t280\t'
            '4000000\t-50',
          )
          ..writeln(
            'process\tp-$backend\t$timestamp\t10123\t10\t1\t100\t'
            '${timestamp == 1000 ? 100 : 110}\t$packageName\t-1\t200\t'
            '0\t280\t4000000\t-50',
          )
          ..writeln(
            'process\tp-$backend\t$timestamp\t10123\t11\t10\t200\t'
            '${timestamp == 1000 ? 200 : 220}\t'
            '$packageName:RunSoLibV2RayDaemon\t-1\t80\t'
            '0\t280\t4000000\t-50',
          );
        if (backend == 'badvpn') {
          metrics.writeln(
            'process\tp-$backend\t$timestamp\t10123\t12\t11\t300\t'
            '${timestamp == 1000 ? 300 : 330}\tlibtun2socks.so\t-1\t30\t'
            '0\t280\t4000000\t-50',
          );
        }
      }
    }

    final report = buildBenchmarkReport(
      logContent: log,
      metricsContent: metrics.toString(),
      packageName: packageName,
      clockTicksPerSecond: 100,
    );

    expect(report.aggregates.every((row) => row.uidPssMeanKb.isNaN), isTrue);
    expect(report.summaryTsv, isNot(contains('NaN')));
    expect(report.summaryMarkdown, contains('UID RSS'));
  });
}
