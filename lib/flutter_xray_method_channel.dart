import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_xray_platform_interface.dart';
import 'model/xray_status.dart' show XrayStatus;

/// An implementation of [FlutterXrayPlatform] that uses method channels.
class MethodChannelFlutterXray extends FlutterXrayPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_xray');

  /// The event channel used to receive status updates from the native platform.
  final eventChannel = const EventChannel('flutter_xray/status');

  StreamSubscription<Object?>? _statusSubscription;

  @override
  Future<void> initialize({
    required void Function(XrayStatus status) onStatusChanged,
    void Function(Object error, StackTrace stackTrace)? onStatusError,
    required String notificationIconResourceType,
    required String notificationIconResourceName,
  }) async {
    await methodChannel.invokeMethod<void>(
      'initialize',
      {
        'notificationIconResourceType': notificationIconResourceType,
        'notificationIconResourceName': notificationIconResourceName,
      },
    );
    await _statusSubscription?.cancel();
    _statusSubscription =
        eventChannel.receiveBroadcastStream().distinct().listen(
      (event) {
        try {
          onStatusChanged(XrayStatus.fromPlatformEvent(event));
        } catch (error, stackTrace) {
          if (onStatusError != null) {
            onStatusError(error, stackTrace);
          } else {
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stackTrace,
                library: 'flutter_xray',
                context: ErrorDescription('while decoding Xray status'),
              ),
            );
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (onStatusError != null) {
          onStatusError(error, stackTrace);
        } else {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'flutter_xray',
              context: ErrorDescription('while receiving Xray status'),
            ),
          );
        }
      },
    );
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
    await methodChannel.invokeMethod<void>('start', {
      'remark': remark,
      'config': config,
      'blocked_apps': blockedApps,
      'bypass_subnets': bypassSubnets,
      'proxy_only': proxyOnly,
      'tunnel_backend': tunnelBackend,
      'notificationDisconnectButtonName': notificationDisconnectButtonName,
    });
  }

  @override
  Future<void> stop() async {
    await methodChannel.invokeMethod<void>('stop');
  }

  @override
  Future<void> dispose() async {
    await _statusSubscription?.cancel();
    _statusSubscription = null;
  }

  @override
  Future<int> getServerDelay({
    required String config,
    required String url,
  }) async {
    final result = await methodChannel.invokeMethod<int>('getServerDelay', {
      'config': config,
      'url': url,
    });
    return _requireResult(result, 'getServerDelay');
  }

  @override
  Future<int> getConnectedServerDelay(String url) async {
    final result = await methodChannel.invokeMethod<int>(
      'getConnectedServerDelay',
      {'url': url},
    );
    return _requireResult(result, 'getConnectedServerDelay');
  }

  @override
  Future<bool> requestPermission() async {
    final result = await methodChannel.invokeMethod<bool>('requestPermission');
    return _requireResult(result, 'requestPermission');
  }

  @override
  Future<String> getCoreVersion() async {
    final result = await methodChannel.invokeMethod<String>('getCoreVersion');
    return _requireResult(result, 'getCoreVersion');
  }

  @override
  Future<List<String>> getLogs() async {
    return await methodChannel.invokeListMethod<String>('getLogs') ?? const [];
  }

  @override
  Future<bool> clearLogs() async {
    final result = await methodChannel.invokeMethod<bool>('clearLogs');
    return _requireResult(result, 'clearLogs');
  }

  T _requireResult<T>(T? result, String method) {
    if (result == null) {
      throw PlatformException(
        code: 'NULL_RESULT',
        message: '$method returned no result',
      );
    }
    return result;
  }
}
