package dev.zikwall.flutter_xray.tunnel;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.assertThrows;

import org.junit.Test;

public final class HevTunnelConfigTest {
    @Test
    public void writesIpv4AndUdpConfiguration() {
        String yaml = new HevTunnelConfig(10808, 1500, false).toYaml();

        assertTrue(yaml.contains("  ipv4: 26.26.26.1\n"));
        assertTrue(yaml.contains("  port: 10808\n"));
        assertTrue(yaml.contains("  address: 127.0.0.1\n"));
        assertTrue(yaml.contains("  udp: 'udp'\n"));
        assertFalse(yaml.contains("  ipv6:"));
    }

    @Test
    public void writesIpv6WhenEnabled() {
        String yaml = new HevTunnelConfig(10808, 1500, true).toYaml();

        assertTrue(yaml.contains("  ipv6: 'fc00::26:26:26:1'\n"));
    }

    @Test
    public void rejectsInvalidPortAndMtu() {
        assertThrows(IllegalArgumentException.class, () -> new HevTunnelConfig(0, 1500, true));
        assertThrows(IllegalArgumentException.class, () -> new HevTunnelConfig(10808, 1279, true));
    }
}
