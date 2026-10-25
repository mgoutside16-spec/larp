import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:larp_player/core/models.dart';
import 'package:larp_player/core/player_store.dart';

import 'package_helper.dart';

void main() {
  late Directory root;
  late PlayerStore store;
  late DateTime now;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('larp-core-');
    now = DateTime.utc(2026, 10, 25, 12);
    store = await PlayerStore.open(
      Directory('${root.path}/player'),
      factory: databaseFactoryFfi,
      clock: () => now,
    );
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  Future<void> install() async =>
      store.installPackage(await package(root, manifest()));

  test(
    'real import opens only entered codes and persists history after restart',
    () async {
      expect(await store.game(gameId), isNull);
      await install();
      expect((await store.games()).single.name, 'Игра');
      expect(await store.history(gameId), isEmpty);
      expect(await store.openedRecord(gameId, recordId), isNull);
      final result = await store.lookup(gameId, '12345');
      expect(result.status, LookupStatus.opened);
      expect(result.record!.groupName, 'Архив');
      expect(result.record!.blocks.single.value, '<p>Привет</p>');
      await store.close();
      store = await PlayerStore.open(
        Directory('${root.path}/player'),
        factory: databaseFactoryFfi,
        clock: () => now,
      );
      expect((await store.history(gameId)).single.id, recordId);
      expect((await store.openedRecord(gameId, recordId))!.title, 'Записка');
    },
  );

  test('third consecutive wrong code locks until exact expiry and history remains accessible', () async {
    await install();
    await store.lookup(gameId, '12345');
    for (final code in ['123', '00000', 'abcde']) {
      expect((await store.lookup(gameId, code)).status, LookupStatus.invalid);
    }
    expect((await store.lookup(gameId, '55555')).wrongAttempts, 1);
    expect((await store.lookup(gameId, '66666')).wrongAttempts, 2);
    final blocked = await store.lookup(gameId, '77777');
    expect(blocked.status, LookupStatus.locked);
    expect(blocked.lockedUntil, DateTime.utc(2026, 10, 25, 12, 30));
    expect((await store.lookup(gameId, '12345')).status, LookupStatus.locked);
    expect((await store.history(gameId)).single.id, recordId);
    await store.close();
    store = await PlayerStore.open(
      Directory('${root.path}/player'),
      factory: databaseFactoryFfi,
      clock: () => now,
    );
    now = now.add(const Duration(minutes: 29, seconds: 59));
    expect((await store.lockState(gameId)).status, LookupStatus.locked);
    now = now.add(const Duration(seconds: 1));
    expect((await store.lookup(gameId, '12345')).status, LookupStatus.opened);
    expect((await store.lockState(gameId)).wrongAttempts, 0);
  });

  test('success resets attempts, games are independent, and concurrent attempts cannot bypass lock', () async {
    await install();
    await store.installPackage(await package(root, manifest(id: secondId)));
    await store.lookup(gameId, '55555');
    expect((await store.lookup(gameId, '12345')).wrongAttempts, 0);
    final attempts = await Future.wait(
      List.generate(10, (_) => store.lookup(gameId, '55555')),
    );
    expect(attempts.where((r) => r.status == LookupStatus.wrong).length, 2);
    expect(attempts.where((r) => r.status == LookupStatus.locked).length, 8);
    expect((await store.lookup(secondId, '12345')).status, LookupStatus.opened);
  });

  test(
    'clock rollback and material updates preserve security and opened history',
    () async {
      await install();
      await store.lookup(gameId, '12345');
      for (var i = 0; i < 3; i++) {
        await store.lookup(gameId, '55555');
      }
      final update = manifest(version: 2);
      update['records'][0]['title'] = 'Обновление';
      await store.installPackage(await package(root, update));
      expect((await store.history(gameId)).single.title, 'Обновление');
      now = now.subtract(const Duration(hours: 1));
      expect((await store.lockState(gameId)).status, LookupStatus.locked);
      expect((await store.game(gameId))!.version, 2);
    },
  );

  test(
    'downgrades and changed bindings cannot damage active materials',
    () async {
      await install();
      await store.lookup(gameId, '12345');
      await expectLater(
        store.installPackage(await package(root, manifest())),
        throwsA(isA<PlayerException>()),
      );
      final changed = manifest(version: 2);
      changed['records'][0]['code'] = '54321';
      changed['reserved_codes'] = ['12345', '54321'];
      await expectLater(
        store.installPackage(await package(root, changed)),
        throwsA(isA<PlayerException>()),
      );
      expect((await store.game(gameId))!.version, 1);
      expect((await store.history(gameId)).single.code, '12345');
    },
  );

  test(
    'deleted and unknown reserved codes can never be assigned to a new record',
    () async {
      final first = manifest();
      first['reserved_codes'].add('54321');
      await store.installPackage(await package(root, first));
      final deleted = manifest(version: 2);
      deleted['records'] = [];
      deleted['reserved_codes'] = ['12345', '54321'];
      await store.installPackage(await package(root, deleted));
      for (final code in ['12345', '54321']) {
        final reuse = manifest(version: 3);
        reuse['records'] = [row(id: secondId, code: code)];
        reuse['reserved_codes'] = ['12345', '54321'];
        await expectLater(
          store.installPackage(await package(root, reuse)),
          throwsA(isA<PlayerException>()),
        );
      }
      expect((await store.game(gameId))!.version, 2);
    },
  );

  test('reservations cannot disappear in an update', () async {
    final first = manifest();
    first['reserved_codes'].add('54321');
    await store.installPackage(await package(root, first));
    await expectLater(
      store.installPackage(await package(root, manifest(version: 2))),
      throwsA(isA<PlayerException>()),
    );
  });

  test('deleted opened materials remain in history and original identity can return', () async {
    await install();
    await store.lookup(gameId, '12345');
    final removed = manifest(version: 2);
    removed['records'] = [];
    await store.installPackage(await package(root, removed));
    expect((await store.history(gameId)).single.title, 'Записка');
    expect((await store.openedRecord(gameId, recordId))!.id, recordId);
    await store.installPackage(await package(root, manifest(version: 3)));
    expect((await store.lookup(gameId, '12345')).status, LookupStatus.opened);
  });

  test(
    'history orders the last opening first even within the same millisecond',
    () async {
      final m = manifest();
      m['records'].add(row(id: secondId, code: '23456', title: 'Вторая'));
      m['reserved_codes'].add('23456');
      await store.installPackage(await package(root, m));
      await store.lookup(gameId, '12345');
      await store.lookup(gameId, '23456');
      expect((await store.history(gameId)).map((r) => r.id), [
        secondId,
        recordId,
      ]);
      await store.lookup(gameId, '12345');
      expect((await store.history(gameId)).map((r) => r.id), [
        recordId,
        secondId,
      ]);
    },
  );
}
