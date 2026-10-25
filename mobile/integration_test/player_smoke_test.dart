import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:larp_player/core/models.dart';
import 'package:larp_player/core/player_store.dart';
import 'package:larp_player/core/update_client.dart';
import 'package:larp_player/ui/player_app.dart';
import 'package:larp_player/ui/player_image.dart';

import '../test/core/package_helper.dart' as fixture;
import 'media_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('bundled workshop emblem is available and decodes on Android', (
    tester,
  ) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    expect(manifest.listAssets(), contains('assets/bez-pravil.png'));
    final bytes = await rootBundle.load('assets/bez-pravil.png');
    final codec = await decodePlayerImage(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 1254);
    expect(frame.image.height, 1254);
    frame.image.dispose();
    codec.dispose();
  });
  testWidgets(
    'native fresh phone discovers saved projects and automatically updates them',
    (tester) async {
      final temporary = await getTemporaryDirectory();
      final root = await Directory(temporary.path)
          .createTemp('native-auto-sync-');
      final store = await PlayerStore.open(Directory('${root.path}/store'));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var version = 1;
      var online = true;
      var registrations = 0;
      const project = '44444444-4444-4444-8444-444444444444';
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (!online) {
          request.response.statusCode = 503;
          request.response.write('{}');
        } else if (request.uri.path.endsWith('get_player_catalog')) {
          request.response.write(
            jsonEncode([
              {
                'game_id': fixture.gameId,
                'project_id': project,
                'name': 'Игра',
                'description': 'Описание',
                'version': version,
                'record_count': 1,
                'updated_at': '2026-10-25T00:00:00Z',
              },
            ]),
          );
        } else if (request.uri.path.endsWith('get_player_snapshot')) {
          final manifest = fixture.manifest(version: version);
          if (version == 2) {
            manifest['records'][0]['title'] = 'Обновлённая записка';
          }
          request.response.write(
            jsonEncode({
              'game_id': fixture.gameId,
              'project_id': project,
              'version': version,
              'manifest': manifest,
              'files': [],
            }),
          );
        } else if (request.uri.path.endsWith('register_player')) {
          registrations++;
          request.response.write(
            jsonEncode({
              'participant_id': fixture.secondId,
              'character_name': 'Элиас',
              'first_seen': '2026-10-25T00:00:00Z',
              'last_seen': '2026-10-25T00:00:00Z',
            }),
          );
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      final updates = UpdateClient(
        store,
        'http://127.0.0.1:${server.port}',
        'sb_publishable_native_test',
      );
      try {
        expect(await store.games(), isEmpty);
        await tester.pumpWidget(PlayerApp(store: store, updates: updates));
        await waitFor(tester, find.text('Игра'));
        expect(find.text('Введите код'), findsNothing);
        await tester.tap(find.text('Игра'));
        await enterCharacter(tester);
        await waitFor(tester, find.text('Введите код'));
        for (final digit in ['1', '2', '3', '4', '5']) {
          await tester.ensureVisible(find.byKey(ValueKey('digit-$digit')));
          await tester.tap(find.byKey(ValueKey('digit-$digit')));
        }
        await tester.pump();
        await tester.ensureVisible(find.text('Открыть материал'));
        await tester.tap(find.text('Открыть материал'));
        await waitFor(
          tester,
          find.textContaining('Привет', findRichText: true),
        );
        await tester.pageBack();
        await tester.pump(const Duration(milliseconds: 400));
        for (var i = 0; i < 3; i++) {
          await store.lookup(fixture.gameId, '99999');
        }
        version = 2;
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while ((await store.game(fixture.gameId))!.version < 2 &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect((await store.game(fixture.gameId))!.version, 2);
        expect((await store.lockState(fixture.gameId)).wrongAttempts, 3);
        expect(
          (await store.history(fixture.gameId)).single.title,
          'Обновлённая записка',
        );
        await waitFor(
          tester,
          find.textContaining('Игры и материалы обновлены'),
        );
        expect(registrations, greaterThan(0));
        online = false;
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await waitFor(tester, find.text('Повторить сейчас'));
        expect((await store.game(fixture.gameId))!.version, 2);
        expect(
          (await store.playerProfile(fixture.gameId))!.characterName,
          'Элиас',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        updates.close();
        await server.close(force: true);
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'native offline import, ordered media, persistent lock and update',
    (tester) async {
      final temporary = await getTemporaryDirectory();
      final root = await Directory(temporary.path)
          .createTemp('native-player-test-');
      var store = await PlayerStore.open(Directory('${root.path}/store'));
      final m = fixture.manifest();
      m['records'][0]['blocks'] = [
        {
          'kind': 'text',
          'value':
              '<h2>Офлайн-проверка</h2><p>Кириллица и <b>жирный текст</b>.</p>',
        },
        {'kind': 'audio', 'value': 'media/tone.wav'},
        {'kind': 'video', 'value': 'media/movie.mp4'},
      ];
      final media = {'media/tone.wav': _wave(), 'media/movie.mp4': testVideo};
      try {
        await store.installPackage(
          await fixture.package(root, m, media: media),
        );
        await tester.pumpWidget(PlayerApp(store: store));
        await waitFor(tester, find.text('Игра'));
        await tester.tap(find.text('Игра'));
        await enterCharacter(tester);
        await waitFor(tester, find.text('Введите код'));
        for (final digit in ['1', '2', '3', '4', '5']) {
          await tester.tap(find.byKey(ValueKey('digit-$digit')));
        }
        await tester.pump();
        await tester.ensureVisible(find.text('Открыть материал'));
        await tester.tap(find.text('Открыть материал'));
        await waitFor(
          tester,
          find.textContaining('Офлайн-проверка', findRichText: true),
        );
        final audioReady = find.byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              widget.tooltip == 'Слушать' &&
              widget.onPressed != null,
        );
        await waitFor(tester, audioReady);
        await tester.ensureVisible(audioReady);
        await tester.pump();
        await tester.tap(audioReady);
        await waitFor(tester, find.byTooltip('Пауза'));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.tap(find.byTooltip('Пауза'));
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('block-2')),
          200,
          maxScrolls: 20,
        );
        await waitFor(tester, find.byTooltip('Смотреть'));
        await tester.ensureVisible(find.byTooltip('Смотреть'));
        await tester.pump();
        await tester.tap(find.byTooltip('Смотреть'));
        await waitFor(tester, find.byTooltip('Пауза'));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.tap(find.byTooltip('Пауза'));
        expect(find.textContaining('Не удалось'), findsNothing);
        await tester.pageBack();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpWidget(const SizedBox.shrink());
        for (var i = 0; i < 3; i++) {
          await store.lookup(fixture.gameId, '99999');
        }
        final locked = await store.lockState(fixture.gameId);
        expect(locked.status, LookupStatus.locked);
        await store.close();
        store = await PlayerStore.open(Directory('${root.path}/store'));
        expect(
          (await store.lockState(fixture.gameId)).lockedUntil,
          locked.lockedUntil,
        );
        await store.installPackage(
          await fixture.package(root, fixture.manifest(version: 2)),
        );
        expect((await store.game(fixture.gameId))!.version, 2);
        expect(
          (await store.lockState(fixture.gameId)).status,
          LookupStatus.locked,
        );
        expect((await store.history(fixture.gameId)).single.code, '12345');
        await tester.pumpWidget(PlayerApp(store: store));
        await waitFor(tester, find.text('Игра'));
        await tester.tap(find.text('Игра'));
        await enterCharacter(tester);
        await waitFor(tester, find.textContaining('Повторите через'));
        expect(find.text('История'), findsNothing);
        expect(find.byType(NavigationBar), findsNothing);
        expect((await store.history(fixture.gameId)).single.code, '12345');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );
}

Future<void> enterCharacter(WidgetTester tester) async {
  await waitFor(tester, find.text('Имя персонажа'));
  await tester.enterText(find.byKey(const ValueKey('character-name')), 'Элиас');
  await tester.tap(find.text('Продолжить'));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> waitFor(WidgetTester tester, Finder target) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (target.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(target, findsWidgets);
}

Uint8List _wave() {
  const sampleRate = 22050, count = sampleRate * 60;
  final data = ByteData(44 + count * 2);
  void text(int at, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(at + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, 36 + count * 2, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, count * 2, Endian.little);
  for (var i = 0; i < count; i++) {
    data.setInt16(
      44 + i * 2,
      (sin(2 * pi * 440 * i / sampleRate) * 1000).round(),
      Endian.little,
    );
  }
  return data.buffer.asUint8List();
}
