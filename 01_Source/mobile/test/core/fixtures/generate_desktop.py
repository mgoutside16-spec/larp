"""Run from repo root with SQLAlchemy installed; uses the real desktop exporter."""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / 'src'))
from larp_studio.project import Project
from larp_studio.packages import export_package

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    game = Project.create(root / 'game', 'Русская игра', 'Экспорт мастерской Python')
    image = root / 'photo.png'
    image.write_bytes(b'image')
    media = game.import_media(image)
    game.add_record('Запись', None, [
        {'kind': 'text', 'value': '<p>Привет</p>'},
        {'kind': 'image', 'value': media},
    ])
    export_package(game, Path(__file__).with_name('desktop.rpgpack'))
    game.close()
