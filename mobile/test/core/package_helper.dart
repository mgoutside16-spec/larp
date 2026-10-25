import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

const gameId = '11111111-1111-4111-8111-111111111111';
const recordId = '22222222-2222-4222-8222-222222222222';
const secondId = '33333333-3333-4333-8333-333333333333';

Map<String, dynamic> manifest({int version = 1, String id = gameId}) => {
  'format_version': 1,
  'version': version,
  'created': '2026-10-25T12:00:00Z',
  'game': {'id': id, 'name': 'Игра', 'description': 'Описание'},
  'locations': [
    {'id': 1, 'name': 'Архив'},
  ],
  'records': [row()],
  'reserved_codes': ['12345'],
  'checksums': <String, String>{},
};

Map<String, dynamic> row({
  String id = recordId,
  String code = '12345',
  String title = 'Записка',
}) => {
  'id': id,
  'code': code,
  'title': title,
  'location_id': 1,
  'modified': '2026-10-25T12:00:00Z',
  'blocks': [
    {'kind': 'text', 'value': '<p>Привет</p>'},
  ],
};

Future<File> package(
  Directory root,
  Map<String, dynamic> m, {
  Map<String, List<int>> media = const {},
  bool checksums = true,
  String name = 'input.rpgpack',
}) async {
  if (checksums) {
    m['checksums'] = {
      for (final e in media.entries) e.key: sha256.convert(e.value).toString(),
    };
  }
  final archive = Archive();
  final description = utf8.encode(jsonEncode(m));
  archive.addFile(
    ArchiveFile('manifest.json', description.length, description),
  );
  for (final e in media.entries) {
    archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  return File('${root.path}/$name')
      .writeAsBytes(ZipEncoder().encode(archive), flush: true);
}
