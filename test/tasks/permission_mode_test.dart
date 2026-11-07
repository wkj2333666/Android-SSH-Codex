import 'package:android_ssh_codex/src/tasks/permission_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('inherited permissions do not override remote policy', () {
    expect(PermissionMode.inherit.turnParams, isEmpty);
  });
  test('permission modes use native protocol fields', () {
    expect(PermissionMode.readOnly.turnParams['sandboxPolicy'], {'type': 'readOnly'});
    expect(PermissionMode.workspace.turnParams['approvalPolicy'], 'on-request');
    expect(PermissionMode.fullAccess.turnParams, {
      'approvalPolicy': 'never', 'sandboxPolicy': {'type': 'dangerFullAccess'},
    });
  });
}
