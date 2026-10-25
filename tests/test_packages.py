import json
import hashlib
from pathlib import Path
import sqlite3
from sqlalchemy import text
import zipfile

import pytest

from larp_studio.project import Project, ProjectError
from larp_studio.packages import export_package, import_package, validate_package


@pytest.fixture
def game(tmp_path):
    p = Project.create(tmp_path / 'Игра', 'Русская игра', 'Описание')
    image = tmp_path / 'изображение.png'
    image.write_bytes(b'picture-data')
    media = p.import_media(image)
    loc = p.add_location('Архив')
    p.add_record('След', loc, [{'kind': 'text', 'value': '<b>Записка</b>'}, {'kind': 'image', 'value': media}])
    yield p
    p.close()


def rewrite(source, destination, change):
    with zipfile.ZipFile(source) as archive:
        contents = {name: archive.read(name) for name in archive.namelist()}
    change(contents)
    with zipfile.ZipFile(destination, 'w') as archive:
        for name, data in contents.items():
            archive.writestr(name, data)


def test_roundtrip_package_preserves_identity_codes_blocks_media(game, tmp_path):
    package = tmp_path / 'игра.rpgpack'
    export_package(game, package)
    manifest = validate_package(package)
    assert manifest['format_version'] == 1
    assert manifest['version'] == 1
    assert manifest['game']['name'] == 'Русская игра'
    assert manifest['game']['id'] == game.info['id']
    copy = import_package(package, tmp_path / 'Импорт')
    assert copy.records() == game.records()
    assert copy.info['id'] == game.info['id']
    for b in copy.records()[0]['blocks']:
        if b['kind'] != 'text':
            assert copy.media_path(b['value']).read_bytes() == b'picture-data'
            assert not Path(b['value']).is_absolute()
    copy.close()


def test_build_versions_increase_codes_never_change(game, tmp_path):
    first = game.records()[0]
    export_package(game, tmp_path / 'v1.rpgpack')
    game.update_record(first['id'], 'Обновлена', first['location_id'], first['blocks'])
    export_package(game, tmp_path / 'v2.rpgpack')
    assert validate_package(tmp_path / 'v2.rpgpack')['version'] == 2
    assert game.records()[0]['code'] == first['code']
    assert [b['version'] for b in game.build_list()] == [2, 1]


def test_tombstones_survive_export_import(game, tmp_path):
    row = game.add_record('Удалённая')
    game.delete_record(row['id'])
    export_package(game, tmp_path / 'pack.rpgpack')
    copy = import_package(tmp_path / 'pack.rpgpack', tmp_path / 'new')
    assert row['code'] in copy.reserved_codes()
    copy.close()


def test_bad_checksum_rejected_before_destination_created(game, tmp_path):
    source, bad = tmp_path / 'ok.rpgpack', tmp_path / 'bad.rpgpack'
    export_package(game, source)
    def corrupt(contents):
        key = next(k for k in contents if k.startswith('media/'))
        contents[key] = b'tampered'
    rewrite(source, bad, corrupt)
    with pytest.raises(ProjectError, match='сумм'):
        import_package(bad, tmp_path / 'Импорт')
    assert not (tmp_path / 'Импорт').exists()


@pytest.mark.parametrize('name', ['../escape', '/absolute', 'C:/absolute', 'media/../../escape'])
def test_traversal_rejected(game, tmp_path, name):
    source, bad = tmp_path / 'ok.rpgpack', tmp_path / 'bad.rpgpack'
    export_package(game, source)
    rewrite(source, bad, lambda data: data.update({name: b'evil'}))
    with pytest.raises(ProjectError):
        validate_package(bad)


def test_invalid_manifest_and_truncated_zip_rejected(game, tmp_path):
    source, bad = tmp_path / 'ok.rpgpack', tmp_path / 'bad.rpgpack'
    export_package(game, source)
    rewrite(source, bad, lambda data: data.update({'manifest.json': b'{'}))
    with pytest.raises(ProjectError):
        validate_package(bad)
    bad.write_bytes(b'not a zip')
    with pytest.raises(ProjectError):
        validate_package(bad)


def test_duplicate_codes_rejected(game, tmp_path):
    source, bad = tmp_path / 'ok.rpgpack', tmp_path / 'bad.rpgpack'
    export_package(game, source)
    def duplicate(data):
        manifest = json.loads(data['manifest.json'])
        row = dict(manifest['records'][0], id='c56a4180-65aa-42ec-a945-5fd21dec0538')
        manifest['records'].append(row)
        data['manifest.json'] = json.dumps(manifest).encode()
    rewrite(source, bad, duplicate)
    with pytest.raises(ProjectError):
        validate_package(bad)


