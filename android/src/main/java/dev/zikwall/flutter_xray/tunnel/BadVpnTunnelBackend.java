package dev.zikwall.flutter_xray.tunnel;

import android.content.Context;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileDescriptor;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/** BadVPN tun2socks backend with bounded startup, restart and shutdown behavior. */
public final class BadVpnTunnelBackend implements TunnelBackend {
    private static final String BADVPN_IPV4 = "26.26.26.2";
    private static final String BADVPN_IPV6 = "fc00::26:26:26:2";
    private static final long STOP_GRACE_MILLIS = 1_000L;
    private static final long FORCE_STOP_MILLIS = 1_000L;
    private static final int MAX_RESTARTS = 3;
    private static final AtomicLong SOCKET_SEQUENCE = new AtomicLong();

    private final File executable;
    private final File workingDirectory;
    private final FileDescriptor tunFileDescriptor;
    private final int localSocksPort;
    private final Runnable failureCallback;
    private final BadVpnRuntime runtime;

    private volatile boolean running;
    private long sessionId;
    private BadVpnProcess process;
    private Thread supervisorThread;
    private File controlSocket;

    public BadVpnTunnelBackend(
            Context context,
            FileDescriptor tunFileDescriptor,
            int localSocksPort,
            Runnable failureCallback) {
        this(
                new File(context.getApplicationInfo().nativeLibraryDir, "libtun2socks.so"),
                context.getFilesDir(),
                tunFileDescriptor,
                localSocksPort,
                failureCallback,
                new AndroidBadVpnRuntime());
    }

    BadVpnTunnelBackend(
            File executable,
            File workingDirectory,
            FileDescriptor tunFileDescriptor,
            int localSocksPort,
            Runnable failureCallback,
            BadVpnRuntime runtime) {
        if (localSocksPort < 1 || localSocksPort > 65535) {
            throw new IllegalArgumentException("SOCKS5 port must be between 1 and 65535");
        }
        this.executable = executable;
        this.workingDirectory = workingDirectory;
        this.tunFileDescriptor = tunFileDescriptor;
        this.localSocksPort = localSocksPort;
        this.failureCallback = failureCallback;
        this.runtime = runtime;
    }

    @Override
    public String name() {
        return "badvpn-tun2socks";
    }

    @Override
    public void start() throws IOException {
        final long activeSession;
        final File socketFile;
        synchronized (this) {
            if (running) {
                return;
            }
            running = true;
            sessionId += 1L;
            activeSession = sessionId;
            socketFile = new File(
                    workingDirectory,
                    "badvpn-" + Long.toHexString(SOCKET_SEQUENCE.incrementAndGet()) + ".sock");
            controlSocket = socketFile;
            deleteControlSocket(socketFile);
        }

        try {
            BadVpnProcess launchedProcess = launchAndHandoff(activeSession, socketFile);
            Thread thread = daemonThread(
                    "BadVpnSupervisor-" + activeSession,
                    () -> supervise(activeSession, socketFile, launchedProcess));
            synchronized (this) {
                requireActiveSession(activeSession);
                supervisorThread = thread;
            }
            thread.start();
        } catch (Exception error) {
            IOException startError = asIOException("Failed to start BadVPN tun2socks", error);
            try {
                stopSession(activeSession);
            } catch (IOException cleanupError) {
                startError.addSuppressed(cleanupError);
            }
            throw startError;
        }
    }

    @Override
    public void stop() throws IOException {
        final long activeSession;
        synchronized (this) {
            activeSession = sessionId;
        }
        stopSession(activeSession);
    }

