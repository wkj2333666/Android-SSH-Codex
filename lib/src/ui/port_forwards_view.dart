import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../ports/port_forward.dart';
import '../ports/port_discovery.dart';

Future<void> showPortForwards(BuildContext context, AppController controller) async {
  final hostId = controller.selectedHostId;
  if (hostId == null) return;
  await showModalBottomSheet<void>(context: context, isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => PortForwardsPanel(controller: controller, hostId: hostId,
        hostLabel: controller.selectedHost?.label ?? hostId));
}

void _message(BuildContext context, String value) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
}

Future<void> openRemotePortLink(BuildContext context, AppController controller,
    Uri source, Future<bool> Function(Uri) openBrowser) async {
  try {
    mapForwardedUri(source, 1024); // Reject credential-bearing/invalid URLs first.
    final hostId = controller.selectedHostId;
    if (hostId == null || !controller.isConnected) {
      throw StateError('Reconnect SSH before opening the remote localhost link.');
    }
    final existing = controller.portForwards.loopbackRule(hostId, source.port, source.host);
    final current = existing == null ? null : controller.portForwards.stateFor(existing.id).localPort;
    Uri mapped;
    if (existing?.enabled == true && current != null) {
      mapped = mapForwardedUri(source, current);
    } else {
      final confirmed = await showDialog<bool>(context: context,
        builder: (context) => AlertDialog(title: const Text('Forward remote port?'),
          content: Text('Open ${source.host}:${source.port} on '
              '${controller.selectedHost?.label ?? hostId} through SSH?\n\n'
              'The phone listener binds only to 127.0.0.1, not the LAN. '
              'You can change or stop it in Ports. This does not use the phone’s own localhost service.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Forward and open')),
          ]));
      if (confirmed != true || !context.mounted) return;
      mapped = await controller.forwardLoopbackUrl(hostId, source);
    }
    if (!context.mounted || controller.selectedHostId != hostId || !controller.isConnected) return;
    if (!await openBrowser(mapped) && context.mounted) _message(context, 'Could not open the browser.');
  } catch (error) { if (context.mounted) _message(context, '$error'); }
}

class PortForwardsPanel extends StatefulWidget {
  const PortForwardsPanel({required this.controller, required this.hostId,
      required this.hostLabel, super.key});
  final AppController controller;
  final String hostId;
  final String hostLabel;
  @override
  State<PortForwardsPanel> createState() => _PortForwardsPanelState();
}

class _PortForwardsPanelState extends State<PortForwardsPanel> {
  List<ListeningPort> _discovered = const [];
  bool _discovering = false;
  String? _discoveryError;
  bool get _sameHost => widget.controller.selectedHostId == widget.hostId;
  @override
  void initState() {
    super.initState();
    if (widget.controller.canDiscoverPorts) unawaited(_discover());
  }

  Future<void> _discover() async {
    if (_discovering || !_sameHost) return;
    setState(() { _discovering = true; _discoveryError = null; });
    try {
      final result = await widget.controller.discoverPorts(widget.hostId);
      if (mounted && _sameHost) setState(() => _discovered = result);
    } catch (error) {
      if (mounted) setState(() => _discoveryError = error.toString());
    } finally { if (mounted) setState(() => _discovering = false); }
  }

  Future<void> _edit({PortForwardRule? rule, ListeningPort? candidate}) async {
    if (!_sameHost) return;
    final result = await showDialog<PortForwardRule>(context: context,
        builder: (_) => _PortEditor(hostId: widget.hostId,
            id: rule?.id ?? widget.controller.portForwards.newId(),
            rule: rule, candidate: candidate));
    if (result == null || !mounted || !_sameHost) return;
    try { await widget.controller.savePortForward(result); }
    catch (error) { if (mounted) _message(context, '$error'); }
  }

  Future<void> _toggle(PortForwardRule rule, bool enabled) async {
    try { await widget.controller.savePortForward(rule.copyWith(enabled: enabled)); }
    catch (error) { if (mounted) _message(context, '$error'); }
  }

