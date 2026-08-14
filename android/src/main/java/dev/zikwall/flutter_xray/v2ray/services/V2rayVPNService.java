package dev.zikwall.flutter_xray.v2ray.services;

import android.app.Service;
import android.content.Intent;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import dev.zikwall.flutter_xray.tunnel.BadVpnTunnelBackend;
import dev.zikwall.flutter_xray.tunnel.HevTunnelBackend;
import dev.zikwall.flutter_xray.tunnel.HevTunnelConfig;
import dev.zikwall.flutter_xray.tunnel.TunnelBackend;
import dev.zikwall.flutter_xray.tunnel.TunnelBackendKind;
import dev.zikwall.flutter_xray.tunnel.TunnelBackendSelector;
import dev.zikwall.flutter_xray.tunnel.TunnelLifecycle;
import dev.zikwall.flutter_xray.v2ray.core.V2rayCoreManager;
import dev.zikwall.flutter_xray.v2ray.interfaces.V2rayServicesListener;
import dev.zikwall.flutter_xray.v2ray.utils.AppConfigs;
import dev.zikwall.flutter_xray.v2ray.utils.V2rayConfig;

import org.json.JSONArray;
import org.json.JSONObject;

public class V2rayVPNService extends VpnService implements V2rayServicesListener {
    private ParcelFileDescriptor mInterface;
    private V2rayConfig v2rayConfig;
    private final TunnelLifecycle tunnelLifecycle = new TunnelLifecycle();

