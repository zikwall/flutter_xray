package dev.zikwall.flutter_xray.v2ray.services;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import android.os.ParcelFileDescriptor;

import dev.zikwall.flutter_xray.tunnel.TunnelBackendKind;
import dev.zikwall.flutter_xray.v2ray.utils.V2rayConfig;

import java.util.ArrayList;
import java.util.Collections;

import org.junit.Test;

public final class VpnNetworkBuilderTest {
    @Test
    public void appliesValidatedPlanToPlatformBuilder() throws Exception {
        RecordingBuilder platform = new RecordingBuilder();
        V2rayConfig config = config();
        config.BLOCKED_APPS = new ArrayList<>(Collections.singletonList("com.example.bypass"));

        new VpnNetworkBuilder().establish(
                platform, config, TunnelBackendKind.BADVPN, true);

        assertEquals("test", platform.session);
        assertEquals(1500, platform.mtu);
        assertEquals(2, platform.addresses);
        assertEquals(2, platform.routes);
        assertEquals(1, platform.dnsServers);
        assertEquals(1, platform.disallowedApplications);
        assertTrue(platform.meteredConfigured);
    }

    @Test
    public void unexpectedBlockedAppPlatformFailureIsNotSwallowed() {
        RecordingBuilder platform = new RecordingBuilder();
        platform.failDisallowedApplication = true;
        V2rayConfig config = config();
        config.BLOCKED_APPS = new ArrayList<>(Collections.singletonList("missing.package"));

        IllegalArgumentException error = assertThrows(
                IllegalArgumentException.class,
                () -> new VpnNetworkBuilder().establish(
                        platform, config, TunnelBackendKind.HEV, true));

        assertTrue(error.getMessage().contains("missing.package"));
    }

    @Test
    public void nullAndroidInterfaceIsAnExplicitFailure() {
        RecordingBuilder platform = new RecordingBuilder();
        platform.establishedInterface = null;

        assertThrows(
                IllegalStateException.class,
                () -> new VpnNetworkBuilder().establish(
                        platform, config(), TunnelBackendKind.XRAY, false));
    }

    private static V2rayConfig config() {
        V2rayConfig config = new V2rayConfig();
        config.REMARK = "test";
        config.V2RAY_FULL_JSON_CONFIG = "{\"dns\":{\"servers\":[\"1.1.1.1\"]}}";
        return config;
    }

    private static final class RecordingBuilder implements VpnNetworkBuilder.PlatformBuilder {
        private String session;
        private int mtu;
        private int addresses;
        private int routes;
        private int dnsServers;
        private int disallowedApplications;
        private boolean meteredConfigured;
        private boolean failDisallowedApplication;
        private ParcelFileDescriptor establishedInterface =
                org.mockito.Mockito.mock(ParcelFileDescriptor.class);

        @Override
        public void setSession(String session) {
            this.session = session;
        }

        @Override
        public void setMtu(int mtu) {
            this.mtu = mtu;
        }

        @Override
        public void addAddress(String address, int prefixLength) {
            addresses += 1;
        }

        @Override
        public void addRoute(String address, int prefixLength) {
            routes += 1;
        }

        @Override
        public void addDnsServer(String address) {
            dnsServers += 1;
        }

        @Override
        public void addDisallowedApplication(String packageName) throws Exception {
            if (failDisallowedApplication) {
                throw new Exception("not installed");
            }
            disallowedApplications += 1;
        }

        @Override
        public void setMetered(boolean metered) {
            meteredConfigured = true;
        }

        @Override
        public ParcelFileDescriptor establish() {
            return establishedInterface;
        }
    }
}
