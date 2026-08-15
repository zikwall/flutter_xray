package dev.zikwall.flutter_xray.v2ray.services;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;
import android.util.Log;

import androidx.annotation.Nullable;

import dev.zikwall.flutter_xray.v2ray.core.V2rayCoreManager;
import dev.zikwall.flutter_xray.v2ray.interfaces.V2rayServicesListener;
import dev.zikwall.flutter_xray.v2ray.utils.AppConfigs;
import dev.zikwall.flutter_xray.v2ray.utils.V2rayConfig;

public class V2rayProxyOnlyService extends Service implements V2rayServicesListener {
    private boolean foregroundActive;
    private boolean coreReleased;

    @Override
    public void onCreate() {
        super.onCreate();
        V2rayCoreManager.getInstance().attachService(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // Handle null intent case - can happen when service is restarted by system
        if (intent == null) {
            Log.w("V2rayProxyOnlyService", "onStartCommand called with null intent, stopping service");
            stopSelf(startId);
            return START_NOT_STICKY;
        }

        AppConfigs.V2RAY_SERVICE_COMMANDS startCommand = (AppConfigs.V2RAY_SERVICE_COMMANDS) intent
                .getSerializableExtra("COMMAND");
        
        // Handle null command case
        if (startCommand == null) {
            Log.w("V2rayProxyOnlyService", "No command found in intent, stopping service");
            stopSelf(startId);
            return START_NOT_STICKY;
        }

        if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE)) {
            // Only START_SERVICE is launched with startForegroundService(). STOP
            // and diagnostics must not call startForeground() during teardown.
            if (!V2rayCoreManager.getInstance().showStartupNotification(
                    intent.getStringExtra(AppConfigs.EXTRA_APPLICATION_NAME),
                    intent.getIntExtra(AppConfigs.EXTRA_APPLICATION_ICON, 0))) {
                Log.e("V2rayProxyOnlyService", "Failed to promote proxy service to startup foreground");
                stopSelf(startId);
                return START_NOT_STICKY;
            }
            foregroundActive = true;
            prepareForStart();
            V2rayConfig v2rayConfig = (V2rayConfig) intent.getSerializableExtra("V2RAY_CONFIG");
            if (v2rayConfig == null) {
                Log.w("V2rayProxyOnlyService", "V2RAY_CONFIG is null, cannot start service");
                stopSelf(startId);
                return START_NOT_STICKY;
            }
            if (V2rayCoreManager.getInstance().isV2rayCoreRunning()) {
                Log.e("V2rayProxyOnlyService", "Cannot start a second proxy session before cleanup completes");
                stopNow();
                return START_NOT_STICKY;
            }
            if (!V2rayCoreManager.getInstance().ensureCoreInitialized(this)) {
                Log.e("V2rayProxyOnlyService", "Failed to initialize v2ray core");
                stopNow();
                return START_NOT_STICKY;
            }
            if (V2rayCoreManager.getInstance().startCore(v2rayConfig)) {
                Log.i("V2rayProxyOnlyService", "onStartCommand success => v2ray core started.");
            } else {
                Log.e("V2rayProxyOnlyService", "Failed to start v2ray core");
                stopNow();
                return START_NOT_STICKY;
            }
        } else if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)) {
            AppConfigs.V2RAY_CONFIG = null;
            stopNow();
            return START_NOT_STICKY;
        } else if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.MEASURE_DELAY)) {
            new Thread(() -> {
                try {
                    String packageName = getPackageName();
                    Intent sendB = new Intent(packageName + ".CONNECTED_V2RAY_SERVER_DELAY");
                    sendB.setPackage(packageName);
                    sendB.putExtra("DELAY", String.valueOf(
                            V2rayCoreManager.getInstance().getConnectedV2rayServerDelay(
                                    intent.getStringExtra(AppConfigs.EXTRA_DELAY_URL))));
                    sendBroadcast(sendB);
                } catch (Exception e) {
                    Log.w("V2rayProxyOnlyService", "Failed to send delay broadcast", e);
                }
            }, "MEASURE_CONNECTED_V2RAY_SERVER_DELAY").start();
        } else {
            Log.w("V2rayProxyOnlyService", "Unknown command received, stopping service");
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        stopCoreOnce();
        stopForegroundOnce();
        V2rayCoreManager.getInstance().publishDisconnected();
        V2rayCoreManager.getInstance().detachService(this);
        super.onDestroy();
    }

    private void stopNow() {
        stopCoreOnce();
        stopForegroundOnce();
        stopSelf();
    }

    private synchronized void stopCoreOnce() {
        if (coreReleased) {
            return;
        }
        coreReleased = true;
        V2rayCoreManager.getInstance().stopCoreRuntime();
    }

    private synchronized void prepareForStart() {
        // A foreground Service instance can be reused after a completed STOP.
        // The next session must not inherit the previous cleanup guard.
        coreReleased = false;
    }

    private synchronized void stopForegroundOnce() {
        if (!foregroundActive) {
            return;
        }
        foregroundActive = false;
        try {
            stopForeground(true);
        } catch (Exception error) {
            Log.w("V2rayProxyOnlyService", "Failed to stop foreground state", error);
        }
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public boolean onProtect(int socket) {
        return true;
    }

    @Override
    public Service getService() {
        return this;
    }

}
