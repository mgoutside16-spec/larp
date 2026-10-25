"""Transactional project storage. No GUI or network dependencies."""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
from pathlib import Path, PurePosixPath, PureWindowsPath
import secrets
import re
import shutil
import sqlite3
import uuid

from sqlalchemy import (Column, ForeignKey, Integer, MetaData, String, Table,
                        Text, UniqueConstraint, create_engine, delete, event,
                        insert, select, update, text)
from sqlalchemy.engine import URL
from sqlalchemy.exc import SQLAlchemyError


class ProjectError(Exception):
    """An actionable storage or validation error, safe to show to the master."""


metadata = MetaData()
games = Table('game', metadata,
    Column('id', String, primary_key=True), Column('name', Text, nullable=False),
    Column('description', Text, nullable=False), Column('schema_version', Integer, nullable=False),
    Column('version', Integer, nullable=False))
locations = Table('locations', metadata, Column('id', Integer, primary_key=True),
    Column('name', Text, unique=True, nullable=False))
codes = Table('codes', metadata, Column('code', String(5), primary_key=True))
records = Table('records', metadata, Column('id', String, primary_key=True),
    Column('code', String(5), ForeignKey('codes.code'), unique=True, nullable=False),
    Column('title', Text, nullable=False),
    Column('location_id', Integer, ForeignKey('locations.id', ondelete='SET NULL')),
    Column('modified', String, nullable=False))
blocks = Table('blocks', metadata, Column('id', Integer, primary_key=True),
    Column('record_id', String, ForeignKey('records.id', ondelete='CASCADE'), nullable=False),
    Column('position', Integer, nullable=False), Column('kind', String, nullable=False),
    Column('value', Text, nullable=False), UniqueConstraint('record_id', 'position'))
