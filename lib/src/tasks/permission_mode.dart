enum PermissionMode {
  inherit('Thread permissions', 'Use the current thread policy'),
  readOnly('Read only', 'Read files; changes require approval'),
  workspace('Workspace', 'Write in the task workspace; ask before escalation'),
  fullAccess('Full access', 'No sandbox or command approval prompts');

  const PermissionMode(this.label, this.description);
  final String label;
  final String description;

  Map<String, dynamic> get turnParams => switch (this) {
    inherit => const {},
    readOnly => const {'approvalPolicy': 'on-request', 'sandboxPolicy': {'type': 'readOnly'}},
    workspace => const {'approvalPolicy': 'on-request', 'sandboxPolicy': {'type': 'workspaceWrite', 'networkAccess': false}},
    fullAccess => const {'approvalPolicy': 'never', 'sandboxPolicy': {'type': 'dangerFullAccess'}},
  };

  static PermissionMode restore(Object? value) => values.firstWhere(
    (mode) => mode.name == value, orElse: () => inherit);
}
