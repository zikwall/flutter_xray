package dev.zikwall.flutter_xray.tunnel;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.os.Build;
import android.util.Log;

import java.io.File;
import java.io.FileDescriptor;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.List;
import java.util.concurrent.TimeUnit;

/** Production BadVPN runtime backed by Android local sockets and {@link ProcessBuilder}. */
final class AndroidBadVpnRuntime implements BadVpnRuntime {
    private static final String TAG = "BadVpnTunnelBackend";

    @Override
    public BadVpnProcess launch(List<String> command, File workingDirectory) throws IOException {
        ProcessBuilder builder = new ProcessBuilder(command);
        builder.redirectErrorStream(true);
        return new AndroidProcess(builder.directory(workingDirectory).start());
    }

    @Override
    public void sendFileDescriptor(File socketFile, FileDescriptor fileDescriptor) throws IOException {
        LocalSocket socket = new LocalSocket();
        try {
            socket.connect(new LocalSocketAddress(
                    socketFile.getAbsolutePath(), LocalSocketAddress.Namespace.FILESYSTEM));
            if (!socket.isConnected()) {
                throw new IOException("tun2socks control socket is not connected");
            }
            socket.setFileDescriptorsForSend(new FileDescriptor[] {fileDescriptor});
            OutputStream output = socket.getOutputStream();
            output.write(32);
            output.flush();
        } finally {
            try {
                socket.setFileDescriptorsForSend(null);
            } catch (Exception ignored) {
                // The socket is closed below. There is no remaining descriptor owner to clean up.
            }
            try {
                socket.close();
            } catch (Exception ignored) {
                // Closing an already failed local socket is best effort.
            }
        }
    }

    @Override
    public long nanoTime() {
        return System.nanoTime();
    }

    @Override
    public void sleep(long millis) throws InterruptedException {
        Thread.sleep(millis);
    }

    @Override
    public void logInfo(String message) {
        Log.i(TAG, message);
    }

    @Override
    public void logWarning(String message, Throwable error) {
        Log.w(TAG, message, error);
    }

    @Override
    public void logError(String message, Throwable error) {
        Log.e(TAG, message, error);
    }

    private static final class AndroidProcess implements BadVpnProcess {
        private final Process process;

        private AndroidProcess(Process process) {
            this.process = process;
        }

        @Override
        public InputStream outputStream() {
            return process.getInputStream();
        }

        @Override
        public boolean isAlive() {
            try {
                process.exitValue();
                return false;
            } catch (IllegalThreadStateException ignored) {
                return true;
            }
        }

        @Override
        public int waitFor() throws InterruptedException {
            return process.waitFor();
        }

        @Override
        public boolean waitFor(long timeout, TimeUnit unit) throws InterruptedException {
            long deadline = System.nanoTime() + unit.toNanos(timeout);
            while (isAlive() && System.nanoTime() < deadline) {
                Thread.sleep(20L);
            }
            return !isAlive();
        }

        @Override
        public void destroy() {
            process.destroy();
        }

        @Override
        public void destroyForcibly() throws IOException {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                process.destroyForcibly();
                return;
            }
            // Process.destroy() maps to SIGKILL on the Android releases supported below API 26.
            process.destroy();
        }
    }
}
