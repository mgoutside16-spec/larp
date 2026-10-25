import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/player_store.dart';
import '../core/update_client.dart';
import 'record_reader.dart';
import 'player_image.dart';

const _ink = Color(0xff18191c);
const _paper = Color(0xfff0ece3);
const _crimson = Color(0xffa93446);

final playerTheme = ThemeData(
  useMaterial3: true,
  fontFamily: 'Roboto',
  brightness: Brightness.dark,
  scaffoldBackgroundColor: _ink,
  colorScheme: ColorScheme.fromSeed(
    seedColor: _crimson,
    brightness: Brightness.dark,
    primary: const Color(0xffe8a2ad),
    surface: const Color(0xff242529),
    onSurface: _paper,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: _ink,
    foregroundColor: _paper,
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(48, 54),
      backgroundColor: _crimson,
      foregroundColor: Colors.white,
      textStyle: const TextStyle(
        fontFamily: 'Roboto',
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 52),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  textTheme: const TextTheme(
    bodyLarge: TextStyle(fontSize: 18, height: 1.55),
    bodyMedium: TextStyle(fontSize: 16, height: 1.45),
    headlineMedium: TextStyle(
      fontSize: 30,
      fontWeight: FontWeight.w600,
      height: 1.2,
    ),
  ),
);

String playerError(Object error) => error is PlayerException
    ? error.message
    : 'Не удалось выполнить действие. Попробуйте ещё раз.';

class PlayerApp extends StatelessWidget {
  const PlayerApp({super.key, required this.store, this.updates});
  final PlayerStore store;
  final UpdateClient? updates;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Без правил',
    debugShowCheckedModeBanner: false,
    theme: playerTheme,
    home: _PlayerHome(store: store, updates: updates),
  );
}

class _PlayerHome extends StatefulWidget {
  const _PlayerHome({required this.store, this.updates});
  final PlayerStore store;
  final UpdateClient? updates;
  @override
  State<_PlayerHome> createState() => _PlayerHomeState();
}

