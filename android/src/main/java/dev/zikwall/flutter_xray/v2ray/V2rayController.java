package dev.zikwall.flutter_xray.v2ray;

import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.os.Build;
import android.util.Log;

import dev.zikwall.flutter_xray.tunnel.TunnelBackendKind;
import dev.zikwall.flutter_xray.v2ray.core.V2rayCoreManager;
import dev.zikwall.flutter_xray.v2ray.services.V2rayProxyOnlyService;
import dev.zikwall.flutter_xray.v2ray.services.V2rayVPNService;
import dev.zikwall.flutter_xray.v2ray.services.VpnNetworkBuilder;
import dev.zikwall.flutter_xray.v2ray.utils.AppConfigs;
import dev.zikwall.flutter_xray.v2ray.utils.Utilities;

import java.util.ArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import libv2ray.Libv2ray;

public class V2rayController {
    private static final ConnectionLifecycleGuard CONNECTION_LIFECYCLE =
            new ConnectionLifecycleGuard();

    public static void init(final Context context, final int app_icon, final String app_name) {
        Utilities.copyAssets(context);
        AppConfigs.APPLICATION_ICON = app_icon;
        AppConfigs.APPLICATION_NAME = app_name;
    }

    public static void StartV2ray(final Context context, final String remark, final String config,
            final ArrayList<String> blocked_apps, final ArrayList<String> bypass_subnets,
            final String tunnel_backend,
            final AppConfigs.V2RAY_CONNECTION_MODES connectionMode) {
        if (!CONNECTION_LIFECYCLE.reserveStart()) {
            throw new IllegalStateException("An Xray connection is already starting or running");
        }
        AppConfigs.V2RAY_CONNECTION_MODE = connectionMode;
        final Intent start_intent;
        try {
            AppConfigs.V2RAY_CONFIG = Utilities.parseV2rayJsonFile(
                    remark, config, blocked_apps, bypass_subnets);
            if (AppConfigs.V2RAY_CONFIG == null) {
                throw new IllegalArgumentException(
                        "Xray configuration is invalid or has no inbounds array");
            }
            TunnelBackendKind backendKind = TunnelBackendKind.fromConfigValue(tunnel_backend);
            AppConfigs.V2RAY_CONFIG.TUNNEL_BACKEND = tunnel_backend;
            if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY) {
                start_intent = new Intent(context, V2rayProxyOnlyService.class);
            } else if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN) {
                AppConfigs.V2RAY_CONFIG.BLOCKED_APPS = installedBlockedApplications(
                        context, AppConfigs.V2RAY_CONFIG.BLOCKED_APPS);
                VpnNetworkBuilder.validate(AppConfigs.V2RAY_CONFIG, backendKind);
                start_intent = new Intent(context, V2rayVPNService.class);
            } else {
                AppConfigs.V2RAY_CONFIG = null;
                throw new IllegalArgumentException("Unsupported Xray connection mode");
            }
        } catch (RuntimeException error) {
            AppConfigs.V2RAY_CONFIG = null;
            CONNECTION_LIFECYCLE.cancelStart();
            throw error;
        }
        start_intent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE);
        start_intent.putExtra("V2RAY_CONFIG", AppConfigs.V2RAY_CONFIG);
        start_intent.putExtra(AppConfigs.EXTRA_APPLICATION_NAME, AppConfigs.V2RAY_CONFIG.APPLICATION_NAME);
        start_intent.putExtra(AppConfigs.EXTRA_APPLICATION_ICON, AppConfigs.V2RAY_CONFIG.APPLICATION_ICON);
        if (Build.VERSION.SDK_INT > Build.VERSION_CODES.N_MR1) {
            try {
                context.startForegroundService(start_intent);
            } catch (RuntimeException error) {
                AppConfigs.V2RAY_CONFIG = null;
                CONNECTION_LIFECYCLE.cancelStart();
                throw error;
            }
        } else {
            try {
                context.startService(start_intent);
            } catch (RuntimeException error) {
                AppConfigs.V2RAY_CONFIG = null;
                CONNECTION_LIFECYCLE.cancelStart();
                throw error;
            }
        }
    }

    private static ArrayList<String> installedBlockedApplications(
            Context context, ArrayList<String> blockedApplications) {
        return BlockedApplicationFilter.installedOnly(
                blockedApplications,
                packageName -> {
                    try {
                        context.getPackageManager().getApplicationInfo(packageName, 0);
                        return true;
                    } catch (PackageManager.NameNotFoundException error) {
                        return false;
                    }
                },
                message -> Log.w("V2rayController", message));
    }

    public static void StopV2ray(final Context context) {
        if (getConnectionState() == AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED) {
            AppConfigs.V2RAY_CONFIG = null;
            return;
        }
        Intent stop_intent;
        if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY) {
            stop_intent = new Intent(context, V2rayProxyOnlyService.class);
        } else if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN) {
            stop_intent = new Intent(context, V2rayVPNService.class);
        } else {
            return;
        }
        // VpnService may remain system-bound after Context.stopService(). Send
        // an explicit command so the service releases the VPN interface and
        // calls stopSelf(). STOP_SERVICE never promotes foreground state.
        stop_intent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE);
        context.startService(stop_intent);
        AppConfigs.V2RAY_CONFIG = null;
    }

    public static long getConnectedV2rayServerDelay(Context context, String url) {
        if (V2rayController.getConnectionState() != AppConfigs.V2RAY_STATES.V2RAY_CONNECTED) {
            return -1;
        }
        Intent check_delay;
        if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY) {
            check_delay = new Intent(context, V2rayProxyOnlyService.class);
        } else if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN) {
            check_delay = new Intent(context, V2rayVPNService.class);
        } else {
            return -1;
        }
        final long[] delay = { -1 };

        final CountDownLatch latch = new CountDownLatch(1);
        android.content.BroadcastReceiver receiver = new android.content.BroadcastReceiver() {
            @Override
            public void onReceive(Context arg0, Intent arg1) {
                String delayString = arg1.getStringExtra("DELAY");
                if (delayString != null) {
                    try {
                        delay[0] = Long.parseLong(delayString);
                    } catch (NumberFormatException error) {
                        Log.w("V2rayController", "Connected delay is not numeric", error);
                    }
                }
                latch.countDown();
            }
        };

        // Use package-specific intent filter to isolate broadcasts per app
        String packageName = context.getPackageName();
        IntentFilter delayIntentFilter = new IntentFilter(packageName + ".CONNECTED_V2RAY_SERVER_DELAY");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.registerReceiver(receiver, delayIntentFilter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            context.registerReceiver(receiver, delayIntentFilter);
        }

        try {
            check_delay.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.MEASURE_DELAY);
            check_delay.putExtra(AppConfigs.EXTRA_DELAY_URL, url);
            context.startService(check_delay);
            boolean received = latch.await(3000, TimeUnit.MILLISECONDS);
            if (!received) {
                return -1;
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return -1;
        } finally {
            try {
                context.unregisterReceiver(receiver);
            } catch (IllegalArgumentException error) {
                Log.w("V2rayController", "Connected-delay receiver was already unregistered", error);
            }
        }
        return delay[0];
    }

    public static long getV2rayServerDelay(final String config, final String url) {
        return V2rayCoreManager.getInstance().getV2rayServerDelay(config, url);
    }

    public static AppConfigs.V2RAY_CONNECTION_MODES getConnectionMode() {
        return AppConfigs.V2RAY_CONNECTION_MODE;
    }

    public static AppConfigs.V2RAY_STATES getConnectionState() {
        return CONNECTION_LIFECYCLE.state();
    }

    static void onConnectionStateChanged(AppConfigs.V2RAY_STATES state) {
        CONNECTION_LIFECYCLE.update(state);
    }

    public static String getCoreVersion() {
        return Libv2ray.checkVersionX();
    }

}
