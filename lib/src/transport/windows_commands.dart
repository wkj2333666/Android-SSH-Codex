import 'dart:convert';
import 'dart:io';

/// EncodedCommand is UTF-16LE. Compress the inner script to stay below cmd.exe's
/// command-length limit, and never consume SSH stdin while reading script text.
String powershellCommand(String script) {
  final payload = base64Encode(gzip.encode(utf8.encode(script)));
  final wrapper = r'$ErrorActionPreference="Stop";'
      r'$ProgressPreference="SilentlyContinue";'
      r'[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);'
      r'try {$m=New-Object IO.MemoryStream(,[Convert]::FromBase64String("'
      '$payload'
      r'"));$g=New-Object IO.Compression.GZipStream($m,[IO.Compression.CompressionMode]::Decompress);'
      r'$r=New-Object IO.StreamReader($g);$s=$r.ReadToEnd();$r.Dispose();'
      r'& ([scriptblock]::Create($s))} catch {[Console]::Error.WriteLine($_.Exception.Message);exit 1}';
  final bytes = <int>[
    for (final unit in wrapper.codeUnits) ...[unit & 255, unit >> 8],
  ];
  return 'powershell.exe -NoLogo -NoProfile -NonInteractive '
      '-EncodedCommand ${base64Encode(bytes)}';
}

String powershellLiteral(String value) => "'${value.replaceAll("'", "''")}'";

String windowsReadFileCommand(String path, int limit) => powershellCommand(
    '\$file = [IO.File]::OpenRead(${powershellLiteral(path)})\n'
    '\$remaining = $limit\n'
    r'''try {
  $output = [Console]::OpenStandardOutput()
  $buffer = New-Object byte[] 65536
  while ($remaining -gt 0) {
    $count = $file.Read($buffer, 0, [Math]::Min($remaining, $buffer.Length))
    if ($count -eq 0) { break }
    $output.Write($buffer, 0, $count)
    $remaining -= $count
  }
} finally { $file.Dispose() }
''');

String windowsCodexCommand(List<String> arguments) => powershellCommand(
      '$windowsCodexResolutionScript\n'
      '\$codexArguments = @(${arguments.map(powershellLiteral).join(',')})\n'
      '$windowsProcessRelayScript',
    );

// Resolve native installs and the standard npm launcher without invoking a
// PowerShell profile or cmd.exe. User paths never become cmd metacharacters.
const windowsCodexResolutionScript = r'''
$codexPrefix = @()
$command = Get-Command codex -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
$candidates = @()
if ($command) { $candidates += $command.Source }
foreach ($dir in @($env:CODEX_INSTALL_DIR, "$env:USERPROFILE\.local\bin", "$env:USERPROFILE\.codex\packages\standalone\current\bin", "$env:APPDATA\npm")) {
  if ($dir) { $candidates += (Join-Path $dir 'codex.exe'); $candidates += (Join-Path $dir 'codex.cmd') }
}
$codexExecutable = $null
foreach ($candidate in $candidates) {
  if (!(Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
  if ([IO.Path]::GetExtension($candidate) -eq '.exe') { $codexExecutable = $candidate; break }
  $js = Join-Path (Split-Path -Parent $candidate) 'node_modules\@openai\codex\bin\codex.js'
  if (Test-Path -LiteralPath $js -PathType Leaf) {
    $root = [Management.Automation.WildcardPattern]::Escape((Split-Path -Parent (Split-Path -Parent $js)))
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
    $packageArch = if ($arch -eq 'aarch64') { 'arm64' } else { 'x64' }
    foreach ($vendor in @("$root\vendor", "$root\node_modules\@openai\codex-win32-$packageArch\vendor", "$root\..\codex-win32-$packageArch\vendor")) {
      foreach ($subdir in @('bin', 'codex')) {
        $native = Get-Item -Path "$vendor\$arch-pc-windows-msvc\$subdir\codex.exe" -ErrorAction SilentlyContinue
        if ($native) { $codexExecutable = $native.FullName; break }
      }
      if ($codexExecutable) { break }
    }
    if ($codexExecutable) { break }
  }
}
if (!$codexExecutable) { throw 'Codex not found. Install native Codex or npm @openai/codex for this Windows SSH user and make it available on PATH.' }
$env:PATH = (Split-Path -Parent $codexExecutable) + ';' + $env:PATH
''';

// PowerShell 5.1 pipelines decode native stdout as text. Relay output with .NET
// threads, but let the native child inherit stdin: reading it through a console
// pump can stall later interactive writes after the first request succeeds.
const windowsProcessRelayScript = r'''
function Quote-NativeArgument([string]$value) {
  $value = [regex]::Replace($value, '(\\*)"', '$1$1\"')
  $value = [regex]::Replace($value, '(\\+)$', '$1$1')
  return '"' + $value + '"'
}
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
public static class CodexSshRelay {
  static Thread Pump(Stream source, Stream target, Process child) {
    var thread = new Thread(() => {
      try {
        var buffer = new byte[16384];
        int count;
        while ((count = source.Read(buffer, 0, buffer.Length)) > 0) {
          target.Write(buffer, 0, count);
          target.Flush();
        }
      }
      catch { try { if (!child.HasExited) child.Kill(); } catch {} }
    });
    thread.IsBackground = true;
    thread.Start();
    return thread;
  }
  public static int Run(string executable, string arguments) {
    using (var child = new Process()) {
      child.StartInfo = new ProcessStartInfo(executable, arguments) {
        UseShellExecute = false, CreateNoWindow = true,
        RedirectStandardInput = false, RedirectStandardOutput = true,
        RedirectStandardError = true
      };
      child.Start();
      try {
        var output = Pump(child.StandardOutput.BaseStream, Console.OpenStandardOutput(), child);
        var error = Pump(child.StandardError.BaseStream, Console.OpenStandardError(), child);
        child.WaitForExit();
        if (!output.Join(5000) || !error.Join(5000)) throw new IOException("SSH proxy streams did not close.");
        return child.ExitCode;
      } finally { if (!child.HasExited) child.Kill(); }
    }
  }
}
'@
$arguments = ((@($codexPrefix) + @($codexArguments) | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
exit ([CodexSshRelay]::Run($codexExecutable, $arguments))
''';

/// Create data directories with a protected user-only DACL from the outset.
/// Existing reparse points are rejected before accessing retained uploads.
const windowsPrivateDirectoryScript = r'''
function New-PrivateDirectory([string]$path) {
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  if ([IO.Directory]::Exists($path)) {
    if (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Private data directory is a reparse point.' }
    $existing = [IO.Directory]::GetAccessControl($path)
    if ($existing.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value) { throw 'Private data directory belongs to another user.' }
    foreach ($rule in $existing.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
      if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -ne $sid.Value) { throw 'Private data directory grants access to another user.' }
    }
    return
  }
  $acl = New-Object Security.AccessControl.DirectorySecurity
  $acl.SetOwner($sid)
  $acl.SetAccessRuleProtection($true, $false)
  $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
  $acl.AddAccessRule($rule)
  [void][IO.Directory]::CreateDirectory($path, $acl)
}
$dataRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'android-ssh-codex'
New-PrivateDirectory $dataRoot
''';
