import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'models.dart';
import 'package_reader.dart';

class PlayerStore {
  PlayerStore._(this._root, this._db, this._clock);
  final Directory _root;
  final Database _db;
  final DateTime Function() _clock;
  Future<void> _queue = Future<void>.value();
  bool _closed = false;

  static Future<PlayerStore> open(
    Directory root, {
    DatabaseFactory? factory,
    DateTime Function()? clock,
  }) async {
    try {
      await root.create(recursive: true);
      await Directory('${root.path}/versions').create(recursive: true);
      final db = await (factory ?? databaseFactory).openDatabase(
        '${root.path}/player.sqlite',
        options: OpenDatabaseOptions(
          version: 1,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON');
          },
          onCreate: (db, version) async {
            await db.execute(
              'CREATE TABLE games (id TEXT PRIMARY KEY,name TEXT NOT NULL,description TEXT NOT NULL,version INTEGER NOT NULL,installed_at INTEGER NOT NULL,directory TEXT NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE records (game_id TEXT NOT NULL,id TEXT NOT NULL,code TEXT NOT NULL,json TEXT NOT NULL,PRIMARY KEY(game_id,id),UNIQUE(game_id,code))',
            );
            await db.execute(
              'CREATE TABLE reservations (game_id TEXT NOT NULL,code TEXT NOT NULL,record_id TEXT,PRIMARY KEY(game_id,code),UNIQUE(game_id,record_id))',
            );
            await db.execute(
              'CREATE TABLE security (game_id TEXT PRIMARY KEY,attempts INTEGER NOT NULL DEFAULT 0,locked_until INTEGER,last_seen INTEGER NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE opened (game_id TEXT NOT NULL,record_id TEXT NOT NULL,json TEXT NOT NULL,directory TEXT NOT NULL,opened_at INTEGER NOT NULL,PRIMARY KEY(game_id,record_id))',
            );
          },
        ),
      );
      return PlayerStore._(root, db, clock ?? DateTime.now);
    } catch (_) {
      throw const PlayerException(
        'Не удалось открыть хранилище игр. Проверьте свободное место.',
      );
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        if (_closed) throw const PlayerException('Хранилище игр закрыто.');
        result.complete(await action());
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  InstalledGame _installed(Map<String, Object?> r) => InstalledGame(
    id: r['id'] as String,
    name: r['name'] as String,
    description: r['description'] as String,
    version: r['version'] as int,
    installedAt: DateTime.fromMillisecondsSinceEpoch(
      r['installed_at'] as int,
      isUtc: true,
    ),
  );
  PlayerRecord _record(String text) {
    final r = jsonDecode(text) as Map<String, dynamic>;
    return PlayerRecord(
      id: r['id'],
      code: r['code'],
      title: r['title'],
      groupName: r['group_name'],
      blocks: List<ContentBlock>.unmodifiable(
        (r['blocks'] as List).map(
          (b) => ContentBlock(kind: b['kind'], value: b['value']),
        ),
      ),
    );
  }

  Future<Map<String, Object?>?> _game(
    String id, [
    DatabaseExecutor? executor,
  ]) async {
    final rows = await (executor ?? _db).query(
      'games',
      where: 'id = ?',
      whereArgs: [id.toLowerCase()],
    );
    return rows.isEmpty ? null : rows.single;
  }

  Future<Map<String, Object?>> _requireGame(
    String id, [
    DatabaseExecutor? executor,
  ]) async {
    final row = await _game(id, executor);
    if (row == null) throw const PlayerException('Игра не установлена.');
    return row;
  }

  Future<List<InstalledGame>> games() => _serial(
    () async => (await _db.query(
      'games',
      orderBy: 'installed_at DESC,id',
    )).map(_installed).toList(growable: false),
  );
  Future<InstalledGame?> game(String id) => _serial(() async {
    final row = await _game(id);
    return row == null ? null : _installed(row);
  });

  Future<InstalledGame> installPackage(
    File file, {
    String? expectedGameId,
    int? expectedVersion,
  }) => _serial(() async {
    Directory? directory;
    var published = false;
    try {
      directory = await Directory('${_root.path}/versions')
          .createTemp('.staging-');
      final snapshot = await readPackage(file, directory);
      final m = snapshot.manifest, g = m['game'] as Map<String, dynamic>;
      final id = g['id'] as String, version = m['version'] as int;
      if ((expectedGameId != null && id != expectedGameId.toLowerCase()) ||
          (expectedVersion != null && version != expectedVersion)) {
        throw const PlayerException(
          'Идентификатор или версия пакета не совпадают с опубликованным обновлением.',
        );
      }
      final existing = await _game(id);
      if (existing != null && version <= (existing['version'] as int)) {
        throw const PlayerException(
          'Установлена эта или более новая версия игры.',
        );
      }
      final oldBindings = await _db.query(
        'reservations',
        where: 'game_id = ?',
        whereArgs: [id],
      );
      final reserved = (m['reserved_codes'] as List).cast<String>().toSet();
      final byCode = {
        for (final r in m['records']) r['code'] as String: r['id'] as String,
      };
      final byId = {
        for (final r in m['records']) r['id'] as String: r['code'] as String,
      };
      for (final binding in oldBindings) {
        final code = binding['code'] as String,
            recordId = binding['record_id'] as String?;
        if (!reserved.contains(code)) {
          throw const PlayerException(
            'Обновление удаляет ранее зарезервированные коды.',
          );
        }
        if ((byCode.containsKey(code) && byCode[code] != recordId) ||
            (recordId != null &&
                byId.containsKey(recordId) &&
                byId[recordId] != code)) {
          throw const PlayerException(
            'Обновление меняет постоянную привязку кода к материалу.',
          );
        }
      }
      final destination =
          '${_root.path}/versions/$id-v$version-${directory.path.split('/').last.substring(9)}';
      directory = await directory.rename(destination);
      final installedAt = _clock().toUtc();
      await _db.transaction((tx) async {
        await tx.insert('games', {
          'id': id,
          'name': g['name'],
          'description': g['description'],
          'version': version,
          'installed_at': installedAt.millisecondsSinceEpoch,
          'directory': destination,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await tx.delete('records', where: 'game_id = ?', whereArgs: [id]);
        final locs = {for (final l in m['locations']) l['id']: l['name']};
        for (final r in m['records']) {
          final record = jsonEncode({
            ...r as Map<String, dynamic>,
            'group_name': locs[r['location_id']],
          });
          await tx.insert('records', {
            'game_id': id,
            'id': r['id'],
            'code': r['code'],
            'json': record,
          });
          await tx.update(
            'opened',
            {'json': record, 'directory': destination},
            where: 'game_id = ? AND record_id = ?',
            whereArgs: [id, r['id']],
          );
        }
        for (final code in reserved) {
          await tx.insert('reservations', {
            'game_id': id,
            'code': code,
            'record_id': byCode[code],
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await tx.insert('security', {
          'game_id': id,
          'last_seen': installedAt.millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      });
      published = true;
      return InstalledGame(
        id: id,
        name: g['name'],
        description: g['description'],
        version: version,
        installedAt: installedAt,
      );
    } on PlayerException {
      rethrow;
    } catch (_) {
      throw const PlayerException(
        'Не удалось установить игру. Предыдущие материалы сохранены.',
      );
    } finally {
      if (!published && directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });

  Future<({int attempts, int? until, int now})> _security(
    DatabaseExecutor tx,
    String gameId,
  ) async {
    final rows = await tx.query(
      'security',
      where: 'game_id = ?',
      whereArgs: [gameId],
    );
    final r = rows.single;
    final wallNow = _clock().toUtc().millisecondsSinceEpoch;
    // A backward wall-clock adjustment must not turn a lock into an early unlock.
    final last = r['last_seen'] as int;
    final now = wallNow < last ? last : wallNow;
    int attempts = r['attempts'] as int;
    int? until = r['locked_until'] as int?;
    if (until != null && now >= until) {
      until = null;
      attempts = 0;
    }
    await tx.update(
      'security',
      {'last_seen': now, 'attempts': attempts, 'locked_until': until},
      where: 'game_id = ?',
      whereArgs: [gameId],
    );
    return (attempts: attempts, until: until, now: now);
  }

  LookupResult _state(int attempts, int? until) => LookupResult(
    status: until == null ? LookupStatus.wrong : LookupStatus.locked,
    wrongAttempts: attempts,
    lockedUntil: until == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(until, isUtc: true),
  );

  Future<LookupResult> lookup(String gameId, String code) => _serial(() async {
    final id = gameId.toLowerCase();
    return _db.transaction((tx) async {
      final g = await _requireGame(id, tx);
      final state = await _security(tx, id);
      if (state.until != null) return _state(state.attempts, state.until);
      if (!RegExp(r'^[1-9][0-9]{4}$').hasMatch(code)) {
        return LookupResult(
          status: LookupStatus.invalid,
          wrongAttempts: state.attempts,
        );
      }
      final rows = await tx.query(
        'records',
        where: 'game_id = ? AND code = ?',
        whereArgs: [id, code],
      );
      if (rows.isEmpty) {
        final attempts = state.attempts + 1;
        final until = attempts >= 3
            ? state.now + const Duration(minutes: 30).inMilliseconds
            : null;
        await tx.update(
          'security',
          {'attempts': attempts, 'locked_until': until},
          where: 'game_id = ?',
          whereArgs: [id],
        );
        return _state(attempts, until);
      }
      final row = rows.single;
      await tx.update(
        'security',
        {'attempts': 0, 'locked_until': null},
        where: 'game_id = ?',
        whereArgs: [id],
      );
      final previous = await tx.rawQuery(
        'SELECT MAX(opened_at) AS latest FROM opened WHERE game_id = ?',
        [id],
      );
      final latest = previous.single['latest'] as int?;
      final openedAt = latest != null && state.now <= latest
          ? latest + 1
          : state.now;
      await tx.insert('opened', {
        'game_id': id,
        'record_id': row['id'],
        'json': row['json'],
        'directory': g['directory'],
        'opened_at': openedAt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return LookupResult(
        status: LookupStatus.opened,
        record: _record(row['json'] as String),
        wrongAttempts: 0,
      );
    });
  });

  Future<LookupResult> lockState(String gameId) => _serial(() async {
    final id = gameId.toLowerCase();
    return _db.transaction((tx) async {
      await _requireGame(id, tx);
      final state = await _security(tx, id);
      return _state(state.attempts, state.until);
    });
  });

  Future<List<PlayerRecord>> history(String gameId) => _serial(() async {
    await _requireGame(gameId);
    final rows = await _db.query(
      'opened',
      where: 'game_id = ?',
      whereArgs: [gameId.toLowerCase()],
      orderBy: 'opened_at DESC,record_id',
    );
    return rows
        .map((r) => _record(r['json'] as String))
        .toList(growable: false);
  });
  Future<PlayerRecord?> openedRecord(String gameId, String recordId) =>
      _serial(() async {
        await _requireGame(gameId);
        final rows = await _db.query(
          'opened',
          where: 'game_id = ? AND record_id = ?',
          whereArgs: [gameId.toLowerCase(), recordId.toLowerCase()],
        );
        return rows.isEmpty ? null : _record(rows.single['json'] as String);
      });
  Future<File> mediaFile(
    String gameId,
    String path, {
    String? recordId,
  }) => _serial(() async {
    validateMediaPath(path);
    final g = await _requireGame(gameId);
    if (recordId != null) {
      final opened = await _db.query(
        'opened',
        columns: ['directory', 'json'],
        where: 'game_id = ? AND record_id = ?',
        whereArgs: [gameId.toLowerCase(), recordId.toLowerCase()],
      );
      if (opened.isEmpty ||
          !_record(opened.single['json'] as String).blocks
              .any((block) => block.kind != 'text' && block.value == path)) {
        throw const PlayerException(
          'Этот файл не относится к открытому материалу.',
        );
      }
      final historical = File('${opened.single['directory']}/$path');
      if (await historical.exists()) return historical;
      throw const PlayerException('Медиафайл открытого материала не найден.');
    }
    final file = File('${g['directory']}/$path');
    if (await file.exists()) return file;
    // Keep historical media for records removed from newer releases.
    final historical = await _db.query(
      'opened',
      columns: ['directory', 'json'],
      where: 'game_id = ?',
      whereArgs: [gameId.toLowerCase()],
      orderBy: 'opened_at DESC',
    );
    for (final row in historical) {
      if (_record(row['json'] as String).blocks
          .any((b) => b.kind != 'text' && b.value == path)) {
        final old = File('${row['directory']}/$path');
        if (await old.exists()) return old;
      }
    }
    throw const PlayerException('Медиафайл не найден в установленной игре.');
  });
  Future<void> close() => _serial(() async {
    await _db.close();
    _closed = true;
  });
}
