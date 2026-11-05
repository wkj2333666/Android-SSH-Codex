import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../diagnostics.dart';
import 'port_forward.dart';

abstract interface class PortForwardChannel {
  Stream<List<int>> get stream;
  StreamSink<List<int>> get sink;
  Future<void> get done;
  void destroy();
}

final class SshPortForwardChannel implements PortForwardChannel {
  SshPortForwardChannel(this.channel);
  final SSHForwardChannel channel;
  @override
  Stream<List<int>> get stream => channel.stream;
  @override
  StreamSink<List<int>> get sink => channel.sink;
  @override
  Future<void> get done => channel.done;
  @override
  void destroy() => channel.destroy();
}

typedef PortForwardOpener = Future<PortForwardChannel> Function(
    String host, int port);

/// UI-independent, host-scoped listeners. Never owns/closes the SSH client.
final class PortForwardManager extends ChangeNotifier {
  static const maxRulesPerHost = 32;
  static const maxConnections = 64;
  final Map<String, PortForwardRule> _rules = {};
  final Map<String, _Listener> _listeners = {};
  final Map<String, String> _errors = {};
  String? _hostId;
  PortForwardOpener? _open;
  Object _session = Object();
  int _revision = 0;
  int _nextId = 0;
  bool _disposed = false;
  Future<void> _work = Future.value();

  List<PortForwardRule> get rules => List.unmodifiable(_rules.values);
  List<PortForwardRule> forHost(String hostId) =>
      rules.where((rule) => rule.hostId == hostId).toList(growable: false);
  String newId() =>
      'port-${DateTime.now().microsecondsSinceEpoch}-${_nextId++}';
  int get _connections =>
      _listeners.values.fold(0, (sum, run) => sum + run.clients.length);
  PortForwardState stateFor(String id) {
    final value = _listeners[id];
    final run = value?.stopped == false ? value : null;
    return PortForwardState(
        localPort: run?.server.port,
        connections: run?.clients.length ?? 0,
        error: _errors[id]);
  }

  PortForwardRule? loopbackRule(
      String hostId, int remotePort, String remoteHost) {
    final target = normalizeForwardHost(remoteHost);
    for (final rule in _rules.values) {
      if (rule.hostId == hostId &&
          rule.remotePort == remotePort &&
          rule.remoteHost == target) {
        return rule;
      }
    }
    return null;
  }

  void restore(Object? raw) {
    if (_disposed || raw is! List) return;
    for (final entry in raw.take(256)) {
      try {
        if (entry is! Map) continue;
        final rule = PortForwardRule.fromJson(entry);
        if (_rules.containsKey(rule.id) ||
            forHost(rule.hostId).length >= maxRulesPerHost ||
            _duplicate(rule)) {
          continue;
        }
        _rules[rule.id] = rule;
      } on Object {/* Ignore malformed preferences, never block connection. */}
    }
    _changed();
  }

  bool _duplicate(PortForwardRule rule) => _rules.values.any((other) =>
      other.id != rule.id &&
      other.hostId == rule.hostId &&
      other.remoteHost == rule.remoteHost &&
      other.remotePort == rule.remotePort);

  Future<void> upsert(PortForwardRule rule) {
    if (_disposed) return Future.error(StateError('Port forwarding is closed'));
    final previous = _rules[rule.id];
    if (previous != null && previous.hostId != rule.hostId) {
      throw ArgumentError('A rule cannot move between hosts.');
    }
    if (_duplicate(rule)) {
      throw ArgumentError('This remote target already has a forwarding rule.');
    }
    if (previous == null && forHost(rule.hostId).length >= maxRulesPerHost) {
      throw ArgumentError(
          'Maximum $maxRulesPerHost forwarding rules per host.');
    }
    _rules[rule.id] = rule;
    _changed();
    return _schedule();
  }

  Future<void> remove(String id) {
    _rules.remove(id);
    _errors.remove(id);
    _changed();
    return _schedule();
  }

  Future<void> removeHost(String id) {
    _rules.removeWhere((_, rule) => rule.hostId == id);
    _changed();
    return _schedule();
  }

  Future<void> retry() => _schedule();

  Future<void> attach(String hostId, PortForwardOpener open) {
    _hostId = hostId;
    _open = open;
    _session = Object();
    // Invalidate old sockets immediately, before asynchronous reconciliation.
    for (final run in _listeners.values) {
      run.stop();
    }
    return _schedule();
  }

  Future<void> detach() {
    _hostId = null;
    _open = null;
    _session = Object();
    for (final run in _listeners.values) {
      run.stop();
    }
    return _schedule();
  }

  Future<void> _schedule() {
    final revision = ++_revision;
    _work = _work.catchError((Object _) {}).then((_) => _sync(revision));
    return _work;
  }

