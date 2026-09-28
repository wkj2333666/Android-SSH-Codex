import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'connection_lifecycle.dart';
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
                        actions: [_ConnectionAction(controller: controller)],
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
        width: 232,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 16, 18),
                child: Row(
                  children: [
                    Icon(Icons.terminal, size: 22),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Remote Codex',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _NavItem(
                icon: Icons.dns_outlined,
                label: 'Hosts',
                selected: controller.section == AppSection.hosts,
                onTap: () => controller.selectSection(AppSection.hosts),
              ),
              _NavItem(
                icon: Icons.forum_outlined,
                label: 'Tasks',
                selected: controller.section == AppSection.tasks,
                onTap: () => controller.selectSection(AppSection.tasks),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.all(16),
                child:
                    _ConnectionAction(controller: controller, expanded: true),
              ),
            ],
          ),
        ),
      );
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          selected: selected,
          leading: Icon(icon),
          title: Text(label),
          onTap: onTap,
        ),
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
