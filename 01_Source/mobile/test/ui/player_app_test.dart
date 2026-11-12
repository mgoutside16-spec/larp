import 'dart:async';
import 'dart:convert';

import 'package:larp_player/core/models.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larp_player/core/player_store.dart';
import 'package:larp_player/core/update_client.dart';
import 'package:larp_player/ui/player_app.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() async {
    FilePickerIO.registerWith();
    const fontPath = String.fromEnvironment('PLAYER_CAPTURE_FONT');
    if (fontPath.isNotEmpty) {
      final loader = FontLoader('Roboto')
        ..addFont(
          Future.value(
            ByteData.sublistView(await File(fontPath).readAsBytes()),
          ),
        );
      await loader.load();
      final bold = File(
        fontPath.replaceFirst('Roboto-Regular.ttf', 'Roboto-Bold.ttf'),
      );
      if (await bold.exists()) {
        await (FontLoader('Roboto')..addFont(
              Future.value(ByteData.sublistView(await bold.readAsBytes())),
            ))
            .load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  late Directory root;
  late PlayerStore store;

  void playerTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('player-ui-');
        store = await PlayerStore.open(root, factory: databaseFactoryFfi);
      });
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await store.close();
          await root.delete(recursive: true);
        });
      }
    });
  }

  Future<File> createPackage() async {
    final manifest = {
      'format_version': 1,
      'version': 1,
      'created': '2026-10-25T00:00:00Z',
      'game': {
        'id': gameId,
        'name': 'Остров Лафей',
        'description': 'Истории острова',
      },
      'locations': [
        {'id': 1, 'name': 'Сны'},
      ],
      'records': [
        {
          'id': '55555555-5555-4555-8555-555555555555',
          'code': '12345',
          'title': 'Первый сон',
          'location_id': 1,
          'modified': '2026-10-25T00:00:00Z',
          'blocks': [
            {
              'kind': 'text',
              'value': '<h2>Берег</h2><p>Вы слышите <b>море</b>.</p>',
            },
            {'kind': 'text', 'value': '<p>Затем наступает утро.</p>'},
          ],
        },
      ],
      'reserved_codes': ['12345'],
      'checksums': <String, String>{},
    };
    final data = utf8.encode(jsonEncode(manifest));
    final archive = Archive()
      ..addFile(ArchiveFile('manifest.json', data.length, data));
    final file = File('${root.path}/game.rpgpack');
    await file.writeAsBytes(ZipEncoder().encode(archive));
    return file;
  }

  Future<void> install() async => store.installPackage(await createPackage());

  playerTest(
    'fresh library automatically loads saved projects without a link or publication',
    (tester) async {
      late HttpServer server;
      late HttpClient client;
      late UpdateClient updates;
      var catalogRequests = 0;
      var registrationRequests = 0;
      var version = 1;
      await tester.runAsync(() async {
        final package = await createPackage();
        final archive = ZipDecoder().decodeBytes(await package.readAsBytes());
        final manifest = jsonDecode(
          utf8.decode(archive.findFile('manifest.json')!.content as List<int>),
        ) as Map<String, dynamic>;
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          request.response.headers.contentType = ContentType.json;
          switch (request.uri.path) {
            case '/rest/v1/rpc/get_player_catalog':
              catalogRequests++;
              request.response.write(
                jsonEncode([
                  {
                    'game_id': gameId,
                    'project_id': '22222222-2222-4222-8222-222222222222',
                    'name': 'Остров Лафей',
                    'description': 'Истории острова',
                    'version': version,
                    'record_count': 1,
                    'updated_at': '2026-10-25T00:00:00Z',
                  },
                  {
                    'game_id': '44444444-4444-4444-8444-444444444444',
                    'project_id': '66666666-6666-4666-8666-666666666666',
                    'name': 'Пустой проект',
                    'description': '',
                    'version': 1,
                    'record_count': 0,
                    'updated_at': '2026-10-25T00:00:00Z',
                  },
                ]),
              );
            case '/rest/v1/rpc/get_player_snapshot':
              final body = jsonDecode(
                await utf8.decoder.bind(request).join(),
              ) as Map<String, dynamic>;
              final empty = body['p_game_id'] != gameId;
              final snapshotManifest =
                  jsonDecode(jsonEncode(manifest)) as Map<String, dynamic>;
              snapshotManifest['version'] = empty ? 1 : version;
              if (empty) {
                snapshotManifest['game'] = {
                  'id': '44444444-4444-4444-8444-444444444444',
                  'name': 'Пустой проект',
                  'description': '',
                };
                snapshotManifest['records'] = [];
                snapshotManifest['locations'] = [];
                snapshotManifest['reserved_codes'] = [];
              } else if (version == 2) {
                (snapshotManifest['records'] as List).single['title'] =
                    'Сон после изменения';
              }
              request.response.write(
                jsonEncode({
                  'game_id': body['p_game_id'],
                  'project_id': empty
                      ? '66666666-6666-4666-8666-666666666666'
                      : '22222222-2222-4222-8222-222222222222',
                  'version': empty ? 1 : version,
                  'manifest': snapshotManifest,
                  'files': [],
                }),
              );
            case '/rest/v1/rpc/register_player':
              registrationRequests++;
              request.response.write(
                jsonEncode({
                  'participant_id': '33333333-3333-4333-8333-333333333333',
                  'character_name': 'Элиас',
                  'first_seen': '2026-10-25T00:00:00Z',
                  'last_seen': '2026-10-25T00:00:00Z',
                }),
              );
            default:
              request.response.statusCode = 404;
          }
          await request.response.close();
        });
        client = _RealNetwork().createHttpClient(null);
        updates = UpdateClient(
          store,
          'http://127.0.0.1:${server.port}',
          'sb_publishable_widget_test',
          client: client,
        );
      });
      try {
        expect((await tester.runAsync(store.games))!, isEmpty);
        await tester.pumpWidget(PlayerApp(store: store, updates: updates));
        await pumpUntil(tester, find.text('Остров Лафей'));
        expect(catalogRequests, greaterThan(0));
        expect(find.text('Введите код'), findsNothing);
        await pumpUntil(tester, find.text('Пустой проект'));
        expect((await tester.runAsync(store.games))!, hasLength(2));
        expect((await tester.runAsync(() => store.game(gameId)))!.version, 1);
        await tester.tap(find.text('Остров Лафей'));
        await pumpUntil(tester, find.text('Имя персонажа'));
        await tester.enterText(find.byType(TextField), 'Элиас');
        await tester.tap(find.text('Продолжить'));
        await pumpUntil(tester, find.text('Введите код'));
        expect(find.text('Элиас'), findsOneWidget);
        await tester.runAsync(() async {
          await store.lookup(gameId, '12345');
          for (var i = 0; i < 3; i++) {
            await store.lookup(gameId, '99999');
          }
        });
        version = 2;
        await tester.pump(const Duration(seconds: 20));
        await pumpUntilValue(
          tester,
          () async => (await store.game(gameId))?.version == 2,
        );
        expect(
          (await tester.runAsync(() => store.lockState(gameId)))!.wrongAttempts,
          3,
        );
        expect(
          (await tester.runAsync(() => store.history(gameId)))!,
          hasLength(1),
        );
        expect(
          (await tester.runAsync(() => store.history(gameId)))!.single.title,
          'Сон после изменения',
        );
        await pumpUntilValue(tester, () async => registrationRequests > 0);
        // A manually supplied package remains usable after automatic installs.
        final manual = await tester.runAsync(() async {
          final package = await createPackage();
          final archive = ZipDecoder().decodeBytes(await package.readAsBytes());
          final manifest = jsonDecode(
            utf8.decode(
              archive.findFile('manifest.json')!.content as List<int>,
            ),
          ) as Map<String, dynamic>;
          manifest['version'] = 3;
          final bytes = utf8.encode(jsonEncode(manifest));
          final updated = Archive()
            ..addFile(ArchiveFile('manifest.json', bytes.length, bytes));
          return File('${root.path}/manual.rpgpack')
              .writeAsBytes(ZipEncoder().encode(updated));
        });
        final original = FilePicker.platform;
        FilePicker.platform = _SelectedPackagePicker(manual!);
        try {
          await tester.tap(find.byTooltip('Ваши игры'));
          await pumpUntil(
            tester,
            find.textContaining('Игры и материалы обновлены'),
          );
          await tester.ensureVisible(find.text('Импорт .rpgpack'));
          await tester.tap(find.text('Импорт .rpgpack'));
          await pumpUntilValue(
            tester,
            () async => (await store.game(gameId))?.version == 3,
          );
          expect(
            (await tester.runAsync(() => store.lockState(gameId)))!
                .wrongAttempts,
            3,
          );
        } finally {
          FilePicker.platform = original;
        }
      } finally {
        updates.close();
        client.close(force: true);
        await tester.runAsync(() => server.close(force: true));
      }
    },
  );

  playerTest(
    'pasted game link downloads a real release after explicit approval',
    (tester) async {
      late HttpServer server;
      late HttpClient client;
      late UpdateClient updates;
      await tester.runAsync(() async {
        final package = await createPackage();
        final bytes = await package.readAsBytes();
        final hash = sha256.convert(bytes).toString();
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          if (request.uri.path == '/rest/v1/rpc/get_player_catalog') {
            request.response.headers.contentType = ContentType.json;
            request.response.write('[]');
          } else if (request.uri.path == '/rest/v1/rpc/get_player_release') {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'game_id': gameId,
                'name': 'Остров Лафей',
                'version': 1,
                'sha256': hash,
                'size': bytes.length,
                'download_path': '$gameId/1/$hash.rpgpack',
              }),
            );
          } else {
            request.response.add(bytes);
          }
          await request.response.close();
        });
        client = _RealNetwork().createHttpClient(null);
        updates = UpdateClient(
          store,
          'http://127.0.0.1:${server.port}',
          'sb_publishable_widget_test',
          client: client,
        );
      });
      try {
        await tester.pumpWidget(PlayerApp(store: store, updates: updates));
        await pumpUntil(tester, find.textContaining('без интернета'));
        await pumpUntil(
          tester,
          find.textContaining('В мастерской пока нет доступных проектов'),
        );
        await tester.tap(find.text('Добавить по ссылке'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField),
          'https://mgoutside16-spec.github.io/larp/?game=$gameId',
        );
        await tester.tap(find.text('Найти'));
        await pumpUntil(tester, find.text('Загрузить'));
        expect((await tester.runAsync(store.games))!, isEmpty);
        await tester.tap(find.text('Загрузить'));
        await pumpUntil(tester, find.text('Версия 1\nИстории острова'));
        expect(
          (await tester.runAsync(store.games))!.single.name,
          'Остров Лафей',
        );
      } finally {
        updates.close();
        client.close(force: true);
        await tester.runAsync(() => server.close(force: true));
      }
    },
  );

  playerTest(
    'offline character stays playable and registers after reconnecting',
    (tester) async {
      late HttpServer server;
      late HttpClient client;
      late UpdateClient updates;
      var online = false;
      var registrations = 0;
      await tester.runAsync(() async {
        await install();
        await store.lookup(gameId, '12345');
        for (var i = 0; i < 3; i++) {
          await store.lookup(gameId, '99999');
        }
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          request.response.headers.contentType = ContentType.json;
          if (!online) {
            request.response.statusCode = 503;
            request.response.write('{}');
          } else if (request.uri.path.endsWith('get_player_catalog')) {
            request.response.write('[]');
          } else if (request.uri.path.endsWith('register_player')) {
            final body = jsonDecode(
              await utf8.decoder.bind(request).join(),
            ) as Map<String, dynamic>;
            registrations++;
            request.response.write(
              jsonEncode({
                'participant_id': '33333333-3333-4333-8333-333333333333',
                'character_name': body['p_character_name'],
                'first_seen': '2026-10-25T00:00:00Z',
                'last_seen': '2026-10-25T00:00:00Z',
              }),
            );
          } else {
            request.response.statusCode = 404;
          }
          await request.response.close();
        });
        client = _RealNetwork().createHttpClient(null);
        updates = UpdateClient(
          store,
          'http://127.0.0.1:${server.port}',
          'sb_publishable_widget_test',
          client: client,
        );
      });
      try {
        await tester.pumpWidget(PlayerApp(store: store, updates: updates));
        await pumpUntil(tester, find.text('Остров Лафей'));
        await tester.tap(find.text('Остров Лафей'));
        await pumpUntil(tester, find.text('Имя персонажа'));
        await tester.enterText(find.byType(TextField), 'Анна');
        await tester.tap(find.text('Продолжить'));
        await pumpUntil(tester, find.text('Введите код'));
        expect(find.text('Анна'), findsOneWidget);
        final profile = (await tester.runAsync(
          () => store.playerProfile(gameId),
        ))!;
        expect(profile.pending, isTrue);
        expect(
          (await tester.runAsync(() => store.lockState(gameId)))!.wrongAttempts,
          3,
        );
        await pumpUntil(tester, find.text('Повторить сейчас'));
        expect(find.byKey(const ValueKey('sync-status')), findsOneWidget);
        await tester.tap(find.text('Изменить имя'));
        await pumpUntil(tester, find.text('Имя персонажа'));
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Анна',
        );
        await tester.enterText(find.byType(TextField), 'Анна Морская');
        await tester.tap(find.text('Продолжить'));
        await pumpUntil(tester, find.text('Анна Морская'));
        final renamed = (await tester.runAsync(
          () => store.playerProfile(gameId),
        ))!;
        expect(renamed.token, profile.token);
        expect(
          (await tester.runAsync(() => store.lockState(gameId)))!.wrongAttempts,
          3,
        );
        expect(
          (await tester.runAsync(() => store.history(gameId)))!,
          hasLength(1),
        );
        online = true;
        await tester.pump(const Duration(seconds: 20));
        await pumpUntilValue(
          tester,
          () async => (await store.playerProfile(gameId))?.pending == false,
        );
        expect(registrations, greaterThan(0));
        await tester.tap(find.byTooltip('Ваши игры'));
        await tester.pump();
        final previous = registrations;
        await tester.pump(const Duration(seconds: 20));
        await pumpUntil(
          tester,
          find.textContaining('Игры и материалы обновлены'),
        );
        expect(
          registrations,
          previous,
          reason: 'Old projects do not receive heartbeats',
        );
      } finally {
        updates.close();
        client.close(force: true);
        await tester.runAsync(() => server.close(force: true));
      }
    },
  );

  playerTest('system picker imports a real local package into the library', (
    tester,
  ) async {
    final file = await tester.runAsync(createPackage);
    final original = FilePicker.platform;
    FilePicker.platform = _SelectedPackagePicker(file!);
    try {
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: PlayerApp(store: store),
        ),
      );
      await pumpUntil(tester, find.textContaining('без интернета'));
      await tester.tap(find.text('Импорт .rpgpack'));
      await pumpUntil(tester, find.text('Остров Лафей'));
      expect((await tester.runAsync(store.games))!.single.version, 1);
      await capture(tester, 'library-installed');
    } finally {
      FilePicker.platform = original;
    }
  });

  playerTest('empty library explains offline package import', (tester) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: PlayerApp(store: store),
      ),
    );
    await pumpUntil(tester, find.textContaining('без интернета'));
    expect(find.text('Ваши игры'), findsOneWidget);
    expect(find.text('Импорт .rpgpack'), findsOneWidget);
    expect(find.text('Добавить по ссылке'), findsOneWidget);
    expect(find.textContaining('без интернета'), findsOneWidget);
    await capture(tester, 'library');
  });

  playerTest('five digit keypad opens local rich text in original order', (
    tester,
  ) async {
    await tester.runAsync(install);
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: PlayerApp(store: store),
      ),
    );
    await pumpUntil(tester, find.text('Остров Лафей'));
    await chooseCharacter(tester, 'Остров Лафей');
    await pumpUntil(tester, find.text('Введите код'));
    for (final digit in ['1', '2', '3', '4', '5']) {
      await tester.tap(find.byKey(ValueKey('digit-$digit')));
    }
    await tester.pump();
    await tester.ensureVisible(find.text('Открыть материал'));
    await tester.tap(find.text('Открыть материал'));
    await pumpUntil(tester, find.text('Первый сон'));
    expect(find.text('Первый сон'), findsOneWidget);
    expect(find.textContaining('Берег', findRichText: true), findsWidgets);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('block-0'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('block-1'))).dy),
    );
    expect(tester.takeException(), isNull);
  });

  playerTest('code screen has no history tab and keeps stored opened records', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await install();
      await store.lookup(gameId, '12345');
      for (var i = 0; i < 3; i++) {
        await store.lookup(gameId, '99999');
      }
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: PlayerApp(store: store),
      ),
    );
    await pumpUntil(tester, find.text('Остров Лафей'));
    await chooseCharacter(tester, 'Остров Лафей');
    await pumpUntil(tester, find.textContaining('Повторите через'));
    expect(find.textContaining('Повторите через'), findsOneWidget);
    expect(find.text('История'), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect((await tester.runAsync(() => store.history(gameId)))!, hasLength(1));
  });

  playerTest(
    'incomplete input is free and three wrong keypad codes lock entry',
    (tester) async {
      await tester.runAsync(install);
      await tester.pumpWidget(PlayerApp(store: store));
      await pumpUntil(tester, find.text('Остров Лафей'));
      await chooseCharacter(tester, 'Остров Лафей');
      await pumpUntil(tester, find.text('Введите код'));
      await tester.tap(find.byKey(const ValueKey('digit-1')));
      await tester.pump();
      final openButton = find.widgetWithText(FilledButton, 'Открыть материал');
      expect(tester.widget<FilledButton>(openButton).onPressed, isNull);
      expect(
        (await tester.runAsync(() => store.lockState(gameId)))!.wrongAttempts,
        0,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('digit-clear')));
      await tester.tap(find.byKey(const ValueKey('digit-clear')));
      for (var attempt = 1; attempt <= 3; attempt++) {
        await pumpUntilValue(
          tester,
          () async =>
              tester
                  .widget<TextButton>(find.byKey(const ValueKey('digit-9')))
                  .onPressed !=
              null,
        );
        await tester.ensureVisible(find.byKey(const ValueKey('digit-9')));
        for (var digit = 0; digit < 5; digit++) {
          await tester.tap(find.byKey(const ValueKey('digit-9')));
        }
        await tester.pump();
        await tester.ensureVisible(openButton);
        await tester.tap(openButton);
        await pumpUntil(
          tester,
          attempt == 3
              ? find.textContaining('Повторите через')
              : find.text('Код не найден. Осталось попыток: ${3 - attempt}.'),
        );
      }
      expect(tester.widget<FilledButton>(openButton).onPressed, isNull);
      expect(
        (await tester.runAsync(() => store.lockState(gameId)))!.wrongAttempts,
        3,
      );
      expect(find.text('История'), findsNothing);
    },
  );

  playerTest(
    'changing games while a lookup is pending does not open a record in the wrong game',
    (tester) async {
      await tester.runAsync(() async {
        final first = await createPackage();
        await store.installPackage(first);
        final archive = ZipDecoder().decodeBytes(await first.readAsBytes());
        final data = jsonDecode(
          utf8.decode(archive.findFile('manifest.json')!.content as List<int>),
        ) as Map<String, dynamic>;
        data['game'] = {
          'id': '33333333-3333-4333-8333-333333333333',
          'name': 'Другая игра',
          'description': '',
        };
        final encoded = utf8.encode(jsonEncode(data));
        final other = Archive()
          ..addFile(ArchiveFile('manifest.json', encoded.length, encoded));
        final file = await File('${root.path}/other.rpgpack')
            .writeAsBytes(ZipEncoder().encode(other));
        await store.installPackage(file);
      });
      final delayed = _DelayedLookupStore(store);
      await tester.pumpWidget(PlayerApp(store: delayed));
      await pumpUntil(tester, find.text('Остров Лафей'));
      await chooseCharacter(tester, 'Остров Лафей');
      await pumpUntil(tester, find.text('Введите код'));
      for (final digit in ['1', '2', '3', '4', '5']) {
        await tester.ensureVisible(find.byKey(ValueKey('digit-$digit')));
        await tester.tap(find.byKey(ValueKey('digit-$digit')));
        await tester.pump();
      }
      await tester.pump();
      await tester.ensureVisible(find.text('Открыть материал'));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Открыть материал'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Открыть материал'));
      for (var turn = 0; turn < 100 && !delayed.started.isCompleted; turn++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(delayed.started.isCompleted, isTrue);
      await tester.tap(find.byTooltip('Ваши игры'));
      await tester.pump();
      await chooseCharacter(tester, 'Другая игра');
      await tester.pump();
      delayed.release.complete();
      // Drain the real lookup and its completion handlers after switching context.
      for (var turn = 0; turn < 50; turn++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(find.text('Другая игра'), findsOneWidget);
      expect(find.text('Первый сон'), findsNothing);
      expect(find.text('Введите код'), findsOneWidget);
    },
  );

  playerTest('code screen fits a narrow device with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.runAsync(install);
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: PlayerApp(store: store),
      ),
    );
    await pumpUntil(tester, find.text('Остров Лафей'));
    await chooseCharacter(tester, 'Остров Лафей');
    await pumpUntil(tester, find.text('Введите код'));
    await capture(tester, 'keypad-narrow-top');
    expect(find.byKey(const ValueKey('digit-0')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('digit-0')));
    await tester.tap(find.byKey(const ValueKey('digit-0')));
    await tester.pumpAndSettle();
    await capture(tester, 'keypad-narrow');
    await tester.ensureVisible(find.text('Открыть материал'));
    expect(tester.takeException(), isNull);
  });
}

