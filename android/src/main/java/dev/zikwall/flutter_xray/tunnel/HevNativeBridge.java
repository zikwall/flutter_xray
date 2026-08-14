package dev.zikwall.flutter_xray.tunnel;

interface HevNativeBridge {
    boolean start(String configPath, int tunFileDescriptor);

    boolean stop();

    boolean isRunning();

    long[] stats();
}
