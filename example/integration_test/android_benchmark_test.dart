import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xray/flutter_xray.dart';
import 'package:integration_test/integration_test.dart';

const _benchmarkUrl = String.fromEnvironment('FLUTTER_XRAY_BENCHMARK_URL');
const _schedule = String.fromEnvironment(
  'FLUTTER_XRAY_BENCHMARK_SCHEDULE',
  defaultValue: 'badvpn,xray,hev',
);
const _warmupSeconds = int.fromEnvironment(
  'FLUTTER_XRAY_BENCHMARK_WARMUP_SECONDS',
  defaultValue: 5,
);
const _measureSeconds = int.fromEnvironment(
  'FLUTTER_XRAY_BENCHMARK_MEASURE_SECONDS',
  defaultValue: 30,
);
const _cooldownSeconds = int.fromEnvironment(
  'FLUTTER_XRAY_BENCHMARK_COOLDOWN_SECONDS',
  defaultValue: 5,
);
const _concurrency = int.fromEnvironment(
  'FLUTTER_XRAY_BENCHMARK_CONCURRENCY',
  defaultValue: 1,
);
const _profilesBase64 = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_PROFILES_B64',
);
const _profileFilter = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_PROFILE_FILTER',
);
const _coreLogLevel = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_CORE_LOG_LEVEL',
  defaultValue: 'warning',
);
const _expectedTunnelEgress = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_EXPECTED_TUNNEL_EGRESS',
);
const _egressUrl = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_EGRESS_URL',
  defaultValue: 'https://api.ipify.org',
);

