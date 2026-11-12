import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:larp_player/core/models.dart';
import 'package:larp_player/core/player_store.dart';
import 'package:larp_player/core/update_client.dart';

import '../core/package_helper.dart' as fixtures;

const projectId = '44444444-4444-4444-8444-444444444444';

Map<String, dynamic> catalogRow({
  String id = fixtures.gameId,
  int version = 1,
}) => {
  'game_id': id,
  'project_id': projectId,
  'name': 'Игра из каталога',
  'description': 'Сохранённый проект',
  'version': version,
  'record_count': 1,
  'updated_at': '2026-10-25T12:00:00Z',
};

CatalogGame catalogGame({int version = 1}) => CatalogGame(
  gameId: fixtures.gameId,
  projectId: projectId,
  name: 'Игра из каталога',
  description: 'Сохранённый проект',
  version: version,
  recordCount: 1,
  updatedAt: DateTime.utc(2026, 10, 25, 12),
);

void main() {
  late Directory root;
  late PlayerStore store;
  late HttpServer server;
  late UpdateClient updates;
  late Map<String, dynamic> snapshot;
  late List<Map<String, dynamic>> catalog;
  late Map<String, List<int>> media;
  late List<Uri> requests;
  late List<Map<String, dynamic>> catalogBodies;
  late List<Map<String, dynamic>> registrations;
  late Completer<void> registrationReceived;
  Completer<void>? registrationGate;
  var registrationStatus = 200;
  final now = DateTime.utc(2026, 10, 25, 12);

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('larp-auto-sync-');
    store = await PlayerStore.open(
      Directory('${root.path}/store'),
      factory: databaseFactoryFfi,
      clock: () => now,
    );
    snapshot = {
      'game_id': fixtures.gameId,
      'project_id': projectId,
      'version': 1,
      'manifest': fixtures.manifest(),
      'files': <Map<String, dynamic>>[],
    };
    catalog = [catalogRow()];
    media = {};
    requests = [];
    catalogBodies = [];
    registrations = [];
    registrationReceived = Completer<void>();
    registrationGate = null;
    registrationStatus = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri);
      expect(request.headers.value('apikey'), 'sb_publishable_auto_test');
      expect(request.headers.value('accept-encoding'), 'identity');
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/rest/v1/rpc/get_player_catalog') {
        expect(request.method, 'POST');
        final body = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        catalogBodies.add(body);
        final limit = (body['p_limit'] as int?) ?? 100;
        expect(limit, inInclusiveRange(1, 200));
        final after = body['p_after'] as String?;
        final rows = catalog
            .where(
              (row) =>
                  after == null ||
                  (row['game_id'] as String).compareTo(after) > 0,
            )
            .take(limit)
            .toList();
        request.response.write(jsonEncode(rows));
      } else if (request.uri.path == '/rest/v1/rpc/get_player_snapshot') {
        expect(request.method, 'POST');
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        expect(body['p_game_id'], fixtures.gameId);
        request.response.write(jsonEncode(snapshot));
      } else if (request.uri.pathSegments.take(4).join('/') ==
          'storage/v1/object/workshop-media') {
        expect(request.method, 'GET');
        final path = request.uri.pathSegments.skip(4).join('/');
        final bytes = media[path];
        if (bytes == null) {
          request.response.statusCode = 404;
        } else {
          request.response.headers.contentType = ContentType.binary;
          for (var start = 0; start < bytes.length; start += 8192) {
            request.response.add(
              bytes.sublist(start, min(start + 8192, bytes.length)),
            );
            await request.response.flush();
          }
        }
      } else if (request.uri.path == '/rest/v1/rpc/register_player') {
        expect(request.method, 'POST');
        final body = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        registrations.add(body);
        if (!registrationReceived.isCompleted) registrationReceived.complete();
        if (registrationGate != null) await registrationGate!.future;
        request.response.statusCode = registrationStatus;
        request.response.write(
          jsonEncode(
            registrationStatus == 200
                ? {
                    'participant_id': fixtures.secondId,
                    'character_name': body['p_character_name'],
                    'first_seen': '2026-10-25T12:00:00Z',
                    'last_seen': '2026-10-25T12:00:00Z',
                  }
                : {'message': 'rejected token: ${body['p_token']}'},
          ),
        );
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    updates = UpdateClient(
      store,
      'http://127.0.0.1:${server.port}',
      'sb_publishable_auto_test',
    );
  });
  tearDown(() async {
    if (registrationGate != null && !registrationGate!.isCompleted) {
      registrationGate!.complete();
    }
    updates.close();
    await server.close(force: true);
    await store.close();
    await root.delete(recursive: true);
  });

  void addMedia(
    String path,
    List<int> bytes, {
    bool knownHash = true,
    int version = 1,
  }) {
    final hash = knownHash ? sha256.convert(bytes).toString() : null;
    snapshot['version'] = version;
    final manifest = snapshot['manifest'] as Map<String, dynamic>;
    manifest['version'] = version;
    (manifest['records'][0]['blocks'] as List).add({
      'kind': 'image',
      'value': path,
    });
    manifest['checksums'] = <String, Object?>{
      ...manifest['checksums'] as Map<String, dynamic>,
      path: hash,
    };
    (snapshot['files'] as List).add({
      'path': path,
      'storage_path': '$projectId/$path',
      'size': bytes.length,
      'sha256': hash,
    });
    media['$projectId/$path'] = bytes;
  }

  Future<LookupResult> installLockedOldVersion() async {
    await store.installPackage(
      await fixtures.package(root, fixtures.manifest()),
    );
    await store.lookup(fixtures.gameId, '12345');
    for (var i = 0; i < 3; i++) {
      await store.lookup(fixtures.gameId, '55555');
    }
    return store.lockState(fixtures.gameId);
  }

  test('empty local library discovers every server catalog page without a known game', () async {
    catalog = List.generate(
      201,
      (index) => catalogRow(
        id: '10000000-0000-4000-8000-${(index + 1).toRadixString(16).padLeft(12, '0')}',
      ),
    );
    expect(await store.games(), isEmpty);
    final found = await updates.catalog();
    expect(found, hasLength(201));
    expect(found.first.gameId, '10000000-0000-4000-8000-000000000001');
    expect(found.last.gameId, '10000000-0000-4000-8000-0000000000c9');
    expect(found.first.projectId, projectId);
    expect(found.first.updatedAt, now);
    expect(catalogBodies.length, greaterThanOrEqualTo(2));
    expect(catalogBodies.first['p_after'], isNull);
    expect(catalogBodies[1]['p_after'], isNotNull);
    expect(await store.games(), isEmpty);
  });

  test('valid Unicode catalog names and bounded description previews do not hide other games', () async {
    final name = '🙂' * 251;
    final preview = '🌙' * 4000;
    catalog = [
      {...catalogRow(), 'name': name, 'description': preview},
      catalogRow(id: fixtures.secondId),
    ];
    final found = await updates.catalog();
    expect(found.map((game) => game.gameId), [
      fixtures.gameId,
      fixtures.secondId,
    ]);
    expect(found.first.name, name);
    expect(found.first.description, preview);
    expect(found.first.description.runes, hasLength(4000));
    expect(found.last.name, 'Игра из каталога');
  });

  test('generated snapshot archive stores every entry with ZIP method zero before real installation', () async {
    const path = 'media/streamed.png';
    final bytes = List<int>.filled(65536, 42);
    addMedia(path, bytes);
    final inspected = _ArchiveInspectingStore(store);
    updates.close();
    updates = UpdateClient(
      inspected,
      'http://127.0.0.1:${server.port}',
      'sb_publishable_auto_test',
    );
    await updates.syncGame(catalogGame());
    expect(inspected.compressionMethods, {'manifest.json': 0, path: 0});
    expect((await store.game(fixtures.gameId))!.version, 1);
    await store.lookup(fixtures.gameId, '12345');
    expect(
      await (await store.mediaFile(fixtures.gameId, path)).readAsBytes(),
      bytes,
    );
  });

  test('catalog snapshot streams text and legacy Unicode hash percent media into an offline game', () async {
    final bytes = List<int>.generate(131073, (index) => index % 251);
    const path = 'media/Сон #1 100%.png';
    addMedia(path, bytes, knownHash: false);
    final found = await updates.catalog();
    final progress = <double>[];
    final game = await updates.syncGame(found.single, onProgress: progress.add);
    expect(game!.id, fixtures.gameId);
    expect(game.version, 1);
    expect(progress, isNotEmpty);
    expect(progress.last, 1);
    expect(progress.every((value) => value >= 0 && value <= 1), isTrue);
    final opened = await store.lookup(fixtures.gameId, '12345');
    expect(opened.status, LookupStatus.opened);
    expect(opened.record!.blocks.first.value, '<p>Привет</p>');
    final local = await store.mediaFile(
      fixtures.gameId,
      path,
      recordId: fixtures.recordId,
    );
    expect(await local.readAsBytes(), bytes);
    final download = requests.singleWhere(
      (uri) => uri.pathSegments.contains('workshop-media'),
    );
    expect(download.toString(), contains('%23'));
    expect(download.toString(), contains('%25'));
    expect(download.pathSegments.last, 'Сон #1 100%.png');
    await server.close(force: true);
    expect(
      (await store.openedRecord(
        fixtures.gameId,
        fixtures.recordId,
      ))!.blocks.last.value,
      path,
    );
    expect(await local.readAsBytes(), bytes);
  });

  for (final corrupt in ['size', 'hash']) {
    test(
      'snapshot $corrupt corruption preserves installed version history and lock',
      () async {
        final locked = await installLockedOldVersion();
        final bytes = List<int>.generate(17001, (index) => index % 251);
        const path = 'media/new.png';
        addMedia(path, bytes, version: 2);
        if (corrupt == 'size') {
          snapshot['files'][0]['size'] = bytes.length + 1;
        } else {
          media['$projectId/$path'] = [...bytes]..[0] = 255;
        }
        await expectLater(
          updates.syncGame(catalogGame(version: 2)),
          throwsA(isA<PlayerException>()),
        );
        expect((await store.game(fixtures.gameId))!.version, 1);
        expect(
          (await store.history(fixtures.gameId)).single.id,
          fixtures.recordId,
        );
        expect(
          (await store.lockState(fixtures.gameId)).lockedUntil,
          locked.lockedUntil,
        );
        expect(
          (await store.lookup(fixtures.gameId, '12345')).status,
          LookupStatus.locked,
        );
      },
    );
  }

  test('snapshot reuses verified installed content addressed media without another GET', () async {
    final bytes = List<int>.generate(25001, (index) => index % 251);
    final hash = sha256.convert(bytes).toString();
    final path = 'media/$hash.png';
    addMedia(path, bytes);
    await updates.syncGame(catalogGame());
    await store.lookup(fixtures.gameId, '12345');
    requests.clear();
    media.clear();
    snapshot['version'] = 2;
    snapshot['manifest']['version'] = 2;
    snapshot['manifest']['records'][0]['title'] = 'Изменённый текст';
    await updates.syncGame(catalogGame(version: 2));
    expect((await store.game(fixtures.gameId))!.version, 2);
    expect(
      (await store.history(fixtures.gameId)).single.title,
      'Изменённый текст',
    );
    expect(
      requests.where((uri) => uri.pathSegments.contains('workshop-media')),
      isEmpty,
    );
    expect(
      await (await store.mediaFile(fixtures.gameId, path)).readAsBytes(),
      bytes,
    );
    requests.clear();
    expect(await updates.syncGame(catalogGame(version: 2)), isNull);
    expect(requests, isEmpty);
  });

  test(
    'legacy media without a checksum is downloaded again on a new snapshot',
    () async {
      const path = 'media/legacy.png';
      addMedia(path, [1, 2, 3], knownHash: false);
      await updates.syncGame(catalogGame());
      requests.clear();
      snapshot['version'] = 2;
      snapshot['manifest']['version'] = 2;
      media['$projectId/$path'] = [3, 2, 1];
      await updates.syncGame(catalogGame(version: 2));
      expect(
        requests.where((uri) => uri.pathSegments.contains('workshop-media')),
        hasLength(1),
      );
      await store.lookup(fixtures.gameId, '12345');
      expect(
        await (await store.mediaFile(fixtures.gameId, path)).readAsBytes(),
        [3, 2, 1],
      );
    },
  );

  test('real registration acknowledges only the submitted name after an in-flight rename', () async {
    await store.installPackage(
      await fixtures.package(root, fixtures.manifest()),
    );
    final old = await store.savePlayerProfile(fixtures.gameId, 'Алиса');
    registrationGate = Completer<void>();
    final inFlight = updates.registerProfile(old);
    await registrationReceived.future.timeout(const Duration(seconds: 5));
    final renamed = await store.savePlayerProfile(fixtures.gameId, 'Ася');
    registrationGate!.complete();
    await inFlight;
    expect((await store.playerProfile(fixtures.gameId))!.pending, isTrue);
    expect(registrations.single, {
      'p_game_id': fixtures.gameId,
      'p_character_name': 'Алиса',
      'p_token': old.token,
    });
    registrationGate = null;
    await updates.registerProfile(renamed);
    final saved = (await store.playerProfile(fixtures.gameId))!;
    expect(saved.pending, isFalse);
    expect(saved.characterName, 'Ася');
    expect(saved.token, old.token);
    expect(registrations.last['p_token'], old.token);
  });

  test('server registration errors preserve pending and never surface a token echoed by the server', () async {
    await store.installPackage(
      await fixtures.package(root, fixtures.manifest()),
    );
    final profile = await store.savePlayerProfile(fixtures.gameId, 'Алиса');
    registrationStatus = 500;
    await expectLater(
      updates.registerProfile(profile),
      throwsA(
        isA<PlayerException>().having(
          (error) => error.toString(),
          'message',
          isNot(contains(profile.token)),
        ),
      ),
    );
    expect((await store.playerProfile(fixtures.gameId))!.pending, isTrue);
    expect((await store.playerProfile(fixtures.gameId))!.token, profile.token);
  });
}

// Inspect the real generated package, then use the production SQLite installer.
class _ArchiveInspectingStore implements PlayerStore {
  _ArchiveInspectingStore(this.real);
  final PlayerStore real;
  final compressionMethods = <String, int>{};

  @override
  Future<InstalledGame?> game(String id) => real.game(id);

  @override
  Future<File> mediaFile(String gameId, String path, {String? recordId}) =>
      real.mediaFile(gameId, path, recordId: recordId);

  @override
  Future<InstalledGame> installPackage(
    File file, {
    String? expectedGameId,
    int? expectedVersion,
  }) async {
    final decoder = ZipDecoder();
    decoder.decodeBytes(await file.readAsBytes());
    compressionMethods.addEntries(
      decoder.directory.fileHeaders.map(
        (header) => MapEntry(header.filename, header.compressionMethod),
      ),
    );
    return real.installPackage(
      file,
      expectedGameId: expectedGameId,
      expectedVersion: expectedVersion,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
