import 'dart:io';
import 'dart:math';

const benchmarkMarker = 'DEVICE_BENCHMARK RESULT ';

void main(List<String> arguments) {
  final options = _parseArguments(arguments);
  final logPath = options['log'];
  final metricsPath = options['metrics'];
  final outputDirectory = options['output'];
  final packageName = options['package'];
  final probePackageName = options['probe-package'];
  final clockTicks = int.tryParse(options['clock-ticks'] ?? '');
  if (logPath == null ||
      metricsPath == null ||
      outputDirectory == null ||
      packageName == null ||
      probePackageName == null ||
      clockTicks == null ||
      clockTicks <= 0) {
    stderr.writeln(
      'Usage: dart run tool/device/benchmark_report.dart '
      '--log=<drive.log> --metrics=<metrics.tsv> --output=<directory> '
      '--package=<application-id> --probe-package=<application-id> '
      '--clock-ticks=<CLK_TCK>',
    );
    exitCode = 64;
    return;
  }

  final report = buildBenchmarkReport(
    logContent: File(logPath).readAsStringSync(),
    metricsContent: File(metricsPath).readAsStringSync(),
    packageName: packageName,
    probePackageName: probePackageName,
    clockTicksPerSecond: clockTicks,
  );
  final output = Directory(outputDirectory)..createSync(recursive: true);
  File('${output.path}/phases.tsv').writeAsStringSync(report.phasesTsv);
  File('${output.path}/summary.tsv').writeAsStringSync(report.summaryTsv);
  File('${output.path}/summary.md').writeAsStringSync(report.summaryMarkdown);
  stdout.write(report.summaryTsv);
}

