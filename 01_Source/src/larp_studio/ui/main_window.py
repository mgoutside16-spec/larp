from datetime import datetime
import os
from pathlib import Path
import re
import shutil

from PySide6.QtCore import Qt, QSettings
from PySide6.QtGui import QAction, QKeySequence
from PySide6.QtWidgets import (QAbstractItemView, QApplication, QCheckBox,
    QFileDialog, QFormLayout, QHBoxLayout, QHeaderView, QInputDialog, QLabel,
    QLineEdit, QListWidget, QMainWindow, QMessageBox, QPushButton, QStackedWidget,
    QTableWidget, QTableWidgetItem, QTextEdit, QVBoxLayout, QWidget, QComboBox)

from ..exports import export_pdf, export_xlsx, material_types
from ..packages import export_package, import_package, validate_package
from ..project import Project, ProjectError
from .editor import RecordEditor
from .preview import PreviewDialog


def app_settings():
    directory = os.environ.get('LARP_STUDIO_CONFIG_DIR')
    if directory:
        return QSettings(str(Path(directory) / 'settings.ini'), QSettings.Format.IniFormat)
    return QSettings('LARP Studio', 'LARP Studio')


def button(label, action, *, primary=False):
    widget = QPushButton(label)
    if primary:
        widget.setObjectName('primary')
    widget.clicked.connect(action)
    return widget


def table(headers):
    result = QTableWidget(0, len(headers))
    result.setHorizontalHeaderLabels(headers)
    result.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
    result.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
    result.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
    result.verticalHeader().hide()
    result.setAlternatingRowColors(True)
    result.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.ResizeToContents)
    result.horizontalHeader().setStretchLastSection(True)
    return result