    private BadVpnProcess launchAndHandoff(long activeSession, File socketFile) throws IOException {
        BadVpnProcess launchedProcess = runtime.launch(command(socketFile), workingDirectory);
        try {
            synchronized (this) {
                if (!isActiveSession(activeSession)) {
                    terminate(launchedProcess);
                    throw new IOException("BadVPN start was cancelled");
                }
                process = launchedProcess;
            }
            drainOutput(launchedProcess, activeSession);

            long startedAtNanos = runtime.nanoTime();
            int failedAttempts = 0;
            Exception lastError = null;
            while (isActiveProcess(activeSession, launchedProcess)) {
                if (!launchedProcess.isAlive()) {
                    throw new IOException("tun2socks exited before receiving the VPN file descriptor");
                }
                long remainingMillis = TunFdRetryPolicy.remainingMillis(
                        startedAtNanos, runtime.nanoTime());
                if (remainingMillis <= 0L) {
                    break;
                }
                long delayMillis = Math.min(
                        TunFdRetryPolicy.retryDelayMillis(failedAttempts), remainingMillis);
                if (delayMillis > 0L) {
                    try {
                        runtime.sleep(delayMillis);
                    } catch (InterruptedException error) {
                        Thread.currentThread().interrupt();
                        throw new IOException("Interrupted while waiting for tun2socks control socket", error);
                    }
                }
                if (!isActiveProcess(activeSession, launchedProcess)) {
                    throw new IOException("BadVPN start was cancelled");
                }
                try {
                    runtime.sendFileDescriptor(socketFile, tunFileDescriptor);
                    runtime.logInfo("Sent VPN file descriptor after "
                            + failedAttempts + " failed attempt(s)");
                    return launchedProcess;
                } catch (Exception error) {
                    lastError = error;
                    failedAttempts += 1;
                }
            }
            throw new IOException(
                    "tun2socks file descriptor handoff timed out after "
                            + failedAttempts + " attempt(s)",
                    lastError);
        } catch (IOException error) {
            try {
                terminate(launchedProcess);
            } catch (IOException cleanupError) {
                error.addSuppressed(cleanupError);
            }
            synchronized (this) {
                if (process == launchedProcess) {
                    process = null;
                }
            }
            throw error;
        }
    }

    private void supervise(long activeSession, File socketFile, BadVpnProcess initialProcess) {
        BadVpnProcess supervisedProcess = initialProcess;
        int restartCount = 0;
        while (isActiveSession(activeSession)) {
            final int exitCode;
            try {
                exitCode = supervisedProcess.waitFor();
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                return;
            }
            if (!isActiveSession(activeSession)) {
                return;
            }
            if (restartCount >= MAX_RESTARTS) {
                signalFailure(activeSession, new IOException(
                        "tun2socks exited with code " + exitCode
                                + " after " + restartCount + " restart(s)"));
                return;
            }

            restartCount += 1;
            long delayMillis = restartDelayMillis(restartCount);
            runtime.logWarning("tun2socks exited with code " + exitCode + "; restart "
                    + restartCount + "/" + MAX_RESTARTS + " in " + delayMillis + " ms", null);
            try {
                runtime.sleep(delayMillis);
                if (!isActiveSession(activeSession)) {
                    return;
                }
                supervisedProcess = launchAndHandoff(activeSession, socketFile);
            } catch (Exception error) {
                if (!isActiveSession(activeSession)) {
                    return;
                }
                if (restartCount >= MAX_RESTARTS) {
                    signalFailure(activeSession, asIOException(
                            "tun2socks restart failed after " + restartCount + " attempt(s)", error));
                    return;
                }
                runtime.logError("tun2socks restart " + restartCount + " failed", error);
                continue;
            }
        }
    }

    private List<String> command(File socketFile) {
        return new ArrayList<>(Arrays.asList(
                executable.getAbsolutePath(),
                "--netif-ipaddr", BADVPN_IPV4,
                "--netif-netmask", "255.255.255.252",
                "--netif-ip6addr", BADVPN_IPV6,
                "--socks-server-addr", "127.0.0.1:" + localSocksPort,
                "--tunmtu", String.valueOf(HevTunnelConfig.DEFAULT_MTU),
                "--sock-path", socketFile.getAbsolutePath(),
                "--socks5-udp",
                "--loglevel", "warning"));
    }

