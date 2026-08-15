package dev.zikwall.flutter_xray.tunnel;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** Converts the plugin's local SOCKS inbound into Xray's Android native TUN inbound. */
public final class XrayTunConfigTransformer {
    public static final String DEFAULT_NAME = "xray0";

    private XrayTunConfigTransformer() {
    }

    public static String transform(String config, int socksPort, int mtu) throws JSONException {
        if (config == null || config.trim().isEmpty()) {
            throw new IllegalArgumentException("Xray config must not be empty");
        }
        if (mtu <= 0) {
            throw new IllegalArgumentException("TUN MTU must be positive");
        }

        JSONObject root = new JSONObject(config);
        JSONArray inbounds = root.optJSONArray("inbounds");
        if (inbounds == null || inbounds.length() == 0) {
            throw new IllegalArgumentException("Xray config must contain a SOCKS inbound");
        }

        int selectedIndex = -1;
        int socksCount = 0;
        for (int index = 0; index < inbounds.length(); index++) {
            JSONObject inbound = inbounds.optJSONObject(index);
            if (inbound == null || !"socks".equalsIgnoreCase(inbound.optString("protocol"))) {
                continue;
            }
            socksCount++;
            if (portMatches(inbound.opt("port"), socksPort)) {
                if (selectedIndex != -1) {
                    throw new IllegalArgumentException(
                            "Xray config contains multiple SOCKS inbounds on port " + socksPort);
                }
                selectedIndex = index;
            }
        }

        if (selectedIndex == -1 && socksCount == 1) {
            for (int index = 0; index < inbounds.length(); index++) {
                JSONObject inbound = inbounds.optJSONObject(index);
                if (inbound != null && "socks".equalsIgnoreCase(inbound.optString("protocol"))) {
                    selectedIndex = index;
                    break;
                }
            }
        }
        if (selectedIndex == -1) {
            String reason = socksCount == 0
                    ? "Xray config does not contain a SOCKS inbound"
                    : "Xray config contains multiple SOCKS inbounds and none uniquely matches port " + socksPort;
            throw new IllegalArgumentException(reason);
        }

        JSONObject source = inbounds.getJSONObject(selectedIndex);
        JSONObject tun = new JSONObject();
        copyIfPresent(source, tun, "tag");
        copyIfPresent(source, tun, "sniffing");
        tun.put("protocol", "tun");
        tun.put("settings", new JSONObject()
                .put("name", DEFAULT_NAME)
                .put("mtu", mtu));
        inbounds.put(selectedIndex, tun);
        return root.toString();
    }

    private static boolean portMatches(Object value, int expectedPort) {
        if (expectedPort <= 0 || value == null || value == JSONObject.NULL) {
            return false;
        }
        if (value instanceof Number) {
            return ((Number) value).intValue() == expectedPort;
        }
        try {
            return Integer.parseInt(String.valueOf(value)) == expectedPort;
        } catch (NumberFormatException ignored) {
            return false;
        }
    }

    private static void copyIfPresent(JSONObject source, JSONObject target, String key)
            throws JSONException {
        if (source.has(key)) {
            target.put(key, source.get(key));
        }
    }
}
