package dev.zikwall.flutter_xray.tunnel;

/** Owns an Xray native TUN runtime and the Android TUN descriptor backing it. */
public final class XrayTunBackend implements TunnelBackend {
    public interface CoreRuntime {
        boolean start() throws Exception;

        void stop() throws Exception;
    }

    public interface TunHandle {
        void close() throws Exception;
    }

    private final CoreRuntime coreRuntime;
    private final TunHandle tunHandle;
    private boolean closed;

    public XrayTunBackend(CoreRuntime coreRuntime, TunHandle tunHandle) {
        if (coreRuntime == null) {
            throw new NullPointerException("coreRuntime");
        }
        if (tunHandle == null) {
            throw new NullPointerException("tunHandle");
        }
        this.coreRuntime = coreRuntime;
        this.tunHandle = tunHandle;
    }

    @Override
    public String name() {
        return "xray-native-tun";
    }

    @Override
    public synchronized void start() throws Exception {
        if (closed) {
            throw new IllegalStateException("Xray native TUN backend is already closed");
        }
        if (!coreRuntime.start()) {
            throw new IllegalStateException("Xray core rejected the native TUN configuration");
        }
    }

    @Override
    public synchronized void stop() throws Exception {
        if (closed) {
            return;
        }
        closed = true;

        Exception failure = null;
        try {
            coreRuntime.stop();
        } catch (Exception error) {
            failure = error;
        }
        try {
            tunHandle.close();
        } catch (Exception error) {
            if (failure == null) {
                failure = error;
            } else {
                failure.addSuppressed(error);
            }
        }
        if (failure != null) {
            throw failure;
        }
    }
}
