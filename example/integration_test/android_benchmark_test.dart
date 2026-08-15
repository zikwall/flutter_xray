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

  testWidgets('balanced steady-state Android tunnel benchmark', (tester) async {
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
      try {
        await xray.stop();
      } finally {
        await xray.dispose();
        await changes.close();
      }
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
        final probePassed = await _runExternalProbe(
          phaseId: phaseId,
          profile: profile.id,
          backend: backendName,
          round: round,
          position: position,
        );
        if (!probePassed) {
          phaseFailures.add('$phaseId(external_probe_failed)');
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
  }, timeout: const Timeout(Duration(minutes: 45)));
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

Future<bool> _runExternalProbe({
  required String phaseId,
  required String profile,
  required String backend,
  required int round,
  required int position,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final completed = Completer<bool>();
  final subscription = server.listen((request) async {
    final callbackPhase = request.uri.queryParameters['phase_id'];
    final callbackOk = request.uri.queryParameters['ok'] == 'true';
    if (request.uri.path == '/done' && callbackPhase == phaseId) {
      if (!completed.isCompleted) completed.complete(callbackOk);
      request.response.statusCode = HttpStatus.noContent;
    } else {
      request.response.statusCode = HttpStatus.badRequest;
    }
    await request.response.close();
  });
  try {
    debugPrint(
      'DEVICE_BENCHMARK PROBE_READY phase_id=$phaseId profile=$profile '
      'backend=$backend round=$round position=$position '
      'concurrency=$_concurrency callback_port=${server.port}',
    );
    return await completed.future.timeout(
      Duration(seconds: _warmupSeconds + _measureSeconds + 30),
      onTimeout: () => false,
    );
  } finally {
    await subscription.cancel();
    await server.close(force: true);
  }
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
