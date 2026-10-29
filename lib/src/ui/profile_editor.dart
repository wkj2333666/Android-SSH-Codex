import 'package:flutter/material.dart';

import '../profiles/host_profile.dart';
import '../ssh_config/ssh_config.dart';
import '../ssh_config/ssh_environment.dart';

final class ProfileDraft {
  const ProfileDraft(this.profile, this.secret);

  final HostProfile profile;
  final HostSecret secret;
}

class ProfileEditor extends StatefulWidget {
  const ProfileEditor({required this.secret, this.profile, super.key});

  final HostProfile? profile;
  final HostSecret secret;

  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  final _formKey = GlobalKey<FormState>();
  final _advancedSsh = ExpansibleController();
  late final TextEditingController _label;
  late final TextEditingController _host;
  late final TextEditingController _user;
  late final TextEditingController _port;
  late final TextEditingController _password;
  late final TextEditingController _privateKey;
  late final TextEditingController _passphrase;
  late final TextEditingController _jumpPassword;
  late final TextEditingController _jumpPrivateKey;
  late final TextEditingController _jumpPassphrase;
  late final TextEditingController _jumpHost;
  late final TextEditingController _jumpUser;
  late final TextEditingController _jumpPort;
  late final TextEditingController _connectTimeout;
  late final TextEditingController _authTimeout;
  late final TextEditingController _keepAliveInterval;
  late final TextEditingController _config;
  late final TextEditingController _alias;
  late final TextEditingController _environment;
  late final TextEditingController _customAppServerSocket;
  late HostAuthMethod _authMethod;
  late AppServerMode _appServerMode;
  late bool _useJump;
  String? _jumpIdentityHint;
  String? _importError;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _label = TextEditingController(text: profile?.label ?? '');
    _host = TextEditingController(text: profile?.hostName ?? '');
    _user = TextEditingController(text: profile?.user ?? '');
    _port = TextEditingController(text: '${profile?.port ?? 22}');
    _password = TextEditingController(text: widget.secret.password ?? '');
    _privateKey = TextEditingController(text: widget.secret.privateKey ?? '');
    _passphrase = TextEditingController(text: widget.secret.passphrase ?? '');
    _jumpPassword =
        TextEditingController(text: widget.secret.jumpPassword ?? '');
    _jumpPrivateKey =
        TextEditingController(text: widget.secret.jumpPrivateKey ?? '');
    _jumpPassphrase =
        TextEditingController(text: widget.secret.jumpPassphrase ?? '');
    _config = TextEditingController();
    _alias = TextEditingController(text: profile?.label ?? '');
    _environment = TextEditingController(
      text: formatSshEnvironmentLines(profile?.environment ?? const {}),
    );
    _customAppServerSocket = TextEditingController(
      text: profile?.customAppServerSocket ?? '',
    );
    _authMethod = profile?.authMethod ?? HostAuthMethod.password;
    _appServerMode = profile?.appServerMode ?? AppServerMode.shared;
    final jump = profile?.proxyJump;
    _useJump = jump != null;
    _jumpIdentityHint = jump?.identityFileHint;
    _jumpHost = TextEditingController(text: jump?.hostName ?? '');
    _jumpUser = TextEditingController(text: jump?.user ?? '');
    _jumpPort = TextEditingController(text: '${jump?.port ?? 22}');
    final options = profile?.sshOptions ?? const SshConnectionOptions();
    _connectTimeout =
        TextEditingController(text: '${options.connectTimeoutSeconds}');
    _authTimeout = TextEditingController(text: '${options.authTimeoutSeconds}');
    _keepAliveInterval =
        TextEditingController(text: '${options.keepAliveIntervalSeconds}');
  }

  @override
  void dispose() {
    _advancedSsh.dispose();
    for (final controller in [
      _label,
      _host,
      _user,
      _port,
      _password,
      _privateKey,
      _passphrase,
      _jumpPassword,
      _jumpPrivateKey,
      _jumpPassphrase,
      _jumpHost,
      _jumpUser,
      _jumpPort,
      _connectTimeout,
      _authTimeout,
      _keepAliveInterval,
      _config,
      _alias,
      _environment,
      _customAppServerSocket,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.profile == null ? 'Add SSH host' : 'Edit SSH host'),
        content: SizedBox(
          width: 560,
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Import SSH config'),
                    children: [
                      TextFormField(
                        controller: _config,
                        minLines: 4,
                        maxLines: 8,
                        style: const TextStyle(fontFamily: 'monospace'),
                        decoration: const InputDecoration(
                          labelText: '~/.ssh/config contents',
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _alias,
                              decoration: const InputDecoration(
                                  labelText: 'Host alias'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.tonalIcon(
                            onPressed: _import,
                            icon: const Icon(Icons.file_download_outlined),
                            label: const Text('Import'),
                          ),
                        ],
                      ),
                      if (_importError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            _importError!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error),
                          ),
                        ),
                      const SizedBox(height: 12),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _label,
                    decoration: const InputDecoration(labelText: 'Name'),
                    validator: _required,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _host,
                    decoration:
                        const InputDecoration(labelText: 'Host name or IP'),
                    validator: _required,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _user,
                          decoration: const InputDecoration(labelText: 'User'),
                          validator: _required,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          controller: _port,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Port'),
                          validator: _portValidator,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SegmentedButton<AppServerMode>(
                    expandedInsets: EdgeInsets.zero,
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: AppServerMode.shared,
                        icon: Icon(Icons.hub_outlined),
                        label: Text('Shared'),
                      ),
                      ButtonSegment(
                        value: AppServerMode.custom,
                        icon: Icon(Icons.settings_ethernet),
                        label: Text('Custom'),
                      ),
                      ButtonSegment(
                        value: AppServerMode.isolated,
                        icon: Icon(Icons.lock_outline),
                        label: Text('Isolated'),
                      ),
                    ],
                    selected: {_appServerMode},
                    onSelectionChanged: (value) =>
                        setState(() => _appServerMode = value.single),
                  ),
                  if (_appServerMode == AppServerMode.custom) ...[
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _customAppServerSocket,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        labelText: 'App-server Unix socket',
                      ),
                      validator: _customSocketValidator,
                    ),
                  ],
                  const SizedBox(height: 14),
                  SegmentedButton<HostAuthMethod>(
                    segments: const [
                      ButtonSegment(
                        value: HostAuthMethod.password,
                        icon: Icon(Icons.password),
                        label: Text('Password'),
                      ),
                      ButtonSegment(
                        value: HostAuthMethod.privateKey,
                        icon: Icon(Icons.key_outlined),
                        label: Text('Private key'),
                      ),
                    ],
                    selected: {_authMethod},
                    onSelectionChanged: (value) =>
                        setState(() => _authMethod = value.single),
                  ),
                  const SizedBox(height: 12),
                  if (_authMethod == HostAuthMethod.password)
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Password'),
                    )
                  else ...[
                    TextFormField(
                      controller: _privateKey,
                      minLines: 5,
                      maxLines: 10,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        labelText: 'OpenSSH private key',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _passphrase,
                      obscureText: true,
                      decoration:
                          const InputDecoration(labelText: 'Key passphrase'),
                    ),
                  ],
                  const SizedBox(height: 12),
                  ExpansionTile(
                    controller: _advancedSsh,
                    maintainState: true,
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Advanced SSH'),
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Use jump host'),
                        subtitle: const Text(
                            'Phone → jump host → target. One ProxyJump hop.'),
                        value: _useJump,
                        onChanged: (value) => setState(() => _useJump = value),
                      ),
                      if (_useJump) ...[
                        TextFormField(
                            controller: _jumpHost,
                            decoration: const InputDecoration(
                                labelText: 'Jump host name or IP'),
                            validator: _required),
                        TextFormField(
                            controller: _jumpUser,
                            decoration:
                                const InputDecoration(labelText: 'Jump user'),
                            validator: _required),
                        TextFormField(
                            controller: _jumpPort,
                            keyboardType: TextInputType.number,
                            decoration:
                                const InputDecoration(labelText: 'Jump port'),
                            validator: _portValidator),
                        TextFormField(
                            controller: _jumpPassword,
                            obscureText: true,
                            decoration: const InputDecoration(
                                labelText: 'Jump password')),
                        TextFormField(
                            controller: _jumpPrivateKey,
                            minLines: 4,
                            maxLines: 8,
                            style: const TextStyle(fontFamily: 'monospace'),
                            decoration: const InputDecoration(
                                labelText: 'Jump OpenSSH private key',
                                alignLabelWithHint: true)),
                        TextFormField(
                            controller: _jumpPassphrase,
                            obscureText: true,
                            decoration: const InputDecoration(
                                labelText: 'Jump key passphrase')),
                        const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                                'Jump credentials are independent. Leave unused fields empty. Each SSH server verifies its own host key.')),
                      ],
                      _numberField(
                          _connectTimeout, 'Connect timeout (seconds)', 1, 120),
                      _numberField(_authTimeout,
                          'Authentication timeout (seconds)', 1, 120),
                      _numberField(_keepAliveInterval,
                          'Keepalive interval (seconds)', 0, 300,
                          helper:
                              '0 disables periodic SSH pings. Default: 15 seconds.'),
                      TextFormField(
                        controller: _environment,
                        minLines: 3,
                        maxLines: 8,
                        style: const TextStyle(fontFamily: 'monospace'),
                        decoration: const InputDecoration(
                          labelText: 'Environment variables',
                          alignLabelWithHint: true,
                        ),
                        validator: validateSshEnvironmentLines,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save'),
          ),
        ],
      );

  void _import() {
    try {
      final resolved =
          SshConfig.parse(_config.text).resolve(_alias.text.trim());
      final imported = HostProfile.fromResolved(resolved);
      setState(() {
        _label.text = imported.label;
        _host.text = imported.hostName;
        _user.text = imported.user;
        _port.text = '${imported.port}';
        _authMethod = imported.authMethod;
        final jump = imported.proxyJump;
        _useJump = jump != null;
        _jumpIdentityHint = jump?.identityFileHint;
        _jumpHost.text = jump?.hostName ?? '';
        _jumpUser.text = jump?.user ?? '';
        _jumpPort.text = '${jump?.port ?? 22}';
        _connectTimeout.text = '${imported.sshOptions.connectTimeoutSeconds}';
        _authTimeout.text = '${imported.sshOptions.authTimeoutSeconds}';
        _keepAliveInterval.text =
            '${imported.sshOptions.keepAliveIntervalSeconds}';
        _environment.text = formatSshEnvironmentLines(imported.environment);
        _importError =
            resolved.warnings.isEmpty ? null : resolved.warnings.join('\n');
      });
    } catch (error) {
      setState(() => _importError = error.toString());
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      _advancedSsh.expand();
      return;
    }
    final environment = parseSshEnvironmentLines(_environment.text);
    final label = _label.text.trim();
    final safeLabel =
        label.toLowerCase().replaceAll(RegExp('[^a-z0-9._-]+'), '-');
    final id = widget.profile?.id ??
        '${safeLabel.isEmpty ? 'host' : safeLabel}-'
            '${DateTime.now().microsecondsSinceEpoch}';
    Navigator.pop(
      context,
      ProfileDraft(
        HostProfile(
          id: id,
          label: label,
          hostName: _host.text.trim(),
          user: _user.text.trim(),
          port: int.parse(_port.text),
          authMethod: _authMethod,
          identityFileHint: widget.profile?.identityFileHint,
          proxyJump: _useJump
              ? JumpHostProfile(
                  hostName: _jumpHost.text.trim(),
                  user: _jumpUser.text.trim(),
                  port: int.parse(_jumpPort.text),
                  identityFileHint: _jumpIdentityHint)
              : null,
          sshOptions: SshConnectionOptions(
              connectTimeoutSeconds: int.parse(_connectTimeout.text),
              authTimeoutSeconds: int.parse(_authTimeout.text),
              keepAliveIntervalSeconds: int.parse(_keepAliveInterval.text)),
          environment: environment,
          appServerMode: _appServerMode,
          customAppServerSocket: _appServerMode == AppServerMode.custom
              ? _customAppServerSocket.text.trim()
              : null,
        ),
        HostSecret(
          password: _password.text,
          privateKey: _privateKey.text,
          passphrase: _passphrase.text,
          jumpPassword: _useJump ? _jumpPassword.text : null,
          jumpPrivateKey: _useJump ? _jumpPrivateKey.text : null,
          jumpPassphrase: _useJump ? _jumpPassphrase.text : null,
        ),
      ),
    );
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Required' : null;

  Widget _numberField(
          TextEditingController controller, String label, int min, int max,
          {String? helper}) =>
      TextFormField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
            labelText: label, helperText: helper ?? '$min–$max seconds'),
        validator: (text) {
          final value = int.tryParse(text ?? '');
          return value == null || value < min || value > max
              ? 'Enter $min–$max seconds.'
              : null;
        },
      );

  String? _portValidator(String? value) {
    final port = int.tryParse(value ?? '');
    return port == null || port < 1 || port > 65535 ? 'Invalid port' : null;
  }

  String? _customSocketValidator(String? value) {
    final configuredSocketPath = value ?? '';
    if (RegExp(r'[\x00-\x1F\x7F]').hasMatch(configuredSocketPath)) {
      return 'Enter an absolute Unix socket path.';
    }
    final socketPath = configuredSocketPath.trim();
    if (socketPath.isEmpty || !socketPath.startsWith('/')) {
      return 'Enter an absolute Unix socket path.';
    }
    return null;
  }
}
