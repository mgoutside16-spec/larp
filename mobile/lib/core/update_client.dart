import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'player_store.dart';

class PlayerRelease {
  const PlayerRelease({
    required this.gameId,
    required this.name,
    required this.version,
    required this.sha256,
    required this.size,
    required this.downloadPath,
  });
  final String gameId, name, sha256, downloadPath;
  final int version, size;
}

final _gameId = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

String parseGameReference(String input) {
  var value = input.trim();
  if (!_gameId.hasMatch(value)) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'mgoutside16-spec.github.io' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        !['/larp/', '/larp'].contains(uri.path) ||
        uri.queryParametersAll['game']?.length != 1 ||
        uri.fragment.isNotEmpty) {
      throw const PlayerException(
        'Вставьте ссылку на игру из мастерской или её полный идентификатор.',
      );
    }
    value = uri.queryParameters['game'] ?? '';
  }
  if (!_gameId.hasMatch(value)) {
    throw const PlayerException(
      'В ссылке отсутствует корректный идентификатор игры.',
    );
  }
  return value.toLowerCase();
}

class UpdateClient {
  UpdateClient(
    this._store,
    String backendUrl,
    this._publicKey, {
    HttpClient? client,
  }) : _base = Uri.parse(backendUrl),
       _client = client ?? HttpClient(),
       _ownsClient = client == null {
    if ((_base.scheme != 'https' &&
            !(_base.scheme == 'http' &&
                ['127.0.0.1', 'localhost', '::1'].contains(_base.host))) ||
        _base.userInfo.isNotEmpty ||
        !['', '/'].contains(_base.path) ||
        _base.hasQuery ||
        _base.hasFragment) {
      throw const PlayerException('Некорректный адрес сервера обновлений.');
    }
    if (!_publicKey.startsWith('sb_publishable_')) {
      throw const PlayerException(
        'Для обновлений нужен публичный ключ мастерской.',
      );
    }
    _client.connectionTimeout = const Duration(seconds: 15);
  }
  final PlayerStore _store;
  final Uri _base;
  final String _publicKey;
  final HttpClient _client;
  final bool _ownsClient;
  bool _closed = false;
  static const _maxSize = 1024 * 1024 * 1024;
  static final _hash = RegExp(r'^[0-9a-f]{64}$');

  void _active() {
    if (_closed) {
      throw const PlayerException(
        'Проверка обновлений завершена. Откройте приложение заново.',
      );
    }
  }

