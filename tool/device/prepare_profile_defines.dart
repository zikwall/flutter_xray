import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final options = _parseArguments(arguments);
  final sourcePath = options['source'];
  final outputPath = options['output'];
  if (sourcePath == null || outputPath == null) {
    stderr.writeln(
      'Usage: dart run tool/device/prepare_profile_defines.dart '
      '--source=<profiles.json> --output=<profiles.device.local.json> '
      '[--expected-host=<dev-host>] [--profiles=id1,id2] '
      '[--query-override=NAME=value] [--define=NAME=value]',
    );
    exitCode = 64;
    return;
  }

  final source = jsonDecode(await File(sourcePath).readAsString());
  if (source is! Map || source['profiles'] is! List) {
    throw const FormatException('Source must contain a profiles array');
  }
  final expectedHost = options['expected-host'] ?? '';
  final selectedIds = (options['profiles'] ?? '')
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toSet();
  final queryOverrides = _queryOverrides(arguments);
  final profiles = <Map<String, String>>[];
  for (final raw in source['profiles'] as List) {
    if (raw is! Map) continue;
    final id = (raw['server_id'] ?? raw['id'] ?? '').toString().trim();
    final link =
        (raw['verification_config'] ?? raw['link'] ?? '').toString().trim();
    if (id.isEmpty || link.isEmpty) continue;
    if (selectedIds.isNotEmpty && !selectedIds.contains(id)) continue;
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'vless' || uri.host.isEmpty) {
      throw FormatException('Profile $id is not a valid VLESS link');
    }
    if (expectedHost.isNotEmpty && uri.host != expectedHost) {
      throw FormatException(
        'Profile $id targets ${uri.host}, expected dev host $expectedHost',
      );
    }
    final effectiveUri = queryOverrides.isEmpty
        ? uri
        : uri.replace(
            queryParameters: {...uri.queryParameters, ...queryOverrides},
          );
    profiles.add({'id': id, 'link': effectiveUri.toString()});
  }
  if (profiles.isEmpty) {
    throw const FormatException('No matching profiles found');
  }

  final defines = <String, String>{
    'FLUTTER_XRAY_DEVICE_PROFILES_B64': base64Encode(
      utf8.encode(jsonEncode(profiles)),
    ),
  };
  for (final define in _defines(arguments)) {
    final separator = define.indexOf('=');
    if (separator <= 0) {
      throw FormatException('Invalid --define value: $define');
    }
    defines[define.substring(0, separator)] = define.substring(separator + 1);
  }

  final output = File(outputPath);
  await output.parent.create(recursive: true);
  await output.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(defines)}\n',
    flush: true,
  );
  if (!Platform.isWindows) {
    final chmod = await Process.run('chmod', ['600', output.absolute.path]);
    if (chmod.exitCode != 0) {
      throw const FileSystemException('Failed to protect local profile file');
    }
  }
  stdout.writeln(
    'Prepared ${profiles.length} local profile(s): '
    '${profiles.map((profile) => profile['id']).join(', ')}',
  );
}

Map<String, String> _parseArguments(List<String> arguments) {
  final options = <String, String>{};
  for (final argument in arguments) {
    if (!argument.startsWith('--') || argument.startsWith('--define=')) {
      continue;
    }
    final separator = argument.indexOf('=');
    if (separator > 2) {
      options[argument.substring(2, separator)] = argument.substring(
        separator + 1,
      );
    }
  }
  return options;
}

Iterable<String> _defines(List<String> arguments) sync* {
  const prefix = '--define=';
  for (final argument in arguments) {
    if (argument.startsWith(prefix)) {
      yield argument.substring(prefix.length);
    }
  }
}

Map<String, String> _queryOverrides(List<String> arguments) {
  const prefix = '--query-override=';
  final overrides = <String, String>{};
  for (final argument in arguments) {
    if (!argument.startsWith(prefix)) continue;
    final value = argument.substring(prefix.length);
    final separator = value.indexOf('=');
    if (separator <= 0) {
      throw FormatException('Invalid --query-override value: $value');
    }
    overrides[value.substring(0, separator)] = value.substring(separator + 1);
  }
  return overrides;
}
