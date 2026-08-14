package dev.zikwall.flutter_xray.tunnel;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public final class HevTunnelBackendTest {
    @Rule public final TemporaryFolder temporaryFolder = new TemporaryFolder();

    @Test
    public void startWritesConfigAndPassesTunFileDescriptor() throws Exception {
        File config = temporaryFolder.newFile("hev.yaml");
        FakeNativeBridge bridge = new FakeNativeBridge();
        HevTunnelBackend backend = backend(config, bridge, () -> {});

        backend.start();

        assertEquals(config.getAbsolutePath(), bridge.configPath);
        assertEquals(42, bridge.tunFileDescriptor);
        assertEquals("config-content", new String(
                Files.readAllBytes(config.toPath()), StandardCharsets.UTF_8));
        assertEquals(1, bridge.startCalls);
        backend.stop();
    }

    @Test
    public void lifecycleCleansUpRejectedStart() throws Exception {
        FakeNativeBridge bridge = new FakeNativeBridge();
        bridge.acceptStart = false;
        HevTunnelBackend backend = backend(
                temporaryFolder.newFile("rejected.yaml"), bridge, () -> {});
        TunnelLifecycle lifecycle = new TunnelLifecycle();

        assertThrows(Exception.class, () -> lifecycle.start(backend));

        assertEquals(TunnelLifecycle.State.STOPPED, lifecycle.state());
        assertEquals(1, bridge.startCalls);
        assertFalse(bridge.running);
    }

    @Test
    public void reportsUnexpectedNativeExit() throws Exception {
        CountDownLatch failed = new CountDownLatch(1);
        FakeNativeBridge bridge = new FakeNativeBridge();
        HevTunnelBackend backend = backend(
                temporaryFolder.newFile("health.yaml"), bridge, failed::countDown);
        backend.start();

        bridge.running = false;

        assertTrue(failed.await(2, TimeUnit.SECONDS));
        backend.stop();
    }

    @Test
    public void survivesOneHundredStartStopCycles() throws Exception {
        FakeNativeBridge bridge = new FakeNativeBridge();
        HevTunnelBackend backend = backend(
                temporaryFolder.newFile("cycles.yaml"), bridge, () -> {});
        TunnelLifecycle lifecycle = new TunnelLifecycle();

        for (int cycle = 0; cycle < 100; cycle += 1) {
            assertTrue(lifecycle.start(backend));
            assertTrue(lifecycle.stop());
        }

        assertEquals(100, bridge.startCalls);
        assertEquals(100, bridge.stopCalls);
        assertEquals(TunnelLifecycle.State.STOPPED, lifecycle.state());
    }

    private static HevTunnelBackend backend(
            File configFile, FakeNativeBridge bridge, Runnable failureCallback) {
        return new HevTunnelBackend(
                configFile,
                "config-content",
                42,
                failureCallback,
                bridge);
    }

    private static final class FakeNativeBridge implements HevNativeBridge {
        private boolean acceptStart = true;
        private volatile boolean running;
        private int startCalls;
        private int stopCalls;
        private String configPath;
        private int tunFileDescriptor;

        @Override
        public boolean start(String configPath, int tunFileDescriptor) {
            startCalls += 1;
            this.configPath = configPath;
            this.tunFileDescriptor = tunFileDescriptor;
            running = acceptStart;
            return acceptStart;
        }

        @Override
        public boolean stop() {
            stopCalls += 1;
            running = false;
            return true;
        }

        @Override
        public boolean isRunning() {
            return running;
        }

        @Override
        public long[] stats() {
            return new long[4];
        }
    }
}
