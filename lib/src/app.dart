import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'connection_lifecycle.dart';
import 'diagnostics.dart';
import 'ui/hosts_view.dart';
import 'ui/tasks_view.dart';

class AndroidSshCodexApp extends StatefulWidget {
  const AndroidSshCodexApp({required this.controller, super.key});

  final AppController controller;

  @override
  State<AndroidSshCodexApp> createState() => _AndroidSshCodexAppState();
}

class _AndroidSshCodexAppState extends State<AndroidSshCodexApp> {
  late final ConnectionLifecycle _lifecycle;

  @override
  void initState() {
    super.initState();
    widget.controller.observeNetwork();
    _lifecycle = ConnectionLifecycle(
      onBackground: () => widget.controller.enterBackground(),
      onForeground: () => widget.controller.restoreForegroundConnection(),
    );
    WidgetsBinding.instance.addObserver(_lifecycle);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Android SSH Codex',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: ThemeMode.system,
        home: _Workspace(controller: widget.controller),
      );
}

ThemeData _theme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF147D76),
    brightness: brightness,
    primary: dark ? const Color(0xFF66D4C9) : const Color(0xFF096B64),
    secondary: dark ? const Color(0xFFFFB4A5) : const Color(0xFFA43F2B),
    surface: dark ? const Color(0xFF171A1C) : const Color(0xFFF8FAF9),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    dividerColor: scheme.outlineVariant.withValues(alpha: 0.7),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
    ),
  );
}

class _Workspace extends StatelessWidget {
  const _Workspace({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final wide = MediaQuery.sizeOf(context).width >= 800;
          return Stack(
            children: [
              Scaffold(
                appBar: wide
                    ? null
                    : AppBar(
                        title: const Text('Remote Codex'),
                        actions: [
                          if (Diagnostics.supported) const _DiagnosticExport(),
                          _ConnectionAction(controller: controller),
                        ],
                      ),
                body: wide
                    ? Row(
                        children: [
                          _DesktopNavigation(controller: controller),
                          const VerticalDivider(width: 1),
                          Expanded(child: _section(controller)),
                        ],
                      )
                    : _section(controller),
                bottomNavigationBar: wide
                    ? null
                    : NavigationBar(
                        selectedIndex: controller.section.index,
                        onDestinationSelected: (index) =>
                            controller.selectSection(AppSection.values[index]),
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.dns_outlined),
                            selectedIcon: Icon(Icons.dns),
                            label: 'Hosts',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.forum_outlined),
                            selectedIcon: Icon(Icons.forum),
                            label: 'Tasks',
                          ),
                        ],
                      ),
              ),
              if (controller.error != null)
                _ErrorBanner(
                    controller: controller, message: controller.error!),
              if (controller.hostKeyChallenge != null)
                _HostKeyPrompt(controller: controller),
            ],
          );
        },
      );

  Widget _section(AppController controller) => switch (controller.section) {
        AppSection.hosts => HostsView(controller: controller),
        AppSection.tasks => TasksWorkspace(controller: controller),
      };
}

class _DesktopNavigation extends StatelessWidget {
  const _DesktopNavigation({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => SizedBox(
        key: const Key('compact-navigation'),
        width: 72,
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 12),
                const Tooltip(
                  message: 'Remote Codex',
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.terminal, size: 22),
                  ),
                ),
                IconButton(
                  tooltip: 'Hosts',
                  icon: const Icon(Icons.dns_outlined),
                  selectedIcon: const Icon(Icons.dns),
                  isSelected: controller.section == AppSection.hosts,
                  onPressed: () => controller.selectSection(AppSection.hosts),
                ),
                IconButton(
                  tooltip: 'Tasks',
                  icon: const Icon(Icons.forum_outlined),
                  selectedIcon: const Icon(Icons.forum),
                  isSelected: controller.section == AppSection.tasks,
                  onPressed: () => controller.selectSection(AppSection.tasks),
                ),
                const Divider(indent: 12, endIndent: 12),
                if (Diagnostics.supported) const _DiagnosticExport(),
                _ConnectionAction(controller: controller),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      );
}

class _DiagnosticExport extends StatefulWidget {
  const _DiagnosticExport();

  @override
  State<_DiagnosticExport> createState() => _DiagnosticExportState();
}

class _DiagnosticExportState extends State<_DiagnosticExport> {
  bool _busy = false;

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear connection logs?'),
        content: const Text('Delete diagnostic logs stored in this app. '
            'Chats, queued messages, hosts and exported files are not affected. '
            'New events will continue to be recorded.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Clear logs')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await Diagnostics.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Connection logs cleared')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not clear logs. Try again.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final saved = await Diagnostics.export();
      if (mounted && saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connection diagnostics saved')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not export diagnostics. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: 'Connection diagnostics',
        enabled: !_busy,
        onSelected: (action) => action == 'clear' ? _clear() : _export(),
        icon: const Icon(Icons.bug_report_outlined),
        itemBuilder: (_) => const [
          PopupMenuItem(
              value: 'export', child: Text('Export connection diagnostics')),
          PopupMenuItem(value: 'clear', child: Text('Clear connection logs')),
        ],
      );
}

class _ConnectionAction extends StatelessWidget {
  const _ConnectionAction({required this.controller, this.expanded = false});

  final AppController controller;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final connected = controller.isConnected;
    final busy =
        controller.connectionPhase == RemoteConnectionPhase.connecting ||
            controller.connectionPhase == RemoteConnectionPhase.reconnecting;
    final label = busy
        ? 'Connecting'
        : connected
            ? controller.selectedHost?.label ?? 'Connected'
            : controller.selectedHost == null
                ? 'Disconnected'
                : 'Reconnect ${controller.selectedHost!.label}';
    final icon = busy
        ? const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(
            connected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            size: 20,
          );
    final action = busy
        ? null
        : connected
            ? controller.disconnect
            : controller.selectedHost == null
                ? null
                : () => controller.connectHost(controller.selectedHost!);
    if (expanded) {
      return OutlinedButton.icon(
        onPressed: action,
        icon: icon,
        label: Text(label, overflow: TextOverflow.ellipsis),
      );
    }
    return Tooltip(
      message: connected ? 'Disconnect from $label' : label,
      child: IconButton(
        onPressed: action,
        icon: icon,
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.controller, required this.message});

  final AppController controller;
  final String message;

  @override
  Widget build(BuildContext context) => Positioned(
        left: 12,
        right: 12,
        top: MediaQuery.paddingOf(context).top + 12,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(6),
          color: Theme.of(context).colorScheme.errorContainer,
          child: ListTile(
            leading: const Icon(Icons.error_outline),
            title: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              tooltip: 'Dismiss',
              onPressed: controller.clearError,
              icon: const Icon(Icons.close),
            ),
          ),
        ),
      );
}

class _HostKeyPrompt extends StatelessWidget {
  const _HostKeyPrompt({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final challenge = controller.hostKeyChallenge!;
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: AlertDialog(
          title: const Text('Trust this host?'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(challenge.label),
                const SizedBox(height: 12),
                Text(challenge.algorithm),
                const SizedBox(height: 4),
                SelectableText(
                  challenge.fingerprint,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => controller.answerHostKey(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => controller.answerHostKey(true),
              child: const Text('Trust'),
            ),
          ],
        ),
      ),
    );
  }
}
