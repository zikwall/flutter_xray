import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xray/flutter_xray.dart';
import 'package:flutter_xray/flutter_xray_platform_interface.dart';

class FakeFlutterXrayPlatform extends FlutterXrayPlatform {
  String? startedRemark;
  String? startedConfig;
  List<String>? startedBlockedApps;
  List<String>? startedBypassSubnets;
  bool? startedProxyOnly;
  int serverDelay = 42;

  @override
  Future<void> start({
    required String remark,
    required String config,
    required String notificationDisconnectButtonName,
    List<String>? blockedApps,
    List<String>? bypassSubnets,
    bool proxyOnly = false,
  }) async {
    startedRemark = remark;
    startedConfig = config;
    startedBlockedApps = blockedApps;
    startedBypassSubnets = bypassSubnets;
    startedProxyOnly = proxyOnly;
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
      );

      expect(platform.startedRemark, 'Test');
      expect(platform.startedConfig, config);
      expect(platform.startedBlockedApps, const ['com.example.bypass']);
      expect(platform.startedBypassSubnets, const ['192.168.0.0/16']);
      expect(platform.startedProxyOnly, isTrue);
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
  });
}
