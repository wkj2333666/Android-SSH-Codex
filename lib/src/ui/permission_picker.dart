import 'package:flutter/material.dart';
import '../tasks/permission_mode.dart';

Future<PermissionMode?> choosePermissionMode(
    BuildContext context, PermissionMode value) async {
  final result = await showModalBottomSheet<PermissionMode>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
        top: false,
        child: SingleChildScrollView(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
                title: Text('Permissions · next new turn'),
                subtitle: Text(
                    'Steer does not change a running turn. Server requirements still apply.')),
            for (final mode in PermissionMode.values)
              ListTile(
                key: ValueKey('permission-${mode.name}'),
                title: Text(mode.label),
                subtitle: Text(mode.description),
                trailing: mode == value ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, mode),
              ),
          ],
        ))),
  );
  if (result != PermissionMode.fullAccess ||
      value == result ||
      !context.mounted) {
    return result;
  }
  final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
            title: const Text('Allow full access?'),
            content: const Text(
                'Commands may access files and networks outside the workspace without approval. Choose only for a trusted task. This cannot bypass server or organization restrictions.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Allow full access'))
            ],
          ));
  return confirmed == true ? result : null;
}

class PermissionPicker extends StatelessWidget {
  const PermissionPicker(
      {required this.value,
      required this.onChanged,
      this.enabled = true,
      this.compact = false,
      super.key});
  final PermissionMode value;
  final ValueChanged<PermissionMode> onChanged;
  final bool enabled;
  final bool compact;
  @override
  Widget build(BuildContext context) => compact
      ? IconButton(
          key: const Key('permission-selector'),
          tooltip: 'Permissions: ${value.label}',
          visualDensity: VisualDensity.compact,
          icon: Icon(
              value == PermissionMode.fullAccess
                  ? Icons.warning_amber
                  : Icons.shield_outlined,
              size: 19),
          onPressed: !enabled
              ? null
              : () async {
                  final mode = await choosePermissionMode(context, value);
                  if (context.mounted && mode != null) onChanged(mode);
                },
        )
      : TextButton.icon(
          key: const Key('permission-selector'),
          style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6)),
          onPressed: !enabled
              ? null
              : () async {
                  final mode = await choosePermissionMode(context, value);
                  if (context.mounted && mode != null) onChanged(mode);
                },
          icon: Icon(
              value == PermissionMode.fullAccess
                  ? Icons.warning_amber
                  : Icons.shield_outlined,
              size: 18),
          label: Text(value.label),
        );
}
