package dev.zikwall.flutter_xray.tunnel;

final class HevNative implements HevNativeBridge {
    private static native boolean TProxyStartService(String configPath, int tunFileDescriptor);

    private static native boolean TProxyStopService();

    private static native boolean TProxyIsRunning();

    private static native long[] TProxyGetStats();

    static {
        System.loadLibrary("hev-socks5-tunnel");
    }

    @Override
    public boolean start(String configPath, int tunFileDescriptor) {
        return TProxyStartService(configPath, tunFileDescriptor);
    }

    @Override
    public boolean stop() {
        return TProxyStopService();
    }

    @Override
    public boolean isRunning() {
        return TProxyIsRunning();
    }

    @Override
    public long[] stats() {
        return TProxyGetStats();
    }
}