const _directConfig = r'''
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": true}
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {"domainStrategy": "UseIP"}
    }
  ]
}
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'balanced steady-state Android tunnel benchmark',
    (tester) async {
      _validateInputs();
      final profile = _loadProfile();
      final schedule = _parseSchedule();
      String state = 'UNKNOWN';
      final changes = StreamController<String>.broadcast();
      final xray = Xray(
        onStatusChanged: (status) {
          state = status.state;
          changes.add(state);
        },
      );
      addTearDown(() async {
        await xray.stop();
      });

      await xray.initialize();
      expect(await xray.requestPermission(), isTrue);
      debugPrint(
        'DEVICE_BENCHMARK CONFIG profile=${profile.id} '
        'phases=${schedule.length} warmup_seconds=$_warmupSeconds '
        'measure_seconds=$_measureSeconds cooldown_seconds=$_cooldownSeconds '
        'concurrency=$_concurrency core=${await xray.getCoreVersion()}',
      );

      final phaseFailures = <String>[];
      for (var index = 0; index < schedule.length; index += 1) {
        final backendName = schedule[index];
        final round = index ~/ 3 + 1;
        final position = index % 3 + 1;
        final phaseId = '${profile.id}-r$round-p$position-$backendName';
        try {
          await xray.start(
            remark: 'benchmark $phaseId',
            config: profile.config,
            tunnelBackend: _backend(backendName),
          );
          await _waitForState(
            expected: 'CONNECTED',
            current: () => state,
            changes: changes.stream,
          );
          await _verifyTunnelEgress();
          await _transferFor(
            Uri.parse(_benchmarkUrl),
            const Duration(seconds: _warmupSeconds),
            _concurrency,
          );

          final startedAt = DateTime.now().millisecondsSinceEpoch;
          debugPrint(
            'DEVICE_BENCHMARK PHASE_BEGIN phase_id=$phaseId '
            'profile=${profile.id} backend=$backendName round=$round '
            'position=$position concurrency=$_concurrency '
            'unix_ms=$startedAt',
          );
          final result = await _transferFor(
            Uri.parse(_benchmarkUrl),
            const Duration(seconds: _measureSeconds),
            _concurrency,
          );
          final endedAt = DateTime.now().millisecondsSinceEpoch;
          debugPrint(
            'DEVICE_BENCHMARK PHASE_END phase_id=$phaseId unix_ms=$endedAt',
          );
          debugPrint(
            'DEVICE_BENCHMARK RESULT phase_id=$phaseId '
            'profile=${profile.id} backend=$backendName round=$round '
            'position=$position concurrency=$_concurrency bytes=${result.bytes} '
            'elapsed_ms=${result.elapsed.inMilliseconds} '
            'mbps=${result.megabitsPerSecond.toStringAsFixed(3)} '
            'requests=${result.requests} errors=${result.errors} '
            'error_types=${result.errorTypes.join(',')}',
          );
          if (result.bytes <= 100000 || result.errors != 0) {
            phaseFailures.add(
              '$phaseId(bytes=${result.bytes}, errors=${result.errors}, '
              'types=${result.errorTypes.join(',')})',
            );
          }
        } finally {
          if (state != 'DISCONNECTED') {
            await xray.stop();
            await _waitForState(
              expected: 'DISCONNECTED',
              current: () => state,
              changes: changes.stream,
            );
          }
        }
        if (index + 1 < schedule.length && _cooldownSeconds > 0) {
          await Future<void>.delayed(const Duration(seconds: _cooldownSeconds));
        }
      }
      expect(
        phaseFailures,
        isEmpty,
        reason: 'Invalid benchmark phases: ${phaseFailures.join('; ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 45)),
  );
}

void _validateInputs() {
  final uri = Uri.tryParse(_benchmarkUrl);
  if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
    throw const FormatException(
      'FLUTTER_XRAY_BENCHMARK_URL must be an explicit HTTP(S) URL',
    );
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const FormatException('Benchmark URL must use HTTP or HTTPS');
  }
  if (_warmupSeconds < 1 || _measureSeconds < 5) {
    throw const FormatException(
      'Warm-up must be at least 1 second and measurement at least 5 seconds',
    );
  }
  if (_cooldownSeconds < 0 || _concurrency < 1 || _concurrency > 16) {
    throw const FormatException(
      'Cooldown must be non-negative and concurrency must be between 1 and 16',
    );
  }
}

_BenchmarkProfile _loadProfile() {
  if (_profilesBase64.isEmpty) {
    return const _BenchmarkProfile('direct', _directConfig);
  }
  final decoded = utf8.decode(base64Decode(_profilesBase64));
  final document = jsonDecode(decoded);
  if (document is! List) {
    throw const FormatException('Device profiles must be a JSON array');
  }
  final matches = <_BenchmarkProfile>[];
  for (final entry in document) {
    if (entry is! Map) continue;
    final id = entry['id']?.toString().trim() ?? '';
    if (id.isEmpty || (_profileFilter.isNotEmpty && id != _profileFilter)) {
      continue;
    }
    if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(id)) {
      throw FormatException('Profile id is not benchmark-safe: $id');
    }
    final rawConfig = entry['config']?.toString() ?? '';
    final link = entry['link']?.toString() ?? '';
    var config =
        rawConfig.isNotEmpty
            ? rawConfig
            : Xray.parseFromURL(link).getFullConfiguration(indent: 0);
    final configDocument = jsonDecode(config) as Map<String, dynamic>;
    final log =
        (configDocument['log'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    log['loglevel'] = _coreLogLevel;
    configDocument['log'] = log;
    config = jsonEncode(configDocument);
    matches.add(_BenchmarkProfile(id, config));
  }
  if (matches.length != 1) {
    throw FormatException(
      'Benchmark requires exactly one profile; matched ${matches.length}. '
      'Set FLUTTER_XRAY_DEVICE_PROFILE_FILTER.',
    );
  }
  return matches.single;
}

List<String> _parseSchedule() {
  final result = _schedule
      .split(',')
      .map((value) => value.trim().toLowerCase())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  if (result.isEmpty || result.length % 3 != 0) {
    throw const FormatException(
      'Benchmark schedule must contain complete three-backend rounds',
    );
  }
  for (var offset = 0; offset < result.length; offset += 3) {
    final round = result.sublist(offset, offset + 3).toSet();
    if (round.length != 3 ||
        !round.containsAll(const ['badvpn', 'xray', 'hev'])) {
      throw FormatException(
        'Every benchmark round must contain badvpn, xray and hev exactly once: '
        '${result.sublist(offset, offset + 3)}',
      );
    }
  }
  return result;
}

TunnelBackend _backend(String value) {
  switch (value) {
    case 'badvpn':
      return TunnelBackend.badVpn;
    case 'xray':
      return TunnelBackend.xray;
    case 'hev':
      return TunnelBackend.hev;
  }
  throw ArgumentError.value(value, 'backend');
}

Future<void> _verifyTunnelEgress() async {
  if (_expectedTunnelEgress.isEmpty) return;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(Uri.parse(_egressUrl));
    final response = await request.close().timeout(const Duration(seconds: 20));
    final egress = (await utf8.decoder.bind(response).join()).trim();
    expect(egress, _expectedTunnelEgress);
  } finally {
    client.close(force: true);
  }
}

Future<_TransferResult> _transferFor(
  Uri uri,
  Duration duration,
  int concurrency,
) async {
  final stopwatch = Stopwatch()..start();
  final deadline = DateTime.now().add(duration);
  final workers = List.generate(
    concurrency,
    (worker) => _transferWorker(uri, deadline, worker),
  );
  final results = await Future.wait(workers);
  stopwatch.stop();
  return _TransferResult(
    bytes: results.fold(0, (sum, result) => sum + result.bytes),
    requests: results.fold(0, (sum, result) => sum + result.requests),
    errors: results.fold(0, (sum, result) => sum + result.errors),
    errorTypes:
        results.expand((result) => result.errorTypes).toSet().toList()..sort(),
    elapsed: stopwatch.elapsed,
  );
}

Future<_WorkerResult> _transferWorker(
  Uri uri,
  DateTime deadline,
  int worker,
) async {
  final client =
      HttpClient()
        ..autoUncompress = false
        ..connectionTimeout = const Duration(seconds: 15);
  var bytes = 0;
  var requests = 0;
  var errors = 0;
  final errorTypes = <String>{};
  try {
    while (DateTime.now().isBefore(deadline)) {
      try {
        final request = await client
            .getUrl(uri)
            .timeout(deadline.difference(DateTime.now()));
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        request.headers.set('X-Flutter-Xray-Benchmark-Worker', '$worker');
        final remaining = deadline.difference(DateTime.now());
        final response = await request.close().timeout(
          remaining < const Duration(seconds: 20)
              ? remaining
              : const Duration(seconds: 20),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException(
            'Unexpected benchmark status ${response.statusCode}',
            uri: uri,
          );
        }
        requests += 1;
        await for (final chunk in response.timeout(
          const Duration(seconds: 20),
        )) {
          bytes += chunk.length;
          if (!DateTime.now().isBefore(deadline)) {
            client.close(force: true);
            break;
          }
        }
      } catch (error) {
        if (DateTime.now().isBefore(deadline) || bytes == 0) {
          errors += 1;
          errorTypes.add(error.runtimeType.toString());
        }
        if (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
  } finally {
    client.close(force: true);
  }
  return _WorkerResult(
    bytes: bytes,
    requests: requests,
    errors: errors,
    errorTypes: errorTypes,
  );
}

Future<void> _waitForState({
  required String expected,
  required String Function() current,
  required Stream<String> changes,
}) async {
  if (current() == expected) return;
  await changes
      .firstWhere((value) => value == expected)
      .timeout(
        const Duration(seconds: 20),
        onTimeout:
            () =>
                throw TimeoutException(
                  'Timed out waiting for $expected; current state is ${current()}',
                ),
      );
}

class _BenchmarkProfile {
  const _BenchmarkProfile(this.id, this.config);

  final String id;
  final String config;
}

class _TransferResult {
  const _TransferResult({
    required this.bytes,
    required this.requests,
    required this.errors,
    required this.errorTypes,
    required this.elapsed,
  });

  final int bytes;
  final int requests;
  final int errors;
  final List<String> errorTypes;
  final Duration elapsed;

  double get megabitsPerSecond => bytes * 8 / elapsed.inMicroseconds;
}

class _WorkerResult {
  const _WorkerResult({
    required this.bytes,
    required this.requests,
    required this.errors,
    required this.errorTypes,
  });

  final int bytes;
  final int requests;
  final int errors;
  final Set<String> errorTypes;
}
