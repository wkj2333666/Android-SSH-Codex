import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:crypto/crypto.dart';

String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
String _program(String value) =>
    "printf '%s' '${base64Encode(utf8.encode(value))}' | base64 -d | /bin/sh";

void _path(String path) {
  if (!path.startsWith('/') || RegExp(r'[\x00\r\n]').hasMatch(path)) {
    throw ArgumentError('Expected an absolute media path');
  }
}

String videoPosterCommand(String path) {
  _path(path);
  return _program('set -eu\n'
      'command -v ffmpeg >/dev/null 2>&1 || exit 69\n'
      'command -v timeout >/dev/null 2>&1 || exit 69\n'
      'test -f ${_quote(path)} || exit 44\n'
      'exec timeout -k 1s 10s ffmpeg -nostdin -v error -max_alloc 67108864 '
      '-threads 1 -filter_threads 1 -protocol_whitelist file,pipe '
      '-format_whitelist mov,matroska,webm,avi,mpeg,mpegts,flv,ogg,asf '
      '-i ${_quote(path)} -map 0:v:0 -frames:v 1 -an -sn '
      '-vf scale=640:360:force_original_aspect_ratio=decrease '
      '-threads 1 -f image2pipe -c:v mjpeg -q:v 4 pipe:1');
}

/// The history serializer replaces the middle of long strings, so use both
/// surviving ends plus original length. Never guess a path from tool arguments.
String imageRecoveryCommand(String rollout, String threadId, String source) {
  _path(rollout);
  if (!rollout.endsWith('.jsonl') ||
      threadId.isEmpty ||
      threadId.length > 100) {
    throw ArgumentError('Invalid thread history');
  }
  final match = RegExp(
          r'^data:(image/(?:png|jpeg|webp|gif));base64,([A-Za-z0-9+/=]+)…(\d+) chars truncated…([A-Za-z0-9+/=]+)$')
      .firstMatch(source);
  if (match == null || match[2]!.length < 32 || match[4]!.length < 32) {
    throw StateError(
        'The historical image is incomplete and cannot be matched safely.');
  }
  final before = match[2]!;
  final after = match[4]!;
  final length = before.length + after.length + int.parse(match[3]!);
  if (length > 14 * 1024 * 1024) {
    throw StateError('Image exceeds the preview limit.');
  }
  final reference = jsonEncode({
    'mime': match[1],
    'length': length,
    'beforeLength': before.length,
    'afterLength': after.length,
    'beforeHash': sha256.convert(utf8.encode(before)).toString(),
    'afterHash': sha256.convert(utf8.encode(after)).toString(),
    'prefix': before.substring(0, before.length < 4096 ? before.length : 4096),
    'suffix': after.substring(after.length > 4096 ? after.length - 4096 : 0),
  });
  return _program('set -eu\n'
      'command -v python3 >/dev/null 2>&1 || exit 69\n'
      'command -v timeout >/dev/null 2>&1 || exit 69\n'
      'ulimit -v 262144 2>/dev/null || true\n'
      'exec timeout -k 1s 15s python3 -I -c ${_quote(imageRecoveryScript)} '
      '${_quote(rollout)} ${_quote(threadId)} ${_quote(reference)}');
}

const imageRecoveryScript = r'''
import base64,hashlib,json,os,stat,sys
path,thread,raw=sys.argv[1:]
ref=json.loads(raw);limit=10*1024*1024;found=None;verified=False;total=0
def images(value,depth=0):
    if depth>6:return
    if isinstance(value,list):
        for block in value:
            yield from images(block,depth+1)
    elif isinstance(value,dict):
        kind=value.get('type')
        if kind in ('input_image','inputImage','image_url','image','localImage'):
            source=value.get('image_url') or value.get('imageUrl') or value.get('url')
            if isinstance(source,dict):source=source.get('url')
            if isinstance(source,str):yield source
            data=value.get('data');mime=value.get('mimeType')
            if isinstance(data,str) and mime==ref['mime']:yield 'data:'+mime+';base64,'+data
        for key in ('content','contentItems','output','result'):
            if key in value:yield from images(value[key],depth+1)
    elif isinstance(value,str) and value.lstrip().startswith(('{','[')):
        try:yield from images(json.loads(value),depth+1)
        except (ValueError,RecursionError):pass
with open(path,'rb') as stream:
    if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):sys.exit(45)
    while True:
        line=stream.readline(32*1024*1024+1)
        if not line:break
        total+=len(line)
        if len(line)>32*1024*1024 or total>64*1024*1024:sys.exit(65)
        try:record=json.loads(line)
        except (ValueError,RecursionError):continue
        payload=record.get('payload',{})
        if not verified:
            if record.get('type')!='session_meta' or payload.get('id')!=thread:sys.exit(43)
            verified=True
            continue
        if record.get('type')!='response_item' or payload.get('type') not in ('custom_tool_call_output','function_call_output','message'):continue
        if payload.get('role')=='user':continue
        for source in images(payload):
            prefix='data:'+ref['mime']+';base64,'
            if not source.startswith(prefix):continue
            data=source[len(prefix):]
            if len(data)!=ref['length'] or not data.startswith(ref['prefix']) or not data.endswith(ref['suffix']):continue
            if hashlib.sha256(data[:ref['beforeLength']].encode()).hexdigest()!=ref['beforeHash'] or hashlib.sha256(data[-ref['afterLength']:].encode()).hexdigest()!=ref['afterHash']:continue
            try:decoded=base64.b64decode(data,validate=True)
            except ValueError:continue
            if len(decoded)>limit:sys.exit(65)
            magic={'image/png':decoded.startswith(b'\x89PNG\r\n\x1a\n'),'image/jpeg':decoded.startswith(b'\xff\xd8'),'image/gif':decoded.startswith((b'GIF87a',b'GIF89a')),'image/webp':decoded.startswith(b'RIFF') and decoded[8:12]==b'WEBP'}
            if not magic.get(ref['mime']):continue
            if found is not None and found!=decoded:sys.exit(66)
            found=decoded
if found is None:sys.exit(44)
sys.stdout.buffer.write(found)
''';

Future<Uint8List> readMediaPreview(SSHClient client, String command,
    {required int maxBytes}) async {
  var expired = false;
  final opening = client.execute(command).then((session) {
    if (expired) session.close();
    return session;
  });
  SSHSession? session;
  StreamSubscription<List<int>>? stderr;
  try {
    session = await opening.timeout(const Duration(seconds: 12));
    final channel = session;
    stderr = channel.stderr.listen((_) {}, onError: (Object _) {});
    return await (() async {
      await channel.stdin.close();
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in channel.stdout) {
        if (bytes.length + chunk.length > maxBytes)
          throw StateError('Preview exceeds the size limit.');
        bytes.add(chunk);
      }
      await channel.done;
      if (channel.exitCode != 0 || bytes.isEmpty) {
        throw StateError(channel.exitCode == 69
            ? 'The remote preview helper is unavailable.'
            : 'The preview could not be restored (code ${channel.exitCode}).');
      }
      return bytes.takeBytes();
    })()
        .timeout(const Duration(seconds: 20));
  } finally {
    expired = true;
    session?.close();
    await stderr?.cancel();
  }
}
