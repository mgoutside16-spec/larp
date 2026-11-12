from PySide6.QtCore import Qt, QUrl
from PySide6.QtGui import QPixmap
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
from PySide6.QtMultimediaWidgets import QVideoWidget
from PySide6.QtWidgets import (QDialog, QHBoxLayout, QLabel, QPushButton,
    QScrollArea, QSlider, QTextBrowser, QVBoxLayout, QWidget)

from .richtext import safe_html


class MediaPlayer(QWidget):
    def __init__(self, path, video=False, parent=None):
        super().__init__(parent)
        layout = QVBoxLayout(self)
        self.player = QMediaPlayer(self)
        self.audio = QAudioOutput(self)
        self.audio.setVolume(.8)
        self.player.setAudioOutput(self.audio)
        if video:
            screen = QVideoWidget(self)
            screen.setMinimumHeight(240)
            self.player.setVideoOutput(screen)
            layout.addWidget(screen)
        controls = QHBoxLayout()
        play = QPushButton('Воспроизвести')
        stop = QPushButton('Пауза')
        controls.addWidget(play)
        controls.addWidget(stop)
        self.slider = QSlider(Qt.Orientation.Horizontal)
        controls.addWidget(self.slider, 1)
        layout.addLayout(controls)
        self.error = QLabel()
        self.error.setObjectName('error')
        self.error.setWordWrap(True)
        layout.addWidget(self.error)
        play.clicked.connect(self.player.play)
        stop.clicked.connect(self.player.pause)
        self.player.durationChanged.connect(lambda duration: self.slider.setRange(0, int(duration)))
        self.player.positionChanged.connect(lambda position: self.slider.setValue(int(position)) if not self.slider.isSliderDown() else None)
        self.slider.sliderMoved.connect(self.player.setPosition)
        self.player.errorOccurred.connect(lambda *_: self.error.setText('Не удалось воспроизвести файл. Проверьте формат и доступные кодеки.'))
        self.player.setSource(QUrl.fromLocalFile(str(path)))

    def stop(self):
        self.player.stop()


class PreviewDialog(QDialog):
    def __init__(self, project, blocks, title='Предпросмотр', parent=None):
        super().__init__(parent)
        self.setWindowTitle('Просмотр игрока — ' + title)
        self.resize(720, 760)
        self.image_count = 0
        self.safe_html = ''
        self.players = []
        self.browsers = []
        root = QVBoxLayout(self)
        hint = QLabel('Просмотр игрока · блоки в порядке показа')
        hint.setObjectName('muted')
        root.addWidget(hint)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        content = QWidget()
        layout = QVBoxLayout(content)
        for block in blocks:
            if block['kind'] == 'text':
                browser = QTextBrowser()
                browser.setOpenExternalLinks(False)
                browser.setOpenLinks(False)
                value = safe_html(block['value'])
                self.safe_html += value
                browser.setHtml(value)
                browser.document().setTextWidth(620)
                browser.setMinimumHeight(min(600, max(100, int(browser.document().size().height() + 35))))
                self.browsers.append(browser)
                layout.addWidget(browser)
            else:
                path = project.media_path(block['value'])
                if not path.is_file():
                    label = QLabel('Медиафайл не найден: ' + path.name)
                    label.setObjectName('error')
                    label.setWordWrap(True)
                    layout.addWidget(label)
                elif block['kind'] == 'image':
                    label = QLabel()
                    label.setAlignment(Qt.AlignmentFlag.AlignCenter)
                    pixmap = QPixmap(str(path))
                    if pixmap.isNull():
                        label.setText('Не удалось открыть изображение: ' + path.name)
                    else:
                        label.setPixmap(pixmap.scaled(640, 500, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation))
                        self.image_count += 1
                    layout.addWidget(label)
                else:
                    player = MediaPlayer(path, video=block['kind'] == 'video')
                    self.players.append(player)
                    layout.addWidget(player)
        if not blocks:
            layout.addWidget(QLabel('В записи пока нет материалов.'))
        layout.addStretch()
        scroll.setWidget(content)
        root.addWidget(scroll)
        close = QPushButton('Закрыть')
        close.clicked.connect(self.accept)
        root.addWidget(close)
        self.finished.connect(lambda *_: [p.stop() for p in self.players])

    def text_content(self):
        return '\n'.join(b.toPlainText() for b in self.browsers)
