import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models.dart';

const _maxTotal = 1024 * 1024 * 1024;
const _maxFile = 512 * 1024 * 1024;
const _maxManifest = 16 * 1024 * 1024;
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final _code = RegExp(r'^[1-9][0-9]{4}$');

void _require(
  bool ok, [
  String message = 'Некорректный или повреждённый игровой пакет.',
]) {
  if (!ok) throw PlayerException(message);
}

/// Shared path validation also protects accesses made after installation.
void validateMediaPath(String value) {
  _require(value.startsWith('media/'));
  final name = value.substring(6);
  _require(
    name.isNotEmpty &&
        name != '.' &&
        name != '..' &&
        !RegExp(r'[/\\<>:"|?*\x00-\x1f]').hasMatch(name) &&
        !name.endsWith('.') &&
        !name.endsWith(' '),
    'Небезопасное имя медиафайла.',
  );
  final stem = name.split('.').first.toUpperCase();
  _require(
    !{'CON', 'PRN', 'AUX', 'NUL', 'CONIN\$', 'CONOUT\$'}.contains(stem) &&
        !RegExp(r'^(COM|LPT)[1-9¹²³]$').hasMatch(stem),
    'Имя медиафайла несовместимо с Windows.',
  );
}

class PackageSnapshot {
  PackageSnapshot(this.manifest, this.directory);
  final Map<String, dynamic> manifest;
  final Directory directory;
}

class _Entry {
  _Entry(
    this.name,
    this.method,
    this.flags,
    this.crc,
    this.size,
    this.compressed,
    this.offset,
  );
  final String name;
  final int method, flags, crc, size, compressed, offset;
  int dataOffset = 0;
}

int _u16(Uint8List b, int n) =>
    ByteData.sublistView(b).getUint16(n, Endian.little);
int _u32(Uint8List b, int n) =>
    ByteData.sublistView(b).getUint32(n, Endian.little);
int _u64(Uint8List b, int n) {
  final high = _u32(b, n + 4);
  _require(high <= 0x7fffffff);
  return _u32(b, n) + (high << 32);
}

Future<Uint8List> _read(RandomAccessFile input, int position, int count) async {
  _require(position >= 0 && count >= 0 && count <= _maxManifest);
  await input.setPosition(position);
  final bytes = await input.read(count);
  _require(bytes.length == count);
  return bytes;
}

// ZIP64 extra values appear only for fields with a saturated 32-bit value.
List<int> _zip64(Uint8List extra, List<int> values) {
  var offset = 0;
  while (offset + 4 <= extra.length) {
    final tag = _u16(extra, offset), length = _u16(extra, offset + 2);
    offset += 4;
    _require(offset + length <= extra.length);
    if (tag == 1) {
      var p = offset;
      return [
        for (final v in values)
          if (v == 0xffffffff)
            (() {
              _require(p + 8 <= offset + length);
              final n = _u64(extra, p);
              p += 8;
              return n;
            })()
          else
            v,
      ];
    }
    offset += length;
  }
  _require(!values.contains(0xffffffff));
  return values;
}

