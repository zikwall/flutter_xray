package dev.zikwall.flutter_xray.tunnel;

import java.util.Locale;

/** Immutable HEV configuration for the local Xray SOCKS5 inbound. */
public final class HevTunnelConfig {
    public static final int DEFAULT_MTU = 1500;
    public static final String DEFAULT_IPV4 = "26.26.26.1";
    public static final String DEFAULT_IPV6 = "fc00::26:26:26:1";

    private final int socksPort;
    private final int mtu;
    private final boolean ipv6Enabled;

    public HevTunnelConfig(int socksPort, int mtu, boolean ipv6Enabled) {
        if (socksPort < 1 || socksPort > 65535) {
            throw new IllegalArgumentException("SOCKS5 port must be between 1 and 65535");
        }
        if (mtu < 1280 || mtu > 9000) {
            throw new IllegalArgumentException("MTU must be between 1280 and 9000");
        }
        this.socksPort = socksPort;
        this.mtu = mtu;
        this.ipv6Enabled = ipv6Enabled;
    }

    public String toYaml() {
        StringBuilder yaml = new StringBuilder();
        yaml.append("tunnel:\n");
        yaml.append("  mtu: ").append(mtu).append('\n');
        yaml.append("  ipv4: ").append(DEFAULT_IPV4).append('\n');
        if (ipv6Enabled) {
            yaml.append("  ipv6: '").append(DEFAULT_IPV6).append("'\n");
        }
        yaml.append("socks5:\n");
        yaml.append("  port: ").append(socksPort).append('\n');
        yaml.append("  address: 127.0.0.1\n");
        yaml.append("  udp: 'udp'\n");
        yaml.append("misc:\n");
        yaml.append("  tcp-read-write-timeout: 300000\n");
        yaml.append("  udp-read-write-timeout: 60000\n");
        yaml.append("  log-level: warn\n");
        return yaml.toString();
    }

    @Override
    public String toString() {
        return String.format(Locale.ROOT, "HEV(socks=127.0.0.1:%d, mtu=%d, ipv6=%s)",
                socksPort, mtu, ipv6Enabled);
    }
}