  Future<void> _sync(int revision) async {
    if (_disposed || revision != _revision) return;
    final closing = <Future<void>>[];
    for (final entry in _listeners.entries.toList()) {
      final rule = _rules[entry.key];
      if (_open == null ||
          rule == null ||
          !rule.enabled ||
          entry.value.stopped ||
          rule.hostId != _hostId ||
          entry.value.session != _session ||
          !entry.value.rule.sameRoute(rule)) {
        _listeners.remove(entry.key);
        closing.add(entry.value.stop());
      }
    }
    await Future.wait(closing);
    if (_disposed || revision != _revision) return;
    _errors.removeWhere(
        (id, _) => !_rules.containsKey(id) || !_rules[id]!.enabled);
    final open = _open;
    if (open != null) {
      for (final rule in forHost(_hostId!)) {
        if (_disposed || revision != _revision) return;
        if (!rule.enabled || _listeners.containsKey(rule.id)) continue;
        ServerSocket? server;
        try {
          if (rule.localPort == 0 && rule.remotePort >= 1024) {
            try {
              server = await ServerSocket.bind(
                  InternetAddress.loopbackIPv4, rule.remotePort);
            } on SocketException {/* Auto chooses another free port. */}
          }
          server ??= await ServerSocket.bind(
              InternetAddress.loopbackIPv4, rule.localPort);
          if (_disposed || revision != _revision) {
            await server.close();
            return;
          }
          final session = _session;
          final run = _Listener(rule, session, server, open,
              () => _connections < maxConnections, () => _changed(), (error) {
            if (!_disposed &&
                identical(_session, session) &&
                identical(_listeners[rule.id]?.session, session)) {
              _errors[rule.id] = error.toString();
              _changed();
            }
          });
          _listeners[rule.id] = run;
          _errors.remove(rule.id);
          run.start();
          Diagnostics.record('portForward.listen', {
            'rule': rule.id,
            'localPort': server.port,
            'remotePort': rule.remotePort
          });
        } catch (error) {
          await server?.close();
          if (!_disposed && revision == _revision) {
            _errors[rule.id] = error.toString();
          }
          Diagnostics.record('portForward.bindFailed',
              {'rule': rule.id, ...Diagnostics.errorFields(error)});
        }
      }
    }
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _open = null;
    for (final run in _listeners.values) {
      unawaited(run.stop());
    }
    _listeners.clear();
    super.dispose();
  }
}

final class _Listener {
  _Listener(this.rule, this.session, this.server, this.open, this.hasCapacity,
      this.changed, this.failed);
  final PortForwardRule rule;
  final Object session;
  final ServerSocket server;
  final PortForwardOpener open;
  final bool Function() hasCapacity;
  final void Function() changed;
  final void Function(Object) failed;
  final Set<_Bridge> clients = {};
  StreamSubscription<Socket>? _subscription;
  Future<void>? _closing;
  bool stopped = false;
  void start() {
    _subscription = server.listen((socket) {
      if (stopped || !hasCapacity() || clients.length >= 16) {
        socket.destroy();
        return;
      }
      socket.setOption(SocketOption.tcpNoDelay, true);
      final bridge = _Bridge(socket, this);
      clients.add(bridge);
      changed();
      unawaited(bridge.run());
    }, onError: (Object error) {
      failed(error);
      unawaited(stop());
    });
  }

  Future<void> stop() {
    if (_closing != null) return _closing!;
    stopped = true;
    for (final client in clients.toList()) {
      client.abort();
    }
    return _closing = () async {
      await _subscription?.cancel();
      await server.close();
    }();
  }
}

final class _Bridge {
  _Bridge(this.socket, this.owner);
  final Socket socket;
  final _Listener owner;
  PortForwardChannel? _channel;
  bool _closed = false;
  void abort() {
    _closed = true;
    socket.destroy();
    _channel?.destroy();
  }

  Future<void> run() async {
    var accepting = true;
    try {
      final pending = owner
          .open(owner.rule.remoteHost, owner.rule.remotePort)
          .then((channel) {
        if (_closed || owner.stopped || !accepting) {
          channel.destroy();
          throw StateError('Discarded late forwarding channel');
        }
        return channel;
      });
      try {
        _channel = await pending.timeout(const Duration(seconds: 10));
      } finally {
        accepting = false;
      }
      final channel = _channel!;
      if (_closed || owner.stopped) return;
      unawaited(channel.done.then((_) {}, onError: (Object error) {
        if (!owner.stopped && !_closed) {
          owner.failed(error);
          Diagnostics.record('portForward.remoteError',
              {'rule': owner.rule.id, ...Diagnostics.errorFields(error)});
        }
        abort();
      }));
      Future<void> transfer(Future<dynamic> operation) async {
        try {
          await operation;
        } catch (error) {
          if (!owner.stopped && !_closed) {
            owner.failed(error);
            Diagnostics.record('portForward.streamError',
                {'rule': owner.rule.id, ...Diagnostics.errorFields(error)});
          }
          abort();
          rethrow;
        }
      }

      // pipe/addStream propagate backpressure and EOF independently. In
      // particular, a client write-half-close must not truncate the response.
      await Future.wait([
        transfer(socket.cast<List<int>>().pipe(channel.sink)),
        transfer(channel.stream.pipe(socket)),
      ]);
    } catch (error) {
      if (!_closed && !owner.stopped) {
        owner.failed(error);
        debugPrint('SSH port forwarding failed: $error');
        Diagnostics.record('portForward.channelFailed',
            {'rule': owner.rule.id, ...Diagnostics.errorFields(error)});
      }
    } finally {
      abort();
      owner.clients.remove(this);
      owner.changed();
    }
  }
}
