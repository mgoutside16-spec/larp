import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:archive/archive_io.dart';

import 'package_reader.dart';

import 'models.dart';
import 'player_store.dart';

class CatalogGame {
  const CatalogGame({
    required this.gameId,
    required this.projectId,
    required this.name,
    required this.description,
    required this.version,
    required this.recordCount,
    required this.updatedAt,
  });
  final String gameId, projectId, name, description;
  final int version, recordCount;
  final DateTime updatedAt;
}

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
    _client.autoUncompress = false;
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
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
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
        name.runes.length > 500 ||
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

  Future<dynamic> _rpc(
    String name,
    Map<String, dynamic> body, {
    int limit = 32 * 1024 * 1024,
  }) async {
    try {
      final response = await _request('POST', '/rest/v1/rpc/$name', body: body);
      if (response.statusCode != 200) {
        await response.drain<void>().timeout(const Duration(seconds: 10));
        throw const PlayerException(
          'Не удалось получить данные мастерской. Проверьте интернет; если ошибка повторяется, сообщите мастеру о настройке автоматической загрузки.',
        );
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        _active();
        if (bytes.length + chunk.length > limit) {
          throw const PlayerException(
            'Ответ мастерской превышает допустимый размер.',
          );
        }
        bytes.addAll(chunk);
      }
      return jsonDecode(utf8.decode(bytes));
    } on PlayerException {
      rethrow;
    } on FormatException {
      throw const PlayerException('Мастерская вернула повреждённые данные.');
    } on TimeoutException {
      throw const PlayerException(
        'Нет связи с мастерской. Сохранённые игры доступны без интернета.',
      );
    } on IOException {
      throw const PlayerException(
        'Нет связи с мастерской. Сохранённые игры доступны без интернета.',
      );
    }
  }

  Never _invalid() => throw const PlayerException(
    'Описание игры повреждено. Предыдущая игра сохранена.',
  );

  Future<List<CatalogGame>> catalog() async {
    final result = <CatalogGame>[];
    String? after;
    while (true) {
      final raw = await _rpc('get_player_catalog', {
        'p_after': after,
        'p_limit': 100,
      });
      if (raw is! List || raw.length > 100) _invalid();
      for (final row in raw) {
        if (row is! Map<String, dynamic>) _invalid();
        final id = row['game_id'],
            project = row['project_id'],
            name = row['name'],
            description = row['description'],
            version = row['version'],
            count = row['record_count'];
        final updated = row['updated_at'] is String
            ? DateTime.tryParse(row['updated_at'])
            : null;
        if (id is! String ||
            !_gameId.hasMatch(id) ||
            id != id.toLowerCase() ||
            project is! String ||
            !_gameId.hasMatch(project) ||
            name is! String ||
            name.trim().isEmpty ||
            name.runes.length > 500 ||
            description is! String ||
            description.length > 1000000 ||
            version is! int ||
            version < 1 ||
            version > 9007199254740991 ||
            count is! int ||
            count < 0 ||
            updated == null ||
            (after != null && id.compareTo(after) <= 0)) {
          _invalid();
        }
        result.add(
          CatalogGame(
            gameId: id,
            projectId: project,
            name: name,
            description: description,
            version: version,
            recordCount: count,
            updatedAt: updated,
          ),
        );
        after = id;
      }
      if (raw.length < 100) return result;
    }
  }

  Future<InstalledGame?> syncGame(
    CatalogGame game, {
    void Function(double)? onProgress,
  }) async {
    _active();
    final current = await _store.game(game.gameId);
    if (current != null && current.version >= game.version) return null;
    Directory? temporary;
    try {
      final raw = await _rpc('get_player_snapshot', {'p_game_id': game.gameId});
      if (raw is! Map<String, dynamic> ||
          raw['game_id'] != game.gameId ||
          raw['project_id'] != game.projectId ||
          raw['version'] is! int ||
          raw['version'] < game.version ||
          raw['version'] > 9007199254740991 ||
          raw['manifest'] is! Map<String, dynamic> ||
          raw['files'] is! List) {
        _invalid();
      }
      final version = raw['version'] as int;
      final manifest = raw['manifest'] as Map<String, dynamic>;
      if (manifest['version'] != version ||
          manifest['game'] is! Map ||
          manifest['game']['id'] != game.gameId ||
          manifest['records'] is! List ||
          manifest['checksums'] is! Map) {
        _invalid();
      }
      final files = raw['files'] as List;
      final seen = <String>{};
      var total = 0;
      for (final entry in files) {
        if (entry is! Map<String, dynamic> ||
            entry['path'] is! String ||
            entry['storage_path'] != '${game.projectId}/${entry['path']}' ||
            entry['size'] is! int ||
            entry['size'] < 1 ||
            entry['size'] > 512 * 1024 * 1024 ||
            (entry['sha256'] != null &&
                (entry['sha256'] is! String ||
                    !_hash.hasMatch(entry['sha256'])))) {
          _invalid();
        }
        validateMediaPath(entry['path']);
        if (!seen.add(entry['path'])) _invalid();
        total += entry['size'] as int;
        if (total > _maxSize - 16 * 1024 * 1024) _invalid();
      }
      final referenced = <String>{};
      for (final record in manifest['records']) {
        if (record is! Map || record['blocks'] is! List) _invalid();
        for (final block in record['blocks']) {
          if (block is! Map ||
              block['kind'] is! String ||
              block['value'] is! String) {
            _invalid();
          }
          if (block['kind'] != 'text') referenced.add(block['value']);
        }
      }
      if (seen.length != referenced.length || !seen.containsAll(referenced)) {
        _invalid();
      }
      temporary = await Directory.systemTemp.createTemp('larp-player-sync-');
      await Directory('${temporary.path}/media').create();
      final checksums = <String, String>{};
      var completed = 0;
      for (final entry in files) {
        _active();
        final path = entry['path'] as String,
            expected = entry['sha256'] as String?;
        final size = entry['size'] as int;
        final destination = File('${temporary.path}/$path');
        var reused = false;
        if (current != null && expected != null) {
          try {
            final cached = await _store.mediaFile(game.gameId, path);
            if (await cached.length() == size &&
                (await sha256.bind(cached.openRead()).first).toString() ==
                    expected) {
              await cached.copy(destination.path);
              reused = true;
            }
          } on PlayerException {
            /* Not cached: download below. */
          } on FileSystemException {
            /* Missing cache: download below. */
          }
        }
        if (!reused) {
          final encodedPath = (entry['storage_path'] as String)
              .split('/')
              .map(Uri.encodeComponent)
              .join('/');
          final response = await _request(
            'GET',
            '/storage/v1/object/workshop-media/$encodedPath',
          );
          if (response.statusCode != 200) {
            await response.drain<void>().timeout(const Duration(seconds: 10));
            throw const PlayerException(
              'Не удалось скачать материал. Прежняя игра сохранена.',
            );
          }
          if (response.contentLength > size) _invalid();
          final output = destination.openWrite();
          final digest = _DigestSink();
          final hashing = sha256.startChunkedConversion(digest);
          var received = 0;
          try {
            await for (final chunk in response.timeout(
              const Duration(seconds: 30),
            )) {
              _active();
              received += chunk.length;
              if (received > size) _invalid();
              hashing.add(chunk);
              output.add(chunk);
              if (received % (1024 * 1024) < chunk.length) await output.flush();
              onProgress?.call(total == 0 ? 0 : (completed + received) / total);
            }
            hashing.close();
            await output.flush();
            if (received != size ||
                (expected != null && digest.value.toString() != expected)) {
              _invalid();
            }
            checksums[path] = digest.value.toString();
          } finally {
            await output.close();
          }
        } else {
          checksums[path] = expected!;
        }
        completed += size;
      }
      manifest['checksums'] = checksums;
      final encoded = utf8.encode(jsonEncode(manifest));
      if (encoded.length > 16 * 1024 * 1024) _invalid();
      final manifestFile = await File('${temporary.path}/manifest.json')
          .writeAsBytes(encoded);
      final package = File('${temporary.path}/game.rpgpack');
      final zip = ZipFileEncoder()
        ..create(package.path, level: ZipFileEncoder.store);
      try {
        await _addStored(zip, manifestFile, 'manifest.json');
        for (final entry in files) {
          _active();
          await _addStored(
            zip,
            File('${temporary.path}/${entry['path']}'),
            entry['path'],
          );
        }
      } finally {
        await zip.close();
      }
      _active();
      final installed = await _store.installPackage(
        package,
        expectedGameId: game.gameId,
        expectedVersion: version,
      );
      onProgress?.call(1);
      return installed;
    } on PlayerException {
      rethrow;
    } on TimeoutException {
      throw const PlayerException(
        'Загрузка прервалась. Прежняя игра сохранена; повторим при появлении связи.',
      );
    } on IOException {
      throw const PlayerException(
        'Не удалось загрузить материалы. Проверьте интернет и свободное место. Прежняя игра сохранена.',
      );
    } finally {
      if (temporary != null && await temporary.exists()) {
        await temporary.delete(recursive: true);
      }
    }
  }

  Future<void> registerProfile(PlayerProfile profile) async {
    final raw = await _rpc('register_player', {
      'p_game_id': profile.gameId,
      'p_character_name': profile.characterName,
      'p_token': profile.token,
    }, limit: 65536);
    if (raw is! Map ||
        raw['character_name'] != profile.characterName ||
        raw['participant_id'] is! String ||
        !_gameId.hasMatch(raw['participant_id']) ||
        raw['first_seen'] is! String ||
        DateTime.tryParse(raw['first_seen']) == null ||
        raw['last_seen'] is! String ||
        DateTime.tryParse(raw['last_seen']) == null) {
      _invalid();
    }
    await _store.markPlayerRegistered(
      profile.gameId,
      profile.token,
      profile.characterName,
    );
  }

  Future<void> _addStored(ZipFileEncoder zip, File file, String path) async {
    final input = InputFileStream(file.path);
    try {
      zip.addArchiveFile(
        ArchiveFile.stream(path, input)..compression = CompressionType.none,
      );
    } finally {
      await input.close();
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