  Future<HttpClientResponse> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    _active();
    final request = await _client
        .openUrl(method, _base.resolve(path))
        .timeout(const Duration(seconds: 20));
    request.followRedirects = false;
    request.headers.set('apikey', _publicKey);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    return request.close().timeout(const Duration(seconds: 30));
  }

  PlayerRelease _parse(dynamic raw, String expectedId) {
    if (raw is! Map<String, dynamic>) {
      throw const PlayerException(
        'Сервер вернул некорректное описание обновления.',
      );
    }
    final id = raw['game_id'],
        name = raw['name'],
        version = raw['version'],
        hash = raw['sha256'],
        size = raw['size'],
        path = raw['download_path'];
    if (id != expectedId ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 500 ||
        version is! int ||
        version < 1 ||
        version > 9007199254740991 ||
        hash is! String ||
        !_hash.hasMatch(hash) ||
        size is! int ||
        size < 1 ||
        size > _maxSize ||
        path is! String) {
      throw const PlayerException(
        'Описание обновления повреждено или превышает допустимый размер.',
      );
    }
    final segments = path.split('/');
    if (segments.length != 3 ||
        !_gameId.hasMatch(segments[0]) ||
        segments[1] != '$version' ||
        segments[2] != '$hash.rpgpack') {
      throw const PlayerException(
        'В обновлении указан недопустимый путь файла.',
      );
    }
    return PlayerRelease(
      gameId: id,
      name: name,
      version: version,
      sha256: hash,
      size: size,
      downloadPath: path,
    );
  }

  Future<PlayerRelease?> check(String gameId) async {
    final id = parseGameReference(gameId);
    try {
      final response = await _request(
        'POST',
        '/rest/v1/rpc/get_player_release',
        body: {'p_game_id': id},
      );
      if (response.statusCode != 200) {
        await response.drain<void>().timeout(const Duration(seconds: 10));
        if (response.statusCode == 404 ||
            response.statusCode == 400 ||
            response.statusCode == 401 ||
            response.statusCode == 403) {
          throw const PlayerException(
            'Онлайн-обновления ещё не настроены в мастерской. Сообщите мастеру или импортируйте файл игры.',
          );
        }
        throw const PlayerException(
          'Сервер обновлений временно недоступен. Установленная игра работает без сети.',
        );
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (bytes.length + chunk.length > 65536) {
          throw const PlayerException('Описание обновления слишком большое.');
        }
        bytes.addAll(chunk);
      }
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw == null) return null;
      final release = _parse(raw, id);
      final current = await _store.game(id);
      return current != null && current.version >= release.version
          ? null
          : release;
    } on PlayerException {
      rethrow;
    } on FormatException {
      throw const PlayerException(
        'Сервер вернул повреждённое описание обновления.',
      );
    } on TimeoutException {
      throw const PlayerException(
        'Проверьте интернет и повторите проверку. Игра доступна без сети.',
      );
    } on IOException {
      throw const PlayerException(
        'Проверьте интернет и повторите проверку. Игра доступна без сети.',
      );
    }
  }

  Future<InstalledGame> install(
    PlayerRelease release, {
    void Function(double)? onProgress,
  }) async {
    _active();
    // Validate public constructor values too, not just responses from check().
    _parse({
      'game_id': release.gameId,
      'name': release.name,
      'version': release.version,
      'sha256': release.sha256,
      'size': release.size,
      'download_path': release.downloadPath,
    }, parseGameReference(release.gameId));
    Directory? temporary;
    IOSink? output;
    try {
      temporary = await Directory.systemTemp.createTemp('larp-player-update-');
      final file = File('${temporary.path}/update.rpgpack');
      final response = await _request(
        'GET',
        '/storage/v1/object/player-releases/${release.downloadPath}',
      );
      if (response.statusCode != 200) {
        await response.drain<void>().timeout(const Duration(seconds: 10));
        throw const PlayerException(
          'Не удалось скачать обновление. Предыдущая игра сохранена; повторите загрузку позже.',
        );
      }
      if (response.contentLength > release.size) {
        throw const PlayerException(
          'Размер обновления не совпадает с описанием.',
        );
      }
      output = file.openWrite();
      final digest = _DigestSink();
      // One streaming digest and one streaming file avoid buffering a game in RAM.
      final hashing = sha256.startChunkedConversion(digest);
      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        _active();
        received += chunk.length;
        if (received > release.size) {
          throw const PlayerException('Размер обновления превышает ожидаемый.');
        }
        hashing.add(chunk);
        output.add(chunk);
        if (received % (1024 * 1024) < chunk.length) await output.flush();
        onProgress?.call(received / release.size);
      }
      hashing.close();
      await output.flush();
      await output.close();
      output = null;
      if (received != release.size ||
          digest.value.toString() != release.sha256) {
        throw const PlayerException(
          'Обновление скачано не полностью или повреждено. Предыдущая игра сохранена.',
        );
      }
      _active();
      final game = await _store.installPackage(
        file,
        expectedGameId: release.gameId,
        expectedVersion: release.version,
      );
      if (game.id != release.gameId || game.version != release.version) {
        throw const PlayerException(
          'Содержимое пакета не совпадает с опубликованной игрой.',
        );
      }
      onProgress?.call(1);
      return game;
    } on PlayerException {
      rethrow;
    } on TimeoutException {
      throw const PlayerException(
        'Загрузка прервалась. Проверьте интернет и повторите; прежняя игра сохранена.',
      );
    } on IOException {
      throw const PlayerException(
        'Не удалось скачать обновление. Проверьте интернет и свободное место. Прежняя игра сохранена.',
      );
    } finally {
      if (output != null) await output.close();
      if (temporary != null && await temporary.exists()) {
        await temporary.delete(recursive: true);
      }
    }
  }

  void close() {
    _closed = true;
    if (_ownsClient) _client.close(force: true);
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
