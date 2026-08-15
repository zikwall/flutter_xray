package dev.zikwall.flutter_xray.tunnel;

import java.io.IOException;
import java.io.InputStream;
import java.util.concurrent.TimeUnit;

/** Testable handle for one BadVPN tun2socks child process. */
interface BadVpnProcess {
    InputStream outputStream();

    boolean isAlive();

    int waitFor() throws InterruptedException;

    boolean waitFor(long timeout, TimeUnit unit) throws InterruptedException;

    void destroy();

    void destroyForcibly() throws IOException;
}
