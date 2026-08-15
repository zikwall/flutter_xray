package dev.zikwall.flutter_xray;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.VpnService;
import android.os.Build;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import dev.zikwall.flutter_xray.v2ray.V2rayController;
import dev.zikwall.flutter_xray.v2ray.V2rayReceiver;
import dev.zikwall.flutter_xray.v2ray.utils.AppConfigs;
import dev.zikwall.flutter_xray.v2ray.utils.LogcatManager;

import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * FlutterXrayPlugin
 */
public class FlutterXrayPlugin implements FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {

    private static final int REQUEST_CODE_VPN_PERMISSION = 24;
    private final ExecutorService executor = Executors.newCachedThreadPool();

    private MethodChannel vpnControlMethod;
    private EventChannel vpnStatusEvent;
    private EventChannel.EventSink vpnStatusSink;
    private Activity activity;
    private Context appContext;
    private BroadcastReceiver v2rayBroadCastReceiver;
    private boolean statusReceiverRegistered;
    private MethodChannel.Result pendingResult;

    @SuppressLint("DiscouragedApi")
    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        this.appContext = binding.getApplicationContext();
        vpnControlMethod = new MethodChannel(binding.getBinaryMessenger(), "flutter_xray");
        vpnStatusEvent = new EventChannel(binding.getBinaryMessenger(), "flutter_xray/status");
        try {
            // Keep lifecycle synchronization active even when Dart temporarily
            // cancels the optional status stream. The VPN service lives in a
            // separate Android process, so broadcasts are the state boundary.
            registerStatusReceiver();
        } catch (RuntimeException error) {
            Log.e("FlutterXrayPlugin", "Failed to register lifecycle receiver", error);
        }

