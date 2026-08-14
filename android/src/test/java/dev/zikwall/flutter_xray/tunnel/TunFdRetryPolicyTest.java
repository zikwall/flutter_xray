package dev.zikwall.flutter_xray.tunnel;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

import java.util.concurrent.TimeUnit;

public class TunFdRetryPolicyTest {
    @Test
    public void retryDelayStartsImmediatelyAndCapsAtMaximum() {
        assertEquals(0L, TunFdRetryPolicy.retryDelayMillis(0));
        assertEquals(50L, TunFdRetryPolicy.retryDelayMillis(1));
        assertEquals(100L, TunFdRetryPolicy.retryDelayMillis(2));
        assertEquals(250L, TunFdRetryPolicy.retryDelayMillis(5));
        assertEquals(250L, TunFdRetryPolicy.retryDelayMillis(100));
    }

    @Test
    public void remainingTimeUsesMonotonicDeadlineAndNeverBecomesNegative() {
        long startedAt = 10_000L;

        assertEquals(5_000L, TunFdRetryPolicy.remainingMillis(startedAt, startedAt));
        assertEquals(
                3_750L,
                TunFdRetryPolicy.remainingMillis(
                        startedAt, startedAt + TimeUnit.MILLISECONDS.toNanos(1_250L)));
        assertEquals(
                0L,
                TunFdRetryPolicy.remainingMillis(
                        startedAt, startedAt + TimeUnit.SECONDS.toNanos(6L)));
    }
}