def test_import_does_not_overwrite_existing_game(game, tmp_path):
    export_package(game, tmp_path / 'pack.rpgpack')
    with pytest.raises(ProjectError):
        import_package(tmp_path / 'pack.rpgpack', game.path)
    assert game.info['name'] == 'Русская игра'
    assert len(game.records()) == 1


def test_missing_media_export_preserves_existing_output_and_version(game, tmp_path):
    output = tmp_path / 'export.rpgpack'
    output.write_bytes(b'existing backup')
    media = game.records()[0]['blocks'][1]['value']
    game.media_path(media).unlink()
    with pytest.raises(ProjectError):
        export_package(game, output)
    assert output.read_bytes() == b'existing backup'
    assert game.info['version'] == 0


@pytest.mark.parametrize('prior_output', [True, False])
def test_commit_failure_restores_output_and_database(game, tmp_path, monkeypatch, prior_output):
    output = tmp_path / 'game.rpgpack'
    if prior_output:
        output.write_bytes(b'previous package')
    def fail_commit(connection):
        raise sqlite3.OperationalError('simulated disk error at commit')
    with monkeypatch.context() as patch:
        patch.setattr(game.engine.dialect, 'do_commit', fail_commit)
        with pytest.raises(ProjectError):
            export_package(game, output)
    if prior_output:
        assert output.read_bytes() == b'previous package'
    else:
        assert not output.exists()
    assert game.info['version'] == 0
    assert game.build_list() == []


def test_export_write_failure_preserves_version(game, tmp_path, monkeypatch):
    output = tmp_path / 'game.rpgpack'
    output.write_bytes(b'previous package')
    def fail_write(*args, **kwargs):
        raise OSError('disk full')
    monkeypatch.setattr(zipfile.ZipFile, 'write', fail_write)
    with pytest.raises(ProjectError):
        export_package(game, output)
    assert output.read_bytes() == b'previous package'
    assert game.info['version'] == 0


def custom_media_package(game, source, bad, names):
    export_package(game, source)
    def change(data):
        manifest = json.loads(data['manifest.json'])
        for value in list(data):
            if value != 'manifest.json':
                del data[value]
        manifest['records'][0]['blocks'] = []
        manifest['checksums'] = {}
        for i, name in enumerate(names):
            contents = f'picture-{i}'.encode()
            manifest['records'][0]['blocks'].append({'kind': 'image', 'value': name})
            manifest['checksums'][name] = hashlib.sha256(contents).hexdigest()
            data[name] = contents
        data['manifest.json'] = json.dumps(manifest).encode()
    rewrite(source, bad, change)


def test_windows_case_aliases_rejected_before_extraction(game, tmp_path):
    source, bad = tmp_path / 'source.rpgpack', tmp_path / 'bad.rpgpack'
    custom_media_package(game, source, bad, ['media/A.png', 'media/a.png'])
    with pytest.raises(ProjectError):
        validate_package(bad)
    with pytest.raises(ProjectError):
        import_package(bad, tmp_path / 'import')
    assert not (tmp_path / 'import').exists()


@pytest.mark.parametrize('name', ['media/photo.png.', 'media/photo.png ', 'media/CON.png', 'media/aux', 'media/photo:stream', 'media/a?.png', 'media/a\x00.png'])
def test_windows_unsafe_names_rejected(game, tmp_path, name):
    source, bad = tmp_path / 'source.rpgpack', tmp_path / 'bad.rpgpack'
    custom_media_package(game, source, bad, [name])
    with pytest.raises(ProjectError):
        validate_package(bad)


@pytest.mark.parametrize('field', ['location_id', 'version'])
def test_oversized_integers_rejected_by_validator(game, tmp_path, field):
    source, bad = tmp_path / 'source.rpgpack', tmp_path / 'bad.rpgpack'
    export_package(game, source)
    def change(data):
        manifest = json.loads(data['manifest.json'])
        if field == 'version':
            manifest['version'] = 2 ** 100
        else:
            manifest['locations'][0]['id'] = 2 ** 100
            manifest['records'][0]['location_id'] = 2 ** 100
        data['manifest.json'] = json.dumps(manifest).encode()
    rewrite(source, bad, change)
    with pytest.raises(ProjectError):
        validate_package(bad)


def test_version_exhaustion_is_reported_without_creating_output(game, tmp_path):
    with game.engine.begin() as conn:
        conn.execute(text('UPDATE game SET version=9223372036854775807'))
    output = tmp_path / 'overflow.rpgpack'
    with pytest.raises(ProjectError, match='верси'):
        export_package(game, output)
    assert not output.exists()
