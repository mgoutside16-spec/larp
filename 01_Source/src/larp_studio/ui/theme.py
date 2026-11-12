from PySide6.QtGui import QFont

STYLE = '''
QWidget { color: #253448; font-family: 'Segoe UI', 'DejaVu Sans', sans-serif; font-size: 14px; }
QMainWindow, QDialog { background: #FAFBFD; }
QLabel#heading { font-size: 25px; font-weight: 600; }
QLabel#brand { font-size: 21px; font-weight: 700; color: #315EA8; padding: 12px 0; }
QLabel#muted { color: #66758A; }
QLabel#code { font-size: 28px; font-weight: 700; color: #315EA8; }
QLabel#error { color: #B33F45; }
QPushButton { background: white; border: 1px solid #CAD4E1; border-radius: 5px; padding: 8px 14px; }
QPushButton:hover { background: #EDF3FC; border-color: #315EA8; }
QPushButton:pressed { background: #DCE7F8; }
QPushButton:disabled { color: #9AA5B4; border-color: #E1E7EF; }
QPushButton#primary { background: #315EA8; color: white; border-color: #315EA8; font-weight: 600; }
QPushButton#primary:hover { background: #264F91; }
QPushButton#danger { color: #B33F45; }
QLineEdit, QTextEdit, QTextBrowser, QComboBox, QListWidget, QTableWidget {
 background: white; border: 1px solid #D7DFEA; border-radius: 4px; padding: 6px;
 selection-background-color: #DCE7F8; selection-color: #253448;
}
QLineEdit:focus, QTextEdit:focus, QComboBox:focus { border: 1px solid #315EA8; }
QHeaderView::section { background: #EDF1F7; border: none; padding: 10px; font-weight: 600; text-align: left; }
QTableWidget { gridline-color: #EDF1F7; alternate-background-color: #F7F9FC; }
QListWidget#navigation { background: #EEF2F8; border: 0; padding: 6px; }
QListWidget#navigation::item { padding: 13px 8px; border-radius: 5px; margin: 2px 0; }
QListWidget#navigation::item:selected { background: #D8E4F6; color: #214B88; font-weight: 600; }
QStatusBar { background: #EEF2F8; color: #66758A; }
QSplitter::handle { background: #E1E7EF; width: 1px; }
QCheckBox { padding: 6px 0; }
'''


def apply_theme(app):
    app.setFont(QFont('Segoe UI', 10))
    app.setStyle('Fusion')
    app.setStyleSheet(STYLE)