class MainWindow(QMainWindow):
    def __init__(self, project=None):
        super().__init__()
        self.project = project
        self.settings = app_settings()
        self.setWindowTitle('LARP Studio — мастерская ролевых игр')
        self.resize(1250, 820)
        self.setMinimumSize(960, 620)
        center = QWidget()
        root = QHBoxLayout(center)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        sidebar = QWidget()
        sidebar.setFixedWidth(235)
        side = QVBoxLayout(sidebar)
        brand = QLabel('LARP Studio')
        brand.setObjectName('brand')
        side.addWidget(brand)
        subtitle = QLabel('Мастерская ролевых игр')
        subtitle.setObjectName('muted')
        side.addWidget(subtitle)
        self.navigation = QListWidget()
        self.navigation.setObjectName('navigation')
        self.navigation.addItems(['Игровые проекты', 'Записи и материалы', 'Локации',
            'Список кодов', 'Экспорт для печати', 'Сборки и версии', 'Настройки'])
        side.addWidget(self.navigation)
        offline = QLabel('Все материалы хранятся\nна вашем компьютере.')
        offline.setObjectName('muted')
        side.addWidget(offline)
        root.addWidget(sidebar)
        self.stack = QStackedWidget()
        root.addWidget(self.stack, 1)
        self.setCentralWidget(center)
        self.project_page = self._project_page()
        self.records_page = self._records_page()
        self.locations_page = self._locations_page()
        self.export_page = self._export_page()
        self.builds_page = self._builds_page()
        self.settings_page = self._settings_page()
        self.pages = [self.project_page, self.records_page, self.locations_page,
            self.records_page, self.export_page, self.builds_page, self.settings_page]
        for page in dict.fromkeys(self.pages):
            self.stack.addWidget(page)
        self.navigation.currentRowChanged.connect(self._navigate)
        self._menus()
        self.refresh()
        self.navigation.setCurrentRow(1 if project else 0)

    def _page(self, title, description):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(28, 26, 28, 24)
        layout.setSpacing(16)
        heading = QLabel(title)
        heading.setObjectName('heading')
        layout.addWidget(heading)
        caption = QLabel(description)
        caption.setObjectName('muted')
        caption.setWordWrap(True)
        layout.addWidget(caption)
        return page, layout

    def _project_page(self):
        page, layout = self._page('Игровые проекты', 'Каждая игра хранится в отдельной папке. Откройте проект или создайте новую игру.')
        actions = QHBoxLayout()
        actions.addWidget(button('Создать проект', self.new_project, primary=True))
        actions.addWidget(button('Открыть проект…', self.open_project))
        actions.addWidget(button('Импорт .rpgpack…', self.import_pack))
        actions.addStretch()
        layout.addLayout(actions)
        self.project_path = QLabel('Проект не открыт')
        self.project_path.setWordWrap(True)
        self.project_path.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        layout.addWidget(self.project_path)
        self.project_form = QWidget()
        form = QFormLayout(self.project_form)
        self.project_name = QLineEdit()
        self.project_description = QTextEdit()
        self.project_description.setAcceptRichText(False)
        self.project_description.setMaximumHeight(170)
        form.addRow('Название игры', self.project_name)
        form.addRow('Описание', self.project_description)
        form.addRow(button('Сохранить параметры', self.save_info))
        form.addRow(button('Создать копию проекта…', self.copy_project))
        remove = button('Удалить проект…', self.delete_project)
        remove.setObjectName('danger')
        form.addRow(remove)
        layout.addWidget(self.project_form)
        layout.addStretch()
        return page

    def _records_page(self):
        page, layout = self._page('Записи и материалы', 'Код выдаётся автоматически и остаётся с записью при любых изменениях.')
        actions = QHBoxLayout()
        self.search_edit = QLineEdit()
        self.search_edit.setPlaceholderText('Найти по названию, коду или локации')
        self.search_edit.setClearButtonEnabled(True)
        self.search_edit.textChanged.connect(self._filter)
        actions.addWidget(self.search_edit, 1)
        self.location_filter = QComboBox()
        self.location_filter.setMinimumWidth(170)
        self.location_filter.currentIndexChanged.connect(self._filter)
        actions.addWidget(self.location_filter)
        actions.addWidget(button('+ Новая запись', self.new_record, primary=True))
        layout.addLayout(actions)
        self.table = table(['Код', 'Название', 'Локация', 'Содержимое', 'Изменено'])
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self.table.itemDoubleClicked.connect(lambda *_: self.edit_record())
        self.table.itemSelectionChanged.connect(self._selection)
        layout.addWidget(self.table, 1)
        bottom = QHBoxLayout()
        self.count_label = QLabel()
        bottom.addWidget(self.count_label)
        bottom.addStretch()
        self.record_buttons = []
        for label, callback in [('Копировать код', self.copy_code), ('Предпросмотр', self.preview_record),
                                ('Редактировать', self.edit_record), ('Удалить', self.delete_record)]:
            widget = button(label, callback)
            self.record_buttons.append(widget)
            bottom.addWidget(widget)
        layout.addLayout(bottom)
        return page

    def _locations_page(self):
        page, layout = self._page('Локации', 'Привязывайте записи к местам на полигоне, чтобы подготовить раскладку материалов.')
        self.location_list = QListWidget()
        layout.addWidget(self.location_list)
        actions = QHBoxLayout()
        actions.addWidget(button('Добавить локацию', self.add_location, primary=True))
        actions.addWidget(button('Переименовать', self.rename_location))
        actions.addWidget(button('Удалить', self.delete_location))
        actions.addStretch()
        layout.addLayout(actions)
        return page

    def _export_page(self):
        page, layout = self._page('Экспорт для печати', 'Выгрузки включают все записи и сортируются по локации и названию.')
        layout.addWidget(QLabel('Excel: коды, названия, локации и типы материалов.'))
        layout.addWidget(button('Сохранить список .xlsx…', lambda: self.export('xlsx'), primary=True))
        layout.addSpacing(16)
        layout.addWidget(QLabel('PDF: 8 карточек на листе A4 с крупными пятизначными кодами.'))
        self.show_title = QCheckBox('Печатать название записи на карточке')
        self.show_location = QCheckBox('Печатать локацию на карточке')
        layout.addWidget(self.show_title)
        layout.addWidget(self.show_location)
        warning = QLabel('Названия и локации могут раскрыть сюжет. По умолчанию на карточке печатается только код.')
        warning.setWordWrap(True)
        warning.setObjectName('muted')
        layout.addWidget(warning)
        layout.addWidget(button('Сохранить карточки .pdf…', lambda: self.export('pdf'), primary=True))
        layout.addStretch()
        return page

    def _builds_page(self):
        page, layout = self._page('Сборки и версии', 'Игровой пакет содержит записи и медиа для автономного просмотра. Каждый экспорт создаёт новую версию.')
        actions = QHBoxLayout()
        actions.addWidget(button('Создать .rpgpack…', lambda: self.export('rpgpack'), primary=True))
        actions.addWidget(button('Проверить пакет…', self.check_pack))
        actions.addWidget(button('Импортировать как проект…', self.import_pack))
        actions.addStretch()
        layout.addLayout(actions)
        self.build_table = table(['Версия', 'Создано', 'Файл'])
        layout.addWidget(self.build_table)
        caption = QLabel('Импорт создаёт отдельную папку и не заменяет открытый проект. Мобильный клиент и сервер обновлений будут отдельным этапом.')
        caption.setWordWrap(True)
        caption.setObjectName('muted')
        layout.addWidget(caption)
        return page

    def _settings_page(self):
        page, layout = self._page('Настройки', 'Параметры мастерской на этом компьютере.')
        self.restore_last = QCheckBox('Открывать последний проект при запуске')
        self.restore_last.setChecked(self.settings.value('restore_last', True, type=bool))
        self.restore_last.toggled.connect(lambda checked: self.settings.setValue('restore_last', checked))
        layout.addWidget(self.restore_last)
        note = QLabel('LARP Studio 0.1\nЯзык: русский\nДиапазон кодов: 10000–99999\nКоды удалённых записей сохраняются в резерве.\n\nДля резервного копирования используйте «Создать копию проекта».')
        note.setWordWrap(True)
        layout.addWidget(note)
        layout.addStretch()
        return page

    def _menus(self):
        menu = self.menuBar().addMenu('Проект')
        for label, key, callback in [('Новый проект…', 'Ctrl+Shift+N', self.new_project),
                                     ('Открыть проект…', 'Ctrl+O', self.open_project),
                                     ('Новая запись', 'Ctrl+N', self.new_record),
                                     ('Импорт пакета…', '', self.import_pack)]:
            action = QAction(label, self)
            if key:
                action.setShortcut(QKeySequence(key))
            action.triggered.connect(callback)
            menu.addAction(action)
        menu.addSeparator()
        quit_action = menu.addAction('Выход')
        quit_action.triggered.connect(self.close)

    def _navigate(self, index):
        if 0 <= index < len(self.pages):
            self.stack.setCurrentWidget(self.pages[index])

    def _require_project(self):
        if self.project is None:
            self.navigation.setCurrentRow(0)
            self.statusBar().showMessage('Сначала создайте или откройте проект.', 6000)
            return False
        return True

    def _error(self, exc):
        QMessageBox.warning(self, 'Не удалось выполнить действие', str(exc))

    def _switch(self, project):
        if self.project and self.project is not project:
            self.project.close()
        self.project = project
        self.settings.setValue('last_project', str(project.path))
        self.refresh()
        self.navigation.setCurrentRow(1)

    def refresh(self):
        self.project_form.setEnabled(self.project is not None)
        if self.project:
            info = self.project.info
            self.setWindowTitle(info['name'] + ' — LARP Studio')
            self.project_name.setText(info['name'])
            self.project_description.setPlainText(info['description'])
            self.project_path.setText(str(self.project.path))
            self.statusBar().showMessage('Изменения записей сохраняются в проекте после нажатия «Сохранить запись».')
        else:
            self.setWindowTitle('LARP Studio — мастерская ролевых игр')
            self.project_name.clear()
            self.project_description.clear()
            self.project_path.setText('Проект не открыт')
        selected_location = self.location_filter.currentData() if self.location_filter.count() else 'all'
        self.location_filter.blockSignals(True)
        self.location_filter.clear()
        self.location_filter.addItem('Все локации', 'all')
        self.location_filter.addItem('Без локации', None)
        self.location_list.clear()
        if self.project:
            for loc in self.project.location_list():
                self.location_filter.addItem(loc['name'], loc['id'])
                self.location_list.addItem(loc['name'])
                self.location_list.item(self.location_list.count()-1).setData(Qt.ItemDataRole.UserRole, loc['id'])
        index = self.location_filter.findData(selected_location)
        self.location_filter.setCurrentIndex(index if index >= 0 else 0)
        self.location_filter.blockSignals(False)
        rows = self.project.records() if self.project else []
        self.table.setSortingEnabled(False)
        self.table.setRowCount(len(rows))
        for index, row in enumerate(rows):
            try:
                changed = datetime.fromisoformat(row['modified']).astimezone().strftime('%d.%m.%Y %H:%M')
            except ValueError:
                changed = row['modified']
            values = [row['code'], row['title'], row['location'] or 'Без локации', material_types(row) or 'Нет блоков', changed]
            for col, value in enumerate(values):
                item = QTableWidgetItem(value)
                item.setData(Qt.ItemDataRole.UserRole, row['id'])
                item.setData(Qt.ItemDataRole.UserRole + 1, row['location_id'])
                self.table.setItem(index, col, item)
        self.table.setSortingEnabled(True)
        self._filter()
        self._selection()
        history = self.project.build_list() if self.project else []
        self.build_table.setRowCount(len(history))
        for i, build in enumerate(history):
            for j, value in enumerate([str(build['version']), build['created'], build['filename']]):
                self.build_table.setItem(i, j, QTableWidgetItem(value))

    def _filter(self, *_):
        if not hasattr(self, 'table'):
            return
        query = self.search_edit.text().strip().casefold()
        location = self.location_filter.currentData()
        count = 0
        for i in range(self.table.rowCount()):
            code = self.table.item(i, 0)
            if code is None:
                continue
            matches = query in ' '.join(self.table.item(i, c).text() for c in (0, 1, 2)).casefold()
            matches = matches and (location == 'all' or code.data(Qt.ItemDataRole.UserRole + 1) == location)
            self.table.setRowHidden(i, not matches)
            count += bool(matches)
        if hasattr(self, 'count_label'):
            self.count_label.setText(f'Показано {count} из {self.table.rowCount()}')
        if self.table.currentRow() >= 0 and self.table.isRowHidden(self.table.currentRow()):
            self.table.clearSelection()
        self._selection()

    def visible_records(self):
        return [self.table.item(i, 0).data(Qt.ItemDataRole.UserRole) for i in range(self.table.rowCount()) if not self.table.isRowHidden(i)]

    def selected_id(self):
        selected = self.table.selectionModel().selectedRows()
        if selected:
            return self.table.item(selected[0].row(), 0).data(Qt.ItemDataRole.UserRole)
        return None

    def _selection(self):
        if hasattr(self, 'record_buttons'):
            for widget in self.record_buttons:
                widget.setEnabled(self.selected_id() is not None)

    def new_project(self):
        name, accepted = QInputDialog.getText(self, 'Новый проект', 'Название игры:')
        if not accepted or not name.strip():
            return
        parent = QFileDialog.getExistingDirectory(self, 'Выберите папку, в которой создать проект')
        if parent:
            safe_name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', name.strip()).rstrip('. ')
            try:
                if not safe_name or safe_name in ('.', '..'):
                    raise ProjectError('Выберите обычное название игры.')
                self._switch(Project.create(Path(parent) / safe_name, name))
            except (ProjectError, OSError) as exc:
                self._error(exc)

    def open_project(self):
        directory = QFileDialog.getExistingDirectory(self, 'Открыть папку проекта')
        if directory:
            try:
                self._switch(Project.open(Path(directory)))
            except ProjectError as exc:
                self._error(exc)

    def save_info(self):
        if self._require_project():
            try:
                self.project.update_info(self.project_name.text(), self.project_description.toPlainText())
                self.refresh()
                self.statusBar().showMessage('Параметры проекта сохранены.', 5000)
            except ProjectError as exc:
                self._error(exc)

    def copy_project(self):
        if not self._require_project():
            return
        target, _ = QFileDialog.getSaveFileName(self, 'Путь новой папки копии', str(self.project.path) + ' — копия')
        if target:
            try:
                self._switch(self.project.copy_to(Path(target)))
            except ProjectError as exc:
                self._error(exc)

    def delete_project(self):
        if not self._require_project():
            return
        path = self.project.path
        answer = QMessageBox.question(self, 'Удалить проект?', f'Будет удалена вся папка вместе с базой и медиафайлами:\n{path}\n\nЭто действие нельзя отменить. Создайте копию, если материалы ещё нужны.',
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No, QMessageBox.StandardButton.No)
        if answer == QMessageBox.StandardButton.Yes:
            self.project.close()
            self.project = None
            try:
                shutil.rmtree(path)
                self.settings.remove('last_project')
            except OSError as exc:
                self._error(exc)
            self.refresh()
            self.navigation.setCurrentRow(0)

    def new_record(self):
        if self._require_project():
            editor = RecordEditor(self.project, parent=self)
            if editor.exec():
                self.refresh()

    def edit_record(self):
        record_id = self.selected_id()
        if self.project and record_id:
            editor = RecordEditor(self.project, record_id, self)
            if editor.exec():
                self.refresh()

    def copy_code(self):
        if self.project and self.selected_id():
            QApplication.clipboard().setText(self.project.record(self.selected_id())['code'])
            self.statusBar().showMessage('Код скопирован.', 4000)

    def preview_record(self):
        if self.project and self.selected_id():
            row = self.project.record(self.selected_id())
            PreviewDialog(self.project, row['blocks'], row['title'], self).exec()

    def delete_record(self):
        if not self.project or not self.selected_id():
            return
        row = self.project.record(self.selected_id())
        answer = QMessageBox.question(self, 'Удалить запись?', f'Удалить «{row["title"]}»?\nКод {row["code"]} останется в резерве и не будет выдан повторно.',
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No, QMessageBox.StandardButton.No)
        if answer == QMessageBox.StandardButton.Yes:
            try:
                self.project.delete_record(row['id'])
                self.refresh()
            except ProjectError as exc:
                self._error(exc)

    def add_location(self):
        if self._require_project():
            name, ok = QInputDialog.getText(self, 'Новая локация', 'Название:')
            if ok:
                try:
                    self.project.add_location(name)
                    self.refresh()
                except ProjectError as exc:
                    self._error(exc)

    def rename_location(self):
        item = self.location_list.currentItem()
        if self.project and item:
            name, ok = QInputDialog.getText(self, 'Переименовать локацию', 'Название:', text=item.text())
            if ok:
                try:
                    self.project.rename_location(item.data(Qt.ItemDataRole.UserRole), name)
                    self.refresh()
                except ProjectError as exc:
                    self._error(exc)

    def delete_location(self):
        item = self.location_list.currentItem()
        if self.project and item:
            answer = QMessageBox.question(self, 'Удалить локацию?', 'Записи сохранятся и перейдут в «Без локации». Продолжить?',
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No, QMessageBox.StandardButton.No)
            if answer == QMessageBox.StandardButton.Yes:
                try:
                    self.project.delete_location(item.data(Qt.ItemDataRole.UserRole))
                    self.refresh()
                except ProjectError as exc:
                    self._error(exc)

    def export(self, kind):
        if not self._require_project():
            return
        path, _ = QFileDialog.getSaveFileName(self, 'Сохранить экспорт', f'Игра.{kind}', f'Файлы (*.{kind})')
        if not path:
            return
        if not path.lower().endswith('.' + kind):
            path += '.' + kind
        QApplication.setOverrideCursor(Qt.CursorShape.WaitCursor)
        try:
            if kind == 'xlsx':
                export_xlsx(self.project, path)
            elif kind == 'pdf':
                export_pdf(self.project, path, show_title=self.show_title.isChecked(), show_location=self.show_location.isChecked())
            else:
                export_package(self.project, path)
            self.refresh()
            self.statusBar().showMessage('Файл сохранён: ' + path, 10000)
        except (ProjectError, OSError, ValueError) as exc:
            self._error(exc)
        finally:
            QApplication.restoreOverrideCursor()

    def check_pack(self):
        path, _ = QFileDialog.getOpenFileName(self, 'Проверить игровой пакет', '', 'Игровые пакеты (*.rpgpack)')
        if path:
            try:
                manifest = validate_package(path)
                QMessageBox.information(self, 'Пакет проверен', f'{manifest["game"]["name"]}\nВерсия {manifest["version"]}\nЗаписей: {len(manifest["records"])}\nВсе контрольные суммы совпадают.')
            except ProjectError as exc:
                self._error(exc)

    def import_pack(self):
        path, _ = QFileDialog.getOpenFileName(self, 'Импорт игрового пакета', '', 'Игровые пакеты (*.rpgpack)')
        if not path:
            return
        target, _ = QFileDialog.getSaveFileName(self, 'Путь новой папки для импортированного проекта', str(Path(path).with_suffix('')) + ' — проект')
        if target:
            try:
                self._switch(import_package(path, Path(target)))
            except (ProjectError, OSError) as exc:
                self._error(exc)

    def closeEvent(self, event):
        if self.project:
            self.settings.setValue('last_project', str(self.project.path))
            self.project.close()
        self.settings.sync()
        super().closeEvent(event)