    private void drainOutput(BadVpnProcess launchedProcess, long activeSession) {
        daemonThread("BadVpnOutput-" + activeSession, () -> {
            try (InputStream output = launchedProcess.outputStream();
                    BufferedReader reader = new BufferedReader(
                            new InputStreamReader(output, StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    if (!line.trim().isEmpty()) {
                        runtime.logInfo("tun2socks: " + line);
                    }
                }
            } catch (IOException error) {
                if (isActiveProcess(activeSession, launchedProcess)) {
                    runtime.logWarning("Failed while draining tun2socks output", error);
                }
            }
        }).start();
    }

    private void stopSession(long activeSession) throws IOException {
        final BadVpnProcess activeProcess;
        final Thread activeSupervisor;
        final File socketFile;
        synchronized (this) {
            if (activeSession != sessionId) {
                return;
            }
            running = false;
            activeProcess = process;
            process = null;
            activeSupervisor = supervisorThread;
            supervisorThread = null;
            socketFile = controlSocket;
            controlSocket = null;
        }

        IOException stopError = null;
        if (activeProcess != null) {
            try {
                terminate(activeProcess);
            } catch (IOException error) {
                stopError = error;
            }
        }
        if (activeSupervisor != null && activeSupervisor != Thread.currentThread()) {
            activeSupervisor.interrupt();
            try {
                activeSupervisor.join(STOP_GRACE_MILLIS);
                if (activeSupervisor.isAlive()) {
                    IOException error = new IOException("BadVPN supervisor thread did not stop");
                    if (stopError == null) {
                        stopError = error;
                    } else {
                        stopError.addSuppressed(error);
                    }
                }
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                IOException interrupted = new IOException("Interrupted while stopping BadVPN", error);
                if (stopError == null) {
                    stopError = interrupted;
                } else {
                    stopError.addSuppressed(interrupted);
                }
            }
        }
        deleteControlSocket(socketFile);
        if (stopError != null) {
            throw stopError;
        }
    }

    private void terminate(BadVpnProcess activeProcess) throws IOException {
        if (!activeProcess.isAlive()) {
            return;
        }
        activeProcess.destroy();
        try {
            if (activeProcess.waitFor(STOP_GRACE_MILLIS, TimeUnit.MILLISECONDS)) {
                return;
            }
            activeProcess.destroyForcibly();
            if (!activeProcess.waitFor(FORCE_STOP_MILLIS, TimeUnit.MILLISECONDS)) {
                throw new IOException("tun2socks did not exit after forced termination");
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new IOException("Interrupted while terminating tun2socks", error);
        }
    }

    private void signalFailure(long activeSession, IOException error) {
        final File socketFile;
        synchronized (this) {
            if (!isActiveSession(activeSession)) {
                return;
            }
            running = false;
            process = null;
            supervisorThread = null;
            socketFile = controlSocket;
            controlSocket = null;
        }
        deleteControlSocket(socketFile);
        runtime.logError("Tunnel backend failed", error);
        try {
            failureCallback.run();
        } catch (RuntimeException callbackError) {
            runtime.logError("Tunnel failure callback failed", callbackError);
        }
    }

    private synchronized boolean isActiveSession(long activeSession) {
        return running && sessionId == activeSession;
    }

    private synchronized boolean isActiveProcess(
            long activeSession, BadVpnProcess expectedProcess) {
        return isActiveSession(activeSession) && process == expectedProcess;
    }

    private synchronized void requireActiveSession(long activeSession) throws IOException {
        if (!isActiveSession(activeSession)) {
            throw new IOException("BadVPN start was cancelled");
        }
    }

    private static long restartDelayMillis(int restartCount) {
        return Math.min(2_000L, 250L << Math.min(restartCount - 1, 3));
    }

    private static Thread daemonThread(String name, Runnable runnable) {
        Thread thread = new Thread(runnable, name);
        thread.setDaemon(true);
        return thread;
    }

    private static IOException asIOException(String message, Exception error) {
        return error instanceof IOException
                ? new IOException(message + ": " + error.getMessage(), error)
                : new IOException(message, error);
    }

    private void deleteControlSocket(File socketFile) {
        if (socketFile != null && socketFile.exists() && !socketFile.delete()) {
            runtime.logWarning("Failed to delete BadVPN control socket: " + socketFile, null);
        }
    }
}
