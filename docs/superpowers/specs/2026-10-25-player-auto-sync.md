# Автоматическая загрузка игрока и персонажи

Основание: пользователь получил пустую библиотеку APK0.4, ожидал автоматической
загрузки всех проектов, а не ручного импорта/публикации. Новое обязательное течение:
выбор проекта → имя персонажа → цифровой ввод/поиск. В мастерской список игроков.

## Причина

UpdateClient проверял только уже установленные игры по известному UUID;
_PlayerHome._checkUpdates обходил пустой локальный список, поэтому сервер вообще
не запрашивался. Материал, просто сохранённый мастером, не создавал player_release.
Исправить оба разрыва, а не только кнопку/текст пустой библиотеки.

## Решение

Добавочная backend/player-auto-sync.sql. Все active-проекты автоматически доступны
игрокам через каталог и снимки игровых данных. Приватные таблицы мастерской,
профили/роли/печатные шаблоны не открываются. Игровые материалы и коды уже входят
в передаваемые игрокам .rpgpack; здесь пользователь явно запросил автоматический
доступ ко всем проектам. Ручная публикация не требуется. Каталог обновляется при
запуске, resume и раз в20сек в foreground. Скачивание и установка автоматические,
с понятным постоянным прогрессом/ошибками и сохранением офлайн-копий при сбое.
Ручной .rpgpack и старый ссылочный протокол сохраняются.

### Серверные интерфейсы

workshop_projects.player_version bigint — независимая монотонная версия игрового
содержимого. BEFORE-триггер на запись повышает её при изменении данных игрока;
игнорирует изменения одних печатных шаблонов/служебной истории. Начальное значение
не меньше document.version, revision и прежнего опубликованного номера. Если
мастер экспортирует .rpgpack, version = max(document.version+1, player_version+1),
при сохранении документа триггер поднимает player_version до той же версии.
Storage.playerVersion(id) локально возвращает game.version; CloudStorage запрашивает
get_player_source_version(p_project_id uuid), доступный своим/общим мастерам.

player_auto_sources привязывает gameUUID к исходному projectUUID. Сначала
привязываются прежние публикации, затем active-проекты в порядке создания.
Импорт той же gameUUID не перехватывает опубликованную игру; независимая копия
имеет новую gameUUID. Привязка сохраняется как tombstone после удаления проекта.

RPC get_player_catalog(p_after uuid default null,p_limit integer default100)
returns JSON array объектов {game_id,project_id,name,description,version,
record_count,updated_at}, сортировка game_id, limit≤200. Анонимный клиент листает
до конца, не ограничивает молча число проектов. Все active, включая пустые.

RPC get_player_snapshot(p_game_id uuid) -> null либо:
{game_id,project_id,version,manifest,files:[{path,storage_path,size,sha256}]}
manifest — обычный .rpgpackv1: format_version,version,created,game,locations,records
(без revision),reserved_codes,checksums. checksum для media/SHA256.ext извлекается
из имени; для старых обычных имён может быть null и вычисляется телефоном после
TLS-загрузки. files содержит только медиа записей, без печатных шаблонов.
storage_path = projectUUID/media/file. Доступ к чтению workshop-media анонимно
только GET текущих referenced-файлов привязанного active-проекта, без listing/
изменения/чтения неигровых файлов. Метаданные size и наличие всех файлов проверяются.

### Персонажи

RPC register_player(p_game_id uuid,p_character_name text,p_token text) ->
{participant_id,character_name,first_seen,last_seen}. Token — случайный секрет
32bytes на устройстве отдельно для каждой игры; сервер хранит SHA256, не оригинал.
Имя1..100символов, без управляющих. Upsert по(game_id,token_hash), изменение имени
не плодит дубликаты. Анонимный пользователь не может перечислить участников.
RPC list_game_players(p_project_id uuid) -> JSON array таких объектов;
только master can_access проекта/админ. Список показывает персонажа и последнюю
связь, не утверждает достоверный realtime-online статус офлайн-игрока.

PlayerStore SQLite schema2 добавляет profiles, не меняя games/security/history.
PlayerProfile(gameId,characterName,token,pending). Методы:
playerProfile(gameId) -> PlayerProfile?;
playerProfiles() -> List<PlayerProfile>;
savePlayerProfile(gameId,name) -> PlayerProfile (сохраняет существующий token);
markPlayerRegistered(gameId,token,name) -> void (снимает pending только при совпадении).
Имя/проект не сбрасывают блокировку или историю. Офлайн профиль сохраняется сразу,
регистрация отправляется при связи; heartbeat только выбранной игре, pending
отправляются по всем сохранённым профилям. Никакой авторизации/пароля игрока.

### Телефон

UpdateClient получает catalog/snapshot через HTTPS/publickey, identity encoding
(обход Android native wrapped-zlib bug). Снимок + неизменяемые медиа скачиваются
потоково во временную папку; повторно используются проверенные файлы установленной
версии по SHA. Для legacy filename без checksum загружается заново. Собирается
потоковый ZIP без сжатия и вызывается существующий guarded installPackage,
ожидаемый UUID/версия проверяются до atomicSQLite switch. Неверный снимок, потеря
сети, нехватка места сохраняют старую игру/историю/блокировку. Удаление серверного
проекта не удаляет его офлайн-копию автоматически.

API UpdateClient: catalog()->List<CatalogGame>, syncGame(CatalogGame,{onProgress})
->InstalledGame? (null уже актуален), registerProfile(PlayerProfile)->void.
CatalogGame(gameId,projectId,name,description,version,recordCount,updatedAt).
Существующие check/install для архивных публикаций остаются. UI владеет циклом
синхронизации и регистрацией, передаёт selected-profile heartbeat.

## Проверка

RED до реализации: пустой чистый телефон сам получает проект/материал без UUID,
файла и Publish; изменения мастера повышают syncversion и сами приходят;
ручной пакет после автосинхронизации тоже устанавливается; SQLitev1→v2 сохраняет
старые данные; имя/смена проекта не снимают lock; pending registration уходит при
восстановлении связи; мастер видит только игроков доступного проекта.
Настоящие PostgreSQL, SQLite, HTTP, Chromium и Android. После добавочной миграции
проверить РЕАЛЬНЫЙ пользовательский проект по publicAPI (без печати сна/спойлеров)
и реальную установку на Android, затем отключить сеть и снова открыть материал.
Новый APK ставится поверх0.4 тем же ключом (versionCode5), без удаления приложения.

## Уточнение после проверки настоящего Storage

Контекстные operation/method/path-проверки не сработали в размещённом Storage.
Финальные player SELECT политики проверяют только активную каноническую связь
медиа/текущую публикацию. Метаданные и подписанные ссылки этих уже публичных
игровых файлов доступны; print/unreferenced/staged, аккаунты и запись закрыты.
Это заменяет первоначальное внутреннее ограничение listing, не требовавшееся
пользователем, и не расширяет перечень доступных игровых материалов.
