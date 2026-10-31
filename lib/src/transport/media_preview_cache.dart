import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

/// Bound background work as well as retained bytes. A scrolling transcript
/// must not start an unbounded number of decoders or history scans.
class MediaPreviewCache {
  final _entries = LinkedHashMap<String, _PreviewEntry>();
  final _queue = Queue<_PreviewEntry>();
  var _active = 0;
  var _bytes = 0;

  Future<Uint8List> load(String key, Future<Uint8List> Function() fetch) {
    final previous = _entries.remove(key);
    if (previous != null) {
      if (!previous.done || DateTime.now().difference(previous.created).inSeconds < 120) {
        _entries[key] = previous;
        return previous.result.future;
      }
      _bytes -= previous.size;
    }
    if (_queue.length >= 8) return Future.error(StateError('Preview queue is busy. Tap Retry.'));
    final entry = _PreviewEntry(fetch);
    _entries[key] = entry;
    _queue.add(entry);
    _pump();
    return entry.result.future;
  }

  void _pump() {
    while (_active < 2 && _queue.isNotEmpty) {
      final entry = _queue.removeFirst();
      _active++;
      unawaited(Future.sync(entry.fetch).then((bytes) {
        entry.size = bytes.length;
        _bytes += entry.size;
        entry.result.complete(bytes);
      }, onError: (Object error, StackTrace stack) {
        entry.result.completeError(error, stack);
      }).whenComplete(() {
        entry.done = true;
        _active--;
        for (final key in _entries.keys.toList()) {
          final candidate = _entries[key]!;
          if (candidate.done && (_entries.length > 12 || _bytes > 16 * 1024 * 1024 || candidate.size == 0)) {
            _bytes -= candidate.size;
            _entries.remove(key);
          }
        }
        _pump();
      }));
    }
  }
}

class _PreviewEntry {
  _PreviewEntry(this.fetch);
  final Future<Uint8List> Function() fetch;
  final result = Completer<Uint8List>();
  final created = DateTime.now();
  var done = false;
  var size = 0;
}
