import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:android_ssh_codex/src/ports/port_forward.dart';
import 'package:android_ssh_codex/src/ports/port_forward_manager.dart';
import 'package:android_ssh_codex/src/ports/port_discovery.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class _Channel implements PortForwardChannel {
  _Channel(this.socket);
  final Socket socket;
  bool destroyed = false;
  @override
  Stream<List<int>> get stream => socket;
  @override
  StreamSink<List<int>> get sink => socket;
  @override
  Future<void> get done => socket.done;
  @override
  void destroy() {
    destroyed = true;
    socket.destroy();
  }
}

PortForwardRule rule(
        {String id = 'a',
        String host = 'pi',
        int remote = 3000,
        int local = 0,
        bool enabled = true}) =>
    PortForwardRule(
        id: id,
        hostId: host,
        remoteHost: '127.0.0.1',
        remotePort: remote,
        localPort: local,
        enabled: enabled);

void main() {
  test('rules validate ports/targets and round trip without credentials', () {
    final value = rule();
    expect(PortForwardRule.fromJson(value.toJson()).toJson(), value.toJson());
    expect(() => rule(local: 65536), throwsArgumentError);
    expect(() => rule(remote: 0), throwsArgumentError);
    expect(() => normalizeForwardHost('user@host'), throwsArgumentError);
    expect(normalizeForwardHost('[::1]'), '::1');
    expect(normalizeForwardHost('LOCALHOST'), '127.0.0.1');
    expect(
        normalizeForwardHost('api_service.internal.'), 'api_service.internal.');
  });

  test('listening discovery handles ss/netstat, wildcard and IPv6 safely', () {
    final found = parseListeningPorts('''
LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*
LISTEN 0 128 [::]:8000 [::]:*
tcp 0 0 0.0.0.0:5000 0.0.0.0:* LISTEN
tcp6 0 0 ::1:9000 :::* LISTEN
LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*
garbage localhost:6000
''');
    expect(found.map((p) => p.port), [3000, 5000, 8000, 9000]);
    expect(found.first.host, '127.0.0.1');
    expect(found.firstWhere((p) => p.port == 8000).host, '::1');
  });

  test('only loopback HTTP links are eligible and mapped paths are preserved',
      () {
    expect(isRemoteLoopbackUri(Uri.parse('http://localhost:3000/a')), isTrue);
    expect(isRemoteLoopbackUri(Uri.parse('https://[::1]:8443/')), isTrue);
    expect(
        isRemoteLoopbackUri(Uri.parse('http://localhost.evil:3000/')), isFalse);
    expect(isRemoteLoopbackUri(Uri.parse('ftp://localhost:3000/')), isFalse);
    final source = Uri.parse('http://localhost:3000/a?q=secret#fragment');
    final mapped = mapForwardedUri(source, 43123);
    expect(mapped.toString(), 'http://127.0.0.1:43123/a?q=secret#fragment');
    expect(() => mapForwardedUri(Uri.parse('http://u:p@localhost:3000/'), 4000),
        throwsArgumentError);
  });

  test(
      'TCP forwarding crosses window sizes, preserves half-close and cleans up',
      () async {
    final target = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = <Socket>[];
    final sub = target.listen((socket) {
      accepted.add(socket);
      unawaited(socket.cast<List<int>>().pipe(socket));
    });
    final manager = PortForwardManager();
    try {
      await manager.upsert(rule(remote: target.port));
      await manager.attach('pi',
          (host, port) async => _Channel(await Socket.connect(host, port)));
      final port = manager.stateFor('a').localPort!;
      expect(port,
          isNot(target.port)); // Auto falls back if preferred port is busy.
      final socket = await Socket.connect('127.0.0.1', port);
      final bytes = Uint8List.fromList(
          List.generate(4 * 1024 * 1024 + 37, (i) => i % 251));
      final receiving = socket
          .fold<BytesBuilder>(
              BytesBuilder(), (builder, chunk) => builder..add(chunk))
          .catchError((Object error) {
        throw StateError(
            'Receive failed: $error; bridge: ${manager.stateFor("a").error}');
      });
      socket.add(bytes);
      await socket.flush();
      await socket.close(); // Client EOF must not discard the echo response.
      final response =
          (await receiving.timeout(const Duration(seconds: 15))).takeBytes();
      expect(response, bytes);
      await manager.detach();
      expect(manager.stateFor('a').localPort, isNull);
      final reclaimed =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await reclaimed.close();
    } finally {
      manager.dispose();
      for (final socket in accepted) {
        socket.destroy();
      }
      await sub.cancel();
      await target.close();
    }
  });

  test('renaming a rule preserves its listener and unrelated rules', () async {
    final manager = PortForwardManager();
    try {
      await manager.attach('pi', (_, __) => throw StateError('unused'));
      await manager.upsert(rule());
      final before = manager.stateFor('a').localPort;
      await manager.upsert(rule().copyWith(label: 'Renamed'));
      expect(manager.stateFor('a').localPort, before);
      await manager.upsert(rule(id: 'b', remote: 33333));
      expect(manager.stateFor('a').localPort, before);
      await manager.remove('b');
      expect(manager.stateFor('a').localPort, before);
    } finally {
      manager.dispose();
    }
  });

  test(
      'conflicting fixed port fails only that rule; disabling does not resurrect',
      () async {
    final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final manager = PortForwardManager();
    try {
      await manager.attach('pi', (_, __) => throw StateError('unused'));
      await manager.upsert(rule(local: busy.port));
      expect(manager.stateFor('a').error, isNotNull);
      await manager.upsert(rule(id: 'b', remote: 12345));
      expect(manager.stateFor('b').localPort, isNotNull);
      await manager.upsert(rule(id: 'b', remote: 12345, enabled: false));
      await manager.detach();
      await manager.attach('pi', (_, __) => throw StateError('unused'));
      expect(manager.stateFor('b').localPort, isNull);
      expect(manager.rules.singleWhere((r) => r.id == 'b').enabled, isFalse);
    } finally {
      manager.dispose();
      await busy.close();
    }
  });

  test(
      'late channel after host switch is destroyed, never attached to new host',
      () async {
    final opening = Completer<PortForwardChannel>();
    final requested = Completer<void>();
    final target = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peers = <Socket>[];
    final sub = target.listen(peers.add);
    final manager = PortForwardManager();
    Socket? client;
    try {
      await manager.upsert(rule());
      await manager.attach('pi', (_, __) {
        requested.complete();
        return opening.future;
      });
      client =
          await Socket.connect('127.0.0.1', manager.stateFor('a').localPort!);
      client.listen((_) {}, onError: (_) {});
      await requested.future;
      await manager.attach('other', (_, __) => throw StateError('wrong host'));
      final channel = _Channel(await Socket.connect('127.0.0.1', target.port));
      opening.complete(channel);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(channel.destroyed, isTrue);
      expect(manager.stateFor('a').localPort, isNull);
    } finally {
      client?.destroy();
      manager.dispose();
      for (final socket in peers) {
        socket.destroy();
      }
      await sub.cancel();
      await target.close();
    }
  });

  test('real SSH forward uses direct-tcpip and survives shared client use',
      () async {
    final client = SSHClient(await SSHSocket.connect('127.0.0.1', 22229),
        username: Platform.environment['USER']!,
        identities: SSHKeyPair.fromPem(
            await File(Platform.environment['DOWNLOAD_TEST_KEY']!)
                .readAsString()));
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peers = <Socket>[];
    final sub = server.listen((socket) {
      peers.add(socket);
      unawaited(socket.cast<List<int>>().pipe(socket));
    });
    final manager = PortForwardManager();
    Socket? socket;
    try {
      await manager.upsert(rule(remote: server.port));
      await manager.attach(
          'pi',
          (host, port) async =>
              SshPortForwardChannel(await client.forwardLocal(host, port)));
      socket =
          await Socket.connect('127.0.0.1', manager.stateFor('a').localPort!);
      final payload = Uint8List.fromList(
          List.generate(4 * 1024 * 1024 + 37, (i) => i % 251));
      final response = socket.fold<BytesBuilder>(
          BytesBuilder(), (buffer, chunk) => buffer..add(chunk));
      socket.add(payload);
      await socket.flush();
      await socket.close();
      expect((await response.timeout(const Duration(seconds: 30))).takeBytes(),
          payload);
      await manager.detach();
      await client.ping();
      expect(client.isClosed, isFalse);
    } finally {
      manager.dispose();
      socket?.destroy();
      client.close();
      for (final peer in peers) {
        peer.destroy();
      }
      await sub.cancel();
      await server.close();
    }
  }, skip: !Platform.environment.containsKey('DOWNLOAD_TEST_KEY'));
}
