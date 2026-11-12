import pytest
from PySide6.QtCore import Qt

from larp_studio.project import Project
from larp_studio.ui.editor import RecordEditor
from larp_studio.ui.main_window import MainWindow
from larp_studio.ui.preview import PreviewDialog


@pytest.fixture
def project(tmp_path):
    p = Project.create(tmp_path / 'Игра', 'Остров Лафей')
    yield p
    p.close()


def test_editor_saves_multiblock_record_and_keeps_code_on_edit(qtbot, project):
    editor = RecordEditor(project)
    qtbot.addWidget(editor)
    editor.title_edit.setText('Дневник')
    editor.add_text('<h2>Вступление</h2><p>Первый день</p>')
    editor.add_text('<p>Второй день</p>')
    editor.block_list.setCurrentRow(1)
    editor.move_block(-1)
    editor.save_record()
    row = project.record(editor.record_id)
    assert row['title'] == 'Дневник'
    assert 'Второй день' in row['blocks'][0]['value']
    edit = RecordEditor(project, row['id'])
    qtbot.addWidget(edit)
    edit.title_edit.setText('Дневник 2')
    edit.save_record()
    assert project.record(row['id'])['code'] == row['code']


def test_editor_cancel_does_not_change_record(qtbot, project):
    row = project.add_record('Оригинал', blocks=[{'kind': 'text', 'value': '<p>Оригинал</p>'}])
    editor = RecordEditor(project, row['id'])
    qtbot.addWidget(editor)
    editor.title_edit.setText('Изменена')
    editor.text_edit.setPlainText('Изменена')
    editor.reject()
    assert project.record(row['id'])['title'] == 'Оригинал'
    assert project.record(row['id'])['blocks'][0]['value'] == '<p>Оригинал</p>'


def test_table_search_and_location_filter(qtbot, project):
    loc = project.add_location('Архив')
    project.add_record('Дневник', loc)
    other = project.add_record('Письмо')
    window = MainWindow(project)
    qtbot.addWidget(window)
    assert window.table.rowCount() == 2
    assert len(window.visible_records()) == 2
    window.search_edit.setText('пись')
    assert window.visible_records() == [other['id']]
    window.search_edit.clear()
    window.location_filter.setCurrentIndex(window.location_filter.findData(loc))
    assert len(window.visible_records()) == 1
    window.location_filter.setCurrentIndex(0)
    window.search_edit.setText(other['code'])
    assert window.visible_records() == [other['id']]


def test_window_and_preview_survive_reopen(qtbot, project):
    row = project.add_record('Находка', blocks=[{'kind': 'text', 'value': '<p>Привет, игрок!</p>'}])
    window = MainWindow(project)
    qtbot.addWidget(window)
    window.show()
    preview = PreviewDialog(project, row['blocks'], row['title'])
    qtbot.addWidget(preview)
    assert 'Привет, игрок!' in preview.text_content()
    window.close()
    reopened = Project.open(project.path)
    second = MainWindow(reopened)
    qtbot.addWidget(second)
    assert second.table.rowCount() == 1
    assert second.table.item(0, 0).text() == row['code']
    second.close()
    reopened.close()


def test_editor_imports_image_from_external_path(qtbot, project, tmp_path):
    from PySide6.QtGui import QImage
    source = tmp_path / 'изображение.png'
    image = QImage(10, 10, QImage.Format.Format_RGB32)
    image.fill(Qt.GlobalColor.blue)
    image.save(str(source))
    editor = RecordEditor(project)
    qtbot.addWidget(editor)
    editor.title_edit.setText('Фотография')
    editor.add_media('image', source)
    source.unlink()
    editor.save_record()
    row = project.record(editor.record_id)
    assert row['blocks'][0]['kind'] == 'image'
    preview = PreviewDialog(project, row['blocks'], row['title'])
    qtbot.addWidget(preview)
    assert preview.image_count == 1


def test_preview_removes_external_resources(qtbot, project):
    preview = PreviewDialog(project, [{'kind': 'text', 'value': '<p>Безопасно</p><img src="https://bad.example/a"><script>bad()</script>'}], 'Текст')
    qtbot.addWidget(preview)
    assert 'Безопасно' in preview.text_content()
    assert 'bad()' not in preview.text_content()
    assert 'https://' not in preview.safe_html
