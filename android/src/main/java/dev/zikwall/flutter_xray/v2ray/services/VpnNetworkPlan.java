package dev.zikwall.flutter_xray.v2ray.services;

import dev.zikwall.flutter_xray.tunnel.HevTunnelConfig;
import dev.zikwall.flutter_xray.tunnel.TunnelBackendKind;
import dev.zikwall.flutter_xray.v2ray.utils.V2rayConfig;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.math.BigInteger;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** Validated, Android-independent description of a VPN interface. */
final class VpnNetworkPlan {
    static final int IPV4_PREFIX = 30;
    static final int IPV6_PREFIX = 126;
    static final int MAX_ROUTES = 512;

    static final class Address {
        final String value;
        final int prefixLength;

        Address(String value, int prefixLength) {
            this.value = value;
            this.prefixLength = prefixLength;
        }
    }

    final String session;
    final int mtu;
    final List<Address> addresses;
    final List<Address> routes;
    final List<String> dnsServers;
    final List<String> disallowedApplications;

    private VpnNetworkPlan(
            String session,
            int mtu,
            List<Address> addresses,
            List<Address> routes,
            List<String> dnsServers,
            List<String> disallowedApplications) {
        this.session = session;
        this.mtu = mtu;
        this.addresses = Collections.unmodifiableList(addresses);
        this.routes = Collections.unmodifiableList(routes);
        this.dnsServers = Collections.unmodifiableList(dnsServers);
        this.disallowedApplications = Collections.unmodifiableList(disallowedApplications);
    }

    static VpnNetworkPlan from(V2rayConfig config, TunnelBackendKind backendKind) {
        if (config == null) {
            throw new IllegalArgumentException("VPN configuration is required");
        }
        if (backendKind == null) {
            throw new IllegalArgumentException("Tunnel backend is required");
        }

        List<Address> addresses = new ArrayList<>();
        addresses.add(new Address(HevTunnelConfig.DEFAULT_IPV4, IPV4_PREFIX));
        addresses.add(new Address(HevTunnelConfig.DEFAULT_IPV6, IPV6_PREFIX));

        return new VpnNetworkPlan(
                config.REMARK == null ? "" : config.REMARK,
                HevTunnelConfig.DEFAULT_MTU,
                addresses,
                routesExcluding(config.BYPASS_SUBNETS),
                dnsServers(config.V2RAY_FULL_JSON_CONFIG),
                disallowedApplications(config.BLOCKED_APPS));
    }

    private static List<String> dnsServers(String jsonConfig) {
        if (jsonConfig == null || jsonConfig.trim().isEmpty()) {
            throw new IllegalArgumentException("Xray JSON configuration is required for VPN DNS setup");
        }

        final JSONObject root;
        try {
            root = new JSONObject(jsonConfig);
        } catch (JSONException error) {
            throw new IllegalArgumentException("Xray JSON configuration is invalid", error);
        }
        if (!root.has("dns")) {
            return Collections.emptyList();
        }

        try {
            JSONObject dns = root.getJSONObject("dns");
            if (!dns.has("servers")) {
                return Collections.emptyList();
            }
            JSONArray servers = dns.getJSONArray("servers");
            Set<String> validated = new LinkedHashSet<>();
            for (int index = 0; index < servers.length(); index += 1) {
                Object entry = servers.get(index);
                String address;
                if (entry instanceof String) {
                    address = (String) entry;
                } else if (entry instanceof JSONObject) {
                    JSONObject object = (JSONObject) entry;
                    if (!object.has("address")) {
                        throw new IllegalArgumentException(
                                "DNS server object at index " + index + " has no address");
                    }
                    address = object.getString("address");
                } else {
                    throw new IllegalArgumentException(
                            "DNS server at index " + index + " must be a string or object");
                }
                validated.add(parseIpAddress(address, "DNS server at index " + index).getHostAddress());
            }
            return new ArrayList<>(validated);
        } catch (JSONException error) {
            throw new IllegalArgumentException("Xray DNS configuration is invalid", error);
        }
    }

    private static List<String> disallowedApplications(List<String> applications) {
        if (applications == null || applications.isEmpty()) {
            return Collections.emptyList();
        }
        Set<String> validated = new LinkedHashSet<>();
        for (int index = 0; index < applications.size(); index += 1) {
            String packageName = applications.get(index);
            if (packageName == null || packageName.trim().isEmpty()) {
                throw new IllegalArgumentException(
                        "blockedApps contains an empty package name at index " + index);
            }
            validated.add(packageName.trim());
        }
        return new ArrayList<>(validated);
    }

    private static List<Address> routesExcluding(List<String> bypassSubnets) {
        List<Subnet> routes = new ArrayList<>();
        routes.add(Subnet.defaultRoute(32));
        routes.add(Subnet.defaultRoute(128));
        if (bypassSubnets != null) {
            for (int index = 0; index < bypassSubnets.size(); index += 1) {
                String value = bypassSubnets.get(index);
                Subnet exclusion = Subnet.parse(value, "bypassSubnets at index " + index);
                List<Subnet> updated = new ArrayList<>();
                for (Subnet route : routes) {
                    route.subtract(exclusion, updated);
                    if (updated.size() > MAX_ROUTES) {
                        throw new IllegalArgumentException(
                                "bypassSubnets expands to more than " + MAX_ROUTES + " VPN routes");
                    }
                }
                routes = updated;
            }
        }

        List<Address> result = new ArrayList<>();
        for (Subnet route : routes) {
            result.add(new Address(route.address(), route.prefixLength));
        }
        return result;
    }