builds = Table('builds', metadata, Column('version', Integer, primary_key=True),
    Column('created', String, nullable=False), Column('filename', Text, nullable=False))


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def file_hash(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def relative_media(value: str) -> str:
    if not isinstance(value, str):
        raise ProjectError('Некорректное имя медиафайла.')
    path = PurePosixPath(value)
    if ('\\' in value or PureWindowsPath(value).drive
            or path.is_absolute() or '..' in path.parts or len(path.parts) != 2
            or path.parts[0] != 'media' or str(path) != value):
        raise ProjectError('Медиафайл должен находиться внутри папки media проекта.')
    filename = path.name
    stem = filename.split('.')[0].upper()
    if (re.search(r'[<>:"|?*\x00-\x1f]', filename) or filename.endswith(('.', ' '))
            or stem in {'CON', 'PRN', 'AUX', 'NUL', 'CONIN$', 'CONOUT$'}
            or re.fullmatch(r'(COM|LPT)[1-9¹²³]', stem)):
        raise ProjectError('Имя медиафайла несовместимо с Windows.')
    return value


class Project:
    def __init__(self, path: Path):
        self.path = Path(path).resolve()
        self.engine = create_engine(URL.create('sqlite', database=str(self.path / 'project.sqlite3')))

        @event.listens_for(self.engine, 'connect')
        def configure(connection, _):
            connection.execute('PRAGMA foreign_keys=ON')
            connection.execute('PRAGMA busy_timeout=5000')

    @contextmanager
    def transaction(self):
        try:
            with self.engine.begin() as connection:
                yield connection
        except (SQLAlchemyError, OverflowError) as exc:
            raise ProjectError('Не удалось сохранить данные. Изменения отменены. Проверьте доступ к диску.') from exc

    @classmethod
    def create(cls, path: Path, name: str, description: str = '') -> Project:
        name = cls._name(name)
        path = Path(path)
        if path.exists():
            raise ProjectError('Папка уже существует. Выберите новую папку для проекта.')
        project = None
        created = False
        try:
            path.mkdir(parents=True)
            created = True
            (path / 'media').mkdir()
            project = cls(path)
            metadata.create_all(project.engine)
            with project.transaction() as conn:
                conn.execute(insert(games).values(id=str(uuid.uuid4()), name=name,
                    description=description, schema_version=1, version=0))
            return project
        except (OSError, SQLAlchemyError, ProjectError) as exc:
            if project:
                project.close()
            if created:
                shutil.rmtree(path)
            raise ProjectError('Не удалось создать проект. Проверьте путь и права доступа.') from exc

    @classmethod
    def open(cls, path: Path) -> Project:
        path = Path(path)
        if not (path / 'project.sqlite3').is_file():
            raise ProjectError('В папке нет проекта LARP Studio (project.sqlite3).')
        project = cls(path)
        try:
            info = project.info
            if info['schema_version'] != 1:
                raise ProjectError('Версия проекта не поддерживается этим приложением.')
            with project.engine.connect() as conn:
                if conn.execute(text('PRAGMA quick_check')).scalar() != 'ok':
                    raise ProjectError('База проекта повреждена. Откройте резервную копию.')
            return project
        except (SQLAlchemyError, ProjectError, TypeError) as exc:
            project.close()
            raise ProjectError('Не удалось открыть проект: повреждённая или неподдерживаемая база.') from exc

    def close(self):
        self.engine.dispose()

    @staticmethod
    def _name(value: str) -> str:
        if not isinstance(value, str) or not value.strip():
            raise ProjectError('Введите название.')
        return value.strip()

    @property
    def info(self) -> dict:
        with self.engine.connect() as conn:
            row = conn.execute(select(games)).mappings().first()
            if row is None:
                raise ProjectError('В базе отсутствуют данные проекта.')
            return dict(row)

    def update_info(self, name: str, description: str):
        with self.transaction() as conn:
            conn.execute(update(games).values(name=self._name(name), description=description))

    def location_list(self) -> list[dict]:
        with self.engine.connect() as conn:
            return [dict(r) for r in conn.execute(select(locations).order_by(locations.c.name)).mappings()]

    def add_location(self, name: str) -> int:
        with self.transaction() as conn:
            return conn.execute(insert(locations).values(name=self._name(name))).inserted_primary_key[0]

    def rename_location(self, location_id: int, name: str):
        with self.transaction() as conn:
            conn.execute(update(locations).where(locations.c.id == location_id).values(name=self._name(name)))

    def delete_location(self, location_id: int):
        with self.transaction() as conn:
            conn.execute(delete(locations).where(locations.c.id == location_id))

    def media_path(self, value: str) -> Path:
        relative_media(value)
        path = self.path / value
        if not path.resolve().is_relative_to(self.path / 'media'):
            raise ProjectError('Медиафайл находится за пределами проекта.')
        return path

    def import_media(self, source: Path) -> str:
        source = Path(source)
        if not source.is_file():
            raise ProjectError('Файл не найден. Выберите существующий медиафайл.')
        try:
            suffix = source.suffix.lower()
            if not suffix or not suffix[1:].isalnum() or len(suffix) > 12:
                raise ProjectError('У файла должно быть обычное расширение: png, jpg, mp3, mp4 и т. п.')
            digest = file_hash(source)
            value = f'media/{digest}{suffix}'
            target = self.media_path(value)
            if target.exists():
                if file_hash(target) != digest:
                    raise ProjectError('Файл в хранилище проекта повреждён. Восстановите его из резервной копии.')
            else:
                temp = target.with_name(target.name + f'.{uuid.uuid4().hex}.tmp')
                try:
                    shutil.copyfile(source, temp)
                    if file_hash(temp) != digest:
                        raise ProjectError('Файл изменился во время копирования. Повторите добавление.')
                    temp.replace(target)
                finally:
                    temp.unlink(missing_ok=True)
            return value
        except OSError as exc:
            raise ProjectError('Не удалось скопировать медиафайл в проект.') from exc

    def _validate_blocks(self, content: list[dict]):
        for block in content:
            if not isinstance(block, dict) or set(block) != {'kind', 'value'}:
                raise ProjectError('Некорректный блок содержимого.')
            if block['kind'] not in ('text', 'image', 'audio', 'video') or not isinstance(block['value'], str):
                raise ProjectError('Неподдерживаемый тип блока содержимого.')
            if block['kind'] != 'text' and not self.media_path(block['value']).is_file():
                raise ProjectError(f"Медиафайл не найден: {block['value']}")

    def _put_blocks(self, conn, record_id: str, content: list[dict]):
        if content:
            conn.execute(insert(blocks), [dict(record_id=record_id, position=i, **b) for i, b in enumerate(content)])

    def add_record(self, title: str, location_id: int | None = None, blocks: list[dict] | None = None) -> dict:
        title = self._name(title)
        content = blocks or []
        self._validate_blocks(content)
        record_id = str(uuid.uuid4())
        with self.transaction() as conn:
            # Serialize allocation, including across application instances.
            conn.execute(text('BEGIN IMMEDIATE'))
            occupied = set(conn.execute(select(codes.c.code)).scalars())
            if len(occupied) >= 90000:
                raise ProjectError('Диапазон кодов исчерпан: все 90 000 кодов уже использованы.')
            code = None
            for _ in range(64):
                candidate = str(secrets.randbelow(90000) + 10000)
                if candidate not in occupied:
                    code = candidate
                    break
            if code is None:
                code = secrets.choice([str(n) for n in range(10000, 100000) if str(n) not in occupied])
            conn.execute(insert(codes).values(code=code))
            conn.execute(insert(records).values(id=record_id, code=code, title=title,
                location_id=location_id, modified=now()))
            self._put_blocks(conn, record_id, content)
        return self.record(record_id)

    def update_record(self, record_id: str, title: str, location_id: int | None, blocks: list[dict]):
        title = self._name(title)
        self._validate_blocks(blocks)
        with self.transaction() as conn:
            result = conn.execute(update(records).where(records.c.id == record_id).values(
                title=title, location_id=location_id, modified=now()))
            if result.rowcount != 1:
                raise ProjectError('Запись не найдена. Обновите список.')
            conn.execute(delete(globals()['blocks']).where(globals()['blocks'].c.record_id == record_id))
            self._put_blocks(conn, record_id, blocks)

    def delete_record(self, record_id: str):
        with self.transaction() as conn:
            conn.execute(delete(records).where(records.c.id == record_id))

    def reserved_codes(self) -> list[str]:
        with self.engine.connect() as conn:
            return list(conn.execute(select(codes.c.code).order_by(codes.c.code)).scalars())

    def records(self) -> list[dict]:
        with self.engine.connect() as conn:
            rows = [dict(r) for r in conn.execute(select(records, locations.c.name.label('location'))
                .outerjoin(locations).order_by(records.c.modified.desc(), records.c.id)).mappings()]
            content = {}
            for b in conn.execute(select(blocks).order_by(blocks.c.position)).mappings():
                content.setdefault(b['record_id'], []).append({'kind': b['kind'], 'value': b['value']})
            for row in rows:
                row['blocks'] = content.get(row['id'], [])
            return rows

    def record(self, record_id: str) -> dict:
        for row in self.records():
            if row['id'] == record_id:
                return row
        raise ProjectError('Запись не найдена.')

    def build_list(self) -> list[dict]:
        with self.engine.connect() as conn:
            return [dict(r) for r in conn.execute(select(builds).order_by(builds.c.version.desc())).mappings()]

    def copy_to(self, destination: Path) -> Project:
        destination = Path(destination)
        if destination.exists():
            raise ProjectError('Для копии выберите новую папку.')
        copied = None
        created = False
        try:
            destination.mkdir(parents=True)
            created = True
            with sqlite3.connect(self.path / 'project.sqlite3') as source:
                with sqlite3.connect(destination / 'project.sqlite3') as target:
                    source.backup(target)
            shutil.copytree(self.path / 'media', destination / 'media')
            copied = Project.open(destination)
            with copied.transaction() as conn:
                conn.execute(update(games).values(id=str(uuid.uuid4()), version=0))
                conn.execute(delete(builds))
            return copied
        except (OSError, sqlite3.Error, ProjectError) as exc:
            if copied:
                copied.close()
            if created:
                shutil.rmtree(destination, ignore_errors=True)
            raise ProjectError('Не удалось создать копию проекта.') from exc
