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
const _holdSeconds = int.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_HOLD_SECONDS',
  defaultValue: 0,
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
  defaultValue: 'https://speed.cloudflare.com/__down?bytes=1000000',
);
const _udpEchoAddress = String.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_UDP_ECHO_ADDRESS',
);
const _udpEchoPort = int.fromEnvironment(
  'FLUTTER_XRAY_DEVICE_UDP_ECHO_PORT',
  defaultValue: 19000,
);

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
    'HEV physical-device packet path and lifecycle',
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
        await xray.stop();
      });

      await xray.initialize();
      expect(await xray.requestPermission(), isTrue);
      debugPrint(
        'DEVICE_EVIDENCE CONFIG cycles=$_lifecycleCycles '
        'require_udp=$_requireUdp hold_seconds=$_holdSeconds',
      );

      for (var cycle = 0; cycle < _lifecycleCycles; cycle += 1) {
        await xray.start(
          remark: 'HEV device lifecycle $cycle',
          config: _directConfig,
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await xray.stop();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      await xray.start(remark: 'HEV device packet path', config: _directConfig);
      await _waitForState(
        expected: 'CONNECTED',
        current: () => state,
        changes: stateChanges.stream,
      );

      final ipv4Result = await _download(Uri.parse(_ipv4Url));
      expect(ipv4Result.bytes, greaterThan(0));
      _evidence('IPV4_TCP', ipv4Result);

      if (_ipv6Url.isNotEmpty) {
        final ipv6Result = await _download(Uri.parse(_ipv6Url));
        expect(ipv6Result.bytes, greaterThan(0));
        _evidence('IPV6_TCP', ipv6Result);
      }

      final throughput = await _download(Uri.parse(_throughputUrl));
      expect(throughput.bytes, greaterThanOrEqualTo(100000));
      _evidence('THROUGHPUT', throughput);

      if (_requireUdp) {
        if (_udpEchoAddress.isNotEmpty) {
          final echoLatency = await _udpEcho(
            InternetAddress(_udpEchoAddress),
            _udpEchoPort,
          );
          debugPrint(
            'DEVICE_EVIDENCE UDP_ECHO latency_ms=${echoLatency.inMilliseconds}',
          );
        } else {
          final dnsLatency = await _udpDnsQuery(
            InternetAddress('1.1.1.1'),
            'example.com',
          );
          debugPrint(
            'DEVICE_EVIDENCE UDP_DNS latency_ms=${dnsLatency.inMilliseconds}',
          );
        }
      } else {
        debugPrint('DEVICE_EVIDENCE UDP_DNS skipped=true');
      }

      if (_holdSeconds > 0) {
        debugPrint('DEVICE_EVIDENCE HOLD_STARTED seconds=$_holdSeconds');
        await Future<void>.delayed(Duration(seconds: _holdSeconds));
        final afterHold = await _download(Uri.parse(_ipv4Url));
        expect(afterHold.bytes, greaterThan(0));
        _evidence('AFTER_HOLD', afterHold);
      }

      await xray.stop();
      await _waitForState(
        expected: 'DISCONNECTED',
        current: () => state,
        changes: stateChanges.stream,
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
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

Future<Duration> _udpDnsQuery(InternetAddress server, String hostname) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
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
    expect(socket.send(bytes, server, 53), bytes.length);
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

Future<Duration> _udpEcho(InternetAddress server, int port) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
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

void _evidence(String name, _DownloadResult result) {
  final seconds =
      result.elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  final megabitsPerSecond =
      seconds == 0 ? 0 : result.bytes * 8 / seconds / 1000000;
  debugPrint(
    'DEVICE_EVIDENCE $name bytes=${result.bytes} '
    'elapsed_ms=${result.elapsed.inMilliseconds} '
    'mbps=${megabitsPerSecond.toStringAsFixed(2)}',
  );
}

final class _DownloadResult {
  const _DownloadResult(this.bytes, this.elapsed);

  final int bytes;
  final Duration elapsed;
}
