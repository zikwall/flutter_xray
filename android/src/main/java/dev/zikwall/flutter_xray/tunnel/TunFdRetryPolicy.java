package dev.zikwall.flutter_xray.tunnel;

import java.util.concurrent.TimeUnit;

final class TunFdRetryPolicy {
    static final long READY_TIMEOUT_MILLIS = 5_000L;
    static final long INITIAL_RETRY_DELAY_MILLIS = 50L;
    static final long MAX_RETRY_DELAY_MILLIS = 250L;

    private TunFdRetryPolicy() {
    }

    static long retryDelayMillis(int failedAttempts) {
        if (failedAttempts <= 0) {
            return 0L;
        }
        return Math.min(
                MAX_RETRY_DELAY_MILLIS,
                INITIAL_RETRY_DELAY_MILLIS * failedAttempts);
    }

    static long remainingMillis(long startedAtNanos, long nowNanos) {
        long elapsedNanos = Math.max(0L, nowNanos - startedAtNanos);
        long elapsedMillis = TimeUnit.NANOSECONDS.toMillis(elapsedNanos);
        return Math.max(0L, READY_TIMEOUT_MILLIS - elapsedMillis);
    }
}
