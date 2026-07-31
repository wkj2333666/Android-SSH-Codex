import 'package:collection/collection.dart';

import '../ssh_config/ssh_config.dart';

enum HostAuthMethod { password, privateKey }

final class JumpHostProfile {
  const JumpHostProfile({
    required this.hostName,
    required this.user,
    this.port = 22,
    this.identityFileHint,
  });

  factory JumpHostProfile.fromJson(Map<String, dynamic> json) =>
      JumpHostProfile(
        hostName: json['hostName'] as String,
        user: json['user'] as String,
        port: json['port'] as int? ?? 22,
        identityFileHint: json['identityFileHint'] as String?,
      );

  final String hostName;
  final String user;
  final int port;
  final String? identityFileHint;

  Map<String, dynamic> toJson() => {
        'hostName': hostName,
        'user': user,
        'port': port,
        if (identityFileHint != null) 'identityFileHint': identityFileHint,
      };

  @override
  bool operator ==(Object other) =>
      other is JumpHostProfile &&
      other.hostName == hostName &&
      other.user == user &&
      other.port == port &&
      other.identityFileHint == identityFileHint;

  @override
  int get hashCode => Object.hash(hostName, user, port, identityFileHint);
}

final class HostProfile {
  factory HostProfile({
    required String id,
    required String label,
    required String hostName,
    required String user,
    required int port,
    HostAuthMethod authMethod = HostAuthMethod.password,
    String? identityFileHint,
    JumpHostProfile? proxyJump,
    Map<String, String> environment = const {},
  }) =>
      HostProfile._(
        id: id,
        label: label,
        hostName: hostName,
        user: user,
        port: port,
        authMethod: authMethod,
        identityFileHint: identityFileHint,
        proxyJump: proxyJump,
        environment: Map.unmodifiable(environment),
      );

  const HostProfile._({
    required this.id,
    required this.label,
    required this.hostName,
    required this.user,
    required this.port,
    required this.authMethod,
    required this.identityFileHint,
    required this.proxyJump,
    required this.environment,
  });

  factory HostProfile.fromResolved(ResolvedSshHost host) => HostProfile(
        id: _profileId(host.alias),
        label: host.alias,
        hostName: host.hostName,
        user: host.user ?? '',
        port: host.port,
        authMethod: host.identityFiles.isEmpty
            ? HostAuthMethod.password
            : HostAuthMethod.privateKey,
        identityFileHint:
            host.identityFiles.isEmpty ? null : host.identityFiles.first,
        environment: host.environment,
        proxyJump: host.proxyJump == null
            ? null
            : JumpHostProfile(
                hostName: host.proxyJump!.hostName,
                user: host.proxyJump!.user ?? '',
                port: host.proxyJump!.port,
                identityFileHint: host.proxyJump!.identityFiles.isEmpty
                    ? null
                    : host.proxyJump!.identityFiles.first,
              ),
      );

  factory HostProfile.fromJson(Map<String, dynamic> json) => HostProfile(
        id: json['id'] as String,
        label: json['label'] as String,
        hostName: json['hostName'] as String,
        user: json['user'] as String,
        port: json['port'] as int? ?? 22,
        authMethod: HostAuthMethod.values.firstWhere(
          (value) => value.name == json['authMethod'],
          orElse: () => HostAuthMethod.password,
        ),
        identityFileHint: json['identityFileHint'] as String?,
        environment: json['environment'] is Map
            ? (json['environment'] as Map).cast<String, String>()
            : const {},
        proxyJump: json['proxyJump'] is Map
            ? JumpHostProfile.fromJson(
                (json['proxyJump'] as Map).cast<String, dynamic>(),
              )
            : null,
      );

  final String id;
  final String label;
  final String hostName;
  final String user;
  final int port;
  final HostAuthMethod authMethod;
  final String? identityFileHint;
  final JumpHostProfile? proxyJump;
  final Map<String, String> environment;

  HostProfile copyWith({
    String? id,
    String? label,
    String? hostName,
    String? user,
    int? port,
    HostAuthMethod? authMethod,
    String? identityFileHint,
    JumpHostProfile? proxyJump,
    Map<String, String>? environment,
    bool clearProxyJump = false,
  }) =>
      HostProfile(
        id: id ?? this.id,
        label: label ?? this.label,
        hostName: hostName ?? this.hostName,
        user: user ?? this.user,
        port: port ?? this.port,
        authMethod: authMethod ?? this.authMethod,
        identityFileHint: identityFileHint ?? this.identityFileHint,
        proxyJump: clearProxyJump ? null : proxyJump ?? this.proxyJump,
        environment: environment ?? this.environment,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'hostName': hostName,
        'user': user,
        'port': port,
        'authMethod': authMethod.name,
        if (identityFileHint != null) 'identityFileHint': identityFileHint,
        if (proxyJump != null) 'proxyJump': proxyJump!.toJson(),
        if (environment.isNotEmpty) 'environment': environment,
      };

  @override
  bool operator ==(Object other) =>
      other is HostProfile &&
      other.id == id &&
      other.label == label &&
      other.hostName == hostName &&
      other.user == user &&
      other.port == port &&
      other.authMethod == authMethod &&
      other.identityFileHint == identityFileHint &&
      other.proxyJump == proxyJump &&
      const MapEquality<String, String>().equals(
        other.environment,
        environment,
      );

  @override
  int get hashCode => Object.hash(
        id,
        label,
        hostName,
        user,
        port,
        authMethod,
        identityFileHint,
        proxyJump,
        const MapEquality<String, String>().hash(environment),
      );
}

final class HostSecret {
  const HostSecret({
    this.password,
    this.privateKey,
    this.passphrase,
    this.jumpPassword,
    this.jumpPrivateKey,
    this.jumpPassphrase,
  });

  final String? password;
  final String? privateKey;
  final String? passphrase;
  final String? jumpPassword;
  final String? jumpPrivateKey;
  final String? jumpPassphrase;

  bool get isEmpty =>
      (password == null || password!.isEmpty) &&
      (privateKey == null || privateKey!.isEmpty);

  Map<String, dynamic> toJson() => {
        if (password != null) 'password': password,
        if (privateKey != null) 'privateKey': privateKey,
        if (passphrase != null) 'passphrase': passphrase,
        if (jumpPassword != null) 'jumpPassword': jumpPassword,
        if (jumpPrivateKey != null) 'jumpPrivateKey': jumpPrivateKey,
        if (jumpPassphrase != null) 'jumpPassphrase': jumpPassphrase,
      };

  factory HostSecret.fromJson(Map<String, dynamic> json) => HostSecret(
        password: json['password'] as String?,
        privateKey: json['privateKey'] as String?,
        passphrase: json['passphrase'] as String?,
        jumpPassword: json['jumpPassword'] as String?,
        jumpPrivateKey: json['jumpPrivateKey'] as String?,
        jumpPassphrase: json['jumpPassphrase'] as String?,
      );
}

String _profileId(String alias) {
  final safe = alias.toLowerCase().replaceAll(RegExp('[^a-z0-9._-]+'), '-');
  return safe.isEmpty ? 'host' : safe;
}
