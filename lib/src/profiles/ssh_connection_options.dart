/// Per-host SSH transport options. Defaults preserve existing connections.
final class SshConnectionOptions {
  const SshConnectionOptions({
    this.connectTimeoutSeconds = 15,
    this.authTimeoutSeconds = 20,
    this.keepAliveIntervalSeconds = 15,
  });

  factory SshConnectionOptions.fromJson(Map<String, dynamic> json) =>
      SshConnectionOptions(
        connectTimeoutSeconds: _seconds(json['connectTimeoutSeconds'], 15, 1, 120),
        authTimeoutSeconds: _seconds(json['authTimeoutSeconds'], 20, 1, 120),
        keepAliveIntervalSeconds: _seconds(json['keepAliveIntervalSeconds'], 15, 0, 300),
      );

  final int connectTimeoutSeconds;
  final int authTimeoutSeconds;
  final int keepAliveIntervalSeconds;

  Duration get connectTimeout => Duration(seconds: connectTimeoutSeconds);
  Duration get authTimeout => Duration(seconds: authTimeoutSeconds);
  Duration get keepAliveInterval => Duration(seconds: keepAliveIntervalSeconds);

  Duration setupTimeout({required bool hasJumpHost}) {
    final seconds = (2 * connectTimeoutSeconds + authTimeoutSeconds) * (hasJumpHost ? 2 : 1) + 30;
    return Duration(seconds: seconds < 90 ? 90 : seconds);
  }

  Map<String, dynamic> toJson() => {
    'connectTimeoutSeconds': connectTimeoutSeconds,
    'authTimeoutSeconds': authTimeoutSeconds,
    'keepAliveIntervalSeconds': keepAliveIntervalSeconds,
  };

  @override
  bool operator ==(Object other) => other is SshConnectionOptions &&
      other.connectTimeoutSeconds == connectTimeoutSeconds &&
      other.authTimeoutSeconds == authTimeoutSeconds &&
      other.keepAliveIntervalSeconds == keepAliveIntervalSeconds;

  @override
  int get hashCode => Object.hash(connectTimeoutSeconds, authTimeoutSeconds, keepAliveIntervalSeconds);
}

int _seconds(Object? value, int fallback, int min, int max) =>
    value is int && value >= min && value <= max ? value : fallback;
