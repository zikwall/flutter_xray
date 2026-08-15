import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xray/flutter_xray.dart';
import 'package:flutter_xray/flutter_xray_platform_interface.dart';

class FakeFlutterXrayPlatform extends FlutterXrayPlatform {
  String? startedRemark;
  String? startedConfig;
  List<String>? startedBlockedApps;
  List<String>? startedBypassSubnets;
  bool? startedProxyOnly;
  String? startedTunnelBackend;
  int serverDelay = 42;
  int disposeCalls = 0;

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
  }

  @override
  Future<void> start({
    required String remark,
    required String config,
    required String notificationDisconnectButtonName,
    List<String>? blockedApps,
    List<String>? bypassSubnets,
    bool proxyOnly = false,
    required String tunnelBackend,
  }) async {
    startedRemark = remark;
    startedConfig = config;
    startedBlockedApps = blockedApps;
    startedBypassSubnets = bypassSubnets;
    startedProxyOnly = proxyOnly;
    startedTunnelBackend = tunnelBackend;
  }

  @override
  Future<int> getServerDelay({
    required String config,
    required String url,
  }) async {
    return serverDelay;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('share-link parsing', () {
    test('parses VMess', () {
      const url =
          'vmess://eyJ2IjoiMiIsInBzIjoiVGVzdCBTZXJ2ZXIiLCJhZGQiOiIxMC4wLjAuMSIsInBvcnQiOiI0NDMiLCJpZCI6IjEyMzQ1Njc4LWFiY2QtMTIzNC1hYmNkLTEyMzQ1Njc4YWJjZCIsImFpZCI6IjAiLCJuZXQiOiJ0Y3AiLCJ0eXBlIjoibm9uZSIsImhvc3QiOiIiLCJwYXRoIjoiIiwidGxzIjoiIn0=';

      final parsed = Xray.parseFromURL(url);

      expect(parsed, isA<XrayURL>());
      expect(parsed.remark, 'Test Server');
    });

    test('parses VLESS', () {
      const url =
          'vless://12345678-abcd-1234-abcd-12345678abcd@10.0.0.1:443?type=tcp&security=tls&sni=example.com#Test VLESS';

      final parsed = Xray.parseFromURL(url);

      expect(parsed, isA<XrayURL>());
      expect(parsed.remark, 'Test VLESS');
      final config = jsonDecode(parsed.getFullConfiguration()) as Map;
      final outbound = (config['outbounds'] as List).first as Map;
      final streamSettings = outbound['streamSettings'] as Map;
      final tlsSettings = streamSettings['tlsSettings'] as Map;
      expect(tlsSettings.containsKey('publicKey'), isFalse);
      expect(tlsSettings.containsKey('shortId'), isFalse);
      expect(tlsSettings.containsKey('spiderX'), isFalse);
      final compact = parsed.getFullConfiguration(indent: 0);
      expect(compact.contains('\n'), isFalse);
      expect(jsonDecode(compact), config);
    });

    test('rejects invalid and unsupported schemes', () {
      expect(() => Xray.parseFromURL('invalid://url'), throwsArgumentError);
      expect(
        () => Xray.parseFromURL('unsupported://example.com'),
        throwsArgumentError,
      );
    });
  });

  group('configuration validation and delegation', () {
    late FakeFlutterXrayPlatform platform;
    late Xray xray;

    setUp(() {
      platform = FakeFlutterXrayPlatform();
      FlutterXrayPlatform.instance = platform;
      xray = Xray(onStatusChanged: (_) {});
    });

    test('passes a valid configuration and options to the platform', () async {
      const config = '{"inbounds": [], "outbounds": []}';

      await xray.start(
        remark: 'Test',
        config: config,
        blockedApps: const ['com.example.bypass'],
        bypassSubnets: const ['192.168.0.0/16'],
        proxyOnly: true,
        tunnelBackend: TunnelBackend.hev,
      );

      expect(platform.startedRemark, 'Test');
      expect(platform.startedConfig, config);
      expect(platform.startedBlockedApps, const ['com.example.bypass']);
      expect(platform.startedBypassSubnets, const ['192.168.0.0/16']);
      expect(platform.startedProxyOnly, isTrue);
      expect(platform.startedTunnelBackend, 'hev');
    });

    test('passes Xray native TUN backend to platform', () async {
      await xray.start(
        remark: 'native tun',
        config: '{"inbounds": [], "outbounds": []}',
        tunnelBackend: TunnelBackend.xray,
      );

      expect(platform.startedTunnelBackend, 'xray');
    });

    test('uses BadVPN as an explicit default', () async {
      await xray.start(
        remark: 'default',
        config: '{"inbounds": [], "outbounds": []}',
      );

      expect(platform.startedTunnelBackend, 'badvpn');
    });

    test('rejects an invalid start configuration before delegation', () async {
      await expectLater(
        xray.start(
          remark: 'Test',
          config: 'invalid json',
          proxyOnly: true,
        ),
        throwsArgumentError,
      );

      expect(platform.startedConfig, isNull);
    });

    test('rejects a valid JSON value that is not a configuration object',
        () async {
      await expectLater(
        xray.start(remark: 'Test', config: '[]'),
        throwsArgumentError,
      );

      expect(platform.startedConfig, isNull);
    });

    test('returns delay from the platform for valid JSON', () async {
      const config = '{"inbounds": [], "outbounds": []}';

      await expectLater(xray.getServerDelay(config: config), completion(42));
    });

    test('rejects an invalid delay configuration before delegation', () async {
      await expectLater(
        xray.getServerDelay(config: 'invalid json'),
        throwsArgumentError,
      );
    });

    test('dispose releases the platform status subscription', () async {
      await xray.dispose();

      expect(platform.disposeCalls, 1);
    });
  });

  group('status event contract', () {
    test('accepts numeric and string traffic fields', () {
      final status = XrayStatus.fromPlatformEvent([
        '00:00:05',
        '1',
        2,
        3.0,
        '4',
        'CONNECTED',
      ]);

      expect(status.duration, '00:00:05');
      expect(status.uploadSpeed, 1);
      expect(status.downloadSpeed, 2);
      expect(status.upload, 3);
      expect(status.download, 4);
      expect(status.state, 'CONNECTED');
    });

    test('rejects malformed platform events explicitly', () {
      expect(
        () => XrayStatus.fromPlatformEvent(['too', 'short']),
        throwsFormatException,
      );
      expect(
        () => XrayStatus.fromPlatformEvent([
          '00:00:00',
          'not-a-number',
          '0',
          '0',
          '0',
          'DISCONNECTED',
        ]),
        throwsFormatException,
      );
    });
  });
}
