package dev.zikwall.flutter_xray.tunnel;

import android.content.Context;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.util.Log;

import java.io.File;
import java.io.FileDescriptor;
import java.io.IOException;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Arrays;

/** The existing BadVPN tun2socks process, isolated behind {@link TunnelBackend}. */
public final class BadVpnTunnelBackend implements TunnelBackend {
    private static final String TAG = "BadVpnTunnelBackend";

    private final Context applicationContext;
    private final FileDescriptor tunFileDescriptor;
    private final int localSocksPort;
    private final Runnable failureCallback;

    private volatile boolean running;
    private Process process;

    public BadVpnTunnelBackend(
            Context context,
            FileDescriptor tunFileDescriptor,
            int localSocksPort,
            Runnable failureCallback) {
        this.applicationContext = context.getApplicationContext();
        this.tunFileDescriptor = tunFileDescriptor;
        this.localSocksPort = localSocksPort;
        this.failureCallback = failureCallback;
    }

    @Override
    public String name() {
        return "badvpn-tun2socks";
    }

    @Override
    public synchronized void start() throws IOException {
        if (running) {
            return;
        }
        running = true;
        try {
            launchProcess();
        } catch (IOException error) {
            running = false;
            throw error;
        }
    }

    @Override
    public synchronized void stop() {
        running = false;
        if (process != null) {
            process.destroy();
            process = null;
        }
    }

    private synchronized void launchProcess() throws IOException {
        if (!running) {
            return;
        }

        ArrayList<String> command = new ArrayList<>(Arrays.asList(
                new File(applicationContext.getApplicationInfo().nativeLibraryDir, "libtun2socks.so")
                        .getAbsolutePath(),
                "--netif-ipaddr", "26.26.26.2",
                "--netif-netmask", "255.255.255.252",
                "--socks-server-addr", "127.0.0.1:" + localSocksPort,
                "--tunmtu", "1500",
                "--sock-path", "sock_path",
                "--enable-udprelay",
                "--loglevel", "error"));
        ProcessBuilder processBuilder = new ProcessBuilder(command);
        processBuilder.redirectErrorStream(true);
        Process launchedProcess = processBuilder.directory(applicationContext.getFilesDir()).start();
        process = launchedProcess;

        new Thread(() -> waitForProcess(launchedProcess), "Tun2socks_Thread").start();
        sendFileDescriptor();
    }

    private void waitForProcess(Process launchedProcess) {
        try {
            launchedProcess.waitFor();
            synchronized (this) {
                if (!running || process != launchedProcess) {
                    return;
                }
                launchProcess();
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
        } catch (Exception error) {
            fail(error);
        }
    }

    private void sendFileDescriptor() {
        String localSocketPath = new File(applicationContext.getFilesDir(), "sock_path").getAbsolutePath();
        new Thread(() -> {
            long startedAtNanos = System.nanoTime();
            int failedAttempts = 0;
            Exception lastError = null;
            while (running) {
                long remainingMillis = TunFdRetryPolicy.remainingMillis(startedAtNanos, System.nanoTime());
                if (remainingMillis <= 0L) {
                    break;
                }

                long retryDelayMillis = Math.min(
                        TunFdRetryPolicy.retryDelayMillis(failedAttempts), remainingMillis);
                if (retryDelayMillis > 0L) {
                    try {
                        Thread.sleep(retryDelayMillis);
                    } catch (InterruptedException error) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                }
                if (!running
                        || TunFdRetryPolicy.remainingMillis(startedAtNanos, System.nanoTime()) <= 0L) {
                    break;
                }

                LocalSocket socket = new LocalSocket();
                try {
                    socket.connect(new LocalSocketAddress(
                            localSocketPath, LocalSocketAddress.Namespace.FILESYSTEM));
                    if (!socket.isConnected()) {
                        throw new IOException("tun2socks control socket is not connected");
                    }
                    OutputStream output = socket.getOutputStream();
                    socket.setFileDescriptorsForSend(new FileDescriptor[] {tunFileDescriptor});
                    output.write(32);
                    Log.i(TAG, "Sent VPN file descriptor after " + failedAttempts + " failed attempt(s)");
                    return;
                } catch (Exception error) {
                    lastError = error;
                    failedAttempts += 1;
                    Log.w(TAG, "VPN file descriptor handoff not ready; retrying (attempt "
                            + failedAttempts + ")");
                } finally {
                    try {
                        socket.setFileDescriptorsForSend(null);
                    } catch (Exception ignored) {
                    }
                    try {
                        socket.close();
                    } catch (Exception ignored) {
                    }
                }
            }

            if (running) {
                Log.e(TAG, "VPN file descriptor handoff timed out after " + failedAttempts
                        + " attempt(s)", lastError);
                fail(lastError == null ? new IOException("tun2socks file descriptor handoff timed out") : lastError);
            }
        }, "sendFd_Thread").start();
    }

    private void fail(Exception error) {
        synchronized (this) {
            if (!running) {
                return;
            }
            running = false;
        }
        Log.e(TAG, "Tunnel backend failed", error);
        failureCallback.run();
    }
}
