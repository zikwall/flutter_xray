package dev.zikwall.flutter_xray.v2ray;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;

import dev.zikwall.flutter_xray.tunnel.TunnelBackendKind;
import dev.zikwall.flutter_xray.v2ray.core.V2rayCoreManager;
import dev.zikwall.flutter_xray.v2ray.services.V2rayProxyOnlyService;
import dev.zikwall.flutter_xray.v2ray.services.V2rayVPNService;
import dev.zikwall.flutter_xray.v2ray.utils.AppConfigs;
import dev.zikwall.flutter_xray.v2ray.utils.Utilities;

import java.util.ArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import libv2ray.Libv2ray;

public class V2rayController {

    public static void init(final Context context, final int app_icon, final String app_name) {
        Utilities.copyAssets(context);
        AppConfigs.APPLICATION_ICON = app_icon;
        AppConfigs.APPLICATION_NAME = app_name;

        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context arg0, Intent arg1) {
                AppConfigs.V2RAY_STATE = (AppConfigs.V2RAY_STATES) arg1.getExtras().getSerializable("STATE");
            }
        };
        // Use package-specific intent filter to isolate broadcasts per app
        String packageName = context.getPackageName();
        IntentFilter filter = new IntentFilter(packageName + ".V2RAY_CONNECTION_INFO");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            context.registerReceiver(receiver, filter);
        }
    }

    public static void changeConnectionMode(final AppConfigs.V2RAY_CONNECTION_MODES connection_mode) {
        if (getConnectionState() == AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED) {
            AppConfigs.V2RAY_CONNECTION_MODE = connection_mode;
        }
    }

    public static void StartV2ray(final Context context, final String remark, final String config,
            final ArrayList<String> blocked_apps, final ArrayList<String> bypass_subnets,
            final String tunnel_backend) {
        AppConfigs.V2RAY_CONFIG = Utilities.parseV2rayJsonFile(remark, config, blocked_apps, bypass_subnets);
        if (AppConfigs.V2RAY_CONFIG == null) {
            throw new IllegalArgumentException("Xray configuration is invalid or has no inbounds array");
        }
        TunnelBackendKind.fromConfigValue(tunnel_backend);
        AppConfigs.V2RAY_CONFIG.TUNNEL_BACKEND = tunnel_backend;
        Intent start_intent;
        if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY) {
            start_intent = new Intent(context, V2rayProxyOnlyService.class);
        } else if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN) {
            start_intent = new Intent(context, V2rayVPNService.class);
        } else {
            return;
        }
        start_intent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE);
        start_intent.putExtra("V2RAY_CONFIG", AppConfigs.V2RAY_CONFIG);
        if (Build.VERSION.SDK_INT > Build.VERSION_CODES.N_MR1) {
            try {
                context.startForegroundService(start_intent);
            } catch (RuntimeException error) {
                AppConfigs.V2RAY_CONFIG = null;
                throw error;
            }
        } else {
            try {
                context.startService(start_intent);
            } catch (RuntimeException error) {
                AppConfigs.V2RAY_CONFIG = null;
                throw error;
            }
        }
    }

    public static void StopV2ray(final Context context) {
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

    public static long getConnectedV2rayServerDelay(Context context) {
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
        check_delay.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.MEASURE_DELAY);
        context.startService(check_delay);
        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context arg0, Intent arg1) {
                String delayString = arg1.getExtras().getString("DELAY");
                delay[0] = Long.parseLong(delayString);
                context.unregisterReceiver(this);
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
            boolean received = latch.await(3000, TimeUnit.MILLISECONDS);
            if (!received) {
                return -1;
            }
        } catch (InterruptedException e) {
            e.printStackTrace();
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
        return AppConfigs.V2RAY_STATE;
    }

    public static String getCoreVersion() {
        return Libv2ray.checkVersionX();
    }

}
