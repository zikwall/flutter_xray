package dev.zikwall.flutter_xray.tunnel;

import java.util.Locale;

public enum TunnelBackendKind {
    BADVPN,
    XRAY,
    HEV;

    public static TunnelBackendKind fromConfigValue(String value) {
        if (value == null || value.trim().isEmpty()) {
            return BADVPN;
        }
        String normalized = value.trim().toLowerCase(Locale.ROOT);
        if (normalized.equals("hev")) {
            return HEV;
        }
        if (normalized.equals("xray")) {
            return XRAY;
        }
        if (normalized.equals("badvpn")) {
            return BADVPN;
        }
        throw new IllegalArgumentException("Unsupported tunnel backend: " + value);
    }
}
