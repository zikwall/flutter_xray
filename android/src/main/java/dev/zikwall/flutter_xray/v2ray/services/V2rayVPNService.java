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
import dev.zikwall.flutter_xray.tunnel.TunnelLifecycle;
import dev.zikwall.flutter_xray.tunnel.XrayTunBackend;
import dev.zikwall.flutter_xray.tunnel.XrayTunConfigTransformer;
import dev.zikwall.flutter_xray.v2ray.core.V2rayCoreManager;
import dev.zikwall.flutter_xray.v2ray.interfaces.V2rayServicesListener;
import dev.zikwall.flutter_xray.v2ray.utils.AppConfigs;
import dev.zikwall.flutter_xray.v2ray.utils.V2rayConfig;

import org.json.JSONArray;
import org.json.JSONObject;

public class V2rayVPNService extends VpnService implements V2rayServicesListener {
    private ParcelFileDescriptor mInterface;
    private V2rayConfig v2rayConfig;
    private TunnelBackendKind activeBackendKind = TunnelBackendKind.BADVPN;
    private final TunnelLifecycle tunnelLifecycle = new TunnelLifecycle();
    private boolean cleaningUp;
    private boolean resourcesReleased;
    private boolean foregroundActive;

    @Override
    public void onCreate() {
        super.onCreate();
        V2rayCoreManager.getInstance().attachService(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
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
            // startForegroundService() creates a strict, short deadline. Promote
            // before config parsing, core initialization or TUN establishment.
            // STOP and MEASURE_DELAY arrive through startService() and must never
            // re-promote a service that is already tearing down.
            if (!V2rayCoreManager.getInstance().showStartupNotification(AppConfigs.APPLICATION_NAME)) {
                Log.e("V2rayVPNService", "Failed to promote VPN service to startup foreground");
                stopSelf(startId);
                return START_NOT_STICKY;
            }
            foregroundActive = true;
            v2rayConfig = (V2rayConfig) intent.getSerializableExtra("V2RAY_CONFIG");
            if (v2rayConfig == null) {
                Log.w("V2rayVPNService", "V2RAY_CONFIG is null, cannot start service");
                stopSelf(startId);
                return START_NOT_STICKY;
            }
            if (V2rayCoreManager.getInstance().isV2rayCoreRunning()) {
                Log.e("V2rayVPNService", "Cannot start a second VPN session before cleanup completes");
                stopNow();
                return START_NOT_STICKY;
            }
            if (!V2rayCoreManager.getInstance().ensureCoreInitialized(this)) {
                Log.e("V2rayVPNService", "Failed to initialize v2ray core");
                stopAllProcess();
                return START_NOT_STICKY;
            }
            try {
                activeBackendKind = TunnelBackendKind.fromConfigValue(v2rayConfig.TUNNEL_BACKEND);
            } catch (Exception error) {
                Log.e("V2rayVPNService", "Invalid tunnel backend configuration", error);
                stopAllProcess();
                return START_NOT_STICKY;
            }

            boolean started;
            if (activeBackendKind == TunnelBackendKind.XRAY) {
                started = startXrayNativeTun();
            } else {
                started = V2rayCoreManager.getInstance().startCore(v2rayConfig)
                        && startExternalTunnel();
            }
            if (started) {
                Log.i("V2rayVPNService", "onStartCommand success => v2ray core started.");
            } else {
                Log.e("V2rayVPNService", "Failed to start v2ray core");
                stopAllProcess();
                return START_NOT_STICKY;
            }
        } else if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)) {
            AppConfigs.V2RAY_CONFIG = null;
            stopAllProcess();
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
        return START_NOT_STICKY;
    }

    private void stopAllProcess() {
        shutdownResources();
        stopNow();
    }

    private void stopNow() {
        stopForegroundOnce();
        try {
            stopSelf();
        } catch (Exception e) {
            // ignore
            Log.e("CANT_STOP", "SELF");
        }
    }

    private synchronized void stopForegroundOnce() {
        if (!foregroundActive) {
            return;
        }
        foregroundActive = false;
        try {
            stopForeground(true);
        } catch (Exception e) {
            Log.w("V2rayVPNService", "stopForeground failed (service may not be in foreground)", e);
        }
    }

    private synchronized void shutdownResources() {
        if (cleaningUp || resourcesReleased) {
            return;
        }
        cleaningUp = true;
        try {
            try {
                tunnelLifecycle.stop();
            } catch (Exception error) {
                Log.e("V2rayVPNService", "Failed to stop tunnel backend", error);
            }
            V2rayCoreManager.getInstance().stopCoreRuntime();
            closeVpnInterface(mInterface);
        } finally {
            resourcesReleased = true;
            cleaningUp = false;
        }
    }

    private ParcelFileDescriptor establishVpnInterface(TunnelBackendKind backendKind) throws Exception {
        Intent prepare_intent = prepare(this);
        if (prepare_intent != null) {
            throw new IllegalStateException("Android VPN permission has not been granted");
        }
        Builder builder = new Builder();
        builder.setSession(v2rayConfig.REMARK);
        builder.setMtu(HevTunnelConfig.DEFAULT_MTU);
        builder.addAddress(HevTunnelConfig.DEFAULT_IPV4, 30);

        if (backendKind == TunnelBackendKind.HEV || backendKind == TunnelBackendKind.XRAY) {
            builder.addAddress(HevTunnelConfig.DEFAULT_IPV6, 126);
        }

        if (v2rayConfig.BYPASS_SUBNETS == null || v2rayConfig.BYPASS_SUBNETS.isEmpty()) {
            builder.addRoute("0.0.0.0", 0);
            if (backendKind == TunnelBackendKind.HEV || backendKind == TunnelBackendKind.XRAY) {
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
        if (mInterface != null) {
            try {
                mInterface.close();
            } catch (Exception ignored) {
            }
            mInterface = null;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false);
        }

        mInterface = builder.establish();
        if (mInterface == null) {
            throw new IllegalStateException("Android failed to establish the VPN interface");
        }
        return mInterface;
    }

    private boolean startExternalTunnel() {
        try {
            ParcelFileDescriptor vpnInterface = establishVpnInterface(activeBackendKind);
            TunnelBackend backend;
            if (activeBackendKind == TunnelBackendKind.HEV) {
                backend = new HevTunnelBackend(
                        getApplicationContext(),
                        vpnInterface.getFd(),
                        v2rayConfig.LOCAL_SOCKS5_PORT,
                        true,
                        this::stopAllProcess);
            } else {
                backend = new BadVpnTunnelBackend(
                        getApplicationContext(),
                        vpnInterface.getFileDescriptor(),
                        v2rayConfig.LOCAL_SOCKS5_PORT,
                        this::stopAllProcess);
            }
            Log.i("VPN_SERVICE", "Starting tunnel backend: " + backend.name());
            if (!tunnelLifecycle.start(backend)) {
                throw new IllegalStateException(
                        "Tunnel backend is already active: " + tunnelLifecycle.activeBackendName());
            }
            return true;
        } catch (Exception e) {
            Log.e("VPN_SERVICE", "Failed to establish VPN interface", e);
            return false;
        }
    }

    private boolean startXrayNativeTun() {
        try {
            final ParcelFileDescriptor vpnInterface = establishVpnInterface(TunnelBackendKind.XRAY);
            final String nativeTunConfig = XrayTunConfigTransformer.transform(
                    v2rayConfig.V2RAY_FULL_JSON_CONFIG,
                    v2rayConfig.LOCAL_SOCKS5_PORT,
                    HevTunnelConfig.DEFAULT_MTU);
            XrayTunBackend backend = new XrayTunBackend(
                    new XrayTunBackend.CoreRuntime() {
                        @Override
                        public boolean start() {
                            return V2rayCoreManager.getInstance().startCoreWithTun(
                                    v2rayConfig,
                                    nativeTunConfig,
                                    vpnInterface.getFd());
                        }

                        @Override
                        public void stop() {
                            V2rayCoreManager.getInstance().stopCoreRuntime();
                        }
                    },
                    () -> closeVpnInterface(vpnInterface));
            Log.i("VPN_SERVICE", "Starting tunnel backend: " + backend.name());
            if (!tunnelLifecycle.start(backend)) {
                throw new IllegalStateException(
                        "Tunnel backend is already active: " + tunnelLifecycle.activeBackendName());
            }
            return true;
        } catch (Exception error) {
            Log.e("VPN_SERVICE", "Failed to start Xray native TUN", error);
            try {
                tunnelLifecycle.stop();
            } catch (Exception cleanupError) {
                Log.e("VPN_SERVICE", "Failed to clean up Xray native TUN", cleanupError);
            }
            closeVpnInterface(mInterface);
            return false;
        }
    }

    private synchronized void closeVpnInterface(ParcelFileDescriptor vpnInterface) {
        if (vpnInterface == null) {
            return;
        }
        try {
            vpnInterface.close();
        } catch (Exception error) {
            Log.w("VPN_SERVICE", "Failed to close VPN interface", error);
        }
        if (mInterface == vpnInterface) {
            mInterface = null;
        }
    }

    @Override
    public void onDestroy() {
        Log.i("V2rayVPNService", "onDestroy called - cleaning up resources");

        shutdownResources();
        stopForegroundOnce();
        V2rayCoreManager.getInstance().publishDisconnected();
        V2rayCoreManager.getInstance().detachService(this);
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

}