  Future<void> _action(PortForwardRule rule, String action) async {
    if (!_sameHost) return;
    try {
      final state = widget.controller.portForwards.stateFor(rule.id);
      switch (action) {
        case 'edit': await _edit(rule: rule); break;
        case 'delete':
          final confirmed = await showDialog<bool>(context: context,
              builder: (context) => AlertDialog(title: const Text('Remove forwarding rule?'),
                content: Text('${rule.remoteAddress}\nCurrent connections will close.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
                ]));
          if (confirmed == true && mounted && _sameHost) await widget.controller.removePortForward(rule.id);
          break;
        case 'retry': await widget.controller.portForwards.retry(); break;
        case 'copy':
          if (state.localPort != null) {
            await Clipboard.setData(ClipboardData(text: '127.0.0.1:${state.localPort}'));
            if (mounted) _message(context, 'Local address copied');
          }
          break;
        case 'open':
          if (state.localPort != null) {
            final uri = Uri(scheme: rule.scheme, host: '127.0.0.1', port: state.localPort, path: '/');
            if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
              _message(context, 'Could not open the browser.');
            }
          }
          break;
      }
    } catch (error) { if (mounted) _message(context, '$error'); }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: Listenable.merge([widget.controller, widget.controller.portForwards]),
      builder: (context, _) {
        final manager = widget.controller.portForwards;
        final rules = manager.forHost(widget.hostId);
        final candidates = _discovered.where((port) => !rules.any((rule) =>
            rule.remoteHost == port.host && rule.remotePort == port.port)).toList();
        return SafeArea(top: false, child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.82,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
              Expanded(child: Text('Ports · ${widget.hostLabel}', maxLines: 1,
                  overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge)),
              IconButton(key: const Key('ports-discover'), tooltip: 'Discover listening ports',
                  onPressed: _sameHost && widget.controller.canDiscoverPorts && !_discovering ? _discover : null,
                  icon: const Icon(Icons.refresh)),
              IconButton(key: const Key('ports-add'), tooltip: 'Add forwarding rule',
                  onPressed: _sameHost ? () => _edit() : null, icon: const Icon(Icons.add)),
            ])),
            if (!_sameHost) const Padding(padding: EdgeInsets.all(12),
                child: Text('Host changed. Close and reopen Ports.')),
            if (!widget.controller.isConnected) const Padding(padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('Offline · Enabled rules resume when this host reconnects.')),
            if (_discovering) const LinearProgressIndicator(),
            if (_discoveryError != null) Padding(padding: const EdgeInsets.all(12), child: Text(_discoveryError!)),
            Expanded(child: ListView(padding: const EdgeInsets.all(12), children: [
              if (rules.isEmpty) const Padding(padding: EdgeInsets.all(12),
                  child: Text('No forwarded ports. Add one, choose a detected port, '
                      'or tap a localhost HTTP link in a conversation.')),
              for (final rule in rules) _ruleCard(rule, manager.stateFor(rule.id)),
              if (candidates.isNotEmpty) ...[
                const Padding(padding: EdgeInsets.all(12), child: Text('Detected on the SSH host')),
                for (final port in candidates) ListTile(title: Text(port.address),
                    subtitle: const Text('Detected listener · not forwarded yet'),
                    trailing: TextButton(onPressed: _sameHost ? () => _edit(candidate: port) : null,
                        child: const Text('Forward'))),
              ],
            ])),
            const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text('Phone → SSH host (TCP). Listens only on 127.0.0.1. '
                    'A listening tunnel does not guarantee the remote service is ready.',
                    style: TextStyle(fontSize: 12))),
          ]),
        ));
      });

  Widget _ruleCard(PortForwardRule rule, PortForwardState state) => Padding(
    padding: const EdgeInsets.only(bottom: 8), child: Card(child: Padding(
      padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(rule.label.isEmpty ? rule.remoteAddress : rule.label,
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600))),
          Switch(key: ValueKey('port-toggle-${rule.id}'), value: rule.enabled,
              onChanged: _sameHost ? (value) => _toggle(rule, value) : null),
          PopupMenuButton<String>(key: ValueKey('port-actions-${rule.id}'),
            enabled: _sameHost,
            tooltip: 'Port actions', onSelected: (value) => _action(rule, value),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit ports')),
              PopupMenuItem(value: 'open', enabled: state.listening, child: const Text('Open in browser')),
              PopupMenuItem(value: 'copy', enabled: state.listening, child: const Text('Copy local address')),
              const PopupMenuItem(value: 'retry', child: Text('Retry forwarding')),
              const PopupMenuItem(value: 'delete', child: Text('Remove rule')),
            ]),
        ]),
        SelectableText('${state.localPort == null ? (rule.localPort == 0 ? "Auto" : "127.0.0.1:${rule.localPort}") : "127.0.0.1:${state.localPort}"} → ${rule.remoteAddress}'),
        Text(!rule.enabled ? 'Stopped' : state.listening
            ? 'Listening locally · ${state.connections} connection(s)'
            : state.error != null ? 'Forwarding failed' : 'Waiting for SSH'),
        if (state.error != null) Text(state.error!, maxLines: 4,
            overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]),
    )));
}

