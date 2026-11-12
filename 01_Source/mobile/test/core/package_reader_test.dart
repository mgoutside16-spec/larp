import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:larp_player/core/models.dart';
import 'package:larp_player/core/player_store.dart';

import 'package_helper.dart';

void main() {
  late Directory root;
  late PlayerStore store;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('larp-package-');
    store = await PlayerStore.open(
      Directory('${root.path}/player'),
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test('ordered media are extracted to files and cannot be reached with unsafe paths', () async {
    final m = manifest();
    m['records'][0]['blocks'].addAll([
      {'kind': 'image', 'value': 'media/photo.png'},
      {'kind': 'audio', 'value': 'media/sound.mp3'},
      {'kind': 'video', 'value': 'media/clip.mp4'},
    ]);
    await store.installPackage(
      await package(
        root,
        m,
        media: {
          'media/photo.png': [1, 2],
          'media/sound.mp3': [3],
          'media/clip.mp4': [4],
        },
      ),
    );
    expect(
      (await store.lookup(gameId, '12345')).record!.blocks.map((b) => b.kind),
      ['text', 'image', 'audio', 'video'],
    );
    expect(
      await (await store.mediaFile(gameId, 'media/photo.png')).readAsBytes(),
      [1, 2],
    );
    await expectLater(
      store.mediaFile(gameId, '../player.sqlite'),
      throwsA(isA<PlayerException>()),
    );
    await expectLater(
      store.mediaFile(gameId, 'media/missing.png'),
      throwsA(isA<PlayerException>()),
    );
  });

  test('bad SHA cannot replace previous files or opened history', () async {
    final m = manifest();
    m['records'][0]['blocks'].add({
      'kind': 'image',
      'value': 'media/photo.png',
    });
    await store.installPackage(
      await package(
        root,
        m,
        media: {
          'media/photo.png': [1, 2],
        },
      ),
    );
    await store.lookup(gameId, '12345');
    m['version'] = 2;
    await expectLater(
      store.installPackage(
        await package(
          root,
          m,
          media: {
            'media/photo.png': [9],
          },
          checksums: false,
        ),
      ),
      throwsA(isA<PlayerException>()),
    );
    expect((await store.game(gameId))!.version, 1);
    expect(
      await (await store.mediaFile(gameId, 'media/photo.png')).readAsBytes(),
      [1, 2],
    );
    expect((await store.history(gameId)).single.id, recordId);
  });

  test('schema rejects broken UUID versions references reservations and media sets', () async {
    final cases = <void Function(Map<String, dynamic>)>[
      (m) => m['format_version'] = 2,
      (m) => m['version'] = 0,
      (m) => m['version'] = 1.5,
      (m) => m['created'] = 'not a date',
      (m) => m['game']['name'] = ' ',
      (m) => m['game']['id'] = '../x',
      (m) => m['records'][0]['id'] = 'bad',
      (m) => m['records'][0]['location_id'] = 999,
      (m) => m['records'].add(row()),
      (m) => m['reserved_codes'] = [],
      (m) => m['records'][0]['blocks'] = [
        {'kind': 'script', 'value': 'x'},
      ],
      (m) => m['records'][0]['blocks'] = [
        {'kind': 'image', 'value': 'media/no.png'},
      ],
      (m) => m['locations'][0]['id'] = -1,
      (m) => m['locations'][0]['id'] = 1.5,
      (m) => m['records'].add(row(id: secondId)),
    ];
    for (final change in cases) {
      final m = manifest();
      change(m);
      await expectLater(
        store.installPackage(await package(root, m)),
        throwsA(isA<PlayerException>()),
      );
      expect(await store.games(), isEmpty);
    }
  });

  test('unsafe Windows names traversal symlinks and duplicate case aliases are rejected', () async {
    for (final path in [
      '../escape',
      '/absolute',
      'media/../escape',
      'media/CON.png',
      'media/a:ads',
      'media/photo.',
      'media/a\\b.png',
    ]) {
      await expectLater(
        store.installPackage(
          await package(
            root,
            manifest(),
            media: {
              path: [1],
            },
          ),
        ),
        throwsA(isA<PlayerException>()),
      );
    }
    await expectLater(
      store.installPackage(
        await package(
          root,
          manifest(),
          media: {
            'media/A.png': [1],
            'media/a.png': [2],
          },
        ),
      ),
      throwsA(isA<PlayerException>()),
    );
    final valid = await package(root, manifest());
    final bytes = await valid.readAsBytes();
    final data = ByteData.sublistView(bytes);
    final central = findSignature(bytes, 0x02014b50);
    data.setUint32(central + 38, 0xa1ff0000, Endian.little);
    await valid.writeAsBytes(bytes);
    await expectLater(
      store.installPackage(valid),
      throwsA(isA<PlayerException>()),
    );
  });

  test(
    'central size bomb and corrupted CRC are rejected before activation',
    () async {
      for (final bomb in [true, false]) {
        final file = await package(root, manifest());
        final bytes = await file.readAsBytes();
        final data = ByteData.sublistView(bytes);
        final central = findSignature(bytes, 0x02014b50);
        if (bomb) {
          data.setUint32(central + 24, 512 * 1024 * 1024 + 1, Endian.little);
        } else {
          data.setUint32(central + 16, 0, Endian.little);
          data.setUint32(14, 0, Endian.little);
        }
        await file.writeAsBytes(bytes);
        await expectLater(
          store.installPackage(file),
          throwsA(isA<PlayerException>()),
        );
        expect(await store.games(), isEmpty);
      }
    },
  );

  test(
    'manifest decompression cannot exceed its declared central size',
    () async {
      final file = await package(root, manifest());
      final bytes = await file.readAsBytes();
      final data = ByteData.sublistView(bytes);
      final central = findSignature(bytes, 0x02014b50);
      data.setUint32(central + 24, 1, Endian.little);
      data.setUint32(22, 1, Endian.little);
      await file.writeAsBytes(bytes);
      await expectLater(
        store.installPackage(file),
        throwsA(isA<PlayerException>()),
      );
    },
  );

  test('local central mismatches nonUTF8 encrypted and multidisk archives are rejected', () async {
    for (final mutate in <void Function(Uint8List, ByteData, int, int)>[
      (b, d, c, e) => d.setUint16(8, 12, Endian.little),
      (b, d, c, e) => b[30] = 0xff,
      (b, d, c, e) => b[c + 46] = 0xff,
      (b, d, c, e) => d.setUint16(c + 8, 1, Endian.little),
      (b, d, c, e) => d.setUint16(e + 4, 1, Endian.little),
      (b, d, c, e) => d.setUint32(c + 42, 1, Endian.little),
    ]) {
      final file = await package(root, manifest());
      final bytes = await file.readAsBytes();
      final data = ByteData.sublistView(bytes);
      mutate(
        bytes,
        data,
        findSignature(bytes, 0x02014b50),
        findSignature(bytes, 0x06054b50),
      );
      await file.writeAsBytes(bytes);
      await expectLater(
        store.installPackage(file),
        throwsA(isA<PlayerException>()),
      );
    }
  });

  test('actual desktop and web master exports install unchanged', () async {
    for (final name in ['desktop', 'web']) {
      final file = File('test/core/fixtures/$name.rpgpack');
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      final m = jsonDecode(
        utf8.decode(archive.findFile('manifest.json')!.content),
      ) as Map<String, dynamic>;
      final installed = await store.installPackage(file);
      expect(installed.name, 'Русская игра');
      final opened = await store.lookup(installed.id, m['records'][0]['code']);
      expect(opened.status, LookupStatus.opened);
      expect(opened.record!.blocks.map((b) => b.kind), ['text', 'image']);
      expect(
        await (await store.mediaFile(
          installed.id,
          opened.record!.blocks[1].value,
        )).readAsString(),
        'image',
      );
    }
  });

  for (final name in ['descriptor', 'zip64']) {
    test('valid $name ZIP installs using streamed decompression', () async {
      final installed = await store.installPackage(
        File('test/core/fixtures/$name.rpgpack'),
      );
      expect(installed.name, 'Русская игра');
    });
  }
}

int findSignature(Uint8List bytes, int signature) {
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i <= bytes.length - 4; i++) {
    if (data.getUint32(i, Endian.little) == signature) return i;
  }
  throw StateError('ZIP signature absent');
}
