import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'file_download.dart';
import 'resumable_download.dart';

enum DownloadState { queued, transferring, saving, completed, failed, cancelled }

typedef SavedDownload = ({String name, String? uri});

class DownloadEntry {
  DownloadEntry._(this.hostId, this.path, this.hostLabel);

  final String hostId;
  final String path;
  final String hostLabel;
  DownloadState _state = DownloadState.queued;
  DownloadProgress _progress = const DownloadProgress(0, null);
  SavedDownload? _saved;
  String? _error;

  String get name => _saved?.name ?? path.split('/').last;
  DownloadState get state => _state;
  DownloadProgress get progress => _progress;
  String? get uri => _saved?.uri;
  String? get error => _error;
  bool get canCancel =>
      state == DownloadState.queued || state == DownloadState.transferring;
  bool get canRetry =>
      state == DownloadState.failed || state == DownloadState.cancelled;
  bool get active => canCancel || state == DownloadState.saving;

  Map<String, Object?> toJson() => {
        'host': hostId,
        'path': path,
        'hostLabel': hostLabel,
        'state': state.name,
        'size': progress.total,
        if (_saved != null) 'name': _saved!.name,
        if (uri != null) 'uri': uri,
        if (error != null) 'error': error,
      };

  static DownloadEntry? _restore(Object? value) {
    if (value is! Map ||
        value['host'] is! String ||
        value['path'] is! String ||
        value['hostLabel'] is! String) {
      return null;
    }
    final entry = DownloadEntry._(
        value['host'] as String, value['path'] as String,
        value['hostLabel'] as String);
    entry._state =
        DownloadState.values.where((s) => s.name == value['state']).firstOrNull ??
            DownloadState.failed;
    final size = value['size'] as int?;
    if (entry.state == DownloadState.completed && value['name'] is String) {
      entry._saved =
          (name: value['name'] as String, uri: value['uri'] as String?);
      entry._progress = DownloadProgress(size ?? 0, size);
    } else if (entry.active) {
      entry._state = DownloadState.failed;
      entry._error = 'Interrupted when the app stopped. Tap Retry to restart.';
    } else {
      entry._error = value['error'] as String?;
    }
    return entry;
  }
}

typedef DownloadWorker = Future<SavedDownload> Function(
  DownloadEntry entry,
  DownloadCancellation cancellation,
  void Function(DownloadProgress) progress,
);

/// The queue lives with the app controller, not a task, route or SSH RPC.
/// One file transfers at a time; the transport pipelines reads within it.
class DownloadQueue extends ChangeNotifier {
  DownloadQueue(this.run, {required this.onChanged});

  static const maxPending = 20;
  static const maxHistory = 60;
  final DownloadWorker run;
  final VoidCallback onChanged;
  final _entries = <DownloadEntry>[];
  final _waiting = <DownloadEntry>[];
  DownloadCancellation? _cancellation;
  DownloadEntry? _running;
  bool _disposed = false;

  List<DownloadEntry> get entries => List.unmodifiable(_entries.reversed);
  int get activeCount => _waiting.length + (_running == null ? 0 : 1);

  void restore(Object? json) {
    if (json is! List) return;
    for (final raw in json.take(maxHistory + maxPending)) {
      try {
        final entry = DownloadEntry._restore(raw);
        if (entry != null) _entries.add(entry);
      } on TypeError {
        // Ignore old/corrupt records without affecting the workspace.
      }
    }
    notifyListeners();
  }

  List<Map<String, Object?>> toJson() =>
      _entries.map((entry) => entry.toJson()).toList(growable: false);

  void enqueue(String hostId, String path, String hostLabel) {
    if (_entries.any((entry) =>
        entry.active && entry.hostId == hostId && entry.path == path)) {
      return;
    }
    _checkSpace();
    final entry = DownloadEntry._(hostId, path, hostLabel);
    _entries.add(entry);
    _add(entry);
  }

  void retry(DownloadEntry entry) {
    if (!_entries.contains(entry) || !entry.canRetry) return;
    if (_entries.any((other) =>
        other.active && other.hostId == entry.hostId && other.path == entry.path)) {
      return;
    }
    _checkSpace();
    _entries.remove(entry);
    _entries.add(entry);
    _add(entry);
  }

  void _checkSpace() {
    if (_disposed) throw StateError('Downloads are closed');
    if (activeCount >= maxPending) {
      throw StateError('Download queue is full');
    }
  }

  void _add(DownloadEntry entry) {
    entry._state = DownloadState.queued;
    entry._error = null;
    entry._progress = const DownloadProgress(0, null);
    _waiting.add(entry);
    _changed();
    unawaited(_startNext());
  }

  void cancel(DownloadEntry entry) {
    if (!entry.canCancel) return;
    if (_running == entry) {
      _cancellation?.cancel();
    } else if (_waiting.remove(entry)) {
      entry._state = DownloadState.cancelled;
      _changed();
    }
  }

  void removeFromHistory(DownloadEntry entry) {
    if (!entry.active && _entries.remove(entry)) _changed();
  }

  void _changed() {
    if (_disposed) return;
    var completed = _entries.where((entry) => !entry.active).length;
    if (completed > maxHistory) {
      _entries.removeWhere((entry) => !entry.active && completed-- > maxHistory);
    }
    onChanged();
    notifyListeners();
  }

  Future<void> _startNext() async {
    if (_running != null || _waiting.isEmpty || _disposed) return;
    final entry = _running = _waiting.removeAt(0);
    final cancellation = _cancellation = DownloadCancellation();
    entry._state = DownloadState.transferring;
    notifyListeners();
    try {
      entry._saved = await run(entry, cancellation, (progress) {
        if (_disposed) return;
        entry._progress = progress;
        if (progress.saving) entry._state = DownloadState.saving;
        notifyListeners();
      });
      entry._state = DownloadState.completed;
    } on DownloadCancelled {
      entry._state = DownloadState.cancelled;
    } catch (error) {
      entry._state = DownloadState.failed;
      entry._error = downloadErrorMessage(error);
    } finally {
      _running = null;
      _cancellation = null;
      _changed();
      if (!_disposed) unawaited(_startNext());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancellation?.cancel();
    _waiting.clear();
    super.dispose();
  }
}

String downloadErrorMessage(Object error) {
  if (error is DownloadCancelled) return 'Download cancelled.';
  if (error is FileDownloadException) return error.message;
  if (error is TimeoutException) {
    return 'Download timed out. Check the connection and retry.';
  }
  if (error is FileSystemException) {
    return 'Phone storage could not be written. Check free space.';
  }
  if (error is PlatformException) {
    return error.message ?? 'Could not save on the phone (${error.code}).';
  }
  if (error is StateError) return 'Download failed: ${error.message}';
  return 'Download failed (${error.runtimeType}). Check the SSH connection and retry.';
}

abstract final class PublicDownloadStorage {
  static const channel = MethodChannel('android_ssh_codex/downloads');
  static const location = 'Downloads/RemoteCodex';

  static Future<SavedDownload> save(String path, String name) async {
    final result = await channel
        .invokeMapMethod<String, String>('publish', {'path': path, 'name': name});
    if (result == null || result['name'] == null) {
      throw StateError('Android did not return a saved file');
    }
    return (name: result['name']!, uri: result['uri']);
  }

  static Future<void> open(String uri) =>
      channel.invokeMethod<void>('openFile', {'uri': uri});

  static Future<void> showFolder() => channel.invokeMethod<void>('openFolder');
}