const gameId = '11111111-1111-4111-8111-111111111111';
const captureKey = ValueKey('ui-capture');

Future<void> capture(WidgetTester tester, String name) async {
  const folder = String.fromEnvironment('PLAYER_CAPTURE_DIR');
  if (folder.isEmpty) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(captureKey),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(folder).create(recursive: true);
    await File('$folder/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

// SQLite and package reads use real isolates and filesystem I/O, while widget
// animations use Flutter's fake clock. Yield real time until the UI arrives.
Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  final elapsed = Stopwatch()..start();
  while (finder.evaluate().isEmpty &&
      elapsed.elapsed < const Duration(seconds: 5)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> chooseCharacter(WidgetTester tester, String game) async {
  await tester.tap(find.text(game));
  await pumpUntil(tester, find.text('Имя персонажа'));
  await tester.enterText(
    find.byKey(const ValueKey('character-name')),
    'Персонаж',
  );
  await tester.tap(find.text('Продолжить'));
  await pumpUntil(tester, find.text('Введите код'));
}

Future<void> pumpUntilValue(
  WidgetTester tester,
  Future<bool> Function() predicate,
) async {
  final elapsed = Stopwatch()..start();
  var pending = false;
  bool? value;
  Object? failure;
  while (elapsed.elapsed < const Duration(seconds: 5)) {
    if (!pending) {
      pending = true;
      await tester.runAsync(() async {
        unawaited(
          predicate().then(
            (result) {
              value = result;
              pending = false;
            },
            onError: (Object error) {
              failure = error;
              pending = false;
            },
          ),
        );
      });
    }
    if (failure != null) throw failure!;
    if (value == true) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(value, isTrue);
}

// The native file dialog cannot run in a headless widget process. Only its
// selected path is substituted; import, ZIP validation and SQLite are real.
class _SelectedPackagePicker extends FilePicker {
  _SelectedPackagePicker(this.file);
  final File file;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    return FilePickerResult([
      PlatformFile(
        path: file.path,
        name: 'game.rpgpack',
        size: await file.length(),
      ),
    ]);
  }
}

class _RealNetwork extends HttpOverrides {}

// Delays only delivery of an actual SQLite result, modeling a slow device.
// All reads, transactions, attempt counters and records remain production code.
class _DelayedLookupStore implements PlayerStore {
  _DelayedLookupStore(this.real);
  final PlayerStore real;
  final release = Completer<void>();
  final started = Completer<void>();
  @override
  Future<LookupResult> lookup(String gameId, String code) async {
    final result = await real.lookup(gameId, code);
    started.complete();
    await release.future;
    return result;
  }

  @override
  Future<List<InstalledGame>> games() => real.games();
  @override
  Future<InstalledGame?> game(String id) => real.game(id);
  @override
  Future<InstalledGame> installPackage(
    File file, {
    String? expectedGameId,
    int? expectedVersion,
  }) => real.installPackage(
    file,
    expectedGameId: expectedGameId,
    expectedVersion: expectedVersion,
  );
  @override
  Future<List<PlayerRecord>> history(String id) => real.history(id);
  @override
  Future<PlayerRecord?> openedRecord(String id, String recordId) =>
      real.openedRecord(id, recordId);
  @override
  Future<File> mediaFile(String id, String path, {String? recordId}) =>
      real.mediaFile(id, path, recordId: recordId);
  @override
  Future<LookupResult> lockState(String id) => real.lockState(id);
  @override
  Future<PlayerProfile?> playerProfile(String gameId) =>
      real.playerProfile(gameId);
  @override
  Future<List<PlayerProfile>> playerProfiles() => real.playerProfiles();
  @override
  Future<PlayerProfile> savePlayerProfile(String gameId, String name) =>
      real.savePlayerProfile(gameId, name);
  @override
  Future<void> markPlayerRegistered(String gameId, String token, String name) =>
      real.markPlayerRegistered(gameId, token, name);
  @override
  Future<void> close() => real.close();
}
