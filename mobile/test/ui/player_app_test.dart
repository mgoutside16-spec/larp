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
          if (request.uri.path == '/rest/v1/rpc/get_player_release') {
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
    await tester.tap(find.text('Остров Лафей'));
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

  playerTest('history remains available during three-attempt lock', (
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
    await tester.tap(find.text('Остров Лафей'));
    await pumpUntil(tester, find.textContaining('Повторите через'));
    expect(find.textContaining('Повторите через'), findsOneWidget);
    await tester.tap(find.text('История'));
    await pumpUntil(tester, find.text('Первый сон'));
    await tester.tap(find.text('Первый сон'));
    await pumpUntil(tester, find.textContaining('Берег', findRichText: true));
    expect(find.textContaining('Берег', findRichText: true), findsWidgets);
  });

  playerTest(
    'incomplete input is free and three wrong keypad codes lock entry',
    (tester) async {
      await tester.runAsync(install);
      await tester.pumpWidget(PlayerApp(store: store));
      await pumpUntil(tester, find.text('Остров Лафей'));
      await tester.tap(find.text('Остров Лафей'));
      await pumpUntil(tester, find.text('Введите код'));
      await tester.tap(find.byKey(const ValueKey('digit-1')));
      await tester.pump();
      final openButton = find.widgetWithText(FilledButton, 'Открыть материал');
      expect(tester.widget<FilledButton>(openButton).onPressed, isNull);
      expect(
        (await tester.runAsync(() => store.lockState(gameId)))!.wrongAttempts,
        0,
      );
      await tester.tap(find.byKey(const ValueKey('digit-clear')));
      for (var attempt = 1; attempt <= 3; attempt++) {
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
      await tester.tap(find.text('История'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Здесь появятся'), findsOneWidget);
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
      await tester.tap(find.text('Остров Лафей'));
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
      await tester.tap(find.text('Другая игра'));
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
    await tester.tap(find.text('Остров Лафей'));
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
  while ((finder.evaluate().isEmpty || tester.binding.hasScheduledFrame) &&
      elapsed.elapsed < const Duration(seconds: 5)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
  await tester.pumpAndSettle();
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
  Future<void> close() => real.close();
}
