import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:larp_player/core/player_store.dart';
import 'package:larp_player/core/models.dart';

import 'package_helper.dart' as fixture;

void main() {
  sqfliteFfiInit();
  test('deleted opened record keeps its own media when an unopened record reuses the filename', () async {
    final root = await Directory.systemTemp.createTemp('history-media-');
    final store = await PlayerStore.open(
      Directory('${root.path}/store'),
      factory: databaseFactoryFfi,
    );
    try {
      final first = fixture.manifest();
      first['records'][0]['blocks'] = [
        {'kind': 'image', 'value': 'media/photo.png'},
      ];
      await store.installPackage(
        await fixture.package(
          root,
          first,
          media: {
            'media/photo.png': [1, 2, 3],
          },
        ),
      );
      await store.lookup(fixture.gameId, '12345');
      final next = fixture.manifest(version: 2);
      next['records'] = [
        {
          ...fixture.row(id: fixture.secondId, code: '23456'),
          'blocks': [
            {'kind': 'image', 'value': 'media/photo.png'},
          ],
        },
      ];
      next['reserved_codes'] = ['12345', '23456'];
      await store.installPackage(
        await fixture.package(
          root,
          next,
          media: {
            'media/photo.png': [9, 8, 7],
          },
        ),
      );
      expect((await store.history(fixture.gameId)).single.code, '12345');
      final opened = await store.mediaFile(
        fixture.gameId,
        'media/photo.png',
        recordId: fixture.recordId,
      );
      expect(await opened.readAsBytes(), [1, 2, 3]);
      await expectLater(
        store.mediaFile(
          fixture.gameId,
          'media/photo.png',
          recordId: fixture.secondId,
        ),
        throwsA(isA<PlayerException>()),
      );
    } finally {
      await store.close();
      await root.delete(recursive: true);
    }
  });
}
