final _controlCharacters = RegExp(r'[\x00-\x1f\x7f]');

bool isWindowsAbsolutePath(String path) =>
    RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) &&
    !_controlCharacters.hasMatch(path);

/// Only local drive paths and POSIX paths. UNC/device paths are not remote files.
bool isRemoteAbsolutePath(String path) =>
    !_controlCharacters.hasMatch(path) &&
    (isWindowsAbsolutePath(path) ||
        (path.startsWith('/') && !path.startsWith('//')));

String normalizeRemotePath(String path) =>
    isWindowsAbsolutePath(path) ? path.replaceAll('\\', '/') : path;

/// Windows OpenSSH's SFTP namespace uses /C:/... for drive-qualified paths.
String remoteSftpPath(String path) =>
    isWindowsAbsolutePath(path) ? '/${normalizeRemotePath(path)}' : path;