class _PlayerHomeState extends State<_PlayerHome> with WidgetsBindingObserver {
  List<InstalledGame>? _games;
  InstalledGame? _game;
  List<PlayerRecord> _history = [];
  final Map<String, PlayerRelease> _releases = {};
  String _code = '';
  String? _message;
  String? _libraryError;
  bool _busy = false;
  bool _checking = false;
  double? _progress;
  int _tab = 0;
  LookupResult? _lock;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadGames().then((_) => _checkUpdates()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_game != null) unawaited(_refreshGame());
      unawaited(_checkUpdates());
    }
  }

  Future<void> _loadGames() async {
    try {
      final games = await widget.store.games();
      if (!mounted) return;
      setState(() {
        _games = games;
        _libraryError = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _games = [];
          _libraryError = playerError(e);
        });
      }
    }
  }

  Future<void> _refreshGame() async {
    final game = _game;
    if (game == null) return;
    try {
      final lock = await widget.store.lockState(game.id);
      final history = await widget.store.history(game.id);
      if (!mounted || _game?.id != game.id) return;
      setState(() {
        _lock = lock;
        _history = history;
      });
      _timer?.cancel();
      if (lock.lockedUntil != null) {
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted) return;
          if (DateTime.now().isAfter(lock.lockedUntil!)) {
            _timer?.cancel();
            unawaited(_refreshGame());
          } else {
            setState(() {});
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _message = playerError(e));
    }
  }

  Future<void> _openGame(InstalledGame game) async {
    _timer?.cancel();
    setState(() {
      _game = game;
      _tab = 0;
      _code = '';
      _message = null;
      _lock = null;
      _history = [];
    });
    await _refreshGame();
  }

  Future<void> _checkUpdates({bool explicit = false}) async {
    if (!mounted) return;
    if (_checking || widget.updates == null) {
      if (explicit && widget.updates == null) {
        _notice(
          'Онлайн-обновления не настроены. Можно импортировать .rpgpack.',
        );
      }
      return;
    }
    setState(() => _checking = true);
    String? failure;
    for (final game in List<InstalledGame>.of(_games ?? [])) {
      try {
        final release = await widget.updates!.check(game.id);
        if (!mounted) return;
        setState(() {
          if (release == null) {
            _releases.remove(game.id);
          } else {
            _releases[game.id] = release;
          }
        });
      } catch (e) {
        failure = playerError(e);
      }
    }
    if (!mounted) return;
    setState(() => _checking = false);
    if (explicit) {
      _notice(
        failure ??
            (_releases.isEmpty
                ? 'Установлены последние версии.'
                : 'Доступны новые версии игр.'),
      );
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _import() async {
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['rpgpack'],
        allowMultiple: false,
      );
      if (!mounted || selection == null) return;
      final path = selection.files.single.path;
      if (path == null) {
        throw PlayerException(
          'Не удалось прочитать файл. Выберите пакет из хранилища устройства.',
        );
      }
      setState(() {
        _busy = true;
        _progress = null;
      });
      final game = await widget.store.installPackage(File(path));
      await _installed(game);
    } catch (e) {
      _notice(playerError(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _installed(InstalledGame game) async {
    await _loadGames();
    if (!mounted) return;
    setState(() {
      _releases.remove(game.id);
      if (_game?.id == game.id) _game = game;
    });
    if (_game?.id == game.id) await _refreshGame();
    _notice('«${game.name}»: установлена версия ${game.version}.');
  }

  Future<void> _installRelease(PlayerRelease release) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _progress = 0;
    });
    try {
      final game = await widget.updates!.install(
        release,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress.clamp(0, 1));
        },
      );
      await _installed(game);
    } catch (e) {
      _notice(playerError(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _addOnline() async {
    if (widget.updates == null) {
      _notice('Онлайн-обновления не настроены. Можно импортировать .rpgpack.');
      return;
    }
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Добавить игру'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Вставьте ссылку от мастера или идентификатор игры.'),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Ссылка или UUID',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (value) => Navigator.pop(context, value),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Найти'),
          ),
        ],
      ),
    );
    // The route can still be finishing its dismissal animation.
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    if (input == null || !mounted) return;
    final String id;
    try {
      id = parseGameReference(input);
    } catch (e) {
      _notice(playerError(e));
      return;
    }
    setState(() {
      _busy = true;
      _progress = null;
    });
    PlayerRelease? release;
    try {
      release = await widget.updates!.check(id);
    } catch (e) {
      _notice(playerError(e));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (release == null) {
      _notice(
        'Новая опубликованная версия не найдена. Проверьте ссылку у мастера.',
      );
      return;
    }
    final result = release;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(result.name),
        content: Text(
          'Версия ${result.version}\nРазмер: ${_fileSize(result.size)}\n\nЗагрузить игру на устройство?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Загрузить'),
          ),
        ],
      ),
    );
    if (approved == true && mounted) await _installRelease(result);
  }

  Future<void> _lookup() async {
    final game = _game;
    if (game == null || _code.length != 5 || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await widget.store.lookup(game.id, _code);
      if (!mounted || _game?.id != game.id) return;
      setState(() {
        _code = '';
        _lock = result;
        _message = switch (result.status) {
          LookupStatus.wrong =>
            'Код не найден. Осталось попыток: ${3 - result.wrongAttempts}.',
          LookupStatus.invalid => 'Введите пять цифр.',
          _ => null,
        };
      });
      await _refreshGame();
      if (result.status == LookupStatus.opened &&
          result.record != null &&
          mounted &&
          _game?.id == game.id) {
        await _read(result.record!, game);
      }
    } catch (e) {
      if (mounted && _game?.id == game.id) {
        setState(() => _message = playerError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _read(PlayerRecord record, InstalledGame game) async {
    if (!mounted || _game?.id != game.id) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            RecordReader(store: widget.store, game: game, record: record),
      ),
    );
  }

  Future<void> _reopen(PlayerRecord record) async {
    final game = _game;
    if (game == null) return;
    try {
      final opened = await widget.store.openedRecord(game.id, record.id);
      if (mounted && opened != null && _game?.id == game.id) {
        await _read(opened, game);
      }
    } catch (e) {
      _notice(playerError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final game = _game;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          game?.name ?? 'Без правил',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: game == null
            ? null
            : IconButton(
                tooltip: 'Ваши игры',
                icon: const Icon(Icons.apps_rounded),
                onPressed: () {
                  _timer?.cancel();
                  setState(() {
                    _game = null;
                    _message = null;
                  });
                },
              ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_busy)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    LinearProgressIndicator(value: _progress),
                    if (_progress != null)
                      Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text('Загрузка: ${(_progress! * 100).round()}%'),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: game == null
                  ? _library()
                  : _tab == 0
                  ? _codeScreen()
                  : _historyScreen(),
            ),
          ],
        ),
      ),
      bottomNavigationBar: game == null
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (index) => setState(() => _tab = index),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.dialpad_rounded),
                  label: 'Код',
                ),
                NavigationDestination(
                  icon: Icon(Icons.history_rounded),
                  label: 'История',
                ),
              ],
            ),
    );
  }

  Widget _library() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Image(
              image: const PlayerImageProvider.asset('assets/bez-pravil.png'),
              width: 92,
              height: 92,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Icon(
                Icons.local_fire_department,
                size: 64,
                color: _crimson,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text('Ваши игры', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          if (_games == null) const Center(child: CircularProgressIndicator()),
          if (_libraryError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                _libraryError!,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          if (_games?.isEmpty == true)
            const Padding(
              padding: EdgeInsets.only(bottom: 24),
              child: Text(
                'Добавьте игру от мастера. После загрузки коды и все материалы доступны без интернета.',
              ),
            ),
          for (final game in _games ?? <InstalledGame>[]) ...[
            ListTile(
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              title: Text(
                game.name,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                'Версия ${game.version}${game.description.isEmpty ? '' : '\n${game.description}'}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openGame(game),
            ),
            if (_releases[game.id] case final release?)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _installRelease(release),
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    'Загрузить версию ${release.version} (${_fileSize(release.size)})',
                  ),
                ),
              ),
            const Divider(),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Импорт .rpgpack'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _addOnline,
            icon: const Icon(Icons.add_link),
            label: const Text('Добавить по ссылке'),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _checking ? null : () => _checkUpdates(explicit: true),
            icon: _checking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(
              _checking ? 'Проверяем версии…' : 'Проверить обновления',
            ),
          ),
        ],
      ),
    ),
  );

  Widget _codeScreen() {
    final until = _lock?.lockedUntil;
    final locked = until != null && until.isAfter(DateTime.now());
    final remaining = locked
        ? until.difference(DateTime.now()).inSeconds.clamp(0, 1800)
        : 0;
    final countdown =
        '${(remaining ~/ 60).toString().padLeft(2, '0')}:${(remaining % 60).toString().padLeft(2, '0')}';
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 390,
              minHeight: (constraints.maxHeight - 40).clamp(0, double.infinity),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Введите код',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  locked
                      ? 'Три неверных кода. Повторите через $countdown'
                      : 'Пять цифр с игровой карточки',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: locked
                        ? const Color(0xffffb5bd)
                        : const Color(0xffbbb8b2),
                  ),
                ),
                const SizedBox(height: 24),
                Semantics(
                  label: 'Введено ${_code.length} из пяти цифр',
                  child: Row(
                    children: [
                      for (var i = 0; i < 5; i++)
                        Expanded(
                          child: Container(
                            margin: EdgeInsets.only(right: i == 4 ? 0 : 8),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color: const Color(0xff242529),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: i == _code.length && !locked
                                    ? const Color(0xffe8a2ad)
                                    : const Color(0xff45454c),
                              ),
                            ),
                            child: Text(
                              i < _code.length ? _code[i] : '–',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      _message!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xffffb5bd)),
                    ),
                  ),
                const SizedBox(height: 20),
                for (final row in [
                  ['1', '2', '3'],
                  ['4', '5', '6'],
                  ['7', '8', '9'],
                  ['clear', '0', 'delete'],
                ])
                  Row(
                    children: [
                      for (final digit in row)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: SizedBox(
                              height: 58,
                              child: TextButton(
                                key: ValueKey('digit-$digit'),
                                onPressed: locked || _busy
                                    ? null
                                    : () => setState(() {
                                        if (digit == 'clear') {
                                          _code = '';
                                        } else if (digit == 'delete') {
                                          if (_code.isNotEmpty) {
                                            _code = _code.substring(
                                              0,
                                              _code.length - 1,
                                            );
                                          }
                                        } else if (_code.length < 5) {
                                          _code += digit;
                                        }
                                        _message = null;
                                      }),
                                child: digit == 'delete'
                                    ? Semantics(
                                        label: 'Удалить цифру',
                                        child: const Icon(
                                          Icons.backspace_outlined,
                                        ),
                                      )
                                    : digit == 'clear'
                                    ? const Text(
                                        'Сброс',
                                        style: TextStyle(fontSize: 14),
                                      )
                                    : Text(
                                        digit,
                                        style: const TextStyle(
                                          fontSize: 28,
                                          color: _paper,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: !locked && _code.length == 5 && !_busy
                        ? _lookup
                        : null,
                    child: const Text('Открыть материал'),
                  ),
                ),
                if (locked)
                  const Padding(
                    padding: EdgeInsets.only(top: 14),
                    child: Text(
                      'Открытые материалы доступны в истории.',
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _historyScreen() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: _history.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Здесь появятся открытые материалы. Их можно читать повторно без ограничений.',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _history.length,
              separatorBuilder: (_, _) => const Divider(),
              itemBuilder: (context, index) {
                final record = _history[index];
                return ListTile(
                  title: Text(record.title),
                  subtitle: Text(record.groupName ?? 'Открытый материал'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _reopen(record),
                );
              },
            ),
    ),
  );
}

String _fileSize(int size) => size < 1024 * 1024
    ? '${(size / 1024).ceil()} КБ'
    : '${(size / (1024 * 1024)).toStringAsFixed(1)} МБ';