BenchmarkReport buildBenchmarkReport({
  required String logContent,
  required String metricsContent,
  required String packageName,
  required String probePackageName,
  required int clockTicksPerSecond,
}) {
  final results = _parseResults(logContent);
  final metrics = _parseMetrics(metricsContent);
  if (results.isEmpty) {
    throw const FormatException('No benchmark result markers were found');
  }

  final phaseSummaries = <PhaseSummary>[];
  for (final result in results) {
    final phaseMetrics = metrics
        .where((sample) => sample.phaseId == result.phaseId)
        .toList(growable: false);
    final environment = phaseMetrics
        .where(
            (sample) => sample is EnvironmentMetric && sample is! ProcessMetric)
        .cast<EnvironmentMetric>()
        .toList(growable: false)
      ..sort((left, right) => left.sampleMs.compareTo(right.sampleMs));
    final processes =
        phaseMetrics.whereType<ProcessMetric>().toList(growable: false);
    if (environment.length < 2 || processes.isEmpty) {
      throw FormatException(
        'Phase ${result.phaseId} has insufficient steady-state metrics: '
        '${environment.length} environment samples, ${processes.length} process samples',
      );
    }
    phaseSummaries.add(
      _summarizePhase(
        result,
        environment,
        processes,
        packageName,
        probePackageName,
        clockTicksPerSecond,
      ),
    );
  }

  final groups = <String, List<PhaseSummary>>{};
  for (final phase in phaseSummaries) {
    groups
        .putIfAbsent(
          '${phase.result.profile}\t${phase.result.backend}\t${phase.result.concurrency}',
          () => <PhaseSummary>[],
        )
        .add(phase);
  }
  final countsByProfile = <String, Map<String, int>>{};
  for (final phase in phaseSummaries) {
    countsByProfile
        .putIfAbsent(phase.result.profile, () => <String, int>{})
        .update(
          phase.result.backend,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
  }
  for (final entry in countsByProfile.entries) {
    final counts = entry.value;
    if (counts.keys
            .toSet()
            .difference(const {'badvpn', 'xray', 'hev'}).isNotEmpty ||
        !counts.keys.toSet().containsAll(const {'badvpn', 'xray', 'hev'}) ||
        counts.values.toSet().length != 1) {
      throw FormatException(
        'Profile ${entry.key} has an unbalanced backend sample count: $counts',
      );
    }
  }
  if (phaseSummaries.any((phase) => phase.result.errors != 0)) {
    throw const FormatException(
        'At least one benchmark phase reported transfer errors');
  }

  final aggregateRows = groups.entries.map((entry) {
    final key = entry.key.split('\t');
    return AggregateSummary.fromPhases(
      profile: key[0],
      backend: key[1],
      concurrency: int.parse(key[2]),
      phases: entry.value,
    );
  }).toList(growable: false)
    ..sort((left, right) {
      final profile = left.profile.compareTo(right.profile);
      if (profile != 0) return profile;
      return _backendOrder(left.backend)
          .compareTo(_backendOrder(right.backend));
    });

  return BenchmarkReport(
    phases: phaseSummaries,
    aggregates: aggregateRows,
  );
}

PhaseSummary _summarizePhase(
  BenchmarkResult result,
  List<EnvironmentMetric> environment,
  List<ProcessMetric> processes,
  String packageName,
  String probePackageName,
  int clockTicksPerSecond,
) {
  final firstSampleMs = environment.first.sampleMs;
  final lastSampleMs = environment.last.sampleMs;
  final sampledSeconds = (lastSampleMs - firstSampleMs) / 1000.0;
  if (sampledSeconds <= 0) {
    throw FormatException('Phase ${result.phaseId} has a zero metric window');
  }

  var uidTickDelta = 0;
  var runtimeTickDelta = 0;
  final byProcess = <String, List<ProcessMetric>>{};
  for (final process in processes) {
    byProcess
        .putIfAbsent(
            '${process.pid}:${process.startTicks}', () => <ProcessMetric>[])
        .add(process);
  }
  for (final samples in byProcess.values) {
    samples.sort((left, right) => left.sampleMs.compareTo(right.sampleMs));
    if (samples.length < 2) continue;
    final delta = max(0, samples.last.cpuTicks - samples.first.cpuTicks);
    final processSeconds =
        (samples.last.sampleMs - samples.first.sampleMs) / 1000.0;
    if (processSeconds <= 0) continue;
    final normalizedDelta = (delta * sampledSeconds / processSeconds).round();
    uidTickDelta += normalizedDelta;
    if (samples.first.name != packageName &&
        samples.first.name != probePackageName) {
      runtimeTickDelta += normalizedDelta;
    }
  }
  final stableNames = byProcess.values
      .where((samples) => samples.length >= 2)
      .map((samples) => samples.first.name)
      .toSet();
  final requiredNames = <String>{
    packageName,
    '$packageName:RunSoLibV2RayDaemon',
    probePackageName,
    if (result.backend == 'badvpn') 'libtun2socks.so',
  };
  final missingNames = requiredNames.difference(stableNames);
  if (missingNames.isNotEmpty) {
    throw FormatException(
      'Phase ${result.phaseId} is missing stable process samples: '
      '${missingNames.join(', ')}',
    );
  }
  final uidCpu = uidTickDelta / clockTicksPerSecond / sampledSeconds * 100;
  final runtimeCpu =
      runtimeTickDelta / clockTicksPerSecond / sampledSeconds * 100;

  final totalPss = <double>[];
  final totalRss = <double>[];
  final runtimePss = <double>[];
  final runtimeRss = <double>[];
  final names = <String>{};
  final byTimestamp = <int, List<ProcessMetric>>{};
  for (final process in processes) {
    byTimestamp
        .putIfAbsent(process.sampleMs, () => <ProcessMetric>[])
        .add(process);
    names.add(process.name);
  }
  for (final sample in byTimestamp.values) {
    final pssValues = sample.where((value) => value.pssKb >= 0).toList();
    final rssValues = sample.where((value) => value.rssKb >= 0).toList();
    if (pssValues.isNotEmpty) {
      totalPss
          .add(pssValues.fold(0, (sum, value) => sum + value.pssKb).toDouble());
      runtimePss.add(
        pssValues
            .where(
              (value) =>
                  value.name != packageName && value.name != probePackageName,
            )
            .fold(0, (sum, value) => sum + value.pssKb)
            .toDouble(),
      );
    }
    if (rssValues.isNotEmpty) {
      totalRss
          .add(rssValues.fold(0, (sum, value) => sum + value.rssKb).toDouble());
      runtimeRss.add(
        rssValues
            .where(
              (value) =>
                  value.name != packageName && value.name != probePackageName,
            )
            .fold(0, (sum, value) => sum + value.rssKb)
            .toDouble(),
      );
    }
  }
  if (totalRss.isEmpty) {
    throw FormatException(
        'Phase ${result.phaseId} has no usable memory metrics');
  }

  final chargeValues = environment
      .map((value) => value.chargeUah)
      .whereType<int>()
      .toList(growable: false);
  final wifiValues = environment
      .map((value) => value.wifiRssi)
      .whereType<int>()
      .map((value) => value.toDouble())
      .toList(growable: false);

  return PhaseSummary(
    result: result,
    sampledSeconds: sampledSeconds,
    uidCpuPercent: uidCpu,
    runtimeCpuPercent: runtimeCpu,
    uidPssMeanKb: _meanOrNaN(totalPss),
    uidPssPeakKb: totalPss.isEmpty ? double.nan : totalPss.reduce(max),
    uidRssMeanKb: _mean(totalRss),
    uidRssPeakKb: totalRss.reduce(max),
    runtimePssMeanKb: _meanOrNaN(runtimePss),
    runtimeRssMeanKb: _mean(runtimeRss),
    thermalStatusMax:
        environment.map((value) => value.thermalStatus).reduce(max),
    batteryTemperatureMaxDeciC:
        environment.map((value) => value.batteryTemperatureDeciC).reduce(max),
    chargeDeltaUah:
        chargeValues.length < 2 ? null : chargeValues.last - chargeValues.first,
    wifiRssiMedian: wifiValues.isEmpty ? null : _median(wifiValues),
    processNames: names.toList()..sort(),
  );
}

List<BenchmarkResult> _parseResults(String content) {
  final results = <BenchmarkResult>[];
  final seen = <String>{};
  for (final line in content.split('\n')) {
    final marker = line.indexOf(benchmarkMarker);
    if (marker < 0) continue;
    final values =
        _parseKeyValues(line.substring(marker + benchmarkMarker.length));
    final result = BenchmarkResult(
      phaseId: _required(values, 'phase_id'),
      profile: _required(values, 'profile'),
      backend: _required(values, 'backend'),
      round: int.parse(_required(values, 'round')),
      position: int.parse(_required(values, 'position')),
      concurrency: int.parse(_required(values, 'concurrency')),
      bytes: int.parse(_required(values, 'bytes')),
      elapsedMs: int.parse(_required(values, 'elapsed_ms')),
      throughputMbps: double.parse(_required(values, 'mbps')),
      requests: int.parse(_required(values, 'requests')),
      errors: int.parse(_required(values, 'errors')),
    );
    if (!seen.add(result.phaseId)) {
      throw FormatException('Duplicate benchmark phase ${result.phaseId}');
    }
    results.add(result);
  }
  return results;
}

List<BenchmarkMetric> _parseMetrics(String content) {
  final metrics = <BenchmarkMetric>[];
  for (final line in content.split('\n')) {
    if (line.isEmpty || line.startsWith('record_type\t')) continue;
    final fields = line.split('\t');
    if (fields.length != 15) {
      throw FormatException(
          'Invalid metric row with ${fields.length} fields: $line');
    }
    final common = (
      phaseId: fields[1],
      sampleMs: int.parse(fields[2]),
      thermalStatus: int.parse(fields[11]),
      batteryTemperatureDeciC: int.parse(fields[12]),
      chargeUah: fields[13].isEmpty ? null : int.parse(fields[13]),
      wifiRssi: fields[14].isEmpty ? null : int.parse(fields[14]),
    );
    if (fields[0] == 'environment') {
      metrics.add(
        EnvironmentMetric(
          phaseId: common.phaseId,
          sampleMs: common.sampleMs,
          thermalStatus: common.thermalStatus,
          batteryTemperatureDeciC: common.batteryTemperatureDeciC,
          chargeUah: common.chargeUah,
          wifiRssi: common.wifiRssi,
        ),
      );
    } else if (fields[0] == 'process') {
      metrics.add(
        ProcessMetric(
          phaseId: common.phaseId,
          sampleMs: common.sampleMs,
          uid: int.parse(fields[3]),
          pid: int.parse(fields[4]),
          ppid: int.parse(fields[5]),
          startTicks: int.parse(fields[6]),
          cpuTicks: int.parse(fields[7]),
          name: fields[8],
          pssKb: int.parse(fields[9]),
          rssKb: int.parse(fields[10]),
          thermalStatus: common.thermalStatus,
          batteryTemperatureDeciC: common.batteryTemperatureDeciC,
          chargeUah: common.chargeUah,
          wifiRssi: common.wifiRssi,
        ),
      );
    } else {
      throw FormatException('Unknown metric record type: ${fields[0]}');
    }
  }
  return metrics;
}

Map<String, String> _parseArguments(List<String> arguments) {
  final result = <String, String>{};
  for (final argument in arguments) {
    if (!argument.startsWith('--') || !argument.contains('=')) continue;
    final separator = argument.indexOf('=');
    result[argument.substring(2, separator)] =
        argument.substring(separator + 1);
  }
  return result;
}

Map<String, String> _parseKeyValues(String input) {
  final values = <String, String>{};
  for (final token in input.trim().split(RegExp(r'\s+'))) {
    final separator = token.indexOf('=');
    if (separator <= 0) continue;
    values[token.substring(0, separator)] = token.substring(separator + 1);
  }
  return values;
}

String _required(Map<String, String> values, String key) {
  final value = values[key];
  if (value == null || value.isEmpty) {
    throw FormatException('Missing $key in benchmark result');
  }
  return value;
}

double _mean(Iterable<double> values) {
  final list = values.toList(growable: false);
  return list.reduce((left, right) => left + right) / list.length;
}

double _meanOrNaN(Iterable<double> values) {
  final available = values.where((value) => value.isFinite);
  return available.isEmpty ? double.nan : _mean(available);
}

String _formatOptional(double value, int fractionDigits) =>
    value.isFinite ? value.toStringAsFixed(fractionDigits) : '';

double _median(Iterable<double> values) {
  final sorted = values.toList()..sort();
  final middle = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[middle];
  return (sorted[middle - 1] + sorted[middle]) / 2;
}

double _standardDeviation(Iterable<double> values) {
  final list = values.toList(growable: false);
  if (list.length < 2) return 0;
  final mean = _mean(list);
  final variance = list
          .map((value) => pow(value - mean, 2).toDouble())
          .reduce((left, right) => left + right) /
      (list.length - 1);
  return sqrt(variance);
}

int _backendOrder(String value) => switch (value) {
      'badvpn' => 0,
      'xray' => 1,
      'hev' => 2,
      _ => 3,
    };

sealed class BenchmarkMetric {
  const BenchmarkMetric({required this.phaseId, required this.sampleMs});

  final String phaseId;
  final int sampleMs;
}

class EnvironmentMetric extends BenchmarkMetric {
  const EnvironmentMetric({
    required super.phaseId,
    required super.sampleMs,
    required this.thermalStatus,
    required this.batteryTemperatureDeciC,
    required this.chargeUah,
    required this.wifiRssi,
  });

  final int thermalStatus;
  final int batteryTemperatureDeciC;
  final int? chargeUah;
  final int? wifiRssi;
}

class ProcessMetric extends EnvironmentMetric {
  const ProcessMetric({
    required super.phaseId,
    required super.sampleMs,
    required this.uid,
    required this.pid,
    required this.ppid,
    required this.startTicks,
    required this.cpuTicks,
    required this.name,
    required this.pssKb,
    required this.rssKb,
    required super.thermalStatus,
    required super.batteryTemperatureDeciC,
    required super.chargeUah,
    required super.wifiRssi,
  });

  final int uid;
  final int pid;
  final int ppid;
  final int startTicks;
  final int cpuTicks;
  final String name;
  final int pssKb;
  final int rssKb;
}

class BenchmarkResult {
  const BenchmarkResult({
    required this.phaseId,
    required this.profile,
    required this.backend,
    required this.round,
    required this.position,
    required this.concurrency,
    required this.bytes,
    required this.elapsedMs,
    required this.throughputMbps,
    required this.requests,
    required this.errors,
  });

  final String phaseId;
  final String profile;
  final String backend;
  final int round;
  final int position;
  final int concurrency;
  final int bytes;
  final int elapsedMs;
  final double throughputMbps;
  final int requests;
  final int errors;
}

class PhaseSummary {
  const PhaseSummary({
    required this.result,
    required this.sampledSeconds,
    required this.uidCpuPercent,
    required this.runtimeCpuPercent,
    required this.uidPssMeanKb,
    required this.uidPssPeakKb,
    required this.uidRssMeanKb,
    required this.uidRssPeakKb,
    required this.runtimePssMeanKb,
    required this.runtimeRssMeanKb,
    required this.thermalStatusMax,
    required this.batteryTemperatureMaxDeciC,
    required this.chargeDeltaUah,
    required this.wifiRssiMedian,
    required this.processNames,
  });

  final BenchmarkResult result;
  final double sampledSeconds;
  final double uidCpuPercent;
  final double runtimeCpuPercent;
  final double uidPssMeanKb;
  final double uidPssPeakKb;
  final double uidRssMeanKb;
  final double uidRssPeakKb;
  final double runtimePssMeanKb;
  final double runtimeRssMeanKb;
  final int thermalStatusMax;
  final int batteryTemperatureMaxDeciC;
  final int? chargeDeltaUah;
  final double? wifiRssiMedian;
  final List<String> processNames;
}

class AggregateSummary {
  const AggregateSummary({
    required this.profile,
    required this.backend,
    required this.concurrency,
    required this.samples,
    required this.throughputMeanMbps,
    required this.throughputMedianMbps,
    required this.throughputStddevMbps,
    required this.throughputCvPercent,
    required this.uidCpuMeanPercent,
    required this.runtimeCpuMeanPercent,
    required this.uidPssMeanKb,
    required this.runtimePssMeanKb,
    required this.uidRssMeanKb,
    required this.runtimeRssMeanKb,
    required this.thermalStatusMax,
    required this.batteryTemperatureMaxDeciC,
    required this.wifiRssiMedian,
  });

  factory AggregateSummary.fromPhases({
    required String profile,
    required String backend,
    required int concurrency,
    required List<PhaseSummary> phases,
  }) {
    final throughput = phases
        .map((phase) => phase.result.throughputMbps)
        .toList(growable: false);
    final throughputMean = _mean(throughput);
    final wifi = phases
        .map((phase) => phase.wifiRssiMedian)
        .whereType<double>()
        .toList(growable: false);
    return AggregateSummary(
      profile: profile,
      backend: backend,
      concurrency: concurrency,
      samples: phases.length,
      throughputMeanMbps: throughputMean,
      throughputMedianMbps: _median(throughput),
      throughputStddevMbps: _standardDeviation(throughput),
      throughputCvPercent: throughputMean == 0
          ? 0
          : _standardDeviation(throughput) / throughputMean * 100,
      uidCpuMeanPercent: _mean(phases.map((phase) => phase.uidCpuPercent)),
      runtimeCpuMeanPercent: _mean(
        phases.map((phase) => phase.runtimeCpuPercent),
      ),
      uidPssMeanKb: _meanOrNaN(phases.map((phase) => phase.uidPssMeanKb)),
      runtimePssMeanKb: _meanOrNaN(
        phases.map((phase) => phase.runtimePssMeanKb),
      ),
      uidRssMeanKb: _mean(phases.map((phase) => phase.uidRssMeanKb)),
      runtimeRssMeanKb: _mean(
        phases.map((phase) => phase.runtimeRssMeanKb),
      ),
      thermalStatusMax:
          phases.map((phase) => phase.thermalStatusMax).reduce(max),
      batteryTemperatureMaxDeciC:
          phases.map((phase) => phase.batteryTemperatureMaxDeciC).reduce(max),
      wifiRssiMedian: wifi.isEmpty ? null : _median(wifi),
    );
  }

  final String profile;
  final String backend;
  final int concurrency;
  final int samples;
  final double throughputMeanMbps;
  final double throughputMedianMbps;
  final double throughputStddevMbps;
  final double throughputCvPercent;
  final double uidCpuMeanPercent;
  final double runtimeCpuMeanPercent;
  final double uidPssMeanKb;
  final double runtimePssMeanKb;
  final double uidRssMeanKb;
  final double runtimeRssMeanKb;
  final int thermalStatusMax;
  final int batteryTemperatureMaxDeciC;
  final double? wifiRssiMedian;
}

class BenchmarkReport {
  const BenchmarkReport({required this.phases, required this.aggregates});

  final List<PhaseSummary> phases;
  final List<AggregateSummary> aggregates;

  String get phasesTsv {
    final buffer = StringBuffer()
      ..writeln(
        'phase_id\tprofile\tbackend\tround\tposition\tconcurrency\tbytes\t'
        'elapsed_ms\tthroughput_mbps\tuid_cpu_pct\truntime_cpu_pct\t'
        'uid_pss_mean_kb\truntime_pss_mean_kb\tuid_rss_mean_kb\t'
        'runtime_rss_mean_kb\tthermal_status_max\tbattery_temp_max_deci_c\t'
        'charge_delta_uah\twifi_rssi_median\tprocess_names',
      );
    for (final phase in phases) {
      buffer.writeln([
        phase.result.phaseId,
        phase.result.profile,
        phase.result.backend,
        phase.result.round,
        phase.result.position,
        phase.result.concurrency,
        phase.result.bytes,
        phase.result.elapsedMs,
        phase.result.throughputMbps.toStringAsFixed(3),
        phase.uidCpuPercent.toStringAsFixed(2),
        phase.runtimeCpuPercent.toStringAsFixed(2),
        _formatOptional(phase.uidPssMeanKb, 0),
        _formatOptional(phase.runtimePssMeanKb, 0),
        phase.uidRssMeanKb.toStringAsFixed(0),
        phase.runtimeRssMeanKb.toStringAsFixed(0),
        phase.thermalStatusMax,
        phase.batteryTemperatureMaxDeciC,
        phase.chargeDeltaUah ?? '',
        phase.wifiRssiMedian?.toStringAsFixed(1) ?? '',
        phase.processNames.join(','),
      ].join('\t'));
    }
    return buffer.toString();
  }

  String get summaryTsv {
    final buffer = StringBuffer()
      ..writeln(
        'profile\tbackend\tconcurrency\tsamples\tthroughput_mean_mbps\t'
        'throughput_median_mbps\tthroughput_stddev_mbps\tthroughput_cv_pct\t'
        'uid_cpu_mean_pct\truntime_cpu_mean_pct\tuid_pss_mean_kb\t'
        'runtime_pss_mean_kb\tuid_rss_mean_kb\truntime_rss_mean_kb\t'
        'thermal_status_max\tbattery_temp_max_deci_c\twifi_rssi_median',
      );
    for (final aggregate in aggregates) {
      buffer.writeln([
        aggregate.profile,
        aggregate.backend,
        aggregate.concurrency,
        aggregate.samples,
        aggregate.throughputMeanMbps.toStringAsFixed(3),
        aggregate.throughputMedianMbps.toStringAsFixed(3),
        aggregate.throughputStddevMbps.toStringAsFixed(3),
        aggregate.throughputCvPercent.toStringAsFixed(2),
        aggregate.uidCpuMeanPercent.toStringAsFixed(2),
        aggregate.runtimeCpuMeanPercent.toStringAsFixed(2),
        _formatOptional(aggregate.uidPssMeanKb, 0),
        _formatOptional(aggregate.runtimePssMeanKb, 0),
        aggregate.uidRssMeanKb.toStringAsFixed(0),
        aggregate.runtimeRssMeanKb.toStringAsFixed(0),
        aggregate.thermalStatusMax,
        aggregate.batteryTemperatureMaxDeciC,
        aggregate.wifiRssiMedian?.toStringAsFixed(1) ?? '',
      ].join('\t'));
    }
    return buffer.toString();
  }

  String get summaryMarkdown {
    final buffer = StringBuffer()
      ..writeln('# Android tunnel benchmark')
      ..writeln()
      ..writeln(
        '| Profile | Backend | N | Mbps median | Mbps mean ± SD | CV | '
        'Test UIDs CPU | VPN CPU | Test UIDs RSS | VPN RSS | Thermal | '
        'Wi-Fi RSSI |',
      )
      ..writeln(
        '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | '
        '---: | ---: | ---: |',
      );
    for (final row in aggregates) {
      buffer.writeln(
        '| ${row.profile} | ${row.backend} | ${row.samples} | '
        '${row.throughputMedianMbps.toStringAsFixed(2)} | '
        '${row.throughputMeanMbps.toStringAsFixed(2)} ± '
        '${row.throughputStddevMbps.toStringAsFixed(2)} | '
        '${row.throughputCvPercent.toStringAsFixed(1)}% | '
        '${row.uidCpuMeanPercent.toStringAsFixed(1)}% | '
        '${row.runtimeCpuMeanPercent.toStringAsFixed(1)}% | '
        '${row.uidRssMeanKb.toStringAsFixed(0)} KB | '
        '${row.runtimeRssMeanKb.toStringAsFixed(0)} KB | '
        '${row.thermalStatusMax} | '
        '${row.wifiRssiMedian?.toStringAsFixed(1) ?? 'n/a'} dBm |',
      );
    }
    buffer
      ..writeln()
      ..writeln(
        'CPU uses cumulative process ticks during steady-state only. Test UID '
        'totals include both benchmark application UIDs; VPN totals exclude the idle '
        'VPN-owner process and the separate traffic-probe process, while retaining '
        'the Xray daemon and standalone BadVPN child process. RSS is read from /proc without '
        'requesting a GC; PSS columns are blank unless the input came from a '
        'separate memory-only sampler.',
      );
    return buffer.toString();
  }
}
