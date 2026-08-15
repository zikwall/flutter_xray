/// Represents the current status of an Xray connection.
///
/// This class holds connection, traffic and state information reported by Xray.
/// service, including connection duration, speeds, and traffic data.
class XrayStatus {
  /// The duration of the current connection in 'HH:MM:SS' format.
  final String duration;

  /// The current upload speed in bytes per second.
  final int uploadSpeed;

  /// The current download speed in bytes per second.
  final int downloadSpeed;

  /// The total uploaded data in bytes.
  final int upload;

  /// The total downloaded data in bytes.
  final int download;

  /// The current connection state (e.g., 'CONNECTED', 'DISCONNECTED').
  final String state;

  /// Creates a new XrayStatus instance with the given parameters.
  ///
  /// [duration] defaults to '00:00:00' if not provided.
  /// [uploadSpeed] defaults to 0.
  /// [downloadSpeed] defaults to 0.
  /// [upload] defaults to 0.
  /// [download] defaults to 0.
  /// [state] defaults to 'DISCONNECTED'.
  XrayStatus({
    this.duration = '00:00:00',
    this.uploadSpeed = 0,
    this.downloadSpeed = 0,
    this.upload = 0,
    this.download = 0,
    this.state = 'DISCONNECTED',
  });

  /// Decodes the stable six-field event emitted by the Android plugin.
  ///
  /// A malformed native event is a plugin contract violation and is surfaced
  /// as a [FormatException] instead of becoming an asynchronous cast error.
  factory XrayStatus.fromPlatformEvent(Object? event) {
    if (event is! List || event.length != 6) {
      throw const FormatException(
        'Xray status event must contain exactly six fields',
      );
    }

    int integerAt(int index, String field) {
      final value = event[index];
      if (value is int) return value;
      if (value is num) return value.toInt();
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed == null) {
        throw FormatException('Xray status $field is not an integer: $value');
      }
      return parsed;
    }

    String stringAt(int index, String field) {
      final value = event[index];
      if (value is! String || value.isEmpty) {
        throw FormatException('Xray status $field is not a non-empty string');
      }
      return value;
    }

    return XrayStatus(
      duration: stringAt(0, 'duration'),
      uploadSpeed: integerAt(1, 'uploadSpeed'),
      downloadSpeed: integerAt(2, 'downloadSpeed'),
      upload: integerAt(3, 'upload'),
      download: integerAt(4, 'download'),
      state: stringAt(5, 'state'),
    );
  }
}