    private static InetAddress parseIpAddress(String value, String label) {
        if (value == null || value.trim().isEmpty()) {
            throw new IllegalArgumentException(label + " is empty");
        }
        String address = value.trim();
        try {
            if (address.indexOf(':') >= 0) {
                if (address.indexOf('%') >= 0) {
                    throw new IllegalArgumentException(label + " must not contain an IPv6 scope: " + value);
                }
                InetAddress parsed = InetAddress.getByName(address);
                if (!(parsed instanceof Inet6Address)) {
                    throw new IllegalArgumentException(label + " is not a numeric IPv6 address: " + value);
                }
                return parsed;
            }
            String[] octets = address.split("\\.", -1);
            if (octets.length != 4) {
                throw new IllegalArgumentException(label + " is not a numeric IP address: " + value);
            }
            byte[] bytes = new byte[4];
            for (int index = 0; index < octets.length; index += 1) {
                if (octets[index].isEmpty() || octets[index].length() > 3) {
                    throw new IllegalArgumentException(label + " is not a numeric IPv4 address: " + value);
                }
                int octet = Integer.parseInt(octets[index]);
                if (octet < 0 || octet > 255) {
                    throw new IllegalArgumentException(label + " is not a numeric IPv4 address: " + value);
                }
                bytes[index] = (byte) octet;
            }
            return InetAddress.getByAddress(bytes);
        } catch (UnknownHostException | NumberFormatException error) {
            throw new IllegalArgumentException(label + " is not a numeric IP address: " + value, error);
        }
    }

    private static final class Subnet {
        private final BigInteger network;
        private final int prefixLength;
        private final int bitCount;

        private Subnet(BigInteger network, int prefixLength, int bitCount) {
            this.bitCount = bitCount;
            this.prefixLength = prefixLength;
            this.network = network.and(mask(bitCount, prefixLength));
        }

        static Subnet defaultRoute(int bitCount) {
            return new Subnet(BigInteger.ZERO, 0, bitCount);
        }

        static Subnet parse(String value, String label) {
            if (value == null) {
                throw new IllegalArgumentException(label + " is null");
            }
            String[] parts = value.trim().split("/", -1);
            if (parts.length != 2) {
                throw new IllegalArgumentException(label + " must use CIDR notation: " + value);
            }
            InetAddress address = parseIpAddress(parts[0], label);
            int bits = address instanceof Inet6Address ? 128 : 32;
            final int prefix;
            try {
                prefix = Integer.parseInt(parts[1]);
            } catch (NumberFormatException error) {
                throw new IllegalArgumentException(label + " has an invalid prefix: " + value, error);
            }
            if (prefix < 0 || prefix > bits) {
                throw new IllegalArgumentException(label + " has an invalid prefix: " + value);
            }
            return new Subnet(new BigInteger(1, address.getAddress()), prefix, bits);
        }

        void subtract(Subnet exclusion, List<Subnet> output) {
            if (bitCount != exclusion.bitCount || !overlaps(exclusion)) {
                output.add(this);
                return;
            }
            if (exclusion.prefixLength <= prefixLength) {
                return;
            }
            int childPrefix = prefixLength + 1;
            BigInteger childSize = BigInteger.ONE.shiftLeft(bitCount - childPrefix);
            new Subnet(network, childPrefix, bitCount).subtract(exclusion, output);
            new Subnet(network.add(childSize), childPrefix, bitCount).subtract(exclusion, output);
        }

        private boolean overlaps(Subnet other) {
            int commonPrefix = Math.min(prefixLength, other.prefixLength);
            BigInteger commonMask = mask(bitCount, commonPrefix);
            return network.and(commonMask).equals(other.network.and(commonMask));
        }

        String address() {
            byte[] raw = toBytes(network, bitCount / 8);
            try {
                return InetAddress.getByAddress(raw).getHostAddress();
            } catch (UnknownHostException impossible) {
                throw new IllegalStateException("Failed to render validated subnet", impossible);
            }
        }

        private static BigInteger mask(int bitCount, int prefixLength) {
            if (prefixLength == 0) {
                return BigInteger.ZERO;
            }
            return BigInteger.ONE.shiftLeft(bitCount).subtract(BigInteger.ONE)
                    .shiftRight(bitCount - prefixLength)
                    .shiftLeft(bitCount - prefixLength);
        }

        private static byte[] toBytes(BigInteger value, int length) {
            byte[] source = value.toByteArray();
            byte[] result = new byte[length];
            int copyLength = Math.min(source.length, length);
            System.arraycopy(source, source.length - copyLength, result, length - copyLength, copyLength);
            return result;
        }
    }
}
