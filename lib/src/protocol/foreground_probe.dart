import 'package:flutter/foundation.dart';

import '../diagnostics.dart';
import 'json_rpc_client.dart';

/// A slow or rejected RPC is not evidence that the transport disconnected.
Future<bool> foregroundTransportDisconnected(
  JsonRpcClient rpc, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  Diagnostics.record('probe.start');
  try {
    await rpc.requestWithTimeout(
      'model/list',
      {'limit': 1, 'includeHidden': false},
      timeout,
    );
    Diagnostics.record('probe.success');
  } on RpcDisconnectedException {
    Diagnostics.record('probe.disconnected');
    return true;
  } catch (exception) {
    Diagnostics.record('probe.inconclusive', Diagnostics.errorFields(exception));
    debugPrint('Foreground probe inconclusive; keeping connection: $exception');
  }
  return false;
}
