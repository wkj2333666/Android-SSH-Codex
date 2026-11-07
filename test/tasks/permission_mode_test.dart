import 'package:android_ssh_codex/src/tasks/permission_mode.dart';
import 'package:android_ssh_codex/src/tasks/task_draft.dart';
import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('permission intent survives queued messages and draft persistence', () {
    final queued = QueuedTaskMessage.fromJson(const QueuedTaskMessage(
            id: 'id', text: 'hello', permissionMode: PermissionMode.workspace)
        .toJson());
    expect(queued.permissionMode, PermissionMode.workspace);
    TaskDraft create() => TaskDraft(
        upload: (file, target, cancel, {onProgress}) async =>
            throw StateError('unused'));
    final draft = create()..permissionMode = PermissionMode.readOnly;
    final restored = create()..restore(draft.toJson());
    expect(restored.permissionMode, PermissionMode.readOnly);
    expect(PermissionMode.restore('unknown'), PermissionMode.inherit);
    draft.dispose();
    restored.dispose();
  });
  test('inherited permissions do not override remote policy', () {
    expect(PermissionMode.inherit.turnParams, isEmpty);
  });
  test('permission modes use native protocol fields', () {
    expect(PermissionMode.readOnly.turnParams['sandboxPolicy'],
        {'type': 'readOnly'});
    expect(PermissionMode.workspace.turnParams['approvalPolicy'], 'on-request');
    expect(PermissionMode.fullAccess.turnParams, {
      'approvalPolicy': 'never',
      'sandboxPolicy': {'type': 'dangerFullAccess'},
    });
  });
}
