import 'dart:io';

Future<void> main(List<String> arguments) async {
  final port = arguments.isEmpty ? 19000 : int.parse(arguments.single);
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('UDP echo listening on 0.0.0.0:$port');
  await for (final event in socket) {
    if (event != RawSocketEvent.read) continue;
    final datagram = socket.receive();
    if (datagram == null) continue;
    stdout.writeln(
      'UDP echo ${datagram.data.length} bytes from '
      '${datagram.address.address}:${datagram.port}',
    );
    socket.send(datagram.data, datagram.address, datagram.port);
  }
}
