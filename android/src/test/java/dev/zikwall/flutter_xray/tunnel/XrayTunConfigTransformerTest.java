package dev.zikwall.flutter_xray.tunnel;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;

public final class XrayTunConfigTransformerTest {
    @Test
    public void replacesMatchingSocksInboundAndPreservesRoutingIdentity() throws Exception {
        String config = "{"
                + "\"inbounds\":[{\"tag\":\"socks\",\"listen\":\"127.0.0.1\",\"port\":10808,"
                + "\"protocol\":\"socks\",\"settings\":{\"udp\":true},"
                + "\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\"]}}],"
                + "\"outbounds\":[{\"tag\":\"proxy\",\"protocol\":\"freedom\"}],"
                + "\"routing\":{\"rules\":[{\"inboundTag\":[\"socks\"],\"outboundTag\":\"proxy\"}]}"
                + "}";

        JSONObject result = new JSONObject(
                XrayTunConfigTransformer.transform(config, 10808, 1500));
        JSONObject inbound = result.getJSONArray("inbounds").getJSONObject(0);

        assertEquals("tun", inbound.getString("protocol"));
        assertEquals("socks", inbound.getString("tag"));
        assertEquals("xray0", inbound.getJSONObject("settings").getString("name"));
        assertEquals(1500, inbound.getJSONObject("settings").getInt("mtu"));
        assertTrue(inbound.getJSONObject("sniffing").getBoolean("enabled"));
        assertFalse(inbound.has("listen"));
        assertFalse(inbound.has("port"));
        assertEquals(
                "socks",
                result.getJSONObject("routing")
                        .getJSONArray("rules")
                        .getJSONObject(0)
                        .getJSONArray("inboundTag")
                        .getString(0));
        assertEquals("freedom", result.getJSONArray("outbounds")
                .getJSONObject(0).getString("protocol"));
    }

    @Test
    public void selectsSocksInboundByConfiguredPort() throws Exception {
        String config = "{\"inbounds\":["
                + "{\"tag\":\"other\",\"port\":2080,\"protocol\":\"socks\"},"
                + "{\"tag\":\"plugin\",\"port\":\"10808\",\"protocol\":\"socks\"},"
                + "{\"tag\":\"api\",\"port\":8080,\"protocol\":\"http\"}]}";

        JSONArray inbounds = new JSONObject(
                XrayTunConfigTransformer.transform(config, 10808, 1400))
                .getJSONArray("inbounds");

        assertEquals("socks", inbounds.getJSONObject(0).getString("protocol"));
        assertEquals("tun", inbounds.getJSONObject(1).getString("protocol"));
        assertEquals(1400, inbounds.getJSONObject(1).getJSONObject("settings").getInt("mtu"));
        assertEquals("http", inbounds.getJSONObject(2).getString("protocol"));
    }

    @Test
    public void rejectsMissingOrAmbiguousSocksInbound() {
        assertThrows(
                IllegalArgumentException.class,
                () -> XrayTunConfigTransformer.transform(
                        "{\"inbounds\":[{\"protocol\":\"http\",\"port\":8080}]}",
                        10808,
                        1500));
        assertThrows(
                IllegalArgumentException.class,
                () -> XrayTunConfigTransformer.transform(
                        "{\"inbounds\":[{\"protocol\":\"socks\",\"port\":1},"
                                + "{\"protocol\":\"socks\",\"port\":2}]}",
                        10808,
                        1500));
    }
}
