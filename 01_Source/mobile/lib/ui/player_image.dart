import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as raster;

import '../core/models.dart';
import '../vendor/software_png_decoder.dart';

const _maxImageBytes = 64 * 1024 * 1024;
const _maxImagePixels = 40 * 1000 * 1000;

class PlayerPixels {
  PlayerPixels(this.width, this.height, this.rgba);
  final int width, height;
  final Uint8List rgba;
}

raster.Decoder _checkedDecoder(Uint8List bytes) {
  if (bytes.length > _maxImageBytes) {
    throw const PlayerException(
      'Изображение слишком большое: используйте файл до 64 МиБ.',
    );
  }
  final png =
      bytes.length >= 24 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71;
  if (png) {
    final header = ByteData.sublistView(bytes);
    final width = header.getUint32(16), height = header.getUint32(20);
    if (width < 1 || height < 1 || width * height > _maxImagePixels) {
      throw const PlayerException(
        'Разрешение изображения слишком большое: допустимо до 40 мегапикселей.',
      );
    }
  }
  final decoder =
      bytes.length >= 8 &&
          bytes[0] == 137 &&
          bytes[1] == 80 &&
          bytes[2] == 78 &&
          bytes[3] == 71
      ? SoftwarePngDecoder(maxPixels: _maxImagePixels)
      : raster.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (decoder == null || info == null) {
    throw const PlayerException(
      'Не удалось прочитать изображение. Проверьте формат файла в мастерской.',
    );
  }
  if (info.width < 1 ||
      info.height < 1 ||
      info.width * info.height > _maxImagePixels) {
    throw const PlayerException(
      'Разрешение изображения слишком большое: допустимо до 40 мегапикселей.',
    );
  }
  return decoder;
}

/// Pure Dart fallback for valid images rejected by a device's native codec.
/// Raw Flutter RGBA uses premultiplied alpha, unlike ordinary PNG pixels.
PlayerPixels decodePlayerPixels(Uint8List bytes) {
  try {
    final decoder = _checkedDecoder(bytes);
    final decoded = decoder.decodeFrame(0);
    if (decoded == null) {
      throw const PlayerException(
        'Изображение повреждено или имеет неподдерживаемый формат.',
      );
    }
    final pixels = decoded
        .convert(format: raster.Format.uint8, numChannels: 4)
        .getBytes(order: raster.ChannelOrder.rgba);
    for (var i = 0; i < pixels.length; i += 4) {
      final alpha = pixels[i + 3];
      if (alpha < 255) {
        pixels[i] = (pixels[i] * alpha + 127) ~/ 255;
        pixels[i + 1] = (pixels[i + 1] * alpha + 127) ~/ 255;
        pixels[i + 2] = (pixels[i + 2] * alpha + 127) ~/ 255;
      }
    }
    return PlayerPixels(decoded.width, decoded.height, pixels);
  } on PlayerException {
    rethrow;
  } catch (_) {
    throw const PlayerException(
      'Не удалось прочитать изображение. Проверьте файл в мастерской.',
    );
  }
}

Future<ui.Codec> softwarePlayerImageCodec(Uint8List bytes) async {
  final pixels = await compute(decodePlayerPixels, bytes);
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels.rgba);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: pixels.width,
    height: pixels.height,
    rowBytes: pixels.width * 4,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  ui.Codec? codec;
  try {
    codec = await descriptor.instantiateCodec();
    // Raw descriptors own the pixel data until asynchronous frame decoding ends.
    // Releasing them after construction alone clears data still used by workers.
    final first = await codec.getNextFrame();
    return _PrimedCodec(codec, first);
  } catch (_) {
    codec?.dispose();
    rethrow;
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }
}

Future<ui.Codec> decodePlayerImage(Uint8List bytes) async {
  try {
    _checkedDecoder(
      bytes,
    ); // Bound dimensions before either decoder allocates pixels.
  } on PlayerException {
    rethrow;
  } catch (_) {
    throw const PlayerException(
      'Не удалось прочитать изображение. Проверьте файл в мастерской.',
    );
  }
  ui.Codec? native;
  try {
    native = await ui.instantiateImageCodec(bytes);
    // Some Android codecs accept the header but reject the first pixel frame.
    // Preserve that first frame so animated images still start at frame zero.
    final first = await native.getNextFrame();
    return _PrimedCodec(native, first);
  } catch (_) {
    native?.dispose();
    return softwarePlayerImageCodec(bytes);
  }
}

class _PrimedCodec implements ui.Codec {
  _PrimedCodec(this._inner, this._first);
  final ui.Codec _inner;
  ui.FrameInfo? _first;
  @override
  int get frameCount => _inner.frameCount;
  @override
  int get repetitionCount => _inner.repetitionCount;
  @override
  Future<ui.FrameInfo> getNextFrame() async {
    final first = _first;
    if (first != null) {
      _first = null;
      return first;
    }
    return _inner.getNextFrame();
  }

  @override
  void dispose() {
    _first?.image.dispose();
    _first = null;
    _inner.dispose();
  }
}

/// Normal Flutter image cache/semantics, with the same codec for assets and files.
class PlayerImageProvider extends ImageProvider<PlayerImageProvider> {
  const PlayerImageProvider.asset(this.location) : isAsset = true;
  PlayerImageProvider.file(File file) : location = file.path, isAsset = false;
  final String location;
  final bool isAsset;

  @override
  Future<PlayerImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    PlayerImageProvider key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: key._load(),
    scale: 1,
    debugLabel: location,
  );

  Future<ui.Codec> _load() async {
    final Uint8List bytes;
    if (isAsset) {
      final data = await rootBundle.load(location);
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } else {
      final file = File(location);
      if (await file.length() > _maxImageBytes) {
        throw const PlayerException(
          'Изображение слишком большое: используйте файл до 64 МиБ.',
        );
      }
      bytes = await file.readAsBytes();
    }
    return decodePlayerImage(bytes);
  }

  @override
  bool operator ==(Object other) =>
      other is PlayerImageProvider &&
      other.location == location &&
      other.isAsset == isAsset;
  @override
  int get hashCode => Object.hash(location, isAsset);
}
