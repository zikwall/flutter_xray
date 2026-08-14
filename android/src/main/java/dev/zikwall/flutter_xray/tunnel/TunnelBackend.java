package dev.zikwall.flutter_xray.tunnel;

/** A single implementation that moves packets from an Android TUN interface. */
public interface TunnelBackend {
    /** Stable diagnostic name; this is not part of the Flutter API. */
    String name();

    /** Starts the backend. Implementations must return after background work is scheduled. */
    void start() throws Exception;

    /** Stops the backend and releases all resources owned by it. */
    void stop() throws Exception;
}
