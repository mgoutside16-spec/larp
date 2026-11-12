"""Versioned, checksum-verified offline packages for future player clients."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tempfile
import uuid
import zipfile

from sqlalchemy import insert, update, text

from .files import atomic_output, preserve_output_on_error
from .project import (Project, ProjectError, blocks, builds, codes, file_hash,
                      games, locations, now, records, relative_media)

MAX_FILE = 1024 ** 3
MAX_TOTAL = 4 * 1024 ** 3
MAX_MANIFEST = 16 * 1024 ** 2
MAX_INTEGER = 2 ** 63 - 1


def _require(condition, message='Некорректная структура игрового пакета.'):
    if not condition:
        raise ProjectError(message)


def _uuid(value):
    _require(isinstance(value, str))
    try:
        uuid.UUID(value)
    except ValueError as exc:
        raise ProjectError('Некорректный идентификатор в пакете.') from exc


def _manifest_schema(m, archive_files):
    _require(isinstance(m, dict))
    _require(m.get('format_version') == 1, 'Эта версия формата пакета не поддерживается.')
    _require(type(m.get('version')) is int and 1 <= m['version'] <= MAX_INTEGER)
    game = m.get('game')
    _require(isinstance(game, dict))
    _uuid(game.get('id'))
    _require(isinstance(game.get('name'), str) and bool(game['name'].strip()))
    _require(isinstance(game.get('description'), str))
    _require(isinstance(m.get('created'), str))
    locs, rows, reserved, checksums = (m.get(k) for k in ('locations', 'records', 'reserved_codes', 'checksums'))
    _require(isinstance(locs, list) and isinstance(rows, list) and isinstance(reserved, list) and isinstance(checksums, dict))
    location_ids = set()
    location_names = set()
    for loc in locs:
        _require(isinstance(loc, dict) and type(loc.get('id')) is int and 1 <= loc['id'] <= MAX_INTEGER)
        _require(isinstance(loc.get('name'), str) and bool(loc['name'].strip()))
        _require(loc['id'] not in location_ids and loc['name'] not in location_names)
        location_ids.add(loc['id'])
        location_names.add(loc['name'])
    _require(len(reserved) <= 90000)
    _require(all(isinstance(c, str) and re.fullmatch('[1-9][0-9]{4}', c) for c in reserved))
    _require(len(set(reserved)) == len(reserved))
    reserved = set(reserved)
    occupied, ids, media = set(), set(), set()
    for row in rows:
        _require(isinstance(row, dict))
        _uuid(row.get('id'))
        code = row.get('code')
        _require(isinstance(code, str) and code in reserved and code not in occupied)
        _require(row['id'] not in ids)
        occupied.add(code)
        ids.add(row['id'])
        _require(isinstance(row.get('title'), str) and bool(row['title'].strip()))
        _require(isinstance(row.get('modified'), str))
        loc = row.get('location_id')
        _require(loc is None or (type(loc) is int and loc in location_ids))
        _require(isinstance(row.get('blocks'), list))
        for block in row['blocks']:
            _require(isinstance(block, dict) and set(block) == {'kind', 'value'})
            _require(block['kind'] in ('text', 'image', 'audio', 'video') and isinstance(block['value'], str))
            if block['kind'] != 'text':
                media.add(relative_media(block['value']))
    _require(set(checksums) == media == archive_files - {'manifest.json'}, 'Список медиафайлов в пакете неполон.')
    _require(all(isinstance(v, str) and re.fullmatch('[0-9a-f]{64}', v) for v in checksums.values()))


def _validate_archive(archive):
    entries = archive.infolist()
    _require(len(entries) <= 100000, 'Слишком много файлов в пакете.')
    names = [entry.filename for entry in entries]
    _require(len(names) == len(set(names)), 'Пакет содержит повторяющиеся имена файлов.')
    _require(len(names) == len({name.casefold() for name in names}), 'Имена медиафайлов совпадают без учёта регистра Windows.')
    _require('manifest.json' in names, 'В пакете нет manifest.json.')
    _require(sum(e.file_size for e in entries) <= MAX_TOTAL, 'Пакет превышает допустимый размер 4 ГиБ.')
    for entry in entries:
        if entry.filename != 'manifest.json':
            relative_media(entry.filename)
        _require(not entry.is_dir() and not entry.flag_bits & 1)
        _require(not stat.S_ISLNK(entry.external_attr >> 16), 'Ссылки внутри пакета запрещены.')
        _require(entry.file_size <= MAX_FILE, 'Один файл в пакете превышает 1 ГиБ.')
    _require(archive.getinfo('manifest.json').file_size <= MAX_MANIFEST)
    manifest = json.loads(archive.read('manifest.json'))
    _manifest_schema(manifest, set(names))
    for name, expected in manifest['checksums'].items():
        with archive.open(name) as stream:
            actual = hashlib.file_digest(stream, 'sha256').hexdigest()
        _require(actual == expected, f'Не совпадает контрольная сумма файла {name}.')
    return manifest


def validate_package(path) -> dict:
    try:
        with zipfile.ZipFile(path) as archive:
            return _validate_archive(archive)
    except (OSError, zipfile.BadZipFile, json.JSONDecodeError, UnicodeDecodeError,
            KeyError, TypeError, ValueError, RuntimeError, NotImplementedError) as exc:
        raise ProjectError('Пакет повреждён или имеет неподдерживаемый формат.') from exc


def export_package(project: Project, destination) -> dict:
    with preserve_output_on_error(destination):
        return _export_package(project, destination)


def _export_package(project: Project, destination) -> dict:
    # The lock serializes version allocation and snapshots with editing instances.
    with project.transaction() as conn:
        conn.execute(text('BEGIN IMMEDIATE'))
        info = project.info
        _require(0 <= info['version'] < MAX_INTEGER, 'Диапазон версий исчерпан. Создайте копию проекта для новой игры.')
        rows = project.records()
        checksums = {}
        for row in rows:
            for block in row['blocks']:
                if block['kind'] != 'text':
                    path = project.media_path(block['value'])
                    if not path.is_file():
                        raise ProjectError(f'Медиафайл не найден: {block["value"]}')
                    checksums[block['value']] = file_hash(path)
        manifest = dict(format_version=1, version=info['version'] + 1, created=now(),
            game={k: info[k] for k in ('id', 'name', 'description')}, locations=project.location_list(),
            records=rows, reserved_codes=project.reserved_codes(), checksums=checksums)
        with atomic_output(destination) as temp:
            with zipfile.ZipFile(temp, 'w', compression=zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
                archive.writestr('manifest.json', json.dumps(manifest, ensure_ascii=False, indent=2))
                for value in checksums:
                    archive.write(project.media_path(value), value)
            validate_package(temp)
            conn.execute(update(games).values(version=manifest['version']))
            conn.execute(insert(builds).values(version=manifest['version'], created=manifest['created'], filename=Path(destination).name))
    return manifest


def import_package(path, destination) -> Project:
    destination = Path(destination)
    if destination.exists():
        raise ProjectError('Для импорта выберите новую папку. Существующий проект не заменяется.')
    staging = None
    project = None
    try:
        # Keep the archive open from validation to extraction, avoiding a path swap.
        with zipfile.ZipFile(path) as archive:
            manifest = _validate_archive(archive)
            destination.parent.mkdir(parents=True, exist_ok=True)
            staging = Path(tempfile.mkdtemp(prefix='.larp-import-', dir=destination.parent))
            project = Project.create(staging / 'project', manifest['game']['name'], manifest['game']['description'])
            for value, checksum in manifest['checksums'].items():
                target = project.media_path(value)
                with archive.open(value) as source, target.open('wb') as out:
                    shutil.copyfileobj(source, out, length=1024 * 1024)
            # Verify the complete extracted set, not only each intermediate write.
            for value, checksum in manifest['checksums'].items():
                target = project.media_path(value)
                _require(file_hash(target) == checksum, 'Не совпадает контрольная сумма после извлечения.')
            with project.transaction() as conn:
                conn.execute(update(games).values(id=manifest['game']['id'], version=manifest['version']))
                if manifest['locations']:
                    conn.execute(insert(locations), manifest['locations'])
                if manifest['reserved_codes']:
                    conn.execute(insert(codes), [{'code': c} for c in manifest['reserved_codes']])
                for row in manifest['records']:
                    conn.execute(insert(records).values(**{k: row[k] for k in ('id', 'code', 'title', 'location_id', 'modified')}))
                    project._put_blocks(conn, row['id'], row['blocks'])
                conn.execute(insert(builds).values(version=manifest['version'], created=manifest['created'], filename=Path(path).name))
            project.close()
            project = None
            (staging / 'project').rename(destination)
        return Project.open(destination)
    except (OSError, zipfile.BadZipFile, json.JSONDecodeError, UnicodeDecodeError,
            KeyError, TypeError, ValueError, OverflowError, RuntimeError, NotImplementedError) as exc:
        raise ProjectError('Не удалось импортировать пакет. Исходные проекты не изменены.') from exc
    finally:
        if project:
            project.close()
        if staging:
            shutil.rmtree(staging, ignore_errors=True)
