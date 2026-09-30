import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../diagnostics.dart';
import 'rpc_transport.dart';

final class WebSocketRpcTransport implements RpcTransport {
  WebSocketRpcTransport._(this._channel);

  final WebSocketChannel _channel;
  bool _localClose = false;

  static Future<WebSocketRpcTransport> connect(Uri uri) async {
    final channel = WebSocketChannel.connect(uri);
    await channel.ready.timeout(const Duration(seconds: 12));
    return WebSocketRpcTransport._(channel);
  }

  @override
  Stream<String> get messages => _channel.stream.transform<dynamic>(
        StreamTransformer<dynamic, dynamic>.fromHandlers(
          handleDone: (sink) {
            Diagnostics.record('websocket.done', {
              'closeCode': _channel.closeCode,
              'localCloseRequested': _localClose,
              'closeReasonPresent': _channel.closeReason?.isNotEmpty == true,
              'reason': _localClose
                  ? 'local_close'
                  : _channel.closeCode == 1006
                      ? 'abnormal_close_without_frame'
                      : 'websocket_close_code',
            });
            sink.close();
          },
        ),
      ).map((message) {
        if (message is String) return message;
        if (message is List<int>) return utf8.decode(message);
        return message.toString();
      });

  @override
  void send(String message) => _channel.sink.add(message);

  @override
  Future<void> close() {
    _localClose = true;
    return _channel.sink.close();
  }
}
