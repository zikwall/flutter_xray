import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_xray/flutter_xray.dart';
import 'log_viewer_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Xray',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const Scaffold(body: HomePage()),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  var xrayStatus = ValueNotifier<XrayStatus>(XrayStatus());
  late final Xray xray = Xray(
    onStatusChanged: (status) {
      xrayStatus.value = status;
    },
  );
  final config = TextEditingController();
  bool proxyOnly = false;
  final bypassSubnetController = TextEditingController();
  List<String> bypassSubnets = [];
  String? coreVersion;

  String remark = "Default Remark";

  void connect() async {
    if (await xray.requestPermission()) {
      xray.start(
        remark: remark,
        config: config.text,
        proxyOnly: proxyOnly,
        bypassSubnets: bypassSubnets,
        notificationDisconnectButtonName: "DISCONNECT",
      );
    } else {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Permission Denied')));
      }
    }
  }

  void importConfig() async {
    if (await Clipboard.hasStrings()) {
      try {
        final String link =
            (await Clipboard.getData('text/plain'))?.text?.trim() ?? '';
        final XrayURL profile = Xray.parseFromURL(link);
        remark = profile.remark;
        config.text = profile.getFullConfiguration();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Success')));
        }
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Error: $error')));
        }
      }
    }
  }

  void delay() async {
    late int delay;
    if (xrayStatus.value.state == 'CONNECTED') {
      delay = await xray.getConnectedServerDelay();
    } else {
      delay = await xray.getServerDelay(config: config.text);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${delay}ms')));
  }

  void bypassSubnet() {
    bypassSubnetController.text = bypassSubnets.join("\n");
    showDialog(
      context: context,
      builder:
          (context) => Dialog(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Subnets:', style: TextStyle(fontSize: 16)),
                  const SizedBox(height: 5),
                  TextFormField(
                    controller: bypassSubnetController,
                    maxLines: 5,
                    minLines: 5,
                  ),
                  const SizedBox(height: 5),
                  ElevatedButton(
                    onPressed: () {
                      bypassSubnets = bypassSubnetController.text.trim().split(
                        '\n',
                      );
                      if (bypassSubnets.first.isEmpty) {
                        bypassSubnets = [];
                      }
                      Navigator.of(context).pop();
                    },
                    child: const Text('Submit'),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  @override
  void initState() {
    super.initState();
    xray
        .initialize(
          notificationIconResourceType: "mipmap",
          notificationIconResourceName: "ic_launcher",
        )
        .then((value) async {
          coreVersion = await xray.getCoreVersion();
          setState(() {});
        });
  }

  @override
  void dispose() {
    unawaited(xray.dispose());
    xrayStatus.dispose();
    config.dispose();
    bypassSubnetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 5),
            const Text('Xray config (JSON):', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 5),
            TextFormField(controller: config, maxLines: 10, minLines: 10),
            const SizedBox(height: 10),
            ValueListenableBuilder(
              valueListenable: xrayStatus,
              builder: (context, value, child) {
                return Column(
                  children: [
                    Text(value.state),
                    const SizedBox(height: 10),
                    Text(value.duration),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('Speed:'),
                        const SizedBox(width: 10),
                        Text(value.uploadSpeed.toString()),
                        const Text('↑'),
                        const SizedBox(width: 10),
                        Text(value.downloadSpeed.toString()),
                        const Text('↓'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('Traffic:'),
                        const SizedBox(width: 10),
                        Text(value.upload.toString()),
                        const Text('↑'),
                        const SizedBox(width: 10),
                        Text(value.download.toString()),
                        const Text('↓'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text('Core Version: $coreVersion'),
                  ],
                );
              },
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.all(5.0),
              child: Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  ElevatedButton(
                    onPressed: connect,
                    child: const Text('Connect'),
                  ),
                  ElevatedButton(
                    onPressed: () => xray.stop(),
                    child: const Text('Disconnect'),
                  ),
                  ElevatedButton(
                    onPressed: () => setState(() => proxyOnly = !proxyOnly),
                    child: Text(proxyOnly ? 'Proxy Only' : 'VPN Mode'),
                  ),
                  ElevatedButton(
                    onPressed: importConfig,
                    child: const Text(
                      'Import Xray-compatible share link (clipboard)',
                    ),
                  ),
                  ElevatedButton(
                    onPressed: delay,
                    child: const Text('Server Delay'),
                  ),
                  ElevatedButton(
                    onPressed: bypassSubnet,
                    child: const Text('Bypass Subnet'),
                  ),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const LogViewerPage(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.article),
                    label: const Text('View Logs'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
