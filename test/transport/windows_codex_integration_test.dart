import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:android_ssh_codex/src/profiles/remote_platform.dart';
import 'package:android_ssh_codex/src/protocol/codex_remote_api.dart';
import 'package:android_ssh_codex/src/protocol/json_rpc_client.dart';
import 'package:android_ssh_codex/src/protocol/websocket_rpc_transport.dart';
import 'package:android_ssh_codex/src/transport/codex_daemon.dart';
import 'package:android_ssh_codex/src/transport/ssh_unix_tunnel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Opt in with the exact socketPath of an already-running local daemon.
  // Only initialize the connection; do not submit prompts or query history.
  final socket = Platform.environment['CODEX_TEST_SOCKET'];
  test('real Windows proxy initializes with the mobile Dart client', () async {
    final command =
        CodexDaemon.proxyCommand(socket!, platform: RemotePlatform.windows);
    final process = await Process.start(
        'powershell.exe', command.split(' ').skip(1).toList());
    final channel = _ProcessChannel(process);
    var exited = false;
    unawaited(process.exitCode.then((_) {
      exited = true;
    }));
    addTearDown(() async {
      if (!exited) {
        await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
      }
      await channel.closeInput();
    });
    final tunnel =
        await SshUnixTunnel.startWithOpener(socket, () async => channel);
    addTearDown(tunnel.close);
    final transport = await WebSocketRpcTransport.connect(
        Uri.parse('ws://127.0.0.1:${tunnel.localPort}/'));
    final rpc = JsonRpcClient(transport)..start();
    addTearDown(rpc.close);
    await CodexRemoteApi(rpc).initialize();
  },
      skip: !Platform.isWindows || socket == null,
      timeout: const Timeout(Duration(seconds: 45)));
}

class _ProcessChannel implements SshProxyChannel {
  _ProcessChannel(this.process) {
    unawaited(_forwardInput());
    done = Future.any([
      process.exitCode.then((code) {
        exitCode = code;
      }),
      _failure.future,
    ]);
  }
  final Process process;
  final _input = StreamController<Uint8List>();

  Future<void> _forwardInput() async {
    try {
      await for (final bytes in _input.stream) {
        process.stdin.add(bytes);
        await process.stdin.flush();
      }
      await process.stdin.close();
    } catch (error, stack) {
      if (!_closing) _failure.completeError(error, stack);
    }
  }

  final _failure = Completer<void>();
  bool _closing = false;

  @override
  Stream<Uint8List> get stdout => process.stdout.map(Uint8List.fromList);
  @override
  Stream<Uint8List> get stderr => process.stderr.map(Uint8List.fromList);
  @override
  StreamSink<Uint8List> get stdin => _input.sink;
  @override
  late final Future<void> done;
  @override
  int? exitCode;
  @override
  String? get exitSignal => null;

  Future<void> closeInput() {
    _closing = true;
    return _input.close();
  }

  @override
  void close() {
    unawaited(closeInput());
  }
}
