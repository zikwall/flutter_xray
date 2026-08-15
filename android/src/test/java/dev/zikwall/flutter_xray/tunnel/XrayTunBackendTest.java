package dev.zikwall.flutter_xray.tunnel;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertThrows;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public final class XrayTunBackendTest {
    @Test
    public void startsCoreAndStopsItBeforeClosingTun() throws Exception {
        List<String> events = new ArrayList<>();
        RecordingRuntime runtime = new RecordingRuntime(events);
        XrayTunBackend backend = new XrayTunBackend(runtime, () -> events.add("close-tun"));

        backend.start();
        backend.stop();
        backend.stop();

        assertEquals(Arrays.asList("start-core", "stop-core", "close-tun"), events);
    }

    @Test
    public void rejectedCoreStartIsCleanedUpByLifecycle() {
        List<String> events = new ArrayList<>();
        RecordingRuntime runtime = new RecordingRuntime(events);
        runtime.startResult = false;
        XrayTunBackend backend = new XrayTunBackend(runtime, () -> events.add("close-tun"));
        TunnelLifecycle lifecycle = new TunnelLifecycle();

        assertThrows(IllegalStateException.class, () -> lifecycle.start(backend));

        assertEquals(Arrays.asList("start-core", "stop-core", "close-tun"), events);
        assertEquals(TunnelLifecycle.State.STOPPED, lifecycle.state());
    }

    @Test
    public void closesTunWhenCoreStopFailsAndPreservesError() throws Exception {
        List<String> events = new ArrayList<>();
        RecordingRuntime runtime = new RecordingRuntime(events);
        Exception expected = new Exception("stop failed");
        runtime.stopError = expected;
        XrayTunBackend backend = new XrayTunBackend(runtime, () -> events.add("close-tun"));
        backend.start();

        Exception actual = assertThrows(Exception.class, backend::stop);

        assertSame(expected, actual);
        assertEquals(Arrays.asList("start-core", "stop-core", "close-tun"), events);
    }

    @Test
    public void oneHundredCyclesReleaseEveryTun() throws Exception {
        int starts = 0;
        int stops = 0;
        int closes = 0;
        for (int cycle = 0; cycle < 100; cycle++) {
            List<String> events = new ArrayList<>();
            XrayTunBackend backend = new XrayTunBackend(
                    new RecordingRuntime(events),
                    () -> events.add("close-tun"));
            TunnelLifecycle lifecycle = new TunnelLifecycle();
            lifecycle.start(backend);
            lifecycle.stop();
            starts += count(events, "start-core");
            stops += count(events, "stop-core");
            closes += count(events, "close-tun");
        }
        assertEquals(100, starts);
        assertEquals(100, stops);
        assertEquals(100, closes);
    }

    private static int count(List<String> values, String expected) {
        int result = 0;
        for (String value : values) {
            if (expected.equals(value)) {
                result++;
            }
        }
        return result;
    }

    private static final class RecordingRuntime implements XrayTunBackend.CoreRuntime {
        private final List<String> events;
        private boolean startResult = true;
        private Exception stopError;

        private RecordingRuntime(List<String> events) {
            this.events = events;
        }

        @Override
        public boolean start() {
            events.add("start-core");
            return startResult;
        }

        @Override
        public void stop() throws Exception {
            events.add("stop-core");
            if (stopError != null) {
                throw stopError;
            }
        }
    }
}
