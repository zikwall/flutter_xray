/// Android packet tunnel implementation used by the plugin.
enum TunnelBackend {
  /// Existing BadVPN tun2socks backend.
  badVpn('badvpn'),

  /// Xray's native TUN inbound. No SOCKS-to-TUN bridge is started.
  xray('xray'),

  /// High-performance hev-socks5-tunnel backend.
  hev('hev');

  const TunnelBackend(this.configValue);

  /// Stable value sent to the native platform implementation.
  final String configValue;
}
