import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'port_forward.dart';

final class ListeningPort {
  const ListeningPort(this.host, this.port);
  final String host;
  final int port;
  String get address => Uri(host: host, port: port).authority;
}

List<ListeningPort> parseListeningPorts(String output) {
  final found = <String, ListeningPort>{};
  for (final line in const LineSplitter().convert(output).take(1024)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    String? address;
    if (parts.length >= 5 && parts[0] == 'LISTEN') {
      address = parts[3];
    } else if (parts.length >= 6 && parts[1] == 'LISTEN') {
      address = parts[4];
    } else if (parts.length >= 6 &&
        (parts[0] == 'tcp' || parts[0] == 'tcp6') && parts.contains('LISTEN')) {
      address = parts[3];
    }
    if (address == null) continue;
    final split = address.lastIndexOf(':');
    if (split < 1) continue;
    final port = int.tryParse(address.substring(split + 1));
    if (port == null || port < 1 || port > 65535) continue;
    try {
      final host = normalizeForwardHost(address.substring(0, split));
      found['$host:$port'] = ListeningPort(host, port);
    } on ArgumentError { continue; }
    if (found.length >= 200) break;
  }
  return found.values.toList()..sort((a, b) {
    final byPort = a.port.compareTo(b.port);
    return byPort == 0 ? a.host.compareTo(b.host) : byPort;
  });
}

// Read-only, no process names/arguments, no sudo or new server dependencies.
const listeningPortsCommand = "/bin/sh -c 'if command -v ss >/dev/null 2>&1; "
    "then ss -H -ltn | head -c 65537; elif command -v netstat >/dev/null 2>&1; "
    "then netstat -ltn | head -c 65537; else exit 69; fi'";

Future<List<ListeningPort>> discoverListeningPorts(SSHClient client) async {
  SSHSession? session;
  var finished = false;
  try {
    session = await client.execute(listeningPortsCommand).then((value) {
      if (finished) { value.close(); throw StateError('Discarded late port discovery'); }
      return value;
    }).timeout(const Duration(seconds: 8));
    final reading = session;
    final output = <int>[];
    final errors = <int>[];
    await Future.wait([
      reading.stdout.forEach((chunk) {
        if (output.length + chunk.length > 65536) {
          throw StateError('Too many listening ports. Add a port manually.');
        }
        output.addAll(chunk);
      }),
      reading.stderr.forEach((chunk) {
        if (errors.length < 512) errors.addAll(chunk.take(512 - errors.length));
      }),
      reading.done,
    ], eagerError: true).timeout(const Duration(seconds: 8));
    if (reading.exitCode != 0 || errors.isNotEmpty) {
      throw StateError('Port discovery needs ss or netstat on the SSH host. Add ports manually if unavailable.');
    }
    return parseListeningPorts(utf8.decode(output, allowMalformed: true));
  } finally { finished = true; session?.close(); }
}
