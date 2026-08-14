import Flutter
import UIKit

public class FlutterXrayPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    // iOS support is currently not implemented; keeping channel for API parity.
    let channel = FlutterMethodChannel(name: "flutter_xray", binaryMessenger: registrar.messenger())
    let instance = FlutterXrayPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
