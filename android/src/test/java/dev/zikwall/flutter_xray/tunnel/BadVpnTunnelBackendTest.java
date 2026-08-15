package dev.zikwall.flutter_xray.tunnel;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileDescriptor;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public final class BadVpnTunnelBackendTest {
    @Rule public final TemporaryFolder temporaryFolder = new TemporaryFolder();

    @Test
    public void startWaitsForFdHandoffAndEnablesIpv6() throws Exception {
        FakeRuntime runtime = new FakeRuntime();
        runtime.handoffFailures = 2;
        BadVpnTunnelBackend backend = backend(runtime, () -> {});

        backend.start();

        assertEquals(3, runtime.handoffCalls);
        assertEquals(1, runtime.commands.size());
        List<String> command = runtime.commands.get(0);
        assertTrue(command.contains("--netif-ip6addr"));
        assertTrue(command.contains("fc00::26:26:26:2"));
        assertTrue(command.contains("--socks5-udp"));
        assertFalse(command.contains("--enable-udprelay"));
        assertTrue(runtime.socketFiles.get(0).isAbsolute());
        backend.stop();
    }

    @Test
    public void usesUniqueControlSocketForEveryLifecycle() throws Exception {
        FakeRuntime runtime = new FakeRuntime();
        BadVpnTunnelBackend backend = backend(runtime, () -> {});

        backend.start();
        File firstSocket = runtime.socketFiles.get(0);
        backend.stop();
        backend.start();
        File secondSocket = runtime.socketFiles.get(1);
        backend.stop();

        assertNotEquals(firstSocket, secondSocket);
    }

    @Test
    public void failedHandoffFailsStartAndTerminatesChild() throws Exception {
        FakeRuntime runtime = new FakeRuntime();
        runtime.alwaysFailHandoff = true;
        BadVpnTunnelBackend backend = backend(runtime, () -> {});

        IOException error = assertThrows(IOException.class, backend::start);

        assertTrue(error.getMessage().contains("Failed to start BadVPN"));
        assertEquals(1, runtime.processes.size());
        assertFalse(runtime.processes.get(0).isAlive());
    }

    @Test
    public void unexpectedExitRestartsWithFreshFdHandoff() throws Exception {
        FakeRuntime runtime = new FakeRuntime();
        BadVpnTunnelBackend backend = backend(runtime, () -> {});
        backend.start();

        runtime.processes.get(0).exit(17);

        await(() -> runtime.processes.size() == 2, "BadVPN was not restarted");
        assertEquals(2, runtime.handoffCalls);
        backend.stop();
    }

    @Test
    public void boundedRestartLoopSignalsFailureOnce() throws Exception {
        FakeRuntime runtime = new FakeRuntime();
        CountDownLatch failure = new CountDownLatch(1);
        BadVpnTunnelBackend backend = backend(runtime, failure::countDown);
        backend.start();

        for (int index = 0; index < 4; index += 1) {
            final int processIndex = index;
            await(() -> runtime.processes.size() > processIndex, "Missing process " + processIndex);
            runtime.processes.get(index).exit(index + 1);
        }

        assertTrue(failure.await(2, TimeUnit.SECONDS));
        assertEquals(4, runtime.processes.size());
        backend.stop();
    }

    @Test
    public void stopEscalatesToForcedTermination() throws Exception {
        FakeRuntime runtime = new FakeRuntime();
        runtime.destroyStopsProcess = false;
        BadVpnTunnelBackend backend = backend(runtime, () -> {});
        backend.start();

        backend.stop();

        FakeProcess process = runtime.processes.get(0);
        assertEquals(1, process.destroyCalls);
        assertEquals(1, process.forceDestroyCalls);
        assertFalse(process.isAlive());
    }

    @Test
    public void survivesOneHundredStartStopCycles() throws Exception {
        FakeRuntime runtime = new FakeRuntime();
        BadVpnTunnelBackend backend = backend(runtime, () -> {});
        TunnelLifecycle lifecycle = new TunnelLifecycle();

        for (int cycle = 0; cycle < 100; cycle += 1) {
            assertTrue(lifecycle.start(backend));
            assertTrue(lifecycle.stop());
        }

        assertEquals(100, runtime.processes.size());
        assertEquals(100, runtime.handoffCalls);
        assertEquals(TunnelLifecycle.State.STOPPED, lifecycle.state());
    }

    private BadVpnTunnelBackend backend(FakeRuntime runtime, Runnable failureCallback)
            throws IOException {
        return new BadVpnTunnelBackend(
                temporaryFolder.newFile("tun2socks-" + runtime.hashCode()),
                temporaryFolder.getRoot(),
                new FileDescriptor(),
                10_808,
                failureCallback,
                runtime);
    }

    private static void await(Check check, String message) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2L);
        while (!check.isTrue() && System.nanoTime() < deadline) {
            Thread.sleep(5L);
        }
        assertTrue(message, check.isTrue());
    }

    private interface Check {
        boolean isTrue();
    }

    private static final class FakeRuntime implements BadVpnRuntime {
        private final List<FakeProcess> processes = Collections.synchronizedList(new ArrayList<>());
        private final List<List<String>> commands = Collections.synchronizedList(new ArrayList<>());
        private final List<File> socketFiles = Collections.synchronizedList(new ArrayList<>());
        private volatile long nowNanos;
        private volatile int handoffFailures;
        private volatile int handoffCalls;
        private volatile boolean alwaysFailHandoff;
        private volatile boolean destroyStopsProcess = true;

        @Override
        public BadVpnProcess launch(List<String> command, File workingDirectory) {
            FakeProcess process = new FakeProcess(destroyStopsProcess);
            commands.add(new ArrayList<>(command));
            processes.add(process);
            return process;
        }

        @Override
        public void sendFileDescriptor(File socketFile, FileDescriptor fileDescriptor)
                throws IOException {
            handoffCalls += 1;
            socketFiles.add(socketFile);
            if (alwaysFailHandoff || handoffCalls <= handoffFailures) {
                throw new IOException("not ready");
            }
        }

        @Override
        public long nanoTime() {
            return nowNanos;
        }

        @Override
        public void sleep(long millis) {
            nowNanos += TimeUnit.MILLISECONDS.toNanos(millis);
        }

        @Override
        public void logInfo(String message) {}

        @Override
        public void logWarning(String message, Throwable error) {}

        @Override
        public void logError(String message, Throwable error) {}
    }

    private static final class FakeProcess implements BadVpnProcess {
        private final CountDownLatch exited = new CountDownLatch(1);
        private final boolean destroyStopsProcess;
        private volatile boolean alive = true;
        private volatile int exitCode;
        private volatile int destroyCalls;
        private volatile int forceDestroyCalls;

        private FakeProcess(boolean destroyStopsProcess) {
            this.destroyStopsProcess = destroyStopsProcess;
        }

        @Override
        public InputStream outputStream() {
            return new ByteArrayInputStream(new byte[0]);
        }

        @Override
        public boolean isAlive() {
            return alive;
        }

        @Override
        public int waitFor() throws InterruptedException {
            exited.await();
            return exitCode;
        }

        @Override
        public boolean waitFor(long timeout, TimeUnit unit) throws InterruptedException {
            return exited.await(timeout, unit);
        }

        @Override
        public void destroy() {
            destroyCalls += 1;
            if (destroyStopsProcess) {
                exit(0);
            }
        }

        @Override
        public void destroyForcibly() {
            forceDestroyCalls += 1;
            exit(137);
        }

        private void exit(int code) {
            exitCode = code;
            alive = false;
            exited.countDown();
        }
    }
}
