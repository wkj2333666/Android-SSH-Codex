import 'package:flutter/material.dart';

import '../../account_usage.dart';

class AccountUsagePanel extends StatelessWidget {
  const AccountUsagePanel({required this.controller, super.key});

  final AccountUsageController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final buckets = controller.buckets;
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Expanded(child: Text('Subscription usage')),
                  IconButton(
                    tooltip: 'Refresh usage',
                    visualDensity: VisualDensity.compact,
                    onPressed: controller.online && !controller.loading
                        ? controller.refresh
                        : null,
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
                ]),
                if (controller.loading) const LinearProgressIndicator(),
                if (!controller.online)
                  const Text('Connect to view the remote account usage.')
                else ...[
                  if (controller.error != null)
                    Text(buckets.isEmpty
                        ? controller.error!
                        : 'Showing previous usage. Refresh failed; retry.'),
                  if (!controller.loading &&
                      controller.error == null &&
                      buckets.isEmpty)
                    const Text('Usage unavailable for this server/account.'),
                  for (final bucket in buckets) ...[
                    Text(
                      '${bucket.name ?? bucket.id}'
                      '${bucket.plan == null ? '' : ' · ${bucket.plan}'}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    if (bucket.primary case final window?)
                      _UsageWindowView(window: window, fallback: 'Primary'),
                    if (bucket.secondary case final window?)
                      _UsageWindowView(window: window, fallback: 'Secondary'),
                    if (bucket.credits != null) Text(bucket.credits!),
                    const SizedBox(height: 4),
                  ],
                  if (buckets.isNotEmpty)
                    Text('Connected server account · Not a message count',
                        style: Theme.of(context).textTheme.labelSmall),
                ],
              ],
            ),
          );
        },
      );
}

class _UsageWindowView extends StatelessWidget {
  const _UsageWindowView({required this.window, required this.fallback});

  final UsageWindow window;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final minutes = window.minutes;
    final label = minutes == null
        ? fallback
        : minutes % 1440 == 0
            ? '${minutes ~/ 1440}d'
            : minutes % 60 == 0
                ? '${minutes ~/ 60}h'
                : '${minutes}m';
    final reset = window.resetsAt?.toLocal();
    final localizations = MaterialLocalizations.of(context);
    final resetLabel = reset == null
        ? null
        : '${localizations.formatShortDate(reset)} '
            '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(reset), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label · ${window.remainingPercent.toStringAsFixed(0)}% left'),
          const SizedBox(height: 3),
          LinearProgressIndicator(value: window.remainingPercent / 100),
          if (resetLabel != null)
            Text('Resets $resetLabel',
                style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}
