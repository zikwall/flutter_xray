package dev.zikwall.flutter_xray.tunnel;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

public class TunnelLifecycleTest {
    @Test
    public void startAndStopOwnExactlyOneBackend() throws Exception {
        TunnelLifecycle lifecycle = new TunnelLifecycle();
        RecordingBackend backend = new RecordingBackend("legacy");

        assertTrue(lifecycle.start(backend));
        assertEquals(TunnelLifecycle.State.RUNNING, lifecycle.state());
        assertEquals("legacy", lifecycle.activeBackendName());
        assertFalse(lifecycle.start(new RecordingBackend("other")));
        assertEquals(1, backend.startCount);

        assertTrue(lifecycle.stop());
        assertEquals(TunnelLifecycle.State.STOPPED, lifecycle.state());
        assertNull(lifecycle.activeBackendName());
        assertEquals(1, backend.stopCount);
        assertFalse(lifecycle.stop());
    }

    @Test
    public void failedStartIsCleanedUpAndCanBeRetried() throws Exception {
        TunnelLifecycle lifecycle = new TunnelLifecycle();
        Exception expected = new Exception("start failed");
        RecordingBackend failed = new RecordingBackend("failed");
        failed.startError = expected;

        try {
            lifecycle.start(failed);
            fail("Expected start failure");
        } catch (Exception actual) {
            assertSame(expected, actual);
        }

        assertEquals(1, failed.stopCount);
        assertEquals(TunnelLifecycle.State.STOPPED, lifecycle.state());
        assertNull(lifecycle.activeBackendName());
        assertTrue(lifecycle.start(new RecordingBackend("retry")));
    }

    @Test
    public void failedStopStillReleasesLifecycleOwnership() throws Exception {
        TunnelLifecycle lifecycle = new TunnelLifecycle();
        Exception expected = new Exception("stop failed");
        RecordingBackend backend = new RecordingBackend("legacy");
        backend.stopError = expected;
        lifecycle.start(backend);

        try {
            lifecycle.stop();
            fail("Expected stop failure");
        } catch (Exception actual) {
            assertSame(expected, actual);
        }

        assertEquals(TunnelLifecycle.State.STOPPED, lifecycle.state());
        assertNull(lifecycle.activeBackendName());
    }

    @Test
    public void concurrentStopWaitsForStartToFinish() throws Exception {
        TunnelLifecycle lifecycle = new TunnelLifecycle();
        BlockingBackend backend = new BlockingBackend();
        ExecutorService executor = Executors.newFixedThreadPool(2);
        try {
            Future<Boolean> start = executor.submit(() -> lifecycle.start(backend));
            assertTrue(backend.startEntered.await(1, TimeUnit.SECONDS));
            assertEquals(TunnelLifecycle.State.STARTING, lifecycle.state());

            Future<Boolean> stop = executor.submit(lifecycle::stop);
            assertFalse(backend.stopEntered.await(100, TimeUnit.MILLISECONDS));

            backend.allowStartToFinish.countDown();
            assertTrue(start.get(1, TimeUnit.SECONDS));
            assertTrue(stop.get(1, TimeUnit.SECONDS));
            assertEquals(TunnelLifecycle.State.STOPPED, lifecycle.state());
            assertEquals(Arrays.asList("start", "stop"), backend.events);
        } finally {
            executor.shutdownNow();
        }
    }

    @Test
    public void repeatedConnectDisconnectLeavesNoActiveBackend() throws Exception {
        TunnelLifecycle lifecycle = new TunnelLifecycle();

        for (int cycle = 0; cycle < 100; cycle++) {
            RecordingBackend backend = new RecordingBackend("cycle-" + cycle);
            assertTrue(lifecycle.start(backend));
            assertTrue(lifecycle.stop());
            assertEquals(1, backend.startCount);
            assertEquals(1, backend.stopCount);
        }

        assertEquals(TunnelLifecycle.State.STOPPED, lifecycle.state());
        assertNull(lifecycle.activeBackendName());
    }

    private static class RecordingBackend implements TunnelBackend {
        private final String name;
        private int startCount;
        private int stopCount;
        private Exception startError;
        private Exception stopError;

        private RecordingBackend(String name) {
            this.name = name;
        }

        @Override
        public String name() {
            return name;
        }

        @Override
        public void start() throws Exception {
            startCount += 1;
            if (startError != null) {
                throw startError;
            }
        }

        @Override
        public void stop() throws Exception {
            stopCount += 1;
            if (stopError != null) {
                throw stopError;
            }
        }
    }

    private static final class BlockingBackend implements TunnelBackend {
        private final CountDownLatch startEntered = new CountDownLatch(1);
        private final CountDownLatch allowStartToFinish = new CountDownLatch(1);
        private final CountDownLatch stopEntered = new CountDownLatch(1);
        private final List<String> events = Collections.synchronizedList(new ArrayList<>());

        @Override
        public String name() {
            return "blocking";
        }

        @Override
        public void start() throws Exception {
            events.add("start");
            startEntered.countDown();
            if (!allowStartToFinish.await(1, TimeUnit.SECONDS)) {
                throw new IllegalStateException("test start timed out");
            }
        }

        @Override
        public void stop() {
            events.add("stop");
            stopEntered.countDown();
        }
    }
}
