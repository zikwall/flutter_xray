/// Packet tunnel implementation used between Android's TUN interface and the
/// local Xray SOCKS5 inbound.
enum TunnelBackend {
  /// Existing BadVPN tun2socks backend.
  badVpn('badvpn'),

  /// High-performance hev-socks5-tunnel backend.
  hev('hev');

  const TunnelBackend(this.configValue);

  /// Stable value sent to the native platform implementation.
  final String configValue;
}
