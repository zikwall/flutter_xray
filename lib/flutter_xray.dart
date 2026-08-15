import 'dart:convert';
import 'dart:io';

import 'package:flutter_xray/url/hysteria.dart';
import 'package:flutter_xray/url/shadowsocks.dart';
import 'package:flutter_xray/url/socks.dart';
import 'package:flutter_xray/url/trojan.dart';
import 'package:flutter_xray/url/url.dart';
import 'package:flutter_xray/url/vless.dart';
import 'package:flutter_xray/url/vmess.dart';

import 'flutter_xray_platform_interface.dart';
import 'model/tunnel_backend.dart';
import 'model/xray_status.dart';

export 'model/tunnel_backend.dart';
export 'model/xray_status.dart';
export 'url/url.dart';

/// Controls the embedded Xray core.
/// Provides methods to initialize, start, stop, and query Xray services.
class Xray {
  /// Creates a new Xray instance.
  /// [onStatusChanged] is called whenever the Xray connection status changes.
  Xray({required this.onStatusChanged});

  /// Callback function invoked when the Xray status changes.
  /// It receives an [XrayStatus] with connection and traffic details.
  final void Function(XrayStatus status) onStatusChanged;

  /// Requests permission to use VPN access on Android.
  /// Returns a [Future] that completes with true if permission is granted, otherwise false.
  /// On non-Android platforms, it defaults to granting permission.
  Future<bool> requestPermission() async {
    if (Platform.isAndroid) {
      return FlutterXrayPlatform.instance.requestPermission();
    }
    return true;
  }

  /// Initializes the Xray client with notification settings and a status callback.
  /// [notificationIconResourceType] specifies the type of the notification icon (e.g., 'mipmap').
  /// [notificationIconResourceName] specifies the name of the notification icon (e.g., 'ic_launcher').
  /// Returns a [Future] that completes when initialization is done.
  Future<void> initialize({
    String notificationIconResourceType = 'mipmap',
    String notificationIconResourceName = 'ic_launcher',
  }) async {
    await FlutterXrayPlatform.instance.initialize(
      onStatusChanged: onStatusChanged,
      notificationIconResourceType: notificationIconResourceType,
      notificationIconResourceName: notificationIconResourceName,
    );
  }

  /// Starts Xray with the given configuration and settings.
  /// [remark] is a string identifier for the connection.
  /// [config] is the Xray configuration in JSON format.
  /// [blockedApps] is an optional list of app package names to block.
  /// [bypassSubnets] is an optional list of subnets to bypass the VPN.
  /// [proxyOnly] is a boolean indicating whether to run in proxy-only mode.
  /// [tunnelBackend] selects the Android packet tunnel implementation for this
  /// connection. BadVPN is the explicit package default.
  /// [notificationDisconnectButtonName] is the text for the disconnect button in notifications.
  /// Throws an [ArgumentError] if the config is not valid JSON.
  /// Returns a [Future] that completes when the service starts.
  Future<void> start({
    required String remark,
    required String config,
    List<String>? blockedApps,
    List<String>? bypassSubnets,
    bool proxyOnly = false,
    TunnelBackend tunnelBackend = TunnelBackend.badVpn,
    String notificationDisconnectButtonName = 'DISCONNECT',
  }) async {
    try {
      if (jsonDecode(config) == null) {
        throw ArgumentError('The provided string is not valid JSON');
      }
    } catch (_) {
      throw ArgumentError('The provided string is not valid JSON');
    }

    await FlutterXrayPlatform.instance.start(
      remark: remark,
      config: config,
      blockedApps: blockedApps,
      proxyOnly: proxyOnly,
      bypassSubnets: bypassSubnets,
      notificationDisconnectButtonName: notificationDisconnectButtonName,
      tunnelBackend: tunnelBackend.configValue,
    );
  }

  /// Stops Xray.
  /// Returns a [Future] that completes when the service is stopped.
  Future<void> stop() async {
    await FlutterXrayPlatform.instance.stop();
  }

  /// Measures the delay using the provided Xray configuration.
  /// [config] is the Xray configuration in JSON format.
  /// [url] is the server URL to test for delay (default is 'https://google.com/generate_204').
  /// Throws an [ArgumentError] if the config is not valid JSON.
  /// Returns a [Future] that completes with the delay in milliseconds.
  Future<int> getServerDelay({
    required String config,
    String url = 'https://google.com/generate_204',
  }) async {
    try {
      if (jsonDecode(config) == null) {
        throw ArgumentError('The provided string is not valid JSON');
      }
    } catch (_) {
      throw ArgumentError('The provided string is not valid JSON');
    }
    return FlutterXrayPlatform.instance
        .getServerDelay(config: config, url: url);
  }

  /// Measures the delay through the current Xray connection.
  /// [url] is the server URL to test for delay (default is 'https://google.com/generate_204').
  /// Returns a [Future] that completes with the delay in milliseconds.
  Future<int> getConnectedServerDelay({
    String url = 'https://google.com/generate_204',
  }) async {
    return FlutterXrayPlatform.instance.getConnectedServerDelay(url);
  }

  /// Retrieves the version of the embedded Xray core.
  Future<String> getCoreVersion() async {
    return FlutterXrayPlatform.instance.getCoreVersion();
  }

  /// Retrieves Xray logs from the system logcat.
  /// Returns a [Future] that completes with a [List] of log lines.
  /// On Android, this fetches logs filtered by Xray-related tags.
  /// On non-Android platforms, returns an empty list.
  Future<List<String>> getLogs() async {
    if (Platform.isAndroid) {
      return FlutterXrayPlatform.instance.getLogs();
    }
    return [];
  }

  /// Clears Xray logs from the system logcat.
  /// Returns a [Future] that completes with a [bool] indicating success.
  /// On Android, this clears the logcat buffer.
  /// On non-Android platforms, returns true.
  Future<bool> clearLogs() async {
    if (Platform.isAndroid) {
      return FlutterXrayPlatform.instance.clearLogs();
    }
    return true;
  }

  /// Parses an Xray-compatible share link.
  /// [url] is a share link (e.g., 'vmess://', 'vless://', etc.).
  /// Throws an [ArgumentError] if the URL scheme is invalid.
  /// Returns an [XrayURL] instance based on the scheme.
  static XrayURL parseFromURL(String url) {
    switch (url.split('://')[0].toLowerCase()) {
      case 'vmess':
        return VmessURL(url: url);
      case 'vless':
        return VlessURL(url: url);
      case 'trojan':
        return TrojanURL(url: url);
      case 'ss':
        return ShadowSocksURL(url: url);
      case 'socks':
        return SocksURL(url: url);
      case 'hysteria':
      case 'hysteria2':
      case 'hy':
      case 'hy2':
        return HysteriaURL(url: url);
      default:
        throw ArgumentError('url is invalid');
    }
  }
}
