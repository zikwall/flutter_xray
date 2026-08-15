import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xray/flutter_xray.dart';
import 'package:integration_test/integration_test.dart';

final _lifecycleCycles = int.parse(
  const String.fromEnvironment('FLUTTER_XRAY_DEVICE_CYCLES', defaultValue: '3'),
);
const _backendName = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_BACKEND',
  defaultValue: 'hev',
);
const _profilesBase64 = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_PROFILES_B64',
);
const _profileFilter = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_PROFILE_FILTER',
);
const _holdSeconds = int.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_HOLD_SECONDS',
  defaultValue: 0,
);
const _profileRuns = int.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_PROFILE_RUNS',
  defaultValue: 1,
);
const _coreLogLevel = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_CORE_LOG_LEVEL',
);
const _requireUdp = bool.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_REQUIRE_UDP',
  defaultValue: true,
);
const _ipv4Url = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_IPV4_URL',
  defaultValue: 'https://1.1.1.1/cdn-cgi/trace',
);
const _ipv6Url = String.fromEnvironment('FLUTTER_XRAY_DEVICE_IPV6_URL');
const _throughputUrl = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_THROUGHPUT_URL',
  defaultValue: '',
);
const _udpEchoAddress = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_UDP_ECHO_ADDRESS',
);
const _udpEchoPort = int.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_UDP_ECHO_PORT',
  defaultValue: 19000,
);
const _dnsProbeAddress = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_DNS_PROBE_ADDRESS',
);
const _dnsProbePort = int.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_DNS_PROBE_PORT',
  defaultValue: 53,
);
const _dnsSourceUrl = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_DNS_SOURCE_URL',
);
const _dnsWhoamiAddress = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_DNS_WHOAMI_ADDRESS',
);
const _dnsWhoamiHostname = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_DNS_WHOAMI_HOSTNAME',
  defaultValue: 'whoami.cloudflare.com',
);
const _expectedDnsSource = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_EXPECTED_DNS_SOURCE',
);
const _expectedTunnelEgress = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_EXPECTED_TUNNEL_EGRESS',
);
const _egressUrl = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_EGRESS_URL',
  defaultValue: 'https://api.ipify.org',
);
const _checkBlockedApps = bool.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_CHECK_BLOCKED_APPS',
  defaultValue: false,
);
const _externalProbeOnly = bool.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_EXTERNAL_PROBE_ONLY',
  defaultValue: false,
);
const _testPackage = 'dev.zikwall.flutter_xray.example';

