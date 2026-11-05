import 'dart:io';

String normalizeForwardHost(String value) {
  var host = value.trim().toLowerCase();
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  if (host == 'localhost' || host == '0.0.0.0' || host == '*') {
    return '127.0.0.1';
  }
  if (host == '::') return '::1';
  if (host.isEmpty ||
      host.length > 253 ||
      (InternetAddress.tryParse(host) == null &&
          !RegExp(r'^[a-z0-9_][a-z0-9_.-]*$').hasMatch(host))) {
    throw ArgumentError(
        'Enter an IP address or hostname, without a URL or credentials.');
  }
  return host;
}

bool isForwardLoopback(String host) {
  try {
    final normalized = normalizeForwardHost(host);
    return InternetAddress.tryParse(normalized)?.isLoopback == true;
  } on ArgumentError {
    return false;
  }
}

bool isRemoteLoopbackUri(Uri uri) =>
    (uri.scheme == 'http' || uri.scheme == 'https') &&
    uri.hasAuthority &&
    isForwardLoopback(uri.host);

Uri mapForwardedUri(Uri source, int localPort) {
  if (!isRemoteLoopbackUri(source) ||
      source.userInfo.isNotEmpty ||
      source.port < 1 ||
      source.port > 65535 ||
      localPort < 1 ||
      localPort > 65535) {
    throw ArgumentError(
        'Only remote loopback HTTP(S) URLs without credentials can be forwarded.');
  }
  return source.replace(host: '127.0.0.1', port: localPort);
}

final class PortForwardRule {
  PortForwardRule(
      {required this.id,
      required this.hostId,
      required String remoteHost,
      required this.remotePort,
      this.localPort = 0,
      this.label = '',
      this.enabled = true,
      this.scheme = 'http'})
      : remoteHost = normalizeForwardHost(remoteHost) {
    if (id.isEmpty ||
        hostId.isEmpty ||
        remotePort < 1 ||
        remotePort > 65535 ||
        localPort < 0 ||
        localPort > 65535 ||
        label.length > 120 ||
        (scheme != 'http' && scheme != 'https')) {
      throw ArgumentError(
          'Ports must be 1–65535 (local 0 means Auto); label maximum 120 characters.');
    }
  }

  factory PortForwardRule.fromJson(Map value) => PortForwardRule(
      id: value['id'] as String,
      hostId: value['hostId'] as String,
      remoteHost: value['remoteHost'] as String,
      remotePort: value['remotePort'] as int,
      localPort: value['localPort'] as int? ?? 0,
      label: value['label'] as String? ?? '',
      enabled: value['enabled'] as bool? ?? false,
      scheme: value['scheme'] as String? ?? 'http');

  final String id;
  final String hostId;
  final String remoteHost;
  final int remotePort;
  final int localPort;
  final String label;
  final bool enabled;
  final String scheme;
  String get remoteAddress => Uri(host: remoteHost, port: remotePort).authority;

  Map<String, dynamic> toJson() => {
        'id': id,
        'hostId': hostId,
        'remoteHost': remoteHost,
        'remotePort': remotePort,
        'localPort': localPort,
        'label': label,
        'enabled': enabled,
        'scheme': scheme,
      };

  PortForwardRule copyWith(
          {String? remoteHost,
          int? remotePort,
          int? localPort,
          String? label,
          bool? enabled,
          String? scheme}) =>
      PortForwardRule(
          id: id,
          hostId: hostId,
          remoteHost: remoteHost ?? this.remoteHost,
          remotePort: remotePort ?? this.remotePort,
          localPort: localPort ?? this.localPort,
          label: label ?? this.label,
          enabled: enabled ?? this.enabled,
          scheme: scheme ?? this.scheme);

  bool sameRoute(PortForwardRule other) =>
      hostId == other.hostId &&
      remoteHost == other.remoteHost &&
      remotePort == other.remotePort &&
      localPort == other.localPort;
}

final class PortForwardState {
  const PortForwardState({this.localPort, this.connections = 0, this.error});
  final int? localPort;
  final int connections;
  final String? error;
  bool get listening => localPort != null;
}
