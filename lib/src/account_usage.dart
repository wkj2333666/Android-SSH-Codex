import 'package:flutter/foundation.dart';

import 'protocol/codex_remote_api.dart';

final class UsageWindow {
  const UsageWindow(this.remainingPercent, this.minutes, this.resetsAt);

  final double remainingPercent;
  final int? minutes;
  final DateTime? resetsAt;

  static UsageWindow? parse(Object? value) {
    if (value is! Map) return null;
    final used = value['usedPercent'];
    if (used is! num || !used.isFinite) return null;
    final minutes = value['windowDurationMins'];
    final reset = value['resetsAt'];
    return UsageWindow(
      (100 - used.toDouble()).clamp(0, 100).toDouble(),
      minutes is num && minutes.isFinite && minutes > 0
          ? minutes.toInt()
          : null,
      reset is num && reset.isFinite && reset > 0 && reset < 8640000000000
          ? DateTime.fromMillisecondsSinceEpoch(reset.toInt() * 1000)
          : null,
    );
  }
}

final class UsageBucket {
  UsageBucket(this.id, Map data)
      : name = data['limitName'] as String?,
        plan = data['planType'] as String?,
        primary = UsageWindow.parse(data['primary']),
        secondary = UsageWindow.parse(data['secondary']),
        credits = _credits(data['credits']);

  final String id;
  final String? name;
  final String? plan;
  final UsageWindow? primary;
  final UsageWindow? secondary;
  final String? credits;
  bool get hasData => primary != null || secondary != null || credits != null;

  static String? _credits(Object? data) {
    if (data is! Map) return null;
    if (data['unlimited'] == true) return 'Unlimited credits';
    final balance = data['balance'];
    if (balance is String && balance.isNotEmpty) return '$balance credits';
    if (data['hasCredits'] == false) return '0 credits';
    return null;
  }

  static Map<String, UsageBucket> parse(Map<String, dynamic> data) {
    final result = <String, UsageBucket>{};
    final buckets = data['rateLimitsByLimitId'];
    if (buckets is Map) {
      for (final entry in buckets.entries) {
        if (entry.key is String && entry.value is Map) {
          result[entry.key as String] = UsageBucket(entry.key, entry.value);
        }
      }
    }
    final legacy = data['rateLimits'];
    if (legacy is Map) {
      final id = legacy['limitId'] as String? ?? 'codex';
      result.putIfAbsent(id, () => UsageBucket(id, legacy));
    }
    return result;
  }
}

/// Optional account data must never block connection or conversation recovery.
/// A new connection/account invalidates every pending read and cached quota.
final class AccountUsageController extends ChangeNotifier {
  CodexRemoteApi? _api;
  var _generation = 0;
  var _revision = 0;
  bool _disposed = false;
  bool loading = false;
  String? error;
  Map<String, UsageBucket> _buckets = {};

  bool get online => _api != null;
  List<UsageBucket> get buckets =>
      _buckets.values.where((bucket) => bucket.hasData).toList();

  void bind(CodexRemoteApi? api) {
    if (_disposed) return;
    _generation++;
    _revision++;
    _api = api;
    _buckets = {};
    loading = false;
    error = null;
    notifyListeners();
  }

  void update(Map<String, dynamic> params) {
    if (_disposed || !online) return;
    _revision++;
    _buckets = {..._buckets, ...UsageBucket.parse(params)};
    error = null;
    notifyListeners();
  }

  Future<void> refresh() async {
    final api = _api;
    if (api == null || loading || _disposed) return;
    final generation = _generation;
    final revision = _revision;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await api.readAccountRateLimits();
      if (_disposed || generation != _generation) return;
      // A notification is newer than the snapshot read started before it.
      if (revision == _revision) _buckets = UsageBucket.parse(result);
    } catch (_) {
      if (_disposed || generation != _generation) return;
      if (revision == _revision) {
        error = 'Usage unavailable. The server/account may not support it; '
            'you can retry.';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
