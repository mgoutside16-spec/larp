from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QFont, QTextBlockFormat, QTextCharFormat
from PySide6.QtWidgets import (QComboBox, QDialog, QFileDialog, QFormLayout,
    QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem, QMessageBox,
    QPushButton, QSplitter, QStackedWidget, QTextEdit, QVBoxLayout, QWidget)

from ..exports import KINDS
from ..project import ProjectError
from .preview import PreviewDialog
from .richtext import safe_html

FILTERS = {'image': 'Изображения (*.png *.jpg *.jpeg *.webp *.bmp *.gif)',
           'audio': 'Аудио (*.mp3 *.wav *.ogg *.m4a *.flac)',
           'video': 'Видео (*.mp4 *.webm *.mkv *.mov *.avi)'}


class RecordEditor(QDialog):
    def __init__(self, project, record_id=None, parent=None):
        super().__init__(parent)
        self.project = project
        self.record_id = record_id
        self._active = None
        self._loading = False
        self.setWindowTitle('Редактировать запись' if record_id else 'Новая запись')
        self.resize(1000, 740)
        self.setAcceptDrops(True)
        layout = QVBoxLayout(self)
        layout.setSpacing(12)
        form = QFormLayout()
        self.title_edit = QLineEdit()
        self.title_edit.setPlaceholderText('Название для мастера, например «Дневник смотрителя»')
        form.addRow('Название', self.title_edit)
        self.location_combo = QComboBox()
        self.location_combo.addItem('Без локации', None)
        for location in project.location_list():
            self.location_combo.addItem(location['name'], location['id'])
        form.addRow('Локация', self.location_combo)
        self.code_label = QLabel('Код появится после сохранения')
        self.code_label.setObjectName('code')
        form.addRow('Постоянный код', self.code_label)
        layout.addLayout(form)
        toolbar = QHBoxLayout()
        for kind, label in [('text', '+ Текст'), ('image', '+ Фото'), ('audio', '+ Аудио'), ('video', '+ Видео')]:
            button = QPushButton(label)
            button.clicked.connect(lambda checked=False, k=kind: self.add_text() if k == 'text' else self.choose_media(k))
            toolbar.addWidget(button)
        toolbar.addStretch()
        layout.addLayout(toolbar)
        splitter = QSplitter()
        left = QWidget()
        left_layout = QVBoxLayout(left)
        left_layout.setContentsMargins(0, 0, 0, 0)
        left_layout.addWidget(QLabel('Порядок материалов'))
        self.block_list = QListWidget()
        self.block_list.setMinimumWidth(210)
        left_layout.addWidget(self.block_list)
        order = QHBoxLayout()
        for label, action in [('Выше', lambda: self.move_block(-1)), ('Ниже', lambda: self.move_block(1)), ('Удалить', self.remove_block)]:
            button = QPushButton(label)
            button.clicked.connect(action)
            order.addWidget(button)
        left_layout.addLayout(order)
        splitter.addWidget(left)
        self.pages = QStackedWidget()
        empty = QLabel('Добавьте текст или перетащите медиафайлы в это окно.\nВыберите блок слева, чтобы отредактировать его.')
        empty.setWordWrap(True)
        empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.pages.addWidget(empty)
        text_page = QWidget()
        text_layout = QVBoxLayout(text_page)
        formatting = QHBoxLayout()
        for label, action in [('Жирный', self.bold), ('Курсив', self.italic), ('Заголовок', self.heading), ('Абзац', self.paragraph)]:
            button = QPushButton(label)
            button.clicked.connect(action)
            formatting.addWidget(button)
        formatting.addStretch()
        text_layout.addLayout(formatting)
        self.text_edit = QTextEdit()
        self.text_edit.setAcceptRichText(False)
        self.text_edit.setAcceptDrops(False)
        self.text_edit.setPlaceholderText('Текст, который увидит игрок…')
        text_layout.addWidget(self.text_edit)
        self.pages.addWidget(text_page)
        media_page = QWidget()
        media_layout = QVBoxLayout(media_page)
        self.media_label = QLabel()
        self.media_label.setWordWrap(True)
        media_layout.addWidget(self.media_label)
        change = QPushButton('Заменить файл…')
        change.clicked.connect(self.replace_media)
        media_layout.addWidget(change)
        media_layout.addStretch()
        self.pages.addWidget(media_page)
        splitter.addWidget(self.pages)
        splitter.setStretchFactor(1, 3)
        layout.addWidget(splitter, 1)
        self.error = QLabel()
        self.error.setObjectName('error')
        self.error.setWordWrap(True)
        layout.addWidget(self.error)
        actions = QHBoxLayout()
        preview = QPushButton('Предпросмотр игрока')
        preview.clicked.connect(self.preview)
        actions.addWidget(preview)
        actions.addStretch()
        cancel = QPushButton('Отмена')
        cancel.clicked.connect(self.reject)
        actions.addWidget(cancel)
        save = QPushButton('Сохранить запись')
        save.setObjectName('primary')
        save.clicked.connect(self.save_record)
        actions.addWidget(save)
        layout.addLayout(actions)
        self.block_list.currentItemChanged.connect(self._select_block)
        if record_id:
            row = project.record(record_id)
            self.title_edit.setText(row['title'])
            self.code_label.setText(row['code'])
            self.location_combo.setCurrentIndex(self.location_combo.findData(row['location_id']))
            for block in row['blocks']:
                self._append(dict(block))
            if self.block_list.count():
                self.block_list.setCurrentRow(0)

    def _append(self, block):
        item = QListWidgetItem(KINDS[block['kind']])
        item.setData(Qt.ItemDataRole.UserRole, block)
        self.block_list.addItem(item)
        return item

    def _flush(self):
        if self._active is not None and not self._loading:
            block = dict(self._active.data(Qt.ItemDataRole.UserRole))
            if block['kind'] == 'text':
                block['value'] = safe_html(self.text_edit.toHtml())
                self._active.setData(Qt.ItemDataRole.UserRole, block)

    def _select_block(self, current, previous=None):
        self._flush()
        self._active = current
        if current is None:
            self.pages.setCurrentIndex(0)
            return
        block = current.data(Qt.ItemDataRole.UserRole)
        self._loading = True
        if block['kind'] == 'text':
            self.text_edit.setHtml(safe_html(block['value']))
            self.pages.setCurrentIndex(1)
        else:
            self.media_label.setText(KINDS[block['kind']] + '\n\nФайл сохранён в проекте:\n' + block['value'])
            self.pages.setCurrentIndex(2)
        self._loading = False

    def add_text(self, value=''):
        item = self._append({'kind': 'text', 'value': value})
        self.block_list.setCurrentItem(item)
        self.text_edit.setFocus()

    def add_media(self, kind, source):
        value = self.project.import_media(source)
        item = self._append({'kind': kind, 'value': value})
        self.block_list.setCurrentItem(item)

    def choose_media(self, kind):
        paths, _ = QFileDialog.getOpenFileNames(self, 'Добавить материалы', '', FILTERS[kind])
        try:
            for path in paths:
                self.add_media(kind, Path(path))
        except ProjectError as exc:
            self.error.setText(str(exc))

    def replace_media(self):
        if self._active is None:
            return
        block = self._active.data(Qt.ItemDataRole.UserRole)
        path, _ = QFileDialog.getOpenFileName(self, 'Заменить файл', '', FILTERS[block['kind']])
        if path:
            try:
                block['value'] = self.project.import_media(Path(path))
                self._active.setData(Qt.ItemDataRole.UserRole, block)
                self._select_block(self._active)
            except ProjectError as exc:
                self.error.setText(str(exc))

    def move_block(self, direction):
        index = self.block_list.currentRow()
        target = index + direction
        if index < 0 or target < 0 or target >= self.block_list.count():
            return
        self._flush()
        self._active = None
        item = self.block_list.takeItem(index)
        self.block_list.insertItem(target, item)
        self.block_list.setCurrentItem(item)

    def remove_block(self):
        index = self.block_list.currentRow()
        if index >= 0:
            self._active = None
            self.block_list.takeItem(index)
            self._select_block(self.block_list.currentItem())

    def content(self):
        self._flush()
        return [dict(self.block_list.item(i).data(Qt.ItemDataRole.UserRole)) for i in range(self.block_list.count())]

    def save_record(self):
        try:
            if self.record_id:
                self.project.update_record(self.record_id, self.title_edit.text(), self.location_combo.currentData(), self.content())
            else:
                row = self.project.add_record(self.title_edit.text(), self.location_combo.currentData(), self.content())
                self.record_id = row['id']
            self.accept()
        except (ProjectError, OSError) as exc:
            self.error.setText(str(exc))

    def preview(self):
        PreviewDialog(self.project, self.content(), self.title_edit.text(), self).exec()

    def bold(self):
        fmt = QTextCharFormat()
        fmt.setFontWeight(QFont.Weight.Normal if self.text_edit.fontWeight() >= QFont.Weight.Bold else QFont.Weight.Bold)
        self.text_edit.mergeCurrentCharFormat(fmt)
        self.text_edit.setFocus()

    def italic(self):
        fmt = QTextCharFormat()
        fmt.setFontItalic(not self.text_edit.fontItalic())
        self.text_edit.mergeCurrentCharFormat(fmt)
        self.text_edit.setFocus()

    def heading(self):
        fmt = QTextBlockFormat()
        fmt.setHeadingLevel(2)
        cursor = self.text_edit.textCursor()
        cursor.mergeBlockFormat(fmt)
        self.text_edit.setFontPointSize(18)
        self.text_edit.setFocus()

    def paragraph(self):
        fmt = QTextBlockFormat()
        fmt.setHeadingLevel(0)
        cursor = self.text_edit.textCursor()
        cursor.mergeBlockFormat(fmt)
        self.text_edit.setFontPointSize(11)
        self.text_edit.setFocus()

    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls() and all(url.isLocalFile() for url in event.mimeData().urls()):
            event.acceptProposedAction()

    def dropEvent(self, event):
        try:
            for url in event.mimeData().urls():
                path = Path(url.toLocalFile())
                ext = path.suffix.lower()
                kind = ('image' if ext in ('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp') else
                        'audio' if ext in ('.mp3', '.wav', '.ogg', '.m4a', '.flac') else
                        'video' if ext in ('.mp4', '.webm', '.mkv', '.mov', '.avi') else None)
                if kind is None:
                    raise ProjectError('Этот формат не поддерживается: ' + path.name)
                self.add_media(kind, path)
            event.acceptProposedAction()
        except ProjectError as exc:
            self.error.setText(str(exc))
