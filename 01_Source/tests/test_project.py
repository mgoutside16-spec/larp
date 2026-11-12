from pathlib import Path

import pytest
from sqlalchemy import text

from larp_studio.project import Project, ProjectError


@pytest.fixture
def project(tmp_path):
    p = Project.create(tmp_path / 'Игра ёж', 'Остров Лафей', 'Описание')
    yield p
    p.close()


def test_create_reopen_and_russian_path(project):
    path = project.path
    game_id = project.info['id']
    project.close()
    p = Project.open(path)
    assert p.info['name'] == 'Остров Лафей'
    assert p.info['description'] == 'Описание'
    assert p.info['id'] == game_id
    p.close()


def test_refuses_overwrite_and_invalid_project(project, tmp_path):
    with pytest.raises(ProjectError):
        Project.create(project.path, 'Другая игра')
    with pytest.raises(ProjectError):
        Project.open(tmp_path / 'несуществующий')
    assert project.info['name'] == 'Остров Лафей'


def test_codes_unique_five_digits_and_survive_edit_restart(project):
    rows = [project.add_record(f'Запись {i}') for i in range(150)]
    codes = [r['code'] for r in rows]
    assert len(set(codes)) == 150
    assert all(10000 <= int(c) <= 99999 and len(c) == 5 for c in codes)
    row = rows[0]
    project.update_record(row['id'], 'Новое название', None, [{'kind': 'text', 'value': '<b>Текст</b>'}])
    project.close()
    p = Project.open(project.path)
    assert p.record(row['id'])['code'] == row['code']
    assert p.record(row['id'])['title'] == 'Новое название'
    p.close()


def test_deleted_code_remains_reserved(project):
    row = project.add_record('Записка')
    project.delete_record(row['id'])
    assert project.records() == []
    assert row['code'] in project.reserved_codes()


def test_no_manual_code_assignment(project):
    with pytest.raises(TypeError):
        project.add_record('Заметка', code='12345')


def test_locations_rename_delete_preserve_records(project):
    location = project.add_location('Библиотека')
    row = project.add_record('Книга', location)
    project.rename_location(location, 'Архив')
    assert project.records()[0]['location'] == 'Архив'
    project.delete_location(location)
    assert project.record(row['id'])['location_id'] is None


def test_media_copied_blocks_order_and_restart(project, tmp_path):
    media = []
    for kind, ext in [('image', 'png'), ('audio', 'mp3'), ('video', 'mp4')]:
        source = tmp_path / f'Материал.{ext}'
        source.write_bytes(kind.encode())
        stored = project.import_media(source)
        source.unlink()
        media.append({'kind': kind, 'value': stored})
    blocks = [media[2], {'kind': 'text', 'value': '<h2>Привет</h2>'}, media[0], media[1]]
    row = project.add_record('Мультимедиа', blocks=blocks)
    assert project.record(row['id'])['blocks'] == blocks
    project.close()
    p = Project.open(project.path)
    assert p.record(row['id'])['blocks'] == blocks
    assert all(p.media_path(b['value']).is_file() for b in media)
    p.close()


def test_same_filename_different_content_and_dedup(project, tmp_path):
    source = tmp_path / 'фото.png'
    source.write_bytes(b'first')
    first = project.import_media(source)
    assert project.import_media(source) == first
    source.write_bytes(b'second')
    second = project.import_media(source)
    assert first != second
    assert project.media_path(first).read_bytes() == b'first'


def test_invalid_update_is_atomic(project):
    row = project.add_record('Исходная', blocks=[{'kind': 'text', 'value': 'Оригинал'}])
    with pytest.raises(ProjectError):
        project.update_record(row['id'], 'Изменена', None, [{'kind': 'alien', 'value': '?'}])
    saved = project.record(row['id'])
    assert saved['title'] == 'Исходная'
    assert saved['blocks'][0]['value'] == 'Оригинал'
    with pytest.raises(ProjectError):
        project.update_record(row['id'], 'Изменена', 999, [])
    assert project.record(row['id'])['title'] == 'Исходная'