Future<List<_Entry>> _index(RandomAccessFile input, int length) async {
  _require(
    length >= 22 && length <= _maxTotal,
    'Файл повреждён или превышает 1 ГиБ.',
  );
  final tailStart = length > 65557 ? length - 65557 : 0;
  final tail = await _read(input, tailStart, length - tailStart);
  var end = tail.length - 22;
  while (end >= 0 &&
      (_u32(tail, end) != 0x06054b50 ||
          end + 22 + _u16(tail, end + 20) != tail.length)) {
    end--;
  }
  _require(end >= 0, 'Файл не является игровым ZIP-пакетом.');
  _require(
    _u16(tail, end + 4) == 0 && _u16(tail, end + 6) == 0,
    'Многотомные архивы не поддерживаются.',
  );
  int count = _u16(tail, end + 10),
      centralSize = _u32(tail, end + 12),
      centralOffset = _u32(tail, end + 16);
  var centralEnd = tailStart + end;
  if (count == 65535 ||
      centralOffset == 0xffffffff ||
      centralSize == 0xffffffff) {
    _require(centralEnd >= 20);
    final locator = await _read(input, centralEnd - 20, 20);
    _require(
      _u32(locator, 0) == 0x07064b50 &&
          _u32(locator, 4) == 0 &&
          _u32(locator, 16) == 1,
    );
    final zip64Offset = _u64(locator, 8);
    final z = await _read(input, zip64Offset, 56);
    _require(
      _u32(z, 0) == 0x06064b50 &&
          _u64(z, 4) >= 44 &&
          _u32(z, 16) == 0 &&
          _u32(z, 20) == 0 &&
          _u64(z, 24) == _u64(z, 32),
    );
    count = _u64(z, 32);
    centralSize = _u64(z, 40);
    centralOffset = _u64(z, 48);
    centralEnd = zip64Offset;
  } else {
    _require(_u16(tail, end + 8) == count);
  }
  _require(
    count > 0 && count <= 100000 && centralOffset + centralSize == centralEnd,
  );
  final entries = <_Entry>[], names = <String>{}, offsets = <int>{};
  var offset = centralOffset, total = 0;
  for (var i = 0; i < count; i++) {
    final h = await _read(input, offset, 46);
    _require(_u32(h, 0) == 0x02014b50);
    final nameLength = _u16(h, 28),
        extraLength = _u16(h, 30),
        commentLength = _u16(h, 32);
    _require(
      offset + 46 + nameLength + extraLength + commentLength <= centralEnd,
    );
    final rest = await _read(input, offset + 46, nameLength + extraLength);
    final name = utf8.decode(
      rest.sublist(0, nameLength),
      allowMalformed: false,
    );
    _require(
      names.add(name.toLowerCase()),
      'Пакет содержит совпадающие имена файлов.',
    );
    if (name != 'manifest.json') validateMediaPath(name);
    final flags = _u16(h, 8),
        method = _u16(h, 10),
        mode = (_u32(h, 38) >> 16) & 0xf000;
    _require(
      flags & 1 == 0 && flags & 0x40 == 0,
      'Зашифрованные архивы не поддерживаются.',
    );
    _require(
      mode != 0xa000 && mode != 0x4000 && !name.endsWith('/'),
      'Ссылки и каталоги в пакете запрещены.',
    );
    _require((mode == 0 || mode == 0x8000) && (method == 0 || method == 8));
    _require(_u16(h, 34) == 0);
    final sizes = _zip64(Uint8List.sublistView(rest, nameLength), [
      _u32(h, 24),
      _u32(h, 20),
      _u32(h, 42),
    ]);
    final size = sizes[0], compressed = sizes[1], localOffset = sizes[2];
    _require(
      size <= _maxFile && compressed <= _maxTotal,
      'Файл в пакете превышает 512 МиБ.',
    );
    total += size;
    _require(total <= _maxTotal, 'Распакованный пакет превышает 1 ГиБ.');
    if (name == 'manifest.json') {
      _require(size <= _maxManifest, 'Описание пакета превышает 16 МиБ.');
    }
    _require(offsets.add(localOffset) && localOffset + 30 <= centralOffset);
    entries.add(
      _Entry(name, method, flags, _u32(h, 16), size, compressed, localOffset),
    );
    offset += 46 + nameLength + extraLength + commentLength;
  }
  _require(
    offset == centralEnd && names.contains('manifest.json'),
    'В пакете нет manifest.json.',
  );
  for (final e in entries) {
    final h = await _read(input, e.offset, 30);
    _require(
      _u32(h, 0) == 0x04034b50 &&
          _u16(h, 6) == e.flags &&
          _u16(h, 8) == e.method,
      'Не совпадают заголовки файлов пакета.',
    );
    final nameLength = _u16(h, 26), extraLength = _u16(h, 28);
    final rest = await _read(input, e.offset + 30, nameLength + extraLength);
    _require(
      utf8.decode(rest.sublist(0, nameLength), allowMalformed: false) == e.name,
    );
    if (e.flags & 8 == 0) {
      final sizes = _zip64(Uint8List.sublistView(rest, nameLength), [
        _u32(h, 22),
        _u32(h, 18),
      ]);
      _require(
        _u32(h, 14) == e.crc && sizes[0] == e.size && sizes[1] == e.compressed,
      );
    }
    e.dataOffset = e.offset + 30 + nameLength + extraLength;
    _require(e.dataOffset + e.compressed <= centralOffset);
  }
  final sorted = [...entries]..sort((a, b) => a.offset.compareTo(b.offset));
  for (var i = 1; i < sorted.length; i++) {
    _require(
      sorted[i - 1].dataOffset + sorted[i - 1].compressed <= sorted[i].offset,
    );
  }
  return entries;
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var j = 0; j < 8; j++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

Future<void> _extract(File source, _Entry entry, File target) async {
  await target.parent.create(recursive: true);
  final output = await target.open(mode: FileMode.write);
  var size = 0, crc = 0xffffffff;
  Stream<List<int>> stream = source.openRead(
    entry.dataOffset,
    entry.dataOffset + entry.compressed,
  );
  if (entry.method == 8) stream = stream.transform(ZLibDecoder(raw: true));
  try {
    await for (final chunk in stream) {
      size += chunk.length;
      _require(
        size <= entry.size &&
            size <= (entry.name == 'manifest.json' ? _maxManifest : _maxFile),
        'Распакованный файл превышает заявленный размер.',
      );
      for (final byte in chunk) {
        crc = _crcTable[(crc ^ byte) & 255] ^ (crc >> 8);
      }
      await output.writeFrom(chunk);
    }
    _require(
      size == entry.size && (crc ^ 0xffffffff) == entry.crc,
      'Пакет повреждён: ошибка CRC файла.',
    );
    await output.flush();
  } finally {
    await output.close();
  }
}

bool _integer(dynamic n) => n is int && n >= 1 && n <= 0x7fffffffffffffff;
bool _text(dynamic n) => n is String && n.trim().isNotEmpty;
bool _date(dynamic n) => n is String && DateTime.tryParse(n) != null;
void _validate(Map<String, dynamic> m, Set<String> names) {
  _require(
    m['format_version'] == 1,
    'Версия формата пакета не поддерживается.',
  );
  _require(_integer(m['version']) && _date(m['created']));
  final g = m['game'];
  _require(
    g is Map &&
        g['id'] is String &&
        _uuid.hasMatch(g['id']) &&
        _text(g['name']) &&
        g['description'] is String,
  );
  _require(
    m['locations'] is List &&
        m['records'] is List &&
        m['reserved_codes'] is List &&
        m['checksums'] is Map,
  );
  final locations = <int>{}, locationNames = <String>{};
  for (final l in m['locations']) {
    _require(l is Map && _integer(l['id']) && _text(l['name']));
    _require(locations.add(l['id']) && locationNames.add(l['name']));
  }
  final reserved = <String>{};
  _require(m['reserved_codes'].length <= 90000);
  for (final c in m['reserved_codes']) {
    _require(c is String && _code.hasMatch(c) && reserved.add(c));
  }
  final ids = <String>{}, codes = <String>{}, media = <String>{};
  for (final r in m['records']) {
    _require(
      r is Map &&
          r['id'] is String &&
          _uuid.hasMatch(r['id']) &&
          r['code'] is String,
    );
    _require(
      ids.add(r['id'].toLowerCase()) &&
          reserved.contains(r['code']) &&
          codes.add(r['code']),
    );
    _require(
      _text(r['title']) &&
          r['modified'] is String &&
          (r['location_id'] == null ||
              (r['location_id'] is int &&
                  locations.contains(r['location_id']))) &&
          r['blocks'] is List,
    );
    for (final b in r['blocks']) {
      _require(
        b is Map &&
            b.length == 2 &&
            b['kind'] is String &&
            {'text', 'image', 'audio', 'video'}.contains(b['kind']) &&
            b['value'] is String,
      );
      if (b['kind'] != 'text') {
        validateMediaPath(b['value']);
        media.add(b['value']);
      }
    }
  }
  final checks = m['checksums'] as Map;
  _require(
    checks.length == media.length && checks.keys.every(media.contains),
    'Неполный список контрольных сумм.',
  );
  _require(
    names.length == media.length + 1 &&
        names.every((n) => n == 'manifest.json' || media.contains(n)),
    'Лишние или отсутствующие медиафайлы.',
  );
  for (final hash in checks.values) {
    _require(hash is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(hash));
  }
  // UUID identity is case-insensitive throughout the persistent store.
  g['id'] = g['id'].toLowerCase();
  for (final r in m['records']) {
    r['id'] = r['id'].toLowerCase();
  }
}

/// Validates into a private directory. Caller publishes the snapshot atomically.
Future<PackageSnapshot> readPackage(File source, Directory staging) async {
  RandomAccessFile? input;
  try {
    input = await source.open();
    final entries = await _index(input, await input.length());
    await input.close();
    input = null;
    final manifestEntry = entries.singleWhere((e) => e.name == 'manifest.json');
    final manifestFile = File('${staging.path}/manifest.json');
    await _extract(source, manifestEntry, manifestFile);
    final decoded = jsonDecode(await manifestFile.readAsString());
    _require(decoded is Map<String, dynamic>);
    final m = decoded as Map<String, dynamic>;
    _validate(m, entries.map((e) => e.name).toSet());
    for (final entry in entries.where((e) => e.name != 'manifest.json')) {
      final file = File('${staging.path}/${entry.name}');
      await _extract(source, entry, file);
      final digest = (await sha256.bind(file.openRead()).first).toString();
      _require(
        digest == m['checksums'][entry.name],
        'Не совпадает контрольная сумма медиафайла.',
      );
      final embedded = RegExp(r'^media/([0-9a-f]{64})\.')
          .firstMatch(entry.name);
      _require(
        embedded == null || embedded.group(1) == digest,
        'Имя медиафайла не соответствует контрольной сумме.',
      );
    }
    return PackageSnapshot(m, staging);
  } on PlayerException {
    rethrow;
  } catch (_) {
    throw const PlayerException(
      'Не удалось прочитать пакет: файл повреждён или недоступен.',
    );
  } finally {
    await input?.close();
  }
}
