import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

class TailnetDevice {
  const TailnetDevice(this.name, this.os, this.ip, this.online);
  final String name;
  final String os;
  final String ip;
  final bool online;
  String get endpoint => '$ip:21118';

  static TailnetDevice? fromJson(Map<dynamic, dynamic> peer) {
    if (peer['InNetworkMap'] == false || peer['TailscaleIPs'] is! List) {
      return null;
    }
    for (final value in peer['TailscaleIPs'] as List) {
      final address = value is String ? InternetAddress.tryParse(value) : null;
      if (address == null || address.type != InternetAddressType.IPv4) continue;
      final bytes = address.rawAddress;
      if (bytes[0] != 100 || bytes[1] < 64 || bytes[1] > 127) continue;
      final dns = peer['DNSName'] as String? ?? '';
      final hostname = peer['HostName'] as String? ?? '';
      final name = hostname.isNotEmpty ? hostname : dns.split('.').first;
      return TailnetDevice(name.isEmpty ? value as String : name,
          peer['OS'] as String? ?? '', address.address, peer['Online'] == true);
    }
    return null;
  }
}

class TailnetHome extends StatefulWidget {
  const TailnetHome(
      {super.key,
      required this.manual,
      required this.incoming,
      required this.allowIncoming});
  final Widget manual;
  final Widget incoming;
  final bool allowIncoming;

  @override
  State<TailnetHome> createState() => _TailnetHomeState();
}

class _TailnetHomeState extends State<TailnetHome> {
  List<TailnetDevice> _devices = [];
  String? _selected;
  String? _installation;
  String? _status;
  int _page = 0;
  bool _refreshing = false;
  bool _loaded = false;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (_page == 0) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final devices = <TailnetDevice>[];
    String? status;
    Process? process;
    try {
      final folders = [
        Platform.environment['ProgramW6432'],
        Platform.environment['ProgramFiles'],
      ].whereType<String>().toSet();
      _installation = null;
      for (final folder in folders) {
        final dir = path.join(folder, 'Tailscale');
        if (await File(path.join(dir, 'tailscale.exe')).exists()) {
          _installation = dir;
          break;
        }
      }
      final dir = _installation;
      if (dir == null) {
        status = 'Tailscale is not installed';
      } else {
        process = await Process.start(
            path.join(dir, 'tailscale.exe'), ['status', '--json'],
            runInShell: false);
        final results = await Future.wait<Object?>([
          process.stdout.transform(utf8.decoder).join(),
          process.stderr.drain<Object?>(),
          process.exitCode,
        ]).timeout(const Duration(seconds: 5));
        final state = jsonDecode(results.first as String) as Map;
        if (state['BackendState'] == 'NeedsLogin') {
          status = 'Sign in to Tailscale on this computer';
        } else if (results[2] != 0 || state['BackendState'] != 'Running') {
          status = 'Connect Tailscale on this computer';
        } else {
          final peers = state['Peer'];
          if (peers is Map) {
            devices.addAll(peers.values
                .whereType<Map>()
                .map(TailnetDevice.fromJson)
                .whereType<TailnetDevice>());
          }
          if (devices.isEmpty) status = 'No Tailscale devices found';
        }
      }
    } catch (_) {
      status = 'Could not read Tailscale status';
    } finally {
      process?.kill();
    }
    if (!mounted) return;
    devices.sort((a, b) => a.online != b.online
        ? (a.online ? -1 : 1)
        : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    setState(() {
      _devices = devices;
      _status = status;
      if (!_loaded && devices.isNotEmpty) {
        _selected = devices.first.ip;
        _loaded = true;
      } else if (!devices.any((d) => d.ip == _selected)) {
        _selected = null;
      }
      _refreshing = false;
    });
  }

  Future<void> _openTailscale() async {
    final dir = _installation;
    try {
      if (dir == null) {
        await launchUrl(Uri.https('tailscale.com', '/download'));
      } else {
        await Process.start(path.join(dir, 'tailscale-ipn.exe'), [],
            runInShell: false, mode: ProcessStartMode.detached);
      }
    } catch (_) {
      if (mounted) showToast(translate('Open Tailscale from the system tray'));
    }
  }