def test_database_failure_rolls_back_record_and_blocks(project):
    row = project.add_record('Оригинал', blocks=[{'kind': 'text', 'value': 'Оригинал'}])
    with project.engine.begin() as conn:
        conn.execute(text("CREATE TRIGGER fail_block BEFORE INSERT ON blocks BEGIN SELECT RAISE(ABORT, 'disk simulation'); END"))
    with pytest.raises(ProjectError):
        project.update_record(row['id'], 'Потеря', None, [{'kind': 'text', 'value': 'Потеря'}])
    assert project.record(row['id'])['title'] == 'Оригинал'
    assert project.record(row['id'])['blocks'] == [{'kind': 'text', 'value': 'Оригинал'}]


@pytest.mark.parametrize('value', ['../outside', '/tmp/outside', 'C:\\outside.png', 'media/../../oops'])
def test_rejects_external_media_paths(project, value):
    with pytest.raises(ProjectError):
        project.add_record('Опасный путь', blocks=[{'kind': 'image', 'value': value}])


def test_copy_independent_identity_and_media(project, tmp_path):
    row = project.add_record('Текст', blocks=[{'kind': 'text', 'value': 'Привет'}])
    copy = project.copy_to(tmp_path / 'Копия')
    assert copy.info['id'] != project.info['id']
    assert copy.record(row['id'])['code'] == row['code']
    copy.delete_record(row['id'])
    assert len(project.records()) == 1
    copy.close()


def test_project_metadata_updates(project):
    project.update_info('Переименована', 'Новое описание')
    assert project.info['name'] == 'Переименована'


def test_missing_media_rejected_without_creating_record(project):
    with pytest.raises(ProjectError):
        project.add_record('Нет файла', blocks=[{'kind': 'image', 'value': 'media/missing.png'}])
    assert project.records() == []


def test_code_exhaustion_reports_error_without_loop(project):
    with project.engine.begin() as conn:
        conn.execute(text('INSERT INTO codes (code) VALUES (:code)'), [{'code': str(i)} for i in range(10000, 100000)])
    with pytest.raises(ProjectError, match='исчерпан'):
        project.add_record('Лишняя')
    assert project.records() == []


def test_existing_content_addressed_media_is_verified_before_reuse(project, tmp_path):
    original = tmp_path / 'image.png'
    original.write_bytes(b'ORIGINAL')
    value = project.import_media(original)
    project.media_path(value).write_bytes(b'DIFFERENT')
    with pytest.raises(ProjectError, match='поврежд'):
        project.import_media(original)


@pytest.mark.parametrize('operation', ['create', 'copy'])
def test_concurrently_created_folder_is_never_removed(project, tmp_path, monkeypatch, operation):
    target = tmp_path / 'Чужой каталог'
    original_mkdir = Path.mkdir
    def racing_mkdir(path, *args, **kwargs):
        if path == target:
            original_mkdir(path)
            (path / 'user-file.txt').write_text('Сохранить', encoding='utf-8')
            raise FileExistsError('another process created the folder')
        return original_mkdir(path, *args, **kwargs)
    monkeypatch.setattr(Path, 'mkdir', racing_mkdir)
    with pytest.raises(ProjectError):
        if operation == 'create':
            Project.create(target, 'Новая')
        else:
            project.copy_to(target)
    assert (target / 'user-file.txt').read_text(encoding='utf-8') == 'Сохранить'


def test_symlink_media_cannot_write_outside_project(project, tmp_path):
    outside = tmp_path / 'outside'
    outside.mkdir()
    (project.path / 'media').rmdir()
    try:
        (project.path / 'media').symlink_to(outside, target_is_directory=True)
    except OSError:
        pytest.skip('Creating symlinks requires privileges on this platform')
    source = tmp_path / 'image.png'
    source.write_bytes(b'image')
    with pytest.raises(ProjectError):
        project.import_media(source)
    assert list(outside.iterdir()) == []