        vpnStatusEvent.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                vpnStatusSink = events;
                V2rayReceiver.vpnStatusSink = vpnStatusSink;
                try {
                    registerStatusReceiver();
                } catch (Exception e) {
                    Log.e("FlutterXrayPlugin", "Failed to register broadcast receiver", e);
                    vpnStatusSink = null;
                    V2rayReceiver.vpnStatusSink = null;
                    events.error("STATUS_LISTENER_FAILED", e.getMessage(), e.getClass().getSimpleName());
                }
            }

            @Override
            public void onCancel(Object arguments) {
                vpnStatusSink = null;
                V2rayReceiver.vpnStatusSink = null;
            }
        });

        vpnControlMethod.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "start":
                    try {
                        AppConfigs.NOTIFICATION_DISCONNECT_BUTTON_NAME = call.argument("notificationDisconnectButtonName");
                        AppConfigs.V2RAY_CONNECTION_MODES connectionMode =
                                Boolean.TRUE.equals(call.argument("proxy_only"))
                                        ? AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY
                                        : AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN;
                        V2rayController.StartV2ray(binding.getApplicationContext(), call.argument("remark"),
                                call.argument("config"), call.argument("blocked_apps"), call.argument("bypass_subnets"),
                                call.argument("tunnel_backend"), connectionMode);
                        result.success(null);
                    } catch (RuntimeException error) {
                        Log.e("FlutterXrayPlugin", "Failed to start Xray service", error);
                        result.error("START_FAILED", error.getMessage(), error.getClass().getSimpleName());
                    }
                    break;
                case "stop":
                    try {
                        V2rayController.StopV2ray(binding.getApplicationContext());
                        result.success(null);
                    } catch (RuntimeException error) {
                        Log.e("FlutterXrayPlugin", "Failed to stop Xray service", error);
                        result.error("STOP_FAILED", error.getMessage(), error.getClass().getSimpleName());
                    }
                    break;
                case "initialize":
                    try {
                        String iconResourceName = call.argument("notificationIconResourceName");
                        String iconResourceType = call.argument("notificationIconResourceType");
                        Context context = binding.getApplicationContext();
                        int iconResourceId = context.getResources().getIdentifier(
                                iconResourceName, iconResourceType, context.getPackageName());
                        if (iconResourceId == 0) {
                            iconResourceId = context.getApplicationInfo().icon;
                        }
                        if (iconResourceId == 0) {
                            iconResourceId = android.R.drawable.stat_sys_warning;
                        }
                        CharSequence applicationLabel = context.getApplicationInfo()
                                .loadLabel(context.getPackageManager());
                        String applicationName = applicationLabel == null
                                ? context.getPackageName()
                                : applicationLabel.toString().trim();
                        if (applicationName.isEmpty()) {
                            applicationName = context.getPackageName();
                        }
                        V2rayController.init(context, iconResourceId, applicationName);
                        result.success(null);
                    } catch (RuntimeException error) {
                        Log.e("FlutterXrayPlugin", "Failed to initialize Xray", error);
                        result.error("INITIALIZE_FAILED", error.getMessage(), error.getClass().getSimpleName());
                    }
                    break;
                case "getServerDelay":
                    executor.submit(() -> {
                        try {
                            result.success(
                                    V2rayController.getV2rayServerDelay(call.argument("config"), call.argument("url")));
                        } catch (Exception e) {
                            Log.e("FlutterXrayPlugin", "Failed to measure server delay", e);
                            result.error("DELAY_FAILED", e.getMessage(), e.getClass().getSimpleName());
                        }
                    });
                    break;
                case "getConnectedServerDelay":
                    executor.submit(() -> {
                        try {
                            result.success(
                                    V2rayController.getConnectedV2rayServerDelay(
                                            binding.getApplicationContext(), call.argument("url")));
                        } catch (Exception e) {
                            Log.e("FlutterXrayPlugin", "Failed to measure connected delay", e);
                            result.error("DELAY_FAILED", e.getMessage(), e.getClass().getSimpleName());
                        }
                    });
                    break;
                case "getCoreVersion":
                    result.success(V2rayController.getCoreVersion());
                    break;
                case "requestPermission":
                    if (activity == null) {
                        result.error("NO_ACTIVITY", "Activity is not available for permission request", null);
                        return;
                    }

                    // Prevent concurrent permission requests which can lead to a null pendingResult when the
                    // activity result returns after a lifecycle change or a second request
                    if (pendingResult != null) {
                        result.error("ALREADY_ACTIVE", "A permission request is already running", null);
                        return;
                    }

                    final Intent request = VpnService.prepare(activity);
                    if (request != null) {
                        pendingResult = result;
                        activity.startActivityForResult(request, REQUEST_CODE_VPN_PERMISSION);
                    } else {
                        result.success(true);
                    }
                    break;
                case "getLogs":
                    executor.submit(() -> {
                        try {
                            String packageName = binding.getApplicationContext().getPackageName();
                            List<String> logs = LogcatManager.getInstance().getLogs(packageName);
                            result.success(logs);
                        } catch (Exception e) {
                            Log.e("FlutterXrayPlugin", "Failed to get logs", e);
                            result.error("LOG_ERROR", "Failed to retrieve logs: " + e.getMessage(), null);
                        }
                    });
                    break;
                case "clearLogs":
                    executor.submit(() -> {
                        try {
                            boolean success = LogcatManager.getInstance().clearLogs();
                            result.success(success);
                        } catch (Exception e) {
                            Log.e("FlutterXrayPlugin", "Failed to clear logs", e);
                            result.error("LOG_ERROR", "Failed to clear logs: " + e.getMessage(), null);
                        }
                    });
                    break;
                default:
                    result.notImplemented();
                    break;
            }
        });
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        unregisterStatusReceiver();
        vpnStatusSink = null;
        V2rayReceiver.vpnStatusSink = null;
        failPendingPermission("ENGINE_DETACHED", "Flutter engine detached during VPN permission request");
        vpnControlMethod.setMethodCallHandler(null);
        vpnStatusEvent.setStreamHandler(null);
        executor.shutdown();
        appContext = null;
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
        binding.addActivityResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        activity = null;
        failPendingPermission(
                "ACTIVITY_DETACHED",
                "Activity changed before receiving VPN permission result");
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
        binding.addActivityResultListener(this);
    }

    @Override
    public void onDetachedFromActivity() {
        activity = null;
        failPendingPermission(
                "ACTIVITY_DETACHED",
                "Activity detached before receiving VPN permission result");
    }

    @Override
    public boolean onActivityResult(int requestCode, int resultCode, @Nullable Intent data) {
        if (requestCode != REQUEST_CODE_VPN_PERMISSION) {
            return false; // Not handled by this plugin
        }

        MethodChannel.Result result = pendingResult;
        pendingResult = null;

        if (result == null) {
            return false; // Nothing to report (possibly after lifecycle change)
        }

        result.success(resultCode == Activity.RESULT_OK);
        return true;
    }

    private void registerStatusReceiver() {
        if (statusReceiverRegistered) {
            return;
        }
        if (appContext == null) {
            throw new IllegalStateException("Application context is unavailable");
        }
        if (v2rayBroadCastReceiver == null) {
            v2rayBroadCastReceiver = new V2rayReceiver();
        }
        String packageName = appContext.getPackageName();
        IntentFilter filter = new IntentFilter(packageName + ".V2RAY_CONNECTION_INFO");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appContext.registerReceiver(
                    v2rayBroadCastReceiver,
                    filter,
                    Context.RECEIVER_NOT_EXPORTED);
        } else {
            appContext.registerReceiver(v2rayBroadCastReceiver, filter);
        }
        statusReceiverRegistered = true;
    }

    private void unregisterStatusReceiver() {
        if (!statusReceiverRegistered || appContext == null || v2rayBroadCastReceiver == null) {
            statusReceiverRegistered = false;
            v2rayBroadCastReceiver = null;
            return;
        }
        try {
            appContext.unregisterReceiver(v2rayBroadCastReceiver);
        } catch (IllegalArgumentException error) {
            Log.w("FlutterXrayPlugin", "Status receiver was already unregistered", error);
        } finally {
            statusReceiverRegistered = false;
            v2rayBroadCastReceiver = null;
        }
    }

    private void failPendingPermission(String code, String message) {
        MethodChannel.Result result = pendingResult;
        pendingResult = null;
        if (result != null) {
            result.error(code, message, null);
        }
    }
}
