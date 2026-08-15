package dev.zikwall.flutter_xray.tunnel;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import org.junit.Test;

public final class TunnelBackendKindTest {
    @Test
    public void defaultsToBadVpn() {
        assertEquals(TunnelBackendKind.BADVPN, TunnelBackendKind.fromConfigValue(null));
        assertEquals(TunnelBackendKind.BADVPN, TunnelBackendKind.fromConfigValue("  "));
        assertEquals(TunnelBackendKind.BADVPN, TunnelBackendKind.fromConfigValue("badvpn"));
    }

    @Test
    public void acceptsHev() {
        assertEquals(TunnelBackendKind.HEV, TunnelBackendKind.fromConfigValue("HEV"));
    }

    @Test
    public void acceptsXray() {
        assertEquals(TunnelBackendKind.XRAY, TunnelBackendKind.fromConfigValue("xray"));
    }

    @Test
    public void rejectsUnknownBackend() {
        assertThrows(
                IllegalArgumentException.class,
                () -> TunnelBackendKind.fromConfigValue("unknown"));
    }
}