const _directConfig = r'''
{
  "log": {"loglevel": "warning"},
  "dns": {"servers": ["1.1.1.1", "2606:4700:4700::1111"]},
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
    'physical-device transport, packet path and lifecycle',
    (tester) async {
      String state = 'UNKNOWN';
      final stateChanges = StreamController<String>.broadcast();
      final xray = Xray(
        onStatusChanged: (status) {
          state = status.state;
          stateChanges.add(state);
        },
      );
      addTearDown(() async {
        try {
          await xray.stop();
        } finally {
          await xray.dispose();
          await stateChanges.close();
        }
      });

      await xray.initialize();
      debugPrint('DEVICE_EVIDENCE CORE version=${await xray.getCoreVersion()}');
      expect(await xray.requestPermission(), isTrue);
      final profiles = _loadProfiles();
      debugPrint(
        'DEVICE_EVIDENCE CONFIG backend=$_backendName '
        'profiles=${profiles.length} cycles=$_lifecycleCycles '
        'profile_runs=$_profileRuns require_udp=$_requireUdp '
        'hold_seconds=$_holdSeconds',
      );

      for (var cycle = 0; cycle < _lifecycleCycles; cycle += 1) {
        await _startAndWait(
          xray: xray,
          remark: '$_backendName lifecycle $cycle',
          config: profiles.first.config,
          state: () => state,
          changes: stateChanges.stream,
        );
        await _stopAndWait(
          xray: xray,
          state: () => state,
          changes: stateChanges.stream,
        );
        debugPrint('DEVICE_EVIDENCE RECONNECT cycle=${cycle + 1} passed=true');
      }

      final profileFailures = <String>[];
      for (var run = 1; run <= _profileRuns; run += 1) {
        for (final profile in profiles) {
          debugPrint(
            'DEVICE_EVIDENCE PROFILE id=${profile.id} run=$run started=true',
          );
          try {
            await _startAndWait(
              xray: xray,
              remark: '$_backendName ${profile.id} run $run',
              config: profile.config,
              state: () => state,
              changes: stateChanges.stream,
            );
            if (_externalProbeOnly) {
              debugPrint(
                'DEVICE_EVIDENCE EXTERNAL_PROBE_READY profile=${profile.id} '
                'hold_seconds=$_holdSeconds',
              );
              await Future<void>.delayed(Duration(seconds: _holdSeconds));
              debugPrint(
                'DEVICE_EVIDENCE PROFILE id=${profile.id} run=$run '
                'external_probe_window_complete=true',
              );
            } else {
              await _runPacketProbes(profile.id, run: run);
              debugPrint(
                'DEVICE_EVIDENCE PROFILE id=${profile.id} run=$run passed=true',
              );
            }
          } catch (error) {
            profileFailures.add('${profile.id}: ${error.runtimeType}');
            debugPrint(
              'DEVICE_EVIDENCE PROFILE id=${profile.id} run=$run '
              'passed=false error_type=${error.runtimeType} error=$error',
            );
          } finally {
            if (state != 'DISCONNECTED') {
              await _stopAndWait(
                xray: xray,
                state: () => state,
                changes: stateChanges.stream,
              );
            }
          }
        }
      }

      expect(
        profileFailures,
        isEmpty,
        reason:
            'Physical-device profile failures: ${profileFailures.join(', ')}',
      );

      if (_checkBlockedApps) {
        await _runBlockedAppsProbe(
          xray: xray,
          config: profiles.first.config,
          state: () => state,
          changes: stateChanges.stream,
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

List<_DeviceProfile> _loadProfiles() {
  if (_profilesBase64.isEmpty) {
    return const [_DeviceProfile('direct', _directConfig)];
  }
  final decoded = utf8.decode(base64Decode(_profilesBase64));
  final document = jsonDecode(decoded);
  if (document is! List) {
    throw const FormatException('Device profiles must be a JSON array');
  }
  final profiles = <_DeviceProfile>[];
  for (final entry in document) {
    if (entry is! Map) continue;
    final id = entry['id']?.toString().trim() ?? '';
    if (id.isEmpty || (_profileFilter.isNotEmpty && id != _profileFilter)) {
      continue;
    }
    final rawConfig = entry['config']?.toString() ?? '';
    final link = entry['link']?.toString() ?? '';
    var config =
        rawConfig.isNotEmpty
            ? rawConfig
            : Xray.parseFromURL(link).getFullConfiguration(indent: 0);
    final document = jsonDecode(config) as Map<String, dynamic>;
    if (_coreLogLevel.isNotEmpty) {
      final log =
          (document['log'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      log['loglevel'] = _coreLogLevel;
      document['log'] = log;
      config = jsonEncode(document);
    }
    final outbounds = document['outbounds'] as List<dynamic>;
    final proxy = outbounds.first as Map;
    debugPrint(
      'DEVICE_EVIDENCE PROFILE_CONFIG id=$id '
      'has_mux=${proxy.containsKey('mux')} bytes=${utf8.encode(config).length}',
    );
    profiles.add(_DeviceProfile(id, config));
  }
  if (profiles.isEmpty) {
    throw const FormatException('No matching device profiles were provided');
  }
  return profiles;
}

Future<void> _startAndWait({
  required Xray xray,
  required String remark,
  required String config,
  required String Function() state,
  required Stream<String> changes,
  List<String>? blockedApps,
}) async {
  await xray.start(
    remark: remark,
    config: config,
    blockedApps: blockedApps,
    tunnelBackend: _selectedBackend(),
  );
  await _waitForState(expected: 'CONNECTED', current: state, changes: changes);
}

TunnelBackend _selectedBackend() {
  switch (_backendName.toLowerCase()) {
    case 'badvpn':
    case 'bad_vpn':
      return TunnelBackend.badVpn;
    case 'hev':
      return TunnelBackend.hev;
    case 'xray':
    case 'xray_native_tun':
      return TunnelBackend.xray;
    default:
      throw ArgumentError.value(
        _backendName,
        'FLUTTER_XRAY_DEVICE_BACKEND',
        'Expected badvpn, xray, or hev',
      );
  }
}

Future<void> _stopAndWait({
  required Xray xray,
  required String Function() state,
  required Stream<String> changes,
}) async {
  await xray.stop();
  await _waitForState(
    expected: 'DISCONNECTED',
    current: state,
    changes: changes,
  );
}

Future<void> _runPacketProbes(String profileId, {required int run}) async {
  // CONNECTED means that the local core and TUN path own their resources. The
  // first remote transport handshake can still be warming up, especially for
  // H3. Gate the measured probes on the expected egress instead of treating a
  // transient cold-handshake failure as a tunnel-backend failure.
  if (_expectedTunnelEgress.isNotEmpty) {
    final egress = await _waitForExpectedEgress(_expectedTunnelEgress);
    expect(egress, _expectedTunnelEgress);
    debugPrint(
      'DEVICE_EVIDENCE EGRESS profile=$profileId '
      'matches_tunnel=${egress == _expectedTunnelEgress}',
    );
  }

  final ipv4Result = await _downloadWithRetry(Uri.parse(_ipv4Url));
  expect(ipv4Result.bytes, greaterThan(0));
  _evidence('IPV4_TCP', ipv4Result, profileId: profileId, run: run);

  if (_ipv6Url.isNotEmpty) {
    final ipv6Result = await _downloadWithRetry(Uri.parse(_ipv6Url));
    expect(ipv6Result.bytes, greaterThan(0));
    _evidence('IPV6_TCP', ipv6Result, profileId: profileId, run: run);
  } else {
    debugPrint('DEVICE_EVIDENCE IPV6_TCP profile=$profileId skipped=true');
  }

  if (_throughputUrl.isNotEmpty) {
    final throughput = await _downloadWithRetry(Uri.parse(_throughputUrl));
    expect(throughput.bytes, greaterThanOrEqualTo(100000));
    _evidence('THROUGHPUT', throughput, profileId: profileId, run: run);
  }

  if (_requireUdp) {
    if (_udpEchoAddress.isNotEmpty) {
      final echoLatency = await _udpEcho(
        InternetAddress(_udpEchoAddress),
        _udpEchoPort,
      );
      debugPrint(
        'DEVICE_EVIDENCE UDP_ECHO profile=$profileId '
        'latency_ms=${echoLatency.inMilliseconds}',
      );
    } else {
      final dnsLatency = await _udpDnsQuery(
        InternetAddress('1.1.1.1'),
        53,
        'example.com',
      );
      debugPrint(
        'DEVICE_EVIDENCE UDP_DNS profile=$profileId '
        'latency_ms=${dnsLatency.inMilliseconds}',
      );
    }
  }

  if (_dnsProbeAddress.isNotEmpty) {
    final hostname =
        'device-${DateTime.now().microsecondsSinceEpoch}.$profileId.test';
    final latency = await _udpDnsQuery(
      InternetAddress(_dnsProbeAddress),
      _dnsProbePort,
      hostname,
    );
    debugPrint(
      'DEVICE_EVIDENCE DNS_TUNNEL profile=$profileId '
      'latency_ms=${latency.inMilliseconds}',
    );
    if (_dnsSourceUrl.isNotEmpty) {
      final sourceUrl = _dnsSourceUrl.replaceAll(
        '{hostname}',
        Uri.encodeQueryComponent(hostname),
      );
      final source = (await _downloadText(Uri.parse(sourceUrl))).trim();
      final expectedSource =
          _expectedDnsSource.isEmpty
              ? _expectedTunnelEgress
              : _expectedDnsSource;
      if (expectedSource.isNotEmpty) {
        expect(source, expectedSource);
      }
      debugPrint(
        'DEVICE_EVIDENCE DNS_SOURCE profile=$profileId '
        'matches_tunnel=${source == expectedSource}',
      );
    }
  }

  if (_dnsWhoamiAddress.isNotEmpty) {
    final answers = await _udpDnsTxtQuery(
      InternetAddress(_dnsWhoamiAddress),
      53,
      _dnsWhoamiHostname,
    );
    final sourceAnswer = answers.where(
      (answer) => answer.toLowerCase().startsWith('remote_ip:'),
    );
    expect(sourceAnswer, isNotEmpty);
    final source = sourceAnswer.first.split(':').skip(1).join(':').trim();
    expect(InternetAddress.tryParse(source), isNotNull);
    final expectedSource =
        _expectedDnsSource.isEmpty ? _expectedTunnelEgress : _expectedDnsSource;
    if (expectedSource.isNotEmpty) {
      expect(source, expectedSource);
    }
    debugPrint(
      'DEVICE_EVIDENCE DNS_SOURCE profile=$profileId '
      'matches_tunnel=${source == expectedSource}',
    );
  }

  if (_holdSeconds > 0) {
    debugPrint(
      'DEVICE_EVIDENCE HOLD_STARTED profile=$profileId seconds=$_holdSeconds',
    );
    await Future<void>.delayed(Duration(seconds: _holdSeconds));
    final afterHold = await _downloadWithRetry(Uri.parse(_ipv4Url));
    expect(afterHold.bytes, greaterThan(0));
    _evidence('AFTER_HOLD', afterHold, profileId: profileId, run: run);
  }
}

Future<String> _waitForExpectedEgress(String expected) async {
  String lastEgress = '';
  Object? lastError;
  for (var attempt = 0; attempt < 15; attempt += 1) {
    try {
      lastEgress =
          (await _downloadText(
            Uri.parse(_egressUrl),
          ).timeout(const Duration(seconds: 4))).trim();
      if (lastEgress == expected) return lastEgress;
      lastError = null;
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  if (lastError != null && lastEgress.isEmpty) {
    Error.throwWithStackTrace(lastError, StackTrace.current);
  }
  return lastEgress;
}

Future<void> _runBlockedAppsProbe({
  required Xray xray,
  required String config,
  required String Function() state,
  required Stream<String> changes,
}) async {
  debugPrint('DEVICE_EVIDENCE BLOCKED_APPS phase=control started=true');
  await _startAndWait(
    xray: xray,
    remark: '$_backendName blockedApps control',
    config: config,
    state: state,
    changes: changes,
  );
  final tunneled =
      _expectedTunnelEgress.isEmpty
          ? (await _downloadText(Uri.parse(_egressUrl))).trim()
          : await _waitForExpectedEgress(_expectedTunnelEgress);
  if (_expectedTunnelEgress.isNotEmpty) {
    expect(tunneled, _expectedTunnelEgress);
  }
  await _stopAndWait(xray: xray, state: state, changes: changes);

  debugPrint('DEVICE_EVIDENCE BLOCKED_APPS phase=bypass started=true');
  await _startAndWait(
    xray: xray,
    remark: '$_backendName blockedApps bypass',
    config: config,
    blockedApps: [
      for (var index = 0; index < 1000; index += 1)
        'dev.zikwall.flutter_xray.missing.$index',
      _testPackage,
    ],
    state: state,
    changes: changes,
  );
  final bypassed = await _waitForDifferentEgress(tunneled);
  expect(bypassed, isNot(tunneled));
  await _stopAndWait(xray: xray, state: state, changes: changes);
  debugPrint(
    'DEVICE_EVIDENCE BLOCKED_APPS passed=true unavailable_ignored=1000',
  );
}

Future<String> _waitForDifferentEgress(String tunneled) async {
  String lastEgress = tunneled;
  Object? lastError;
  for (var attempt = 0; attempt < 15; attempt += 1) {
    try {
      lastEgress =
          (await _downloadText(
            Uri.parse(_egressUrl),
          ).timeout(const Duration(seconds: 4))).trim();
      if (lastEgress.isNotEmpty && lastEgress != tunneled) return lastEgress;
      lastError = null;
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  if (lastError != null && lastEgress == tunneled) {
    Error.throwWithStackTrace(lastError, StackTrace.current);
  }
  return lastEgress;
}

Future<void> _waitForState({
  required String expected,
  required String Function() current,
  required Stream<String> changes,
}) async {
  if (current() == expected) return;
  await changes
      .firstWhere((state) => state == expected)
      .timeout(
        const Duration(seconds: 20),
        onTimeout:
            () =>
                throw TimeoutException(
                  'Timed out waiting for $expected; current state is ${current()}',
                ),
      );
}

Future<_DownloadResult> _download(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final stopwatch = Stopwatch()..start();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 30));
    expect(response.statusCode, inInclusiveRange(200, 299));
    var bytes = 0;
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      bytes += chunk.length;
    }
    stopwatch.stop();
    return _DownloadResult(bytes, stopwatch.elapsed);
  } finally {
    client.close(force: true);
  }
}

Future<_DownloadResult> _downloadWithRetry(Uri uri) async {
  Object? lastError;
  for (var attempt = 0; attempt < 3; attempt += 1) {
    try {
      return await _download(uri);
    } catch (error) {
      lastError = error;
      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
  }
  Error.throwWithStackTrace(lastError!, StackTrace.current);
}

Future<String> _downloadText(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 30));
    expect(response.statusCode, inInclusiveRange(200, 299));
    return await utf8.decoder
        .bind(response.timeout(const Duration(seconds: 30)))
        .join()
        .timeout(const Duration(seconds: 30));
  } finally {
    client.close(force: true);
  }
}

Future<Duration> _udpDnsQuery(
  InternetAddress server,
  int port,
  String hostname,
) async {
  final socket = await RawDatagramSocket.bind(
    server.type == InternetAddressType.IPv6
        ? InternetAddress.anyIPv6
        : InternetAddress.anyIPv4,
    0,
  );
  final random = Random.secure();
  final transactionId = random.nextInt(0x10000);
  final query = BytesBuilder(copy: false)..add([
    transactionId >> 8,
    transactionId & 0xff,
    0x01,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
  ]);
  for (final label in hostname.split('.')) {
    final encoded = ascii.encode(label);
    query
      ..addByte(encoded.length)
      ..add(encoded);
  }
  query.add([0x00, 0x00, 0x01, 0x00, 0x01]);

  final stopwatch = Stopwatch()..start();
  try {
    final response = socket
        .where((event) => event == RawSocketEvent.read)
        .map((_) => socket.receive())
        .where((datagram) => datagram != null)
        .cast<Datagram>()
        .first
        .timeout(const Duration(seconds: 10));
    final bytes = query.takeBytes();
    expect(socket.send(bytes, server, port), bytes.length);
    final datagram = await response;
    stopwatch.stop();
    expect(datagram.data.length, greaterThan(12));
    expect(datagram.data[0], transactionId >> 8);
    expect(datagram.data[1], transactionId & 0xff);
    expect(datagram.data[2] & 0x80, 0x80);
    return stopwatch.elapsed;
  } finally {
    socket.close();
  }
}

Future<List<String>> _udpDnsTxtQuery(
  InternetAddress server,
  int port,
  String hostname,
) async {
  final socket = await RawDatagramSocket.bind(
    server.type == InternetAddressType.IPv6
        ? InternetAddress.anyIPv6
        : InternetAddress.anyIPv4,
    0,
  );
  final random = Random.secure();
  final transactionId = random.nextInt(0x10000);
  final query = BytesBuilder(copy: false)..add([
    transactionId >> 8,
    transactionId & 0xff,
    0x01,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
  ]);
  for (final label in hostname.split('.')) {
    final encoded = ascii.encode(label);
    query
      ..addByte(encoded.length)
      ..add(encoded);
  }
  query.add([0x00, 0x00, 0x10, 0x00, 0x01]);

  try {
    final response = socket
        .where((event) => event == RawSocketEvent.read)
        .map((_) => socket.receive())
        .where((datagram) => datagram != null)
        .cast<Datagram>()
        .first
        .timeout(const Duration(seconds: 10));
    final bytes = query.takeBytes();
    expect(socket.send(bytes, server, port), bytes.length);
    final packet = (await response).data;
    expect(packet.length, greaterThan(12));
    expect(packet[0], transactionId >> 8);
    expect(packet[1], transactionId & 0xff);
    expect(packet[2] & 0x80, 0x80);
    return _dnsTxtAnswers(packet);
  } finally {
    socket.close();
  }
}

List<String> _dnsTxtAnswers(Uint8List packet) {
  if (packet.length < 12) {
    throw const FormatException('Truncated DNS response');
  }
  final questionCount = _dnsUint16(packet, 4);
  final answerCount = _dnsUint16(packet, 6);
  var offset = 12;
  for (var index = 0; index < questionCount; index += 1) {
    offset = _skipDnsName(packet, offset);
    if (offset + 4 > packet.length) {
      throw const FormatException('Truncated DNS question');
    }
    offset += 4;
  }

  final answers = <String>[];
  for (var index = 0; index < answerCount; index += 1) {
    offset = _skipDnsName(packet, offset);
    if (offset + 10 > packet.length) {
      throw const FormatException('Truncated DNS answer');
    }
    final type = _dnsUint16(packet, offset);
    final dnsClass = _dnsUint16(packet, offset + 2);
    final dataLength = _dnsUint16(packet, offset + 8);
    offset += 10;
    final dataEnd = offset + dataLength;
    if (dataEnd > packet.length) {
      throw const FormatException('Truncated DNS answer data');
    }
    if (type == 16 && dnsClass == 1) {
      final text = BytesBuilder(copy: false);
      while (offset < dataEnd) {
        final length = packet[offset];
        offset += 1;
        if (offset + length > dataEnd) {
          throw const FormatException('Truncated DNS TXT segment');
        }
        text.add(packet.sublist(offset, offset + length));
        offset += length;
      }
      answers.add(utf8.decode(text.takeBytes()));
    } else {
      offset = dataEnd;
    }
  }
  return answers;
}

int _skipDnsName(Uint8List packet, int offset) {
  while (offset < packet.length) {
    final length = packet[offset];
    if (length == 0) return offset + 1;
    if (length & 0xc0 == 0xc0) {
      if (offset + 2 > packet.length) {
        throw const FormatException('Truncated DNS name pointer');
      }
      return offset + 2;
    }
    if (length & 0xc0 != 0 || offset + 1 + length > packet.length) {
      throw const FormatException('Invalid DNS name');
    }
    offset += 1 + length;
  }
  throw const FormatException('Truncated DNS name');
}

int _dnsUint16(Uint8List packet, int offset) {
  if (offset + 2 > packet.length) {
    throw const FormatException('Truncated DNS integer');
  }
  return packet[offset] << 8 | packet[offset + 1];
}

Future<Duration> _udpEcho(InternetAddress server, int port) async {
  final socket = await RawDatagramSocket.bind(
    server.type == InternetAddressType.IPv6
        ? InternetAddress.anyIPv6
        : InternetAddress.anyIPv4,
    0,
  );
  final payload = List<int>.generate(32, (index) => index);
  final stopwatch = Stopwatch()..start();
  try {
    final response = socket
        .where((event) => event == RawSocketEvent.read)
        .map((_) => socket.receive())
        .where((datagram) => datagram != null)
        .cast<Datagram>()
        .first
        .timeout(const Duration(seconds: 10));
    expect(socket.send(payload, server, port), payload.length);
    final datagram = await response;
    stopwatch.stop();
    expect(datagram.data, orderedEquals(payload));
    return stopwatch.elapsed;
  } finally {
    socket.close();
  }
}

void _evidence(
  String name,
  _DownloadResult result, {
  required String profileId,
  required int run,
}) {
  final seconds =
      result.elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  final megabitsPerSecond =
      seconds == 0 ? 0 : result.bytes * 8 / seconds / 1000000;
  debugPrint(
    'DEVICE_EVIDENCE $name profile=$profileId run=$run bytes=${result.bytes} '
    'elapsed_ms=${result.elapsed.inMilliseconds} '
    'mbps=${megabitsPerSecond.toStringAsFixed(2)}',
  );
}

final class _DeviceProfile {
  const _DeviceProfile(this.id, this.config);

  final String id;
  final String config;
}

final class _DownloadResult {
  const _DownloadResult(this.bytes, this.elapsed);

  final int bytes;
  final Duration elapsed;
}