class _PortEditor extends StatefulWidget {
  const _PortEditor({required this.hostId, required this.id, this.rule, this.candidate});
  final String hostId;
  final String id;
  final PortForwardRule? rule;
  final ListeningPort? candidate;
  @override
  State<_PortEditor> createState() => _PortEditorState();
}

class _PortEditorState extends State<_PortEditor> {
  late final _host = TextEditingController(text: widget.rule?.remoteHost ?? widget.candidate?.host ?? '127.0.0.1');
  late final _remote = TextEditingController(text: (widget.rule?.remotePort ?? widget.candidate?.port)?.toString() ?? '');
  late final _local = TextEditingController(text: (widget.rule?.localPort ?? 0).toString());
  late final _label = TextEditingController(text: widget.rule?.label ?? '');
  late bool _https = widget.rule?.scheme == 'https';
  String? _error;
  @override
  void dispose() { _host.dispose(); _remote.dispose(); _local.dispose(); _label.dispose(); super.dispose(); }
  void _save() {
    try {
      final result = PortForwardRule(id: widget.id, hostId: widget.hostId,
          remoteHost: _host.text, remotePort: int.tryParse(_remote.text) ?? -1,
          localPort: _local.text.trim().isEmpty ? 0 : int.tryParse(_local.text) ?? -1,
          label: _label.text.trim(), enabled: widget.rule?.enabled ?? true,
          scheme: _https ? 'https' : 'http');
      Navigator.pop(context, result);
    } catch (error) { setState(() => _error = '$error'); }
  }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.rule == null ? 'Forward a port' : 'Edit forwarding'),
    content: SizedBox(width: 420, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(key: const Key('port-remote-host'), controller: _host,
            decoration: const InputDecoration(labelText: 'Host reached from SSH server')),
        const SizedBox(height: 12),
        TextField(key: const Key('port-remote-port'), controller: _remote,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Remote port (1–65535)')),
        const SizedBox(height: 12),
        TextField(key: const Key('port-local-port'), controller: _local,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Phone port (0 = Auto)',
                helperText: 'Auto tries the remote port, then an available port.')),
        const SizedBox(height: 12),
        TextField(key: const Key('port-label'), controller: _label, maxLength: 120,
            decoration: const InputDecoration(labelText: 'Label (optional)')),
        SwitchListTile.adaptive(contentPadding: EdgeInsets.zero, title: const Text('HTTPS browser link'),
            subtitle: const Text('TCP forwarding also works for non-web services.'),
            value: _https, onChanged: (value) => setState(() => _https = value)),
        if (widget.rule != null) const Text('Changing the route closes its current client connections.'),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(key: const Key('port-save'), onPressed: _save, child: const Text('Save')),
    ],
  );
}
