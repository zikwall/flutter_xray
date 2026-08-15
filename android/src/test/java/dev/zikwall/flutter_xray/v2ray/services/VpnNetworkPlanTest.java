package dev.zikwall.flutter_xray.v2ray.services;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import dev.zikwall.flutter_xray.tunnel.TunnelBackendKind;
import dev.zikwall.flutter_xray.v2ray.utils.V2rayConfig;

import java.net.InetAddress;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

import org.junit.Test;

public final class VpnNetworkPlanTest {
    @Test
    public void everyBackendGetsSymmetricIpv4AndIpv6Defaults() {
        for (TunnelBackendKind backend : TunnelBackendKind.values()) {
            VpnNetworkPlan plan = VpnNetworkPlan.from(config(), backend);

            assertEquals(2, plan.addresses.size());
            assertEquals("26.26.26.1", plan.addresses.get(0).value);
            assertEquals(30, plan.addresses.get(0).prefixLength);
            assertEquals("fc00::26:26:26:1", plan.addresses.get(1).value);
            assertEquals(126, plan.addresses.get(1).prefixLength);
            assertTrue(hasRoute(plan.routes, "0.0.0.0", 0));
            assertTrue(hasRoute(plan.routes, "0:0:0:0:0:0:0:0", 0));
        }
    }

    @Test
    public void parsesStringAndObjectDnsServersWithoutDuplicates() {
        V2rayConfig config = config();
        config.V2RAY_FULL_JSON_CONFIG = "{\"dns\":{\"servers\":["
                + "\"1.1.1.1\",{\"address\":\"2606:4700:4700::1111\"},\"1.1.1.1\"]}}";

        VpnNetworkPlan plan = VpnNetworkPlan.from(config, TunnelBackendKind.BADVPN);

        assertEquals(2, plan.dnsServers.size());
        assertEquals("1.1.1.1", plan.dnsServers.get(0));
        assertTrue(plan.dnsServers.get(1).contains(":"));
    }

    @Test
    public void rejectsMalformedDnsInsteadOfUsingSilentFallback() {
        V2rayConfig config = config();
        config.V2RAY_FULL_JSON_CONFIG = "{not-json";
        assertThrows(
                IllegalArgumentException.class,
                () -> VpnNetworkPlan.from(config, TunnelBackendKind.HEV));

        config.V2RAY_FULL_JSON_CONFIG = "{\"dns\":{\"servers\":[{\"queryStrategy\":\"UseIP\"}]}}";
        assertThrows(
                IllegalArgumentException.class,
                () -> VpnNetworkPlan.from(config, TunnelBackendKind.HEV));

        config.V2RAY_FULL_JSON_CONFIG = "{\"dns\":{\"servers\":[\"dns.example.com\"]}}";
        assertThrows(
                IllegalArgumentException.class,
                () -> VpnNetworkPlan.from(config, TunnelBackendKind.HEV));
    }

    @Test
    public void validatesAndDeduplicatesAlreadyFilteredBlockedApps() {
        V2rayConfig config = config();
        config.BLOCKED_APPS = new ArrayList<>(Arrays.asList(
                " com.example.bypass ", "com.example.bypass"));

        for (TunnelBackendKind backend : TunnelBackendKind.values()) {
            VpnNetworkPlan plan = VpnNetworkPlan.from(config, backend);
            assertEquals(
                    Collections.singletonList("com.example.bypass"),
                    plan.disallowedApplications);
        }

        config.BLOCKED_APPS = new ArrayList<>(Collections.singletonList(" "));
        assertThrows(
                IllegalArgumentException.class,
                () -> VpnNetworkPlan.from(config, TunnelBackendKind.XRAY));
    }

    @Test
    public void bypassSubnetsAreExcludedFromFullTunnelRoutes() throws Exception {
        V2rayConfig config = config();
        config.BYPASS_SUBNETS = new ArrayList<>(Arrays.asList(
                "192.168.0.0/16", "fd00::/8"));

        VpnNetworkPlan plan = VpnNetworkPlan.from(config, TunnelBackendKind.BADVPN);

        assertFalse(plan.routes.isEmpty());
        assertFalse(hasRoute(plan.routes, "0.0.0.0", 0));
        assertFalse(hasRoute(plan.routes, "0:0:0:0:0:0:0:0", 0));
        assertFalse(anyRouteContains(plan.routes, InetAddress.getByName("192.168.1.1")));
        assertFalse(anyRouteContains(plan.routes, InetAddress.getByName("fd00::1")));
        assertTrue(anyRouteContains(plan.routes, InetAddress.getByName("8.8.8.8")));
        assertTrue(anyRouteContains(plan.routes, InetAddress.getByName("2606:4700:4700::1111")));
    }

    @Test
    public void rejectsInvalidBypassSubnet() {
        V2rayConfig config = config();
        config.BYPASS_SUBNETS = new ArrayList<>(Collections.singletonList("192.168.0.0/99"));

        assertThrows(
                IllegalArgumentException.class,
                () -> VpnNetworkPlan.from(config, TunnelBackendKind.BADVPN));
    }

    private static V2rayConfig config() {
        V2rayConfig config = new V2rayConfig();
        config.REMARK = "test";
        config.V2RAY_FULL_JSON_CONFIG = "{\"dns\":{\"servers\":[\"1.1.1.1\"]}}";
        return config;
    }

    private static boolean hasRoute(
            List<VpnNetworkPlan.Address> routes, String address, int prefixLength) {
        for (VpnNetworkPlan.Address route : routes) {
            if (route.value.equals(address) && route.prefixLength == prefixLength) {
                return true;
            }
        }
        return false;
    }

    private static boolean anyRouteContains(
            List<VpnNetworkPlan.Address> routes, InetAddress candidate) throws Exception {
        byte[] candidateBytes = candidate.getAddress();
        for (VpnNetworkPlan.Address route : routes) {
            byte[] routeBytes = InetAddress.getByName(route.value).getAddress();
            if (routeBytes.length != candidateBytes.length) {
                continue;
            }
            boolean matches = true;
            for (int bit = 0; bit < route.prefixLength; bit += 1) {
                int mask = 1 << (7 - bit % 8);
                if ((routeBytes[bit / 8] & mask) != (candidateBytes[bit / 8] & mask)) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                return true;
            }
        }
        return false;
    }
}
