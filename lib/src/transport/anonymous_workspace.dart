import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

const _workspaceRoot = '.local/share/android-ssh-codex/workspaces';
final _workspacePath = RegExp('/${RegExp.escape(_workspaceRoot)}/'
    r'session\.[A-Za-z0-9]{12}(?:/|$)');

bool isAnonymousWorkspacePath(String path) =>
    path.startsWith('/') && _workspacePath.hasMatch(path);

Future<String> createRemoteAnonymousWorkspace(SSHClient client) async {
  // No prompt, user path, or project data enters the shell command.
  // mktemp atomically allocates a private directory per new session.
  final script = r'case "${HOME:-}" in /*) ;; *) exit 1 ;; esac; '
      'umask 077; root="\$HOME/$_workspaceRoot"; '
      'mkdir -p "\$root" && mktemp -d "\$root/session.XXXXXXXXXXXX"';
  final result = await client
      .runWithResult("/bin/sh -c '$script'")
      .timeout(const Duration(seconds: 15));
  if (result.exitCode != 0 || result.exitSignal != null) {
    throw StateError('Could not create an anonymous workspace on the SSH host.');
  }
  final path = utf8.decode(result.stdout).trim();
  if (!isAnonymousWorkspacePath(path) ||
      _workspacePath.firstMatch(path)?.end != path.length ||
      path.endsWith('/') ||
      path.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw StateError('SSH did not return a valid anonymous workspace path.');
  }
  return path;
}
