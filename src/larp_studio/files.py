"""Replace output files only after successful, complete generation."""
from contextlib import contextmanager
import os
from pathlib import Path
import shutil
import tempfile

from .project import ProjectError


@contextmanager
def preserve_output_on_error(destination):
    """Keep a recovery copy until both file replacement and DB commit succeed.

    A process interruption leaves the sibling .larp-recovery file available for
    manual recovery. Handled errors restore the previous output automatically.
    """
    destination = Path(destination)
    backup = None
    keep_backup = False
    existed = destination.exists()
    try:
        if existed:
            fd, name = tempfile.mkstemp(prefix=f'.{destination.name}.larp-recovery-', dir=destination.parent)
            os.close(fd)
            backup = Path(name)
            backup.unlink()
            try:
                os.link(destination, backup)
            except OSError:
                shutil.copyfile(destination, backup)
        try:
            yield
        except BaseException:
            try:
                if backup:
                    backup.replace(destination)
                elif not existed:
                    destination.unlink(missing_ok=True)
            except OSError as exc:
                keep_backup = True
                raise ProjectError(f'Не удалось восстановить предыдущий экспорт. Копия для восстановления: {backup}') from exc
            raise
    except OSError as exc:
        raise ProjectError('Не удалось подготовить резервную копию экспорта. Проверьте доступ к папке.') from exc
    finally:
        if backup and not keep_backup:
            backup.unlink(missing_ok=True)


@contextmanager
def atomic_output(destination):
    destination = Path(destination)
    temp = None
    try:
        fd, name = tempfile.mkstemp(prefix=f'.{destination.name}.', suffix='.tmp', dir=destination.parent)
        os.close(fd)
        temp = Path(name)
        yield temp
        with temp.open('rb') as stream:
            os.fsync(stream.fileno())
        temp.replace(destination)
    except OSError as exc:
        raise ProjectError('Не удалось записать файл. Проверьте свободное место и закройте файл в других программах.') from exc
    finally:
        if temp is not None:
            temp.unlink(missing_ok=True)
