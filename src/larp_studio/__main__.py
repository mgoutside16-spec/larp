import argparse
from pathlib import Path
import sys

from PySide6.QtCore import QCoreApplication, QTimer
from PySide6.QtWidgets import QApplication, QMessageBox

from .project import Project, ProjectError
from .ui.main_window import MainWindow, app_settings
from .ui.theme import apply_theme


def main():
    parser = argparse.ArgumentParser(description='LARP Studio — мастерская ролевых игр')
    parser.add_argument('--project', type=Path, help='Папка игрового проекта')
    parser.add_argument('--smoke-test', action='store_true', help='Проверить запуск Qt и закрыть окно через 0,5 с')
    args = parser.parse_args()
    app = QApplication(sys.argv[:1])
    QCoreApplication.setOrganizationName('LARP Studio')
    QCoreApplication.setApplicationName('LARP Studio')
    apply_theme(app)
    settings = app_settings()
    path = args.project
    if path is None and not args.smoke_test and settings.value('restore_last', True, type=bool):
        last = settings.value('last_project', '')
        path = Path(last) if last else None
    project = None
    if path:
        try:
            project = Project.open(path)
        except ProjectError as exc:
            if args.smoke_test:
                print(str(exc), file=sys.stderr)
                return 1
            QMessageBox.warning(None, 'Проект не открыт', str(exc))
    window = MainWindow(project)
    window.show()
    if args.smoke_test:
        QTimer.singleShot(500, window.close)
    return app.exec()


if __name__ == '__main__':
    sys.exit(main())
