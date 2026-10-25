import 'dart:convert';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larp_player/core/models.dart';
import 'package:larp_player/ui/player_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'software image codec retains raw pixels until the first frame is ready',
    () async {
      final bytes = await rootBundle.load('assets/bez-pravil.png');
      final codec = await softwarePlayerImageCodec(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 1254);
      expect(frame.image.height, 1254);
      frame.image.dispose();
      codec.dispose();
    },
  );
  test(
    'pure PNG software path preserves the exact full supplied emblem pixels',
    () async {
      final bytes = await rootBundle.load('assets/bez-pravil.png');
      final image = decodePlayerPixels(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      expect(
        sha256.convert(image.rgba).toString(),
        '48c01cc3923bb03648372a363d4dd3193d86918d5f4a1e266c960e5edeb6e095',
      );
    },
  );
  test('native animation still starts with its first frame after compatibility preflight', () async {
    final codec = await decodePlayerImage(
      base64Decode(
        'R0lGODlhAQABAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAQABAAAIBAABBAQAIfkEAQoAAQAsAAAAAAEAAQCBAP8AAAAAAAAAAAAACAQAAQQEADs=',
      ),
    );
    expect(codec.frameCount, 2);
    final red = await codec.getNextFrame();
    final redBytes = await red.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    expect(redBytes!.buffer.asUint8List(), [255, 0, 0, 255]);
    red.image.dispose();
    final green = await codec.getNextFrame();
    final greenBytes = await green.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    expect(greenBytes!.buffer.asUint8List(), [0, 255, 0, 255]);
    green.image.dispose();
    codec.dispose();
  });
  test('software PNG fallback preserves RGBA and premultiplies translucent colours', () {
    final pixels = decodePlayerPixels(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR4nGP4z8DQwPAfCBkY/oMIBgA44AV8m8QKZgAAAABJRU5ErkJggg==',
      ),
    );
    expect(pixels.width, 2);
    expect(pixels.height, 2);
    expect(pixels.rgba, [
      128,
      0,
      0,
      128,
      0,
      255,
      0,
      255,
      0,
      0,
      255,
      255,
      0,
      0,
      0,
      0,
    ]);
  });
  test('oversized PNG dimensions are refused before pixel decompression', () {
    expect(
      () => decodePlayerPixels(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAJxAAACcQCAYAAAC6TmInAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==',
        ),
      ),
      throwsA(
        isA<PlayerException>().having(
          (e) => e.message,
          'message',
          contains('больш'),
        ),
      ),
    );
  });
  test('invalid images produce an actionable Russian error', () async {
    await expectLater(
      decodePlayerImage(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<PlayerException>()),
    );
  });
  test('bundled emblem decodes through the production player codec', () async {
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
}
