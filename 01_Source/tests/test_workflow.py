"""Exercise the GUI controls with real local storage and exported files."""
from pathlib import Path
import wave

from openpyxl import load_workbook
from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import QApplication, QFileDialog, QPushButton

from larp_studio.project import Project
from larp_studio.packages import validate_package
from larp_studio.ui.editor import RecordEditor
from larp_studio.ui.main_window import MainWindow
from larp_studio.ui.preview import PreviewDialog


def test_create_edit_and_export_from_window(qtbot, tmp_path, monkeypatch):
    project = Project.create(tmp_path / 'Путь с кириллицей', 'Проверка')
    window = MainWindow(project)
    qtbot.addWidget(window)
    window.show()

    def fill_editor():
        editor = next(w for w in QApplication.topLevelWidgets() if isinstance(w, RecordEditor) and w.isVisible())
        editor.title_edit.setText('Материал для игры')
        editor.add_text('<p>Первая запись</p>')
        save = next(b for b in editor.findChildren(QPushButton) if b.text() == 'Сохранить запись')
        qtbot.mouseClick(save, Qt.MouseButton.LeftButton)

    QTimer.singleShot(50, fill_editor)
    create = next(b for b in window.findChildren(QPushButton) if b.text() == '+ Новая запись')
    qtbot.mouseClick(create, Qt.MouseButton.LeftButton)
    assert len(window.visible_records()) == 1
    window.table.selectRow(0)
    copy = next(b for b in window.findChildren(QPushButton) if b.text() == 'Копировать код')
    qtbot.mouseClick(copy, Qt.MouseButton.LeftButton)
    assert QApplication.clipboard().text() == project.records()[0]['code']

    for kind in ['xlsx', 'pdf', 'rpgpack']:
        target = tmp_path / f'Пакет.{kind}'
        monkeypatch.setattr(QFileDialog, 'getSaveFileName', lambda *args, t=target: (str(t), ''))
        window.export(kind)
        assert target.is_file() and target.stat().st_size > 100
    assert validate_package(tmp_path / 'Пакет.rpgpack')['records'][0]['title'] == 'Материал для игры'
    assert load_workbook(tmp_path / 'Пакет.xlsx').active['B2'].value == 'Материал для игры'
    window.close()
    reopened = Project.open(project.path)
    assert reopened.records()[0]['title'] == 'Материал для игры'
    reopened.close()


def test_internal_audio_backend_loads_copied_wav(qtbot, tmp_path):
    project = Project.create(tmp_path / 'Аудио', 'Аудио')
    source = tmp_path / 'звук.wav'
    with wave.open(str(source), 'wb') as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(8000)
        output.writeframes(b'\x00\x00' * 8000)
    value = project.import_media(source)
    source.unlink()
    preview = PreviewDialog(project, [{'kind': 'audio', 'value': value}], 'Звук')
    qtbot.addWidget(preview)
    assert len(preview.players) == 1
    qtbot.waitUntil(lambda: preview.players[0].player.duration() == 1000, timeout=10000)
    preview.accept()
    project.close()
