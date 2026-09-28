import 'package:flutter/foundation.dart';

import 'json_rpc_client.dart';

/// A slow or rejected RPC is not evidence that the transport disconnected.
Future<bool> foregroundTransportDisconnected(
  JsonRpcClient rpc, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  try {
    await rpc.requestWithTimeout(
      'model/list',
      {'limit': 1, 'includeHidden': false},
      timeout,
    );
  } on RpcDisconnectedException {
    return true;
  } catch (exception) {
    debugPrint('Foreground probe inconclusive; keeping connection: $exception');
  }
  return false;
}
