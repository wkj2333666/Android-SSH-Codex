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
  late final TextEditingController _config;
  late final TextEditingController _alias;
  late final TextEditingController _environment;
  late HostAuthMethod _authMethod;
  JumpHostProfile? _jump;
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
    _authMethod = profile?.authMethod ?? HostAuthMethod.password;
    _jump = profile?.proxyJump;
  }

  @override
  void dispose() {
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
      _config,
      _alias,
      _environment,
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
                  if (_jump != null) ...[
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.alt_route),
                      title: const Text('ProxyJump'),
                      subtitle: Text(
                          '${_jump!.user}@${_jump!.hostName}:${_jump!.port}'),
                      trailing: IconButton(
                        tooltip: 'Remove jump host',
                        onPressed: () => setState(() => _jump = null),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                    TextFormField(
                      controller: _jumpPassword,
                      obscureText: true,
                      decoration:
                          const InputDecoration(labelText: 'Jump password'),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _jumpPrivateKey,
                      minLines: 4,
                      maxLines: 8,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        labelText: 'Jump OpenSSH private key',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _jumpPassphrase,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Jump key passphrase',
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Advanced SSH'),
                    children: [
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
        _jump = imported.proxyJump;
        _environment.text = formatSshEnvironmentLines(imported.environment);
        _importError =
            resolved.warnings.isEmpty ? null : resolved.warnings.join('\n');
      });
    } catch (error) {
      setState(() => _importError = error.toString());
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
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
          proxyJump: _jump,
          environment: environment,
        ),
        HostSecret(
          password: _password.text,
          privateKey: _privateKey.text,
          passphrase: _passphrase.text,
          jumpPassword: _jumpPassword.text,
          jumpPrivateKey: _jumpPrivateKey.text,
          jumpPassphrase: _jumpPassphrase.text,
        ),
      ),
    );
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Required' : null;

  String? _portValidator(String? value) {
    final port = int.tryParse(value ?? '');
    return port == null || port < 1 || port > 65535 ? 'Invalid port' : null;
  }
}
