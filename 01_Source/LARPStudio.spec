# Run on Windows to obtain a Windows executable; PyInstaller is not a cross-compiler.
from pathlib import Path

root = Path(SPECPATH)
a = Analysis(
    [str(root / 'launch.py')],
    pathex=[str(root / 'src')],
    binaries=[],
    datas=[(str(root / 'src' / 'larp_studio' / 'assets'), 'larp_studio/assets')],
    hiddenimports=['sqlalchemy.dialects.sqlite'],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tkinter', 'matplotlib', 'numpy', 'pandas', 'IPython', 'pytest'],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='LARP Studio',
          debug=False, bootloader_ignore_signals=False, strip=False, upx=False,
          console=False, disable_windowed_traceback=False)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name='LARP Studio')
