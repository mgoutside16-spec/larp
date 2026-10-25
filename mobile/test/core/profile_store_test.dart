import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:larp_player/core/models.dart';
import 'package:larp_player/core/player_store.dart';

import 'package_helper.dart';

void main() {
  late Directory root;
  late Directory playerRoot;
  late PlayerStore store;
  final now = DateTime.utc(2026, 10, 25, 12);

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('larp-profiles-');
    playerRoot = Directory('${root.path}/player');
    store = await PlayerStore.open(
      playerRoot,
      factory: databaseFactoryFfi,
      clock: () => now,
    );
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  Future<void> install([String id = gameId]) async {
    await store.installPackage(await package(root, manifest(id: id)));
  }

  test(
    'offline profile trims the name and persists its secret after restart',
    () async {
      await install();
      final profiles = store;
      expect(await profiles.playerProfile(gameId), isNull);
      expect(await profiles.playerProfiles(), isEmpty);
      final profile = await profiles.savePlayerProfile(gameId, '  Алиса  ');
      expect(profile.gameId, gameId);
      expect(profile.characterName, 'Алиса');
      expect(profile.pending, isTrue);
      expect(profile.token, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(base64Url.decode('${profile.token}='), hasLength(32));
      expect(profile.toString(), isNot(contains(profile.token)));

      await store.close();
      store = await PlayerStore.open(playerRoot, factory: databaseFactoryFfi);
      final reopened = store;
      final saved = (await reopened.playerProfile(gameId))!;
      expect(saved.characterName, 'Алиса');
      expect(saved.token, profile.token);
      expect(saved.pending, isTrue);
      expect((await reopened.playerProfiles()).single.token, profile.token);
    },
  );

  test('only installed games can create profiles', () async {
    final profiles = store;
    await expectLater(
      profiles.savePlayerProfile(gameId, 'Алиса'),
      throwsA(isA<PlayerException>()),
    );
    expect(await profiles.playerProfile(gameId), isNull);
    expect(await profiles.playerProfiles(), isEmpty);
  });

  test(
    'names have 1 to 100 characters and reject all control characters',
    () async {
      await install();
      final profiles = store;
      for (final invalid in [
        '',
        '   ',
        'я' * 101,
        '🙂' * 101,
        'А\u0000Б',
        'А\tБ',
        '\nАлиса',
        'Алиса\r',
        'А\u007fБ',
        'А\u0085Б',
        'А\u009fБ',
      ]) {
        await expectLater(
          profiles.savePlayerProfile(gameId, invalid),
          throwsA(isA<PlayerException>()),
        );
      }
      expect(await profiles.playerProfile(gameId), isNull);
      expect(
        (await profiles.savePlayerProfile(gameId, 'я')).characterName,
        'я',
      );
      expect(
        (await profiles.savePlayerProfile(gameId, '🙂' * 100)).characterName,
        '🙂' * 100,
      );
    },
  );

  test(
    'rename retains the token while separate games have separate tokens',
    () async {
      await install();
      await install(secondId);
      final profiles = store;
      final first = await profiles.savePlayerProfile(
        gameId.toUpperCase(),
        'Алиса',
      );
      final other = await profiles.savePlayerProfile(secondId, 'Борис');
      await profiles.markPlayerRegistered(
        gameId,
        first.token,
        first.characterName,
      );
      final renamed = await profiles.savePlayerProfile(gameId, 'Ася');
      expect(renamed.gameId, gameId);
      expect(renamed.token, first.token);
      expect(renamed.pending, isTrue);
      expect(other.token, isNot(first.token));
      final saved = await profiles.playerProfiles();
      expect(saved.map((p) => p.characterName), ['Ася', 'Борис']);
    },
  );

  test('only an acknowledgement for the current token and exact name clears pending', () async {
    await install();
    final profiles = store;
    final first = await profiles.savePlayerProfile(gameId, 'Алиса');
    await profiles.savePlayerProfile(gameId, 'Ася');
    await profiles.markPlayerRegistered(gameId, first.token, 'Алиса');
    expect((await profiles.playerProfile(gameId))!.pending, isTrue);
    await profiles.markPlayerRegistered(gameId, 'wrong-token', 'Ася');
    expect((await profiles.playerProfile(gameId))!.pending, isTrue);
    await profiles.markPlayerRegistered(gameId, first.token, 'ася');
    expect((await profiles.playerProfile(gameId))!.pending, isTrue);
    await profiles.markPlayerRegistered(gameId, first.token, 'Ася');
    expect((await profiles.playerProfile(gameId))!.pending, isFalse);
    await store.close();
    store = await PlayerStore.open(playerRoot, factory: databaseFactoryFfi);
    final reopened = store;
    expect((await reopened.playerProfile(gameId))!.pending, isFalse);
    expect((await reopened.playerProfile(gameId))!.token, first.token);
  });

  test(
    'queued saves and stale acknowledgements preserve the latest name',
    () async {
      await install();
      final profiles = store;
      final first = await profiles.savePlayerProfile(gameId, 'Алиса');
      await Future.wait<dynamic>([
        profiles.savePlayerProfile(gameId, 'Ася'),
        profiles.markPlayerRegistered(gameId, first.token, 'Алиса'),
        profiles.savePlayerProfile(gameId, 'Анна'),
        profiles.markPlayerRegistered(gameId, first.token, 'Ася'),
      ]);
      final current = (await profiles.playerProfile(gameId))!;
      expect(current.characterName, 'Анна');
      expect(current.token, first.token);
      expect(current.pending, isTrue);
    },
  );

  test('profile write failures never expose the device secret', () async {
    await install();
    final profile = await store.savePlayerProfile(gameId, 'Алиса');
    final db = await databaseFactoryFfi.openDatabase(
      '${playerRoot.path}/player.sqlite',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      await db.execute(
        "CREATE TRIGGER fail_profile_save BEFORE INSERT ON profiles BEGIN SELECT RAISE(ABORT, 'write failure'); END",
      );
      await db.execute(
        "CREATE TRIGGER fail_profile_ack BEFORE UPDATE ON profiles BEGIN SELECT RAISE(ABORT, 'write failure'); END",
      );
      for (final operation in <Future<void> Function()>[
        () async {
          await store.savePlayerProfile(gameId, 'Ася');
        },
        () => store.markPlayerRegistered(gameId, profile.token, 'Алиса'),
      ]) {
        await expectLater(
          operation(),
          throwsA(
            isA<PlayerException>().having(
              (error) => error.toString(),
              'message',
              isNot(contains(profile.token)),
            ),
          ),
        );
      }
      expect((await store.playerProfile(gameId))!.characterName, 'Алиса');
      expect((await store.playerProfile(gameId))!.pending, isTrue);
    } finally {
      await db.close();
    }
  });

  test(
    'profile and project changes preserve lock, history and installed content',
    () async {
      await install();
      await install(secondId);
      await store.lookup(gameId, '12345');
      for (var i = 0; i < 3; i++) {
        await store.lookup(gameId, '55555');
      }
      final locked = await store.lockState(gameId);
      final profiles = store;
      final first = await profiles.savePlayerProfile(gameId, 'Алиса');
      await profiles.savePlayerProfile(secondId, 'Борис');
      await profiles.savePlayerProfile(gameId, 'Ася');
      await profiles.markPlayerRegistered(gameId, first.token, 'Ася');
      await store.installPackage(await package(root, manifest(version: 2)));
      final currentLock = await store.lockState(gameId);
      expect(currentLock.status, LookupStatus.locked);
      expect(currentLock.wrongAttempts, 3);
      expect(currentLock.lockedUntil, locked.lockedUntil);
      expect((await store.history(gameId)).single.id, recordId);
      expect((await store.openedRecord(gameId, recordId))!.title, 'Записка');
      expect((await profiles.playerProfile(gameId))!.token, first.token);
      expect((await profiles.playerProfile(gameId))!.characterName, 'Ася');
      expect((await profiles.playerProfile(gameId))!.pending, isFalse);
    },
  );

  test(
    'v1 database migration preserves every old row and version directory',
    () async {
      await store.close();
      await File('${playerRoot.path}/player.sqlite').delete();
      final oldDirectory = Directory('${playerRoot.path}/versions/legacy-v1');
      await oldDirectory.create(recursive: true);
      final sentinel = await File('${oldDirectory.path}/keep.txt')
          .writeAsString('legacy-media');
      final db = await databaseFactoryFfi.openDatabase(
        '${playerRoot.path}/player.sqlite',
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE games (id TEXT PRIMARY KEY,name TEXT NOT NULL,description TEXT NOT NULL,version INTEGER NOT NULL,installed_at INTEGER NOT NULL,directory TEXT NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE records (game_id TEXT NOT NULL,id TEXT NOT NULL,code TEXT NOT NULL,json TEXT NOT NULL,PRIMARY KEY(game_id,id),UNIQUE(game_id,code))',
            );
            await db.execute(
              'CREATE TABLE reservations (game_id TEXT NOT NULL,code TEXT NOT NULL,record_id TEXT,PRIMARY KEY(game_id,code),UNIQUE(game_id,record_id))',
            );
            await db.execute(
              'CREATE TABLE security (game_id TEXT PRIMARY KEY,attempts INTEGER NOT NULL DEFAULT 0,locked_until INTEGER,last_seen INTEGER NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE opened (game_id TEXT NOT NULL,record_id TEXT NOT NULL,json TEXT NOT NULL,directory TEXT NOT NULL,opened_at INTEGER NOT NULL,PRIMARY KEY(game_id,record_id))',
            );
          },
        ),
      );
      final timestamp = now.millisecondsSinceEpoch;
      final record = jsonEncode({
        'id': recordId,
        'code': '12345',
        'title': 'Старый материал',
        'group_name': 'Архив',
        'blocks': [
          {'kind': 'text', 'value': '<p>Сохранено</p>'},
        ],
      });
      await db.insert('games', {
        'id': gameId,
        'name': 'Старая игра',
        'description': 'До обновления',
        'version': 7,
        'installed_at': timestamp,
        'directory': oldDirectory.path,
      });
      await db.insert('records', {
        'game_id': gameId,
        'id': recordId,
        'code': '12345',
        'json': record,
      });
      await db.insert('reservations', {
        'game_id': gameId,
        'code': '12345',
        'record_id': recordId,
      });
      await db.insert('security', {
        'game_id': gameId,
        'attempts': 3,
        'locked_until': timestamp + 1800000,
        'last_seen': timestamp,
      });
      await db.insert('opened', {
        'game_id': gameId,
        'record_id': recordId,
        'json': record,
        'directory': oldDirectory.path,
        'opened_at': timestamp,
      });
      final before = <String, List<Map<String, Object?>>>{
        for (final table in [
          'games',
          'records',
          'reservations',
          'security',
          'opened',
        ])
          table: await db.query(table),
      };
      await db.close();

      store = await PlayerStore.open(
        playerRoot,
        factory: databaseFactoryFfi,
        clock: () => now,
      );
      final profiles = store;
      expect(await profiles.playerProfiles(), isEmpty);
      await profiles.savePlayerProfile(gameId, 'Алиса');
      expect((await store.game(gameId))!.version, 7);
      expect((await store.history(gameId)).single.title, 'Старый материал');
      expect((await store.lockState(gameId)).status, LookupStatus.locked);
      expect(await sentinel.readAsString(), 'legacy-media');
      expect(await Directory('${playerRoot.path}/versions').list().length, 1);
      await store.close();
      final upgraded = await databaseFactoryFfi.openDatabase(
        '${playerRoot.path}/player.sqlite',
      );
      expect(await upgraded.getVersion(), 2);
      for (final entry in before.entries) {
        expect(await upgraded.query(entry.key), entry.value, reason: entry.key);
      }
      await upgraded.close();
      store = await PlayerStore.open(
        playerRoot,
        factory: databaseFactoryFfi,
        clock: () => now,
      );
    },
  );
}
