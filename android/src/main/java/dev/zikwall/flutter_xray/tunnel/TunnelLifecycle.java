package dev.zikwall.flutter_xray.tunnel;

import java.util.Objects;

/**
 * Serializes ownership of the Android TUN data path.
 *
 * <p>Only one backend may own the TUN interface at a time. Calls are deliberately serialized so
 * rapid connect/disconnect requests cannot overlap backend start and stop operations.
 */
public final class TunnelLifecycle {
    public enum State {
        STOPPED,
        STARTING,
        RUNNING,
        STOPPING
    }

    private volatile State state = State.STOPPED;
    private TunnelBackend activeBackend;

    public State state() {
        return state;
    }

    public synchronized String activeBackendName() {
        return activeBackend == null ? null : activeBackend.name();
    }

    /**
     * Starts {@code backend} when stopped.
     *
     * @return {@code true} when this call started the backend, or {@code false} when a backend was
     *     already starting or running.
     */
    public synchronized boolean start(TunnelBackend backend) throws Exception {
        Objects.requireNonNull(backend, "backend");
        if (state != State.STOPPED) {
            return false;
        }

        activeBackend = backend;
        state = State.STARTING;
        try {
            backend.start();
            state = State.RUNNING;
            return true;
        } catch (Exception startError) {
            try {
                backend.stop();
            } catch (Exception cleanupError) {
                startError.addSuppressed(cleanupError);
            } finally {
                activeBackend = null;
                state = State.STOPPED;
            }
            throw startError;
        }
    }

    /**
     * Stops the active backend.
     *
     * @return {@code true} when this call stopped a backend, or {@code false} when already stopped.
     */
    public synchronized boolean stop() throws Exception {
        if (state == State.STOPPED) {
            return false;
        }

        TunnelBackend backend = activeBackend;
        state = State.STOPPING;
        try {
            if (backend != null) {
                backend.stop();
            }
            return true;
        } finally {
            activeBackend = null;
            state = State.STOPPED;
        }
    }
}
