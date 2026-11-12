# Сборка программы для Windows

Собирается на Linux без Wine:

1. `cd web && npm ci && npm run build`, затем скопировать `web/dist` в `desktop/web`
   (без `config.json`, `play/`, `games/`).
2. Положить `ffmpeg.exe` для Windows в `desktop/bin/` (сборка b6.1.1 из
   github.com/eugeneware/ffmpeg-static, файл `ffmpeg-win32-x64.gz`) и его лицензию `ffmpeg.LICENSE`.
3. `cd desktop && npm ci && npx electron-builder --win dir --x64`.
4. `makensis installer.nsi` (NSIS из кеша electron-builder, с `LANG=C.UTF-8`) —
   готовый установщик появится в `desktop/release/`.

Ключ подписи Android хранится у владельца отдельно и в репозиторий не попадает.
