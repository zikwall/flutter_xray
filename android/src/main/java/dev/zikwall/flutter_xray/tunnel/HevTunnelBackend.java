package dev.zikwall.flutter_xray.tunnel;

import android.content.Context;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/** HEV tun2socks backend using the upstream JNI lifecycle. */
public final class HevTunnelBackend implements TunnelBackend {
    private static final String TAG = "HevTunnelBackend";
    private static final long HEALTH_CHECK_INTERVAL_MILLIS = 250L;

    private final File configFile;
    private final String configContent;
    private final int tunFileDescriptor;
    private final Runnable failureCallback;
    private final HevNativeBridge nativeBridge;

    private volatile boolean running;
    private ScheduledExecutorService healthMonitor;

    public HevTunnelBackend(
            Context context,
            int tunFileDescriptor,
            int localSocksPort,
            boolean ipv6Enabled,
            Runnable failureCallback) {
        this(
                new File(context.getFilesDir(), "hev-socks5-tunnel.yaml"),
                new HevTunnelConfig(
                        localSocksPort,
                        HevTunnelConfig.DEFAULT_MTU,
                        ipv6Enabled).toYaml(),
                tunFileDescriptor,
                failureCallback,
                new HevNative());
    }

    HevTunnelBackend(
            File configFile,
            String configContent,
            int tunFileDescriptor,
            Runnable failureCallback,
            HevNativeBridge nativeBridge) {
        this.configFile = configFile;
        this.configContent = configContent;
        this.tunFileDescriptor = tunFileDescriptor;
        this.failureCallback = failureCallback;
        this.nativeBridge = nativeBridge;
    }

    @Override
    public String name() {
        return "hev-socks5-tunnel";
    }

    @Override
    public synchronized void start() throws IOException {
        if (running) {
            return;
        }
        if (nativeBridge.isRunning()) {
            throw new IOException("HEV native runtime is already active");
        }

        writeConfig();
        if (!nativeBridge.start(configFile.getAbsolutePath(), tunFileDescriptor)) {
            throw new IOException("HEV native runtime rejected the start request");
        }

        running = true;
        healthMonitor = Executors.newSingleThreadScheduledExecutor(runnable -> {
            Thread thread = new Thread(runnable, "HevTunnelHealth");
            thread.setDaemon(true);
            return thread;
        });
        healthMonitor.scheduleWithFixedDelay(
                this::checkHealth,
                HEALTH_CHECK_INTERVAL_MILLIS,
                HEALTH_CHECK_INTERVAL_MILLIS,
                TimeUnit.MILLISECONDS);
    }

    @Override
    public synchronized void stop() throws IOException {
        boolean wasRunning = running;
        running = false;
        if (healthMonitor != null) {
            healthMonitor.shutdownNow();
            healthMonitor = null;
        }
        if ((wasRunning || nativeBridge.isRunning()) && !nativeBridge.stop()) {
            throw new IOException("HEV native runtime failed to stop cleanly");
        }
    }

    private void writeConfig() throws IOException {
        File parent = configFile.getParentFile();
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw new IOException("Failed to create HEV config directory: " + parent);
        }
        byte[] bytes = configContent.getBytes(StandardCharsets.UTF_8);
        try (FileOutputStream output = new FileOutputStream(configFile, false)) {
            output.write(bytes);
            output.flush();
            output.getFD().sync();
        }
    }

    private void checkHealth() {
        if (!running || nativeBridge.isRunning()) {
            return;
        }
        synchronized (this) {
            if (!running) {
                return;
            }
            running = false;
            if (healthMonitor != null) {
                healthMonitor.shutdown();
                healthMonitor = null;
            }
        }
        try {
            failureCallback.run();
        } finally {
            Log.e(TAG, "HEV native runtime exited unexpectedly");
        }
    }
}
