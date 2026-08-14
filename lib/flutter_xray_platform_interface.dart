import 'package:flutter_xray/model/xray_status.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_xray_method_channel.dart';

/// The interface that implementations of flutter_xray must implement.
///
/// Platform implementations should extend this class rather than implement it as flutter_xray
/// does not consider newly added methods to be breaking changes. Extending this class
/// (using `extends`) ensures that the subclass will get the default implementation, while
/// platform implementations that `implements` this interface will be broken by newly added methods.
abstract class FlutterXrayPlatform extends PlatformInterface {
  /// Constructs a FlutterXrayPlatform.
  FlutterXrayPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterXrayPlatform _instance = MethodChannelFlutterXray();

  /// The default instance of [FlutterXrayPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterXray].
  static FlutterXrayPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterXrayPlatform] when
  /// they register themselves.
  static set instance(FlutterXrayPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Requests permission to use Android VPN features.
  /// Returns a [Future] that completes with a [bool] indicating whether permission was granted.
  Future<bool> requestPermission() {
    throw UnimplementedError('requestPermission() has not been implemented.');
  }

  /// Initializes Xray with a status callback and notification settings.
  /// [onStatusChanged] is invoked when the Xray status changes.
  /// [notificationIconResourceType] specifies the type of the notification icon resource (e.g., 'mipmap').
  /// [notificationIconResourceName] specifies the name of the notification icon resource (e.g., 'ic_launcher').
  /// Returns a [Future] that completes when initialization is done.
  Future<void> initialize({
    required void Function(XrayStatus status) onStatusChanged,
    required String notificationIconResourceType,
    required String notificationIconResourceName,
  }) {
    throw UnimplementedError('initialize() has not been implemented.');
  }

  /// Starts the Xray connection with the given configuration and settings.
  /// [remark] is a string identifier for the connection.
  /// [config] is the Xray configuration in JSON format.
  /// [notificationDisconnectButtonName] is the text for the disconnect button in notifications.
  /// [blockedApps] is an optional list of apps to block.
  /// [bypassSubnets] is an optional list of subnets to bypass.
  /// [proxyOnly] is a boolean indicating whether to use proxy-only mode (default is false).
  /// [tunnelBackend] is an optional native backend identifier.
  /// Returns a [Future] that completes when the connection starts.
  Future<void> start({
    required String remark,
    required String config,
    required String notificationDisconnectButtonName,
    List<String>? blockedApps,
    List<String>? bypassSubnets,
    bool proxyOnly = false,
    String? tunnelBackend,
  }) {
    throw UnimplementedError('start() has not been implemented.');
  }

  /// Stops the Xray connection.
  /// Returns a [Future] that completes when the connection is stopped.
  Future<void> stop() {
    throw UnimplementedError('stop() has not been implemented.');
  }

  /// Measures delay using the provided Xray configuration and URL.
  /// [config] is the Xray configuration in JSON format.
  /// [url] is the server URL to test.
  /// Returns a [Future] that completes with the delay in milliseconds.
  Future<int> getServerDelay({required String config, required String url}) {
    throw UnimplementedError('getServerDelay() has not been implemented.');
  }

  /// Measures delay through the current Xray connection.
  /// [url] is the server URL to test.
  /// Returns a [Future] that completes with the delay in milliseconds.
  Future<int> getConnectedServerDelay(String url) async {
    throw UnimplementedError(
      'getConnectedServerDelay() has not been implemented.',
    );
  }

  /// Retrieves the version of the Xray core.
  /// Returns a [Future] that completes with a [String] representing the core version.
  Future<String> getCoreVersion() async {
    throw UnimplementedError(
      'getCoreVersion() has not been implemented.',
    );
  }

  /// Retrieves Xray logs from the system logcat.
  /// Returns a [Future] that completes with a [List] of log lines.
  /// On non-Android platforms, returns an empty list.
  Future<List<String>> getLogs() async {
    throw UnimplementedError(
      'getLogs() has not been implemented.',
    );
  }

  /// Clears Xray logs from the system logcat.
  /// Returns a [Future] that completes with a [bool] indicating success.
  /// On non-Android platforms, returns true.
  Future<bool> clearLogs() async {
    throw UnimplementedError(
      'clearLogs() has not been implemented.',
    );
  }
}
