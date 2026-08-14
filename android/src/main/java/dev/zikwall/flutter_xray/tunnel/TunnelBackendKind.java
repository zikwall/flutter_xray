package dev.zikwall.flutter_xray.tunnel;

import java.util.Locale;

public enum TunnelBackendKind {
    BADVPN,
    HEV;

    public static TunnelBackendKind fromConfigValue(String value) {
        if (value == null || value.trim().isEmpty()) {
            return BADVPN;
        }
        String normalized = value.trim().toLowerCase(Locale.ROOT);
        if (normalized.equals("hev") || normalized.equals("hev-socks5-tunnel")) {
            return HEV;
        }
        if (normalized.equals("badvpn") || normalized.equals("badvpn-tun2socks")) {
            return BADVPN;
        }
        throw new IllegalArgumentException("Unsupported tunnel backend: " + value);
    }
}
