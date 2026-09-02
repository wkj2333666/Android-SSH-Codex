import 'package:android_ssh_codex/src/projects/remote_project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote project round-trips its host and working directory', () {
    const project = RemoteProject(
      id: 'mobile',
      hostId: 'pi',
      name: 'Mobile',
      cwd: '/srv/mobile',
    );

    expect(RemoteProject.fromJson(project.toJson()), project);
  });

  test('copyWith can rename a project without changing its directory', () {
    const project = RemoteProject(
      id: 'mobile',
      hostId: 'pi',
      name: 'Mobile',
      cwd: '/srv/mobile',
    );

    expect(
      project.copyWith(name: 'Mobile app'),
      const RemoteProject(
        id: 'mobile',
        hostId: 'pi',
        name: 'Mobile app',
        cwd: '/srv/mobile',
      ),
    );
  });

  test('discovers stable projects from normalized remote directories', () {
    final first = mergeRemoteProjects(
      hostId: 'pi',
      existing: const [],
      discoveredCwds: const ['/home/wkj/projects/cscg/', '/srv/mobile', ''],
    );
    final second = mergeRemoteProjects(
      hostId: 'pi',
      existing: const [],
      discoveredCwds: const ['/srv/mobile/', '/home/wkj/projects/cscg'],
    );

    expect(first.map((project) => project.name), ['cscg', 'mobile']);
    expect(first.map((project) => project.cwd), [
      '/home/wkj/projects/cscg',
      '/srv/mobile',
    ]);
    expect(
      first.map((project) => project.id),
      second.map((project) => project.id),
    );
  });

  test('a stored project name overrides the discovered cwd default', () {
    final projects = mergeRemoteProjects(
      hostId: 'pi',
      existing: const [
        RemoteProject(
          id: 'saved-cscg',
          hostId: 'pi',
          name: 'PC Bench',
          cwd: '/home/wkj/projects/cscg/',
        ),
      ],
      discoveredCwds: const ['/home/wkj/projects/cscg'],
    );

    expect(projects, hasLength(1));
    expect(projects.single.id, 'saved-cscg');
    expect(projects.single.name, 'PC Bench');
    expect(projects.single.cwd, '/home/wkj/projects/cscg');
  });

  test('projects follow latest task activity instead of alphabetic order', () {
    final projects = mergeRemoteProjects(
      hostId: 'pi',
      existing: const [],
      discoveredCwds: const ['/srv/alpha', '/srv/zeta', '/srv/idle'],
      activityByCwd: {
        '/srv/alpha': DateTime.utc(2026, 8, 1),
        '/srv/zeta': DateTime.utc(2026, 9, 1),
      },
    );

    expect(projects.map((project) => project.name), [
      'zeta',
      'alpha',
      'idle',
    ]);
  });
}