  void _navigate(int page) => setState(() => _page = page);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _devices.where((d) => d.ip == _selected).firstOrNull;
    return Row(children: [
      SizedBox(
          width: 218,
          child: Material(
            color: theme.colorScheme.surfaceContainerLow,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 6, 4),
                      child: Row(children: [
                        Expanded(
                            child: Text(translate('My devices'),
                                style: theme.textTheme.titleMedium)),
                        IconButton(
                          tooltip: translate('Refresh devices'),
                          onPressed: _refreshing ? null : _refresh,
                          icon: const Icon(Icons.refresh),
                        ),
                      ])),
                  ListTile(
                    leading: const Icon(Icons.devices_outlined),
                    title: Text(translate('All devices')),
                    selected: _page == 0 && _selected == null,
                    onTap: () => setState(() {
                      _page = 0;
                      _selected = null;
                    }),
                  ),
                  Expanded(
                      child: ListView.builder(
                    itemCount: _devices.length,
                    itemBuilder: (context, index) {
                      final device = _devices[index];
                      return ListTile(
                        dense: true,
                        leading: Icon(Icons.circle,
                            size: 9,
                            color: device.online
                                ? Colors.teal
                                : theme.disabledColor),
                        title: Text(device.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        selected: _page == 0 && device.ip == _selected,
                        onTap: () => setState(() {
                          _page = 0;
                          _selected = device.ip;
                        }),
                      );
                    },
                  )),
                  const Divider(height: 1),
                  ListTile(
                      leading: const Icon(Icons.link),
                      title: Text(translate('Manual connection')),
                      selected: _page == 1,
                      onTap: () => _navigate(1)),
                  if (widget.allowIncoming)
                    ListTile(
                        leading: const Icon(Icons.support_agent),
                        title: Text(translate('Your Desktop')),
                        selected: _page == 2,
                        onTap: () => _navigate(2)),
                ]),
          )),
      const VerticalDivider(width: 1),
      Expanded(
          child: Stack(fit: StackFit.expand, children: [
        Offstage(
            offstage: _page != 1,
            child: ExcludeFocus(excluding: _page != 1, child: widget.manual)),
        if (_page == 2)
          Align(alignment: Alignment.topLeft, child: widget.incoming),
        if (_page == 0)
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: selected != null
                ? _details(context, selected)
                : _overview(context),
          ),
      ])),
    ]);
  }

  Widget _overview(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(translate('All devices'), style: theme.textTheme.headlineSmall),
      const SizedBox(height: 8),
      Text(translate('Devices visible to this Tailscale account')),
      const SizedBox(height: 20),
      if (_status != null) ...[
        Text(translate(_status!)),
        const SizedBox(height: 12),
        OutlinedButton(
            onPressed: _openTailscale,
            child: Text(translate(
                _installation == null ? 'Get Tailscale' : 'Open Tailscale'))),
      ] else if (_devices.isEmpty && _refreshing)
        const LinearProgressIndicator(),
      for (final device in _devices)
        Card(
            child: ListTile(
          leading: const Icon(Icons.desktop_windows_outlined),
          title: Text(device.name),
          subtitle: Text(translate(
              device.online ? 'Tailscale online' : 'Tailscale offline')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => setState(() => _selected = device.ip),
        )),
    ]);
  }

  Widget _details(BuildContext context, TailnetDevice device) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(device.name, style: theme.textTheme.headlineSmall),
      const SizedBox(height: 6),
      Text([
        translate(device.online ? 'Tailscale online' : 'Tailscale offline'),
        if (device.os.isNotEmpty) device.os,
        device.endpoint
      ].join('  路  ')),
      const SizedBox(height: 4),
      Text(translate('RustDesk availability is checked when connecting')),
      const SizedBox(height: 16),
      DevicePreview(key: ValueKey(device.ip), device: device),
      const SizedBox(height: 16),
      Wrap(spacing: 12, runSpacing: 8, children: [
        FilledButton.icon(
            onPressed: () => connect(context, device.endpoint),
            icon: const Icon(Icons.arrow_forward),
            label: Text(translate('Enter desktop'))),
        OutlinedButton.icon(
            onPressed: () =>
                connect(context, device.endpoint, isFileTransfer: true),
            icon: const Icon(Icons.folder_open),
            label: Text(translate('Transfer file'))),
      ]),
    ]);
  }
}

class DevicePreview extends StatefulWidget {
  const DevicePreview({super.key, required this.device});
  final TailnetDevice device;

  @override
  State<DevicePreview> createState() => _DevicePreviewState();
}

class _DevicePreviewState extends State<DevicePreview> {
  DateTime? _previousModified;
  Future<Uint8List>? _bytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appData = Platform.environment['APPDATA'];
    final file = appData == null
        ? null
        : File(path.join(appData, 'RustDesk', 'device-previews',
            '${widget.device.ip}-21118.png'));
    final stat = file?.statSync();
    final modified =
        stat?.type == FileSystemEntityType.file ? stat!.modified : null;
    if (modified != _previousModified) {
      _previousModified = modified;
      _bytes = modified == null ? null : file!.readAsBytes();
    }
    final fallback = Center(
        child: Icon(Icons.desktop_windows_outlined,
            size: 72, color: theme.colorScheme.primary));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AspectRatio(
          aspectRatio: 16 / 8,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: FutureBuilder<Uint8List>(
                    key: ValueKey(modified),
                    future: _bytes,
                    builder: (context, snapshot) => snapshot.hasData
                        ? Image.memory(snapshot.data!,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => fallback)
                        : fallback)),
          )),
      const SizedBox(height: 6),
      Text(
          modified == null
              ? translate('No saved preview')
              : '${translate('Last preview')} 路 ${MaterialLocalizations.of(context).formatShortDate(modified)} '
                  '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(modified))}',
          style: theme.textTheme.bodySmall),
    ]);
  }
}
