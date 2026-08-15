package dev.zikwall.flutter_xray.benchmark_probe;

import android.app.Activity;
import android.os.Bundle;
import android.util.Base64;
import android.util.Log;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.regex.Pattern;

public final class BenchmarkProbeActivity extends Activity {
    private static final String TAG = "FlutterXrayProbe";
    private static final Pattern SAFE_TOKEN = Pattern.compile("^[a-zA-Z0-9_.-]+$");
    private static final AtomicBoolean PROBE_RUNNING = new AtomicBoolean(false);

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (!PROBE_RUNNING.compareAndSet(false, true)) {
            Log.w(TAG, "DEVICE_BENCHMARK DUPLICATE_ACTIVITY_REJECTED");
            finish();
            return;
        }
        new Thread(this::runProbe, "flutter-xray-benchmark-probe").start();
    }

    private void runProbe() {
        String phaseId = "invalid";
        boolean callbackOk = false;
        try {
            phaseId = requiredToken("phase_id");
            final String profile = requiredToken("profile");
            final String backend = requiredToken("backend");
            final int round = positiveInt("round", 1, 1000);
            final int position = positiveInt("position", 1, 3);
            final int concurrency = positiveInt("concurrency", 1, 16);
            final int warmupSeconds = positiveInt("warmup_seconds", 1, 600);
            final int measureSeconds = positiveInt("measure_seconds", 5, 3600);
            final int callbackPort = positiveInt("callback_port", 1024, 65535);
            final URL payloadUrl = decodedUrl("url_b64");
            final URL egressUrl = decodedUrl("egress_url_b64");
            final String expectedEgress = getIntent().getStringExtra("expected_egress");
            if (expectedEgress == null || expectedEgress.trim().isEmpty()) {
                throw new IllegalArgumentException("expected_egress is required");
            }

            final String actualEgress = readText(egressUrl).trim();
            Log.i(TAG, "DEVICE_BENCHMARK PROBE_EGRESS phase_id=" + phaseId
                    + " expected=" + expectedEgress + " actual=" + actualEgress);
            if (!expectedEgress.equals(actualEgress)) {
                emitResult(phaseId, profile, backend, round, position, concurrency,
                        new TransferResult(
                                0,
                                0,
                                1,
                                0,
                                Collections.singleton("EgressMismatch")
                        ));
                postDone(callbackPort, phaseId, false);
                return;
            }

            transferFor(payloadUrl, warmupSeconds, concurrency);
            final long startedAt = System.currentTimeMillis();
            Log.i(TAG, "DEVICE_BENCHMARK PHASE_BEGIN phase_id=" + phaseId
                    + " profile=" + profile + " backend=" + backend
                    + " round=" + round + " position=" + position
                    + " concurrency=" + concurrency + " unix_ms=" + startedAt);
            final TransferResult result = transferFor(
                    payloadUrl,
                    measureSeconds,
                    concurrency
            );
            final long endedAt = System.currentTimeMillis();
            Log.i(TAG, "DEVICE_BENCHMARK PHASE_END phase_id=" + phaseId
                    + " unix_ms=" + endedAt);
            emitResult(phaseId, profile, backend, round, position, concurrency, result);
            callbackOk = result.bytes > 100_000 && result.errors == 0;
            postDone(callbackPort, phaseId, callbackOk);
        } catch (Exception error) {
            Log.e(TAG, "DEVICE_BENCHMARK PROBE_FATAL phase_id=" + phaseId
                    + " error=" + error.getClass().getSimpleName(), error);
            final int callbackPort = getIntent().getIntExtra("callback_port", 0);
            if (callbackPort > 0) {
                postDone(callbackPort, phaseId, false);
            }
        } finally {
            final boolean completed = callbackOk;
            PROBE_RUNNING.set(false);
            runOnUiThread(() -> {
                setResult(completed ? RESULT_OK : RESULT_CANCELED);
                finishAndRemoveTask();
            });
        }
    }

    private TransferResult transferFor(URL url, int seconds, int concurrency) throws Exception {
        final long startedNanos = System.nanoTime();
        final long deadlineNanos = startedNanos + seconds * 1_000_000_000L;
        final ExecutorService workers = Executors.newFixedThreadPool(concurrency);
        final List<Future<WorkerResult>> futures = new ArrayList<>();
        try {
            for (int index = 0; index < concurrency; index += 1) {
                futures.add(workers.submit(new DownloadWorker(url, deadlineNanos)));
            }
            long bytes = 0;
            int requests = 0;
            int errors = 0;
            final Set<String> errorTypes = new HashSet<>();
            for (Future<WorkerResult> future : futures) {
                final WorkerResult result = future.get();
                bytes += result.bytes;
                requests += result.requests;
                errors += result.errors;
                errorTypes.addAll(result.errorTypes);
            }
            final long elapsedMs = (System.nanoTime() - startedNanos) / 1_000_000L;
            return new TransferResult(bytes, requests, errors, elapsedMs, errorTypes);
        } finally {
            workers.shutdownNow();
        }
    }

    private void emitResult(
            String phaseId,
            String profile,
            String backend,
            int round,
            int position,
            int concurrency,
            TransferResult result
    ) {
        final double mbps = result.elapsedMs <= 0
                ? 0
                : result.bytes * 8.0 / result.elapsedMs / 1000.0;
        final List<String> sortedErrors = new ArrayList<>(result.errorTypes);
        sortedErrors.sort(String::compareTo);
        Log.i(TAG, String.format(java.util.Locale.US,
                "DEVICE_BENCHMARK RESULT phase_id=%s profile=%s backend=%s "
                        + "round=%d position=%d concurrency=%d bytes=%d elapsed_ms=%d "
                        + "mbps=%.3f requests=%d errors=%d error_types=%s",
                phaseId, profile, backend, round, position, concurrency,
                result.bytes, result.elapsedMs, mbps, result.requests, result.errors,
                String.join(",", sortedErrors)));
    }

    private void postDone(int port, String phaseId, boolean ok) {
        HttpURLConnection connection = null;
        try {
            final String query = "phase_id=" + URLEncoder.encode(
                    phaseId,
                    StandardCharsets.UTF_8.name()
            ) + "&ok=" + ok;
            connection = (HttpURLConnection) new URL(
                    "http://127.0.0.1:" + port + "/done?" + query
            ).openConnection();
            connection.setConnectTimeout(3000);
            connection.setReadTimeout(3000);
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.getOutputStream().close();
            connection.getResponseCode();
        } catch (Exception error) {
            Log.e(TAG, "DEVICE_BENCHMARK CALLBACK_FAILED phase_id=" + phaseId, error);
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private String readText(URL url) throws Exception {
        final HttpURLConnection connection = open(url);
        requireSuccess(connection);
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                connection.getInputStream(),
                StandardCharsets.UTF_8
        ))) {
            final StringBuilder body = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null && body.length() < 1024) {
                body.append(line);
            }
            return body.toString();
        } finally {
            connection.disconnect();
        }
    }

    private static HttpURLConnection open(URL url) throws Exception {
        final HttpURLConnection connection = (HttpURLConnection) url.openConnection();
        connection.setConnectTimeout(15_000);
        connection.setReadTimeout(20_000);
        connection.setUseCaches(false);
        connection.setRequestProperty("Accept-Encoding", "identity");
        connection.setRequestProperty("Cache-Control", "no-cache");
        connection.setRequestProperty(
                "User-Agent",
                "Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 "
                        + "(KHTML, like Gecko) Chrome/151.0 Mobile Safari/537.36"
        );
        return connection;
    }

    private static void requireSuccess(HttpURLConnection connection) throws Exception {
        final int status = connection.getResponseCode();
        if (status < 200 || status >= 300) {
            connection.disconnect();
            throw new IllegalStateException("HTTP " + status);
        }
    }

    private String requiredToken(String name) {
        final String value = getIntent().getStringExtra(name);
        if (value == null || !SAFE_TOKEN.matcher(value).matches()) {
            throw new IllegalArgumentException("invalid " + name);
        }
        return value;
    }

    private int positiveInt(String name, int min, int max) {
        final int value = getIntent().getIntExtra(name, -1);
        if (value < min || value > max) {
            throw new IllegalArgumentException("invalid " + name);
        }
        return value;
    }

    private URL decodedUrl(String name) throws Exception {
        final String encoded = getIntent().getStringExtra(name);
        if (encoded == null) {
            throw new IllegalArgumentException("missing " + name);
        }
        final String value = new String(Base64.decode(encoded, Base64.NO_WRAP), StandardCharsets.UTF_8);
        final URL url = new URL(value);
        if (!"http".equals(url.getProtocol()) && !"https".equals(url.getProtocol())) {
            throw new IllegalArgumentException("invalid URL scheme");
        }
        return url;
    }

    private static final class DownloadWorker implements Callable<WorkerResult> {
        private final URL url;
        private final long deadlineNanos;

        private DownloadWorker(URL url, long deadlineNanos) {
            this.url = url;
            this.deadlineNanos = deadlineNanos;
        }

        @Override
        public WorkerResult call() {
            long bytes = 0;
            int requests = 0;
            int errors = 0;
            final Set<String> errorTypes = new HashSet<>();
            while (System.nanoTime() < deadlineNanos) {
                HttpURLConnection connection = null;
                try {
                    connection = open(url);
                    requireSuccess(connection);
                    requests += 1;
                    try (BufferedInputStream input = new BufferedInputStream(connection.getInputStream(), 65536)) {
                        final byte[] buffer = new byte[65536];
                        while (System.nanoTime() < deadlineNanos) {
                            final int count = input.read(buffer);
                            if (count < 0) {
                                break;
                            }
                            bytes += count;
                        }
                    }
                } catch (Exception error) {
                    if (System.nanoTime() < deadlineNanos || bytes == 0) {
                        if (errors == 0) {
                            Log.w(TAG, "DEVICE_BENCHMARK TRANSFER_ERROR "
                                    + error.getClass().getSimpleName() + ": "
                                    + String.valueOf(error.getMessage()), error);
                        }
                        errors += 1;
                        errorTypes.add(error.getClass().getSimpleName());
                        try {
                            Thread.sleep(100);
                        } catch (InterruptedException interrupted) {
                            Thread.currentThread().interrupt();
                            break;
                        }
                    }
                } finally {
                    if (connection != null) {
                        connection.disconnect();
                    }
                }
            }
            return new WorkerResult(bytes, requests, errors, errorTypes);
        }
    }

    private static class WorkerResult {
        final long bytes;
        final int requests;
        final int errors;
        final Set<String> errorTypes;

        WorkerResult(long bytes, int requests, int errors, Set<String> errorTypes) {
            this.bytes = bytes;
            this.requests = requests;
            this.errors = errors;
            this.errorTypes = errorTypes;
        }
    }

    private static final class TransferResult extends WorkerResult {
        final long elapsedMs;

        TransferResult(long bytes, int requests, int errors, long elapsedMs, Set<String> errorTypes) {
            super(bytes, requests, errors, errorTypes);
            this.elapsedMs = elapsedMs;
        }
    }
}
