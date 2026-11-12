import os
import pytest

# Headless CI by default; a developer can explicitly select a native Qt platform.
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')


@pytest.fixture(autouse=True)
def isolated_settings(tmp_path, monkeypatch):
    monkeypatch.setenv('LARP_STUDIO_CONFIG_DIR', str(tmp_path / 'settings'))
