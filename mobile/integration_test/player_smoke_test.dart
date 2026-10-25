import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:larp_player/core/models.dart';
import 'package:larp_player/core/player_store.dart';
import 'package:larp_player/ui/player_app.dart';

import '../test/core/package_helper.dart' as fixture;
import 'media_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
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
        await waitFor(tester, find.text('Введите код'));
        for (final digit in ['1', '2', '3', '4', '5']) {
          await tester.tap(find.byKey(ValueKey('digit-$digit')));
        }
        await tester.ensureVisible(find.text('Открыть материал'));
        await tester.tap(find.text('Открыть материал'));
        await waitFor(
          tester,
          find.textContaining('Офлайн-проверка', findRichText: true),
        );
        await waitFor(tester, find.byTooltip('Слушать'));
        await tester.ensureVisible(find.byTooltip('Слушать'));
        await tester.tap(find.byTooltip('Слушать'));
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
        await waitFor(tester, find.textContaining('Повторите через'));
        await tester.tap(find.text('История'));
        await waitFor(tester, find.text('Записка'));
        await tester.tap(find.text('Записка'));
        await waitFor(
          tester,
          find.textContaining('Привет', findRichText: true),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );
}

Future<void> waitFor(WidgetTester tester, Finder target) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (target.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(target, findsWidgets);
}

Uint8List _wave() {
  const sampleRate = 22050, count = sampleRate * 4;
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
