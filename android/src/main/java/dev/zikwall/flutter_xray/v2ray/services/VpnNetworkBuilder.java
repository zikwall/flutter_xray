package dev.zikwall.flutter_xray.v2ray.services;

import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.content.pm.PackageManager;
import android.util.Log;

import dev.zikwall.flutter_xray.tunnel.TunnelBackendKind;
import dev.zikwall.flutter_xray.v2ray.utils.V2rayConfig;

/** Applies a validated {@link VpnNetworkPlan} to Android's VPN builder. */
public final class VpnNetworkBuilder {
    interface PlatformBuilder {
        void setSession(String session);

        void setMtu(int mtu);

        void addAddress(String address, int prefixLength);

        void addRoute(String address, int prefixLength);

        void addDnsServer(String address);

        void addDisallowedApplication(String packageName) throws Exception;

        void setMetered(boolean metered);

        ParcelFileDescriptor establish();
    }

    /** Validates all platform-independent VPN fields before a foreground service is launched. */
    public static void validate(V2rayConfig config, TunnelBackendKind backendKind) {
        VpnNetworkPlan.from(config, backendKind);
    }

    ParcelFileDescriptor establish(
            PlatformBuilder builder,
            V2rayConfig config,
            TunnelBackendKind backendKind,
            boolean supportsMeteredFlag) throws Exception {
        VpnNetworkPlan plan = VpnNetworkPlan.from(config, backendKind);
        builder.setSession(plan.session);
        builder.setMtu(plan.mtu);
        for (VpnNetworkPlan.Address address : plan.addresses) {
            builder.addAddress(address.value, address.prefixLength);
        }
        for (VpnNetworkPlan.Address route : plan.routes) {
            builder.addRoute(route.value, route.prefixLength);
        }
        for (String dnsServer : plan.dnsServers) {
            builder.addDnsServer(dnsServer);
        }
        for (String packageName : plan.disallowedApplications) {
            try {
                builder.addDisallowedApplication(packageName);
            } catch (Exception error) {
                throw new IllegalArgumentException(
                        "Failed to exclude blockedApps package: " + packageName, error);
            }
        }
        if (supportsMeteredFlag) {
            builder.setMetered(false);
        }
        ParcelFileDescriptor vpnInterface = builder.establish();
        if (vpnInterface == null) {
            throw new IllegalStateException("Android failed to establish the VPN interface");
        }
        return vpnInterface;
    }

    static PlatformBuilder android(VpnService.Builder builder) {
        return new PlatformBuilder() {
            @Override
            public void setSession(String session) {
                builder.setSession(session);
            }

            @Override
            public void setMtu(int mtu) {
                builder.setMtu(mtu);
            }

            @Override
            public void addAddress(String address, int prefixLength) {
                builder.addAddress(address, prefixLength);
            }

            @Override
            public void addRoute(String address, int prefixLength) {
                builder.addRoute(address, prefixLength);
            }

            @Override
            public void addDnsServer(String address) {
                builder.addDnsServer(address);
            }

            @Override
            public void addDisallowedApplication(String packageName) throws Exception {
                try {
                    builder.addDisallowedApplication(packageName);
                } catch (PackageManager.NameNotFoundException error) {
                    // The package can disappear after the preflight filter.
                    // Keep the VPN usable and make the race observable.
                    Log.w("VpnNetworkBuilder",
                            "Ignoring blockedApps package removed during VPN startup");
                }
            }

            @Override
            public void setMetered(boolean metered) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    builder.setMetered(metered);
                }
            }

            @Override
            public ParcelFileDescriptor establish() {
                return builder.establish();
            }
        };
    }
}
