package dev.zikwall.flutter_xray.tunnel;

import java.io.File;
import java.io.FileDescriptor;
import java.io.IOException;
import java.util.List;

/** Android-dependent operations used by the BadVPN supervisor. */
interface BadVpnRuntime {
    BadVpnProcess launch(List<String> command, File workingDirectory) throws IOException;

    void sendFileDescriptor(File socketFile, FileDescriptor fileDescriptor) throws IOException;

    long nanoTime();

    void sleep(long millis) throws InterruptedException;

    void logInfo(String message);

    void logWarning(String message, Throwable error);

    void logError(String message, Throwable error);
}
