"""Opt-in native Windows Codex smoke test; no provider requests or user history.

Run after flutter pub get: python tool/test_windows_codex.py --dart path/to/dart.exe
Requires an installed Windows Codex CLI. Uses its own temporary CODEX_HOME.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import queue
import secrets
import struct
import subprocess
import tempfile
import threading
import time


def stop_process(process):
    if process.poll() is None:
        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def cleanup_test_daemons(directory):
    # `daemon stop` can leave its updater holding the temporary work directory.
    # Only terminate executables installed below this test's own resolved home.
    prefix = str(Path(directory, "home").resolve()).replace("'", "''")
    script = """$ProgressPreference = 'SilentlyContinue'
$prefix = '%s' + '\\'
Get-CimInstance Win32_Process -Filter "Name = 'codex.exe'" | ForEach-Object {
  $path = $_.ExecutablePath
  if ($path -and $path.StartsWith('\\\\?\\')) { $path = $path.Substring(4) }
  if ($path -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
  }
}
""" % prefix
    subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand",
                    base64.b64encode(script.encode("utf-16le")).decode()], check=True,
                   stdout=subprocess.DEVNULL, timeout=15)
    time.sleep(0.3)


def lifecycle(command, environment, directory, name):
    # Files avoid inheriting a Python capture pipe in a detached daemon.
    output = Path(directory, name + ".out")
    error = Path(directory, name + ".err")
    with output.open("wb") as out, error.open("wb") as err:
        process = subprocess.Popen(command.split(), stdin=subprocess.DEVNULL,
                                   stdout=out, stderr=err, env=environment)
        try:
            code = process.wait(timeout=45)
        finally:
            stop_process(process)
    if code:
        raise RuntimeError(f"{name} failed: {error.read_text(errors='replace')[-1200:]}")
    return output.read_text(encoding="utf-8")


def exercise_proxy(command, environment):
    process = subprocess.Popen(command.split(), stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               env=environment)
    chunks = queue.Queue()
    buffer = bytearray()

    def receive_chunks():
        while True:
            chunk = process.stdout.read1(65536)
            chunks.put(chunk)
            if not chunk:
                return

    threading.Thread(target=receive_chunks, daemon=True).start()

    def read(count):
        while len(buffer) < count:
            chunk = chunks.get(timeout=15)
            if not chunk:
                raise RuntimeError("Proxy closed before the response")
            buffer.extend(chunk)
        result = bytes(buffer[:count])
        del buffer[:count]
        return result

    def send(message):
        payload = json.dumps(message).encode("utf-8")
        mask = secrets.token_bytes(4)
        header = (bytes([0x81, 0x80 | len(payload)]) if len(payload) < 126 else
                  bytes([0x81, 0xFE]) + struct.pack("!H", len(payload)))
        process.stdin.write(header + mask + bytes(
            byte ^ mask[index % 4] for index, byte in enumerate(payload)))
        process.stdin.flush()

    def response(request_id):
        for _ in range(30):
            opcode, flags = read(2)
            size = flags & 127
            if size == 126:
                size = struct.unpack("!H", read(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", read(8))[0]
            if size > 1024 * 1024:
                raise RuntimeError("Unexpectedly large smoke-test response")
            payload = read(size)
            if opcode & 15 == 1:
                message = json.loads(payload)
                if message.get("id") == request_id:
                    if "result" not in message:
                        raise RuntimeError(f"RPC {request_id} failed: {message}")
                    return
        raise RuntimeError("Expected RPC response was not received")

    try:
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        process.stdin.write(("GET / HTTP/1.1\r\nHost: localhost\r\n"
                             "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                             f"Sec-WebSocket-Key: {key}\r\n"
                             "Sec-WebSocket-Version: 13\r\n\r\n").encode())
        process.stdin.flush()
        header = bytearray()
        while not header.endswith(b"\r\n\r\n"):
            header.extend(read(1))
            if len(header) > 16384:
                raise RuntimeError("Invalid WebSocket upgrade response")
        if not header.startswith(b"HTTP/1.1 101 "):
            raise RuntimeError("WebSocket upgrade failed")
        send({"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "windows_host_smoke", "version": "1.0"},
            "capabilities": {"experimentalApi": True}}})
        response(1)
        send({"method": "initialized", "params": {}})
        send({"id": 2, "method": "thread/list", "params": {"limit": 1}})
        response(2)
        print("WebSocket upgrade, initialize, and thread/list: PASS")
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            stop_process(process)
            raise RuntimeError("Proxy did not exit after SSH stdin closed")
        finally:
            process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dart", default="dart")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("This smoke test requires native Windows")
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="asc.") as directory:
        home = Path(directory, "home")
        home.mkdir()
        socket = home / "app-server-control" / "app-server-control.sock"
        commands = json.loads(subprocess.check_output(
            [args.dart, "tool/windows_codex_commands.dart", str(socket)], cwd=root, text=True))
        environment = dict(os.environ, CODEX_HOME=str(home))
        try:
            started = json.loads(lifecycle(commands["start"], environment, directory, "start"))
            actual = started["socketPath"]
            commands = json.loads(subprocess.check_output(
                [args.dart, "tool/windows_codex_commands.dart", actual], cwd=root, text=True))
            print("Native Shared startup: PASS")
            exercise_proxy(commands["proxy"], environment)
        finally:
            try:
                lifecycle(commands["stop"], environment, directory, "stop")
                print("Native Shared shutdown: PASS")
            finally:
                cleanup_test_daemons(directory)


if __name__ == "__main__":
    main()