    @Override
    public void onCreate() {
        super.onCreate();
        V2rayCoreManager.getInstance().attachService(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (!V2rayCoreManager.getInstance().showStartupNotification(AppConfigs.APPLICATION_NAME)) {
            Log.e("V2rayVPNService", "Failed to promote VPN service to startup foreground");
            stopSelf(startId);
            return START_NOT_STICKY;
        }

        // Handle null intent case - can happen when service is restarted by system
        if (intent == null) {
            Log.w("V2rayVPNService", "onStartCommand called with null intent, stopping service");
            stopSelf(startId);
            return START_NOT_STICKY;
        }

        AppConfigs.V2RAY_SERVICE_COMMANDS startCommand = (AppConfigs.V2RAY_SERVICE_COMMANDS) intent
                .getSerializableExtra("COMMAND");

        // Handle null command case
        if (startCommand == null) {
            Log.w("V2rayVPNService", "No command found in intent, stopping service");
            stopSelf(startId);
            return START_NOT_STICKY;
        }

        if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE)) {
            v2rayConfig = (V2rayConfig) intent.getSerializableExtra("V2RAY_CONFIG");
            if (v2rayConfig == null) {
                Log.w("V2rayVPNService", "V2RAY_CONFIG is null, cannot start service");
                stopSelf(startId);
                return START_NOT_STICKY;
            }
            if (V2rayCoreManager.getInstance().isV2rayCoreRunning()) {
                V2rayCoreManager.getInstance().stopCore();
            }
            if (!V2rayCoreManager.getInstance().showNotification(v2rayConfig)) {
                Log.e("V2rayVPNService", "Failed to promote VPN service to foreground");
                stopAllProcess();
                return START_NOT_STICKY;
            }
            if (!V2rayCoreManager.getInstance().ensureCoreInitialized(this)) {
                Log.e("V2rayVPNService", "Failed to initialize v2ray core");
                stopAllProcess();
                return START_NOT_STICKY;
            }
            if (V2rayCoreManager.getInstance().startCore(v2rayConfig)) {
                Log.i("V2rayVPNService", "onStartCommand success => v2ray core started.");
            } else {
                Log.e("V2rayVPNService", "Failed to start v2ray core");
                stopAllProcess();
                return START_NOT_STICKY;
            }
        } else if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)) {
            V2rayCoreManager.getInstance().stopCore();
            AppConfigs.V2RAY_CONFIG = null;
            stopSelf(startId);
            return START_NOT_STICKY;
        } else if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.MEASURE_DELAY)) {
            new Thread(() -> {
                try {
                    String packageName = getPackageName();
                    Intent sendB = new Intent(packageName + ".CONNECTED_V2RAY_SERVER_DELAY");
                    sendB.setPackage(packageName);
                    sendB.putExtra("DELAY", String.valueOf(V2rayCoreManager.getInstance().getConnectedV2rayServerDelay()));
                    sendBroadcast(sendB);
                } catch (Exception e) {
                    Log.w("V2rayVPNService", "Failed to send delay broadcast", e);
                }
            }, "MEASURE_CONNECTED_V2RAY_SERVER_DELAY").start();
        } else {
            Log.w("V2rayVPNService", "Unknown command received, stopping service");
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        return START_STICKY;
    }

    private void stopAllProcess() {
        try {
            stopForeground(true);
        } catch (Exception e) {
            Log.w("V2rayVPNService", "stopForeground failed (service may not be in foreground)", e);
        }
        try {
            tunnelLifecycle.stop();
        } catch (Exception e) {
            Log.e("V2rayVPNService", "Failed to stop tunnel backend", e);
        }
        V2rayCoreManager.getInstance().stopCore();
        try {
            stopSelf();
        } catch (Exception e) {
            // ignore
            Log.e("CANT_STOP", "SELF");
        }
        try {
            if (mInterface != null) {
                mInterface.close();
                mInterface = null;
            }
        } catch (Exception e) {
            // ignored
        }

    }

    private void setup() {
        Intent prepare_intent = prepare(this);
        if (prepare_intent != null) {
            return;
        }
        Builder builder = new Builder();
        builder.setSession(v2rayConfig.REMARK);
        builder.setMtu(HevTunnelConfig.DEFAULT_MTU);
        builder.addAddress(HevTunnelConfig.DEFAULT_IPV4, 30);

        TunnelBackendKind backendKind;
        try {
            backendKind = TunnelBackendSelector.resolve(this, v2rayConfig.TUNNEL_BACKEND);
        } catch (Exception error) {
            Log.e("VPN_SERVICE", "Invalid tunnel backend configuration", error);
            stopAllProcess();
            return;
        }

        if (backendKind == TunnelBackendKind.HEV) {
            builder.addAddress(HevTunnelConfig.DEFAULT_IPV6, 126);
        }

        if (v2rayConfig.BYPASS_SUBNETS == null || v2rayConfig.BYPASS_SUBNETS.isEmpty()) {
            builder.addRoute("0.0.0.0", 0);
            if (backendKind == TunnelBackendKind.HEV) {
                builder.addRoute("::", 0);
            }
        } else {
            for (String subnet : v2rayConfig.BYPASS_SUBNETS) {
                String[] parts = subnet.split("/");
                if (parts.length == 2) {
                    String address = parts[0];
                    int prefixLength = Integer.parseInt(parts[1]);
                    builder.addRoute(address, prefixLength);
                }
            }
        }
        if (v2rayConfig.BLOCKED_APPS != null) {
            for (int i = 0; i < v2rayConfig.BLOCKED_APPS.size(); i++) {
                try {
                    builder.addDisallowedApplication(v2rayConfig.BLOCKED_APPS.get(i));
                } catch (Exception e) {
                    // ignore
                }
            }
        }
        try {
            JSONObject json = new JSONObject(v2rayConfig.V2RAY_FULL_JSON_CONFIG);
            if (json.has("dns")) {
                JSONObject dnsObject = json.getJSONObject("dns");
                if (dnsObject.has("servers")) {
                    JSONArray serversArray = dnsObject.getJSONArray("servers");
                    for (int i = 0; i < serversArray.length(); i++) {
                        try {
                            Object entry = serversArray.get(i);
                            if (entry instanceof String) {
                                builder.addDnsServer((String) entry);
                            } else if (entry instanceof JSONObject) {
                                JSONObject obj = (JSONObject) entry;
                                if (obj.has("address")) {
                                    builder.addDnsServer(obj.getString("address"));
                                }
                            }
                        } catch (Exception ignored) {
                        }
                    }
                }
            }
        } catch (Exception e) {
            // If parsing fails, add sane fallback DNS
            try {
                builder.addDnsServer("1.1.1.1");
            } catch (Exception ignored) {
            }
            try {
                builder.addDnsServer("8.8.8.8");
            } catch (Exception ignored) {
            }
        }
        try {
            mInterface.close();
        } catch (Exception e) {
            // ignore
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false);
        }

        try {
            mInterface = builder.establish();
            if (mInterface == null) {
                throw new IllegalStateException("Android failed to establish the VPN interface");
            }
            TunnelBackend backend;
            if (backendKind == TunnelBackendKind.HEV) {
                backend = new HevTunnelBackend(
                        getApplicationContext(),
                        mInterface.getFd(),
                        v2rayConfig.LOCAL_SOCKS5_PORT,
                        true,
                        this::stopAllProcess);
            } else {
                backend = new BadVpnTunnelBackend(
                        getApplicationContext(),
                        mInterface.getFileDescriptor(),
                        v2rayConfig.LOCAL_SOCKS5_PORT,
                        this::stopAllProcess);
            }
            Log.i("VPN_SERVICE", "Starting tunnel backend: " + backend.name());
            if (!tunnelLifecycle.start(backend)) {
                throw new IllegalStateException(
                        "Tunnel backend is already active: " + tunnelLifecycle.activeBackendName());
            }
        } catch (Exception e) {
            Log.e("VPN_SERVICE", "Failed to establish VPN interface", e);
            stopAllProcess();
        }

    }

    @Override
    public void onDestroy() {
        Log.i("V2rayVPNService", "onDestroy called - cleaning up resources");
        
        // Stop the V2ray core
        try {
            if (V2rayCoreManager.getInstance().isV2rayCoreRunning()) {
                V2rayCoreManager.getInstance().stopCore();
            }
        } catch (Exception e) {
            Log.e("V2rayVPNService", "Error stopping V2ray core in onDestroy", e);
        }
        
        // Stop foreground service and remove notification
        try {
            stopForeground(true);
        } catch (Exception e) {
            Log.e("V2rayVPNService", "Error stopping foreground in onDestroy", e);
        }
        
        // Stop the active TUN backend
        try {
            tunnelLifecycle.stop();
        } catch (Exception e) {
            Log.e("V2rayVPNService", "Error stopping tunnel backend in onDestroy", e);
        }
        
        // Close VPN interface
        try {
            if (mInterface != null) {
                mInterface.close();
                mInterface = null;
            }
        } catch (Exception e) {
            Log.e("V2rayVPNService", "Error closing VPN interface in onDestroy", e);
        }
        
        super.onDestroy();
    }

    @Override
    public void onRevoke() {
        stopAllProcess();
    }

    @Override
    public boolean onProtect(int socket) {
        return protect(socket);
    }

    @Override
    public Service getService() {
        return this;
    }

    @Override
    public void startService() {
        setup();
    }

    @Override
    public void stopService() {
        stopAllProcess();
    }
}
