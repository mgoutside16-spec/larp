import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:larp_player/core/models.dart';
import 'package:larp_player/core/player_store.dart';
import 'package:larp_player/core/update_client.dart';

import '../core/package_helper.dart' as fixtures;

void main() {
  late Directory root;
  late PlayerStore store;
  late HttpServer server;
  late UpdateClient updater;
  late List<int> packageBytes;
  late Map<String, dynamic>? release;
  late List<String> calls;
  var responseCode = 200;
  var redirect = false;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('larp-online-tests-');
    store = await PlayerStore.open(
      Directory('${root.path}/store'),
      factory: databaseFactoryFfi,
    );
    final file = await fixtures.package(root, fixtures.manifest());
    packageBytes = await file.readAsBytes();
    final hash = sha256.convert(packageBytes).toString();
    release = {
      'game_id': fixtures.gameId,
      'name': 'Игра',
      'version': 1,
      'sha256': hash,
      'size': packageBytes.length,
      'download_path': '${fixtures.gameId}/1/$hash.rpgpack',
      'created_at': '2026-10-25T00:00:00Z',
    };
    calls = [];
    responseCode = 200;
    redirect = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      calls.add(request.uri.path);
      expect(request.headers.value('apikey'), 'sb_publishable_test');
      if (request.uri.path == '/rest/v1/rpc/get_player_release') {
        expect(request.method, 'POST');
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        expect(body['p_game_id'], fixtures.gameId);
        request.response.statusCode = responseCode;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(
            responseCode == 200
                ? release
                : {'code': 'PGRST202', 'message': 'missing function'},
          ),
        );
      } else if (request.uri.path.startsWith(
        '/storage/v1/object/player-releases/',
      )) {
        if (redirect) {
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            'http://127.0.0.1:${server.port}/forbidden',
          );
        } else {
          request.response.add(packageBytes);
        }
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    updater = UpdateClient(
      store,
      'http://127.0.0.1:${server.port}',
      'sb_publishable_test',
    );
  });
  tearDown(() async {
    updater.close();
    await server.close(force: true);
    await store.close();
    await root.delete(recursive: true);
  });

  test('known game can be installed through real anonymous HTTP and checksum verification', () async {
    final update = await updater.check(fixtures.gameId);
    expect(update, isNotNull);
    final progress = <double>[];
    final game = await updater.install(update!, onProgress: progress.add);
    expect(game.id, fixtures.gameId);
    expect(game.version, 1);
    expect((await store.lookup(game.id, '12345')).status, LookupStatus.opened);
    expect(progress.last, 1);
    expect(calls, [
      '/rest/v1/rpc/get_player_release',
      '/storage/v1/object/player-releases/${release!['download_path']}',
    ]);
  });

  test('same installed version and unpublished games have no update', () async {
    await store.installPackage(
      await fixtures.package(root, fixtures.manifest()),
    );
    expect(await updater.check(fixtures.gameId), isNull);
    release = null;
    expect(await updater.check(fixtures.gameId), isNull);
    expect(calls.every((p) => p.startsWith('/rest/')), isTrue);
  });

  test(
    'online version switch preserves opened history and active lock',
    () async {
      await updater.install((await updater.check(fixtures.gameId))!);
      await store.lookup(fixtures.gameId, '12345');
      for (var i = 0; i < 3; i++) {
        await store.lookup(fixtures.gameId, '99999');
      }
      final locked = await store.lockState(fixtures.gameId);
      expect(locked.status, LookupStatus.locked);
      final next = await fixtures.package(root, fixtures.manifest(version: 2));
      packageBytes = await next.readAsBytes();
      final hash = sha256.convert(packageBytes).toString();
      release = {
        ...release!,
        'version': 2,
        'sha256': hash,
        'size': packageBytes.length,
        'download_path': '${fixtures.gameId}/2/$hash.rpgpack',
      };
      await updater.install((await updater.check(fixtures.gameId))!);
      expect((await store.game(fixtures.gameId))!.version, 2);
      expect(
        (await store.lockState(fixtures.gameId)).lockedUntil,
        locked.lockedUntil,
      );
      expect((await store.history(fixtures.gameId)).single.code, '12345');
      expect(
        (await store.lookup(fixtures.gameId, '12345')).status,
        LookupStatus.locked,
      );
    },
  );

  test('corrupt download keeps the existing installed game usable', () async {
    await store.installPackage(
      await fixtures.package(root, fixtures.manifest()),
    );
    final hash = 'a' * 64;
    release = {
      ...release!,
      'version': 2,
      'sha256': hash,
      'download_path': '${fixtures.gameId}/2/$hash.rpgpack',
    };
    await expectLater(
      updater.install((await updater.check(fixtures.gameId))!),
      throwsA(isA<PlayerException>()),
    );
    expect((await store.game(fixtures.gameId))!.version, 1);
    expect(
      (await store.lookup(fixtures.gameId, '12345')).status,
      LookupStatus.opened,
    );
  });

  test(
    'a valid archive of an unexpected version cannot replace the active game',
    () async {
      await store.installPackage(
        await fixtures.package(root, fixtures.manifest()),
      );
      packageBytes = await (await fixtures.package(
        root,
        fixtures.manifest(version: 3),
      )).readAsBytes();
      final hash = sha256.convert(packageBytes).toString();
      release = {
        ...release!,
        'version': 2,
        'sha256': hash,
        'size': packageBytes.length,
        'download_path': '${fixtures.gameId}/2/$hash.rpgpack',
      };
      await expectLater(
        updater.install((await updater.check(fixtures.gameId))!),
        throwsA(isA<PlayerException>()),
      );
      expect((await store.game(fixtures.gameId))!.version, 1);
    },
  );

  test('truncated download is rejected before installation', () async {
    release!['size'] = packageBytes.length + 1;
    await expectLater(
      updater.install((await updater.check(fixtures.gameId))!),
      throwsA(isA<PlayerException>()),
    );
    expect(await store.games(), isEmpty);
  });

  test('redirects are not followed to untrusted content', () async {
    final update = (await updater.check(fixtures.gameId))!;
    redirect = true;
    await expectLater(updater.install(update), throwsA(isA<PlayerException>()));
    expect(calls.any((p) => p == '/forbidden'), isFalse);
    expect(await store.games(), isEmpty);
  });

  test('unsafe metadata paths, mismatching game IDs and oversized packages are rejected', () async {
    final valid = {...release!};
    for (final change in [
      {'download_path': '../../escape.rpgpack'},
      {'download_path': 'https://external.test/secret'},
      {'game_id': fixtures.secondId},
      {'version': 0},
      {'size': 1024 * 1024 * 1024 + 1},
      {'sha256': 'not-a-hash'},
    ]) {
      release = {...valid, ...change};
      await expectLater(
        updater.check(fixtures.gameId),
        throwsA(isA<PlayerException>()),
      );
    }
    expect(calls.every((p) => p.startsWith('/rest/')), isTrue);
    expect(await store.games(), isEmpty);
  });

  test('missing backend setup is explained in Russian', () async {
    responseCode = 404;
    await expectLater(
      updater.check(fixtures.gameId),
      throwsA(
        isA<PlayerException>().having(
          (e) => e.message,
          'message',
          contains('настро'),
        ),
      ),
    );
  });

  test('no network leaves installed offline code lookup available', () async {
    await store.installPackage(
      await fixtures.package(root, fixtures.manifest()),
    );
    await server.close(force: true);
    await expectLater(
      updater.check(fixtures.gameId),
      throwsA(
        isA<PlayerException>().having(
          (e) => e.message,
          'message',
          contains('интернет'),
        ),
      ),
    );
    expect(
      (await store.lookup(fixtures.gameId, '12345')).status,
      LookupStatus.opened,
    );
  });

  test('trusted share link and UUID parse without allowing arbitrary URLs', () {
    expect(parseGameReference(fixtures.gameId.toUpperCase()), fixtures.gameId);
    expect(
      parseGameReference(
        'https://mgoutside16-spec.github.io/larp/?game=${fixtures.gameId}',
      ),
      fixtures.gameId,
    );
    for (final value in [
      'https://external.test/?game=${fixtures.gameId}',
      '12345',
      '../../x',
    ]) {
      expect(() => parseGameReference(value), throwsA(isA<PlayerException>()));
    }
  });
}
