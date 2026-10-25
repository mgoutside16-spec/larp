import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import '../core/models.dart';
import '../core/player_store.dart';
import 'player_image.dart';

/// Preserve only the package's passive text vocabulary. No attributes, links,
/// external resources or embedded players survive this boundary.
String safePlayerHtml(String source) {
  final fragment = parser.parseFragment(source);
  const allowed = {
    'p',
    'br',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'b',
    'strong',
    'i',
    'em',
    'u',
    'ul',
    'ol',
    'li',
    'blockquote',
  };
  const discard = {
    'script',
    'style',
    'iframe',
    'object',
    'embed',
    'svg',
    'math',
    'template',
  };
  final output = dom.DocumentFragment();
  void append(dom.Node source, dom.Node target) {
    if (source is dom.Text) {
      target.nodes.add(dom.Text(source.data));
      return;
    }
    if (source is! dom.Element || discard.contains(source.localName)) return;
    if (source.localName == 'span') {
      final style = <String, String>{};
      for (final declaration in (source.attributes['style'] ?? '').split(';')) {
        final colon = declaration.indexOf(':');
        if (colon > 0) {
          style[declaration.substring(0, colon).trim().toLowerCase()] =
              declaration.substring(colon + 1).trim().toLowerCase();
        }
      }
      var destination = target;
      if (style['font-weight'] == 'bold' ||
          (int.tryParse(style['font-weight'] ?? '') ?? 0) >= 600) {
        final bold = dom.Element.tag('b');
        destination.nodes.add(bold);
        destination = bold;
      }
      if (style['font-style'] == 'italic') {
        final italic = dom.Element.tag('i');
        destination.nodes.add(italic);
        destination = italic;
      }
      for (final node in source.nodes) {
        append(node, destination);
      }
    } else if (allowed.contains(source.localName) ||
        source.localName == 'div') {
      final clean = dom.Element.tag(
        source.localName == 'div' ? 'p' : source.localName,
      );
      target.nodes.add(clean);
      for (final node in source.nodes) {
        append(node, clean);
      }
    } else {
      for (final node in source.nodes) {
        append(node, target);
      }
    }
  }

  for (final node in fragment.nodes) {
    append(node, output);
  }
  return output.outerHtml;
}

class RecordReader extends StatelessWidget {
  const RecordReader({
    super.key,
    required this.store,
    required this.game,
    required this.record,
  });
  final PlayerStore store;
  final InstalledGame game;
  final PlayerRecord record;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(record.title)),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
            children: [
              if (record.groupName != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    record.groupName!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              for (var i = 0; i < record.blocks.length; i++)
                Padding(
                  key: ValueKey('block-$i'),
                  padding: const EdgeInsets.only(bottom: 24),
                  child: _ContentView(
                    store: store,
                    gameId: game.id,
                    recordId: record.id,
                    block: record.blocks[i],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ContentView extends StatefulWidget {
  const _ContentView({
    required this.store,
    required this.gameId,
    required this.recordId,
    required this.block,
  });
  final PlayerStore store;
  final String gameId;
  final String recordId;
  final ContentBlock block;
  @override
  State<_ContentView> createState() => _ContentViewState();
}

class _ContentViewState extends State<_ContentView> {
  Future<File>? _file;
  @override
  void initState() {
    super.initState();
    if (widget.block.kind != 'text') {
      _file = widget.store.mediaFile(
        widget.gameId,
        widget.block.value,
        recordId: widget.recordId,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    if (block.kind == 'text') {
      return HtmlWidget(
        safePlayerHtml(block.value),
        textStyle: Theme.of(context).textTheme.bodyLarge,
        onTapUrl: (_) => true,
      );
    }
    return FutureBuilder<File>(
      future: _file,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _MediaError(
            'Не удалось открыть файл материала. Попробуйте обновить пакет игры.',
          );
        }
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final file = snapshot.data!;
        return switch (block.kind) {
          'image' => _LocalImage(file: file),
          'audio' => _LocalAudio(file: file),
          'video' => _LocalVideo(file: file),
          _ => const _MediaError('Этот тип материала не поддерживается.'),
        };
      },
    );
  }
}

class _LocalImage extends StatelessWidget {
  const _LocalImage({required this.file});
  final File file;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Изображение. Нажмите, чтобы увеличить.',
    button: true,
    child: InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('Изображение')),
            body: Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 8,
                child: Image(
                  image: PlayerImageProvider.file(file),
                  errorBuilder: (_, _, _) =>
                      const _MediaError('Не удалось показать изображение.'),
                ),
              ),
            ),
          ),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image(
          image: PlayerImageProvider.file(file),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) =>
              const _MediaError('Не удалось показать изображение.'),
        ),
      ),
    ),
  );
}

class _LocalAudio extends StatefulWidget {
  const _LocalAudio({required this.file});
  final File file;
  @override
  State<_LocalAudio> createState() => _LocalAudioState();
}

class _LocalAudioState extends State<_LocalAudio> with WidgetsBindingObserver {
  final AudioPlayer _player = AudioPlayer();
  bool _ready = false;
  String? _error;
  StreamSubscription<PlayerState>? _stateSubscription;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stateSubscription = _player.playerStateStream.listen(
      (state) {
        if (state.processingState == ProcessingState.completed) {
          unawaited(_player.pause());
          unawaited(_player.seek(Duration.zero));
        }
      },
      onError: (Object error) {
        if (mounted) setState(() => _error = 'Не удалось воспроизвести аудио.');
      },
    );
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _player.setFilePath(widget.file.path);
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Не удалось открыть аудио. Формат может не поддерживаться устройством.',
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_player.pause());
  }

  @override
  void deactivate() {
    unawaited(_player.pause());
    super.deactivate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stateSubscription?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (_player.playing) {
        await _player.pause();
      } else {
        await _player.play();
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось воспроизвести аудио.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _MediaError(_error!);
    return _MediaPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Аудио', style: TextStyle(fontWeight: FontWeight.w600)),
          StreamBuilder<PlayerState>(
            stream: _player.playerStateStream,
            builder: (context, state) => Row(
              children: [
                IconButton.filled(
                  tooltip: state.data?.playing == true ? 'Пауза' : 'Слушать',
                  onPressed: _ready ? _toggle : null,
                  icon: Icon(
                    state.data?.playing == true
                        ? Icons.pause
                        : Icons.play_arrow,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ready
                      ? StreamBuilder<Duration>(
                          stream: _player.positionStream,
                          builder: (context, position) {
                            final duration = _player.duration ?? Duration.zero;
                            final current = position.data ?? Duration.zero;
                            return Column(
                              children: [
                                Slider(
                                  semanticFormatterCallback: (value) =>
                                      '${value.round()} секунд',
                                  value: current.inMilliseconds
                                      .toDouble()
                                      .clamp(
                                        0,
                                        duration.inMilliseconds.toDouble(),
                                      ),
                                  max: duration.inMilliseconds > 0
                                      ? duration.inMilliseconds.toDouble()
                                      : 1,
                                  onChanged: duration.inMilliseconds > 0
                                      ? (value) => unawaited(
                                          _player.seek(
                                            Duration(
                                              milliseconds: value.round(),
                                            ),
                                          ),
                                        )
                                      : null,
                                ),
                                Text('${_time(current)} / ${_time(duration)}'),
                              ],
                            );
                          },
                        )
                      : const LinearProgressIndicator(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LocalVideo extends StatefulWidget {
  const _LocalVideo({required this.file});
  final File file;
  @override
  State<_LocalVideo> createState() => _LocalVideoState();
}

class _LocalVideoState extends State<_LocalVideo> with WidgetsBindingObserver {
  late final VideoPlayerController _player;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player = VideoPlayerController.file(widget.file);
    _player.addListener(_changed);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _player.initialize();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Не удалось открыть видео. Формат может не поддерживаться устройством.',
        );
      }
    }
  }

  void _changed() {
    if (mounted) {
      setState(() {
        if (_player.value.hasError) _error = 'Не удалось воспроизвести видео.';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_player.pause());
  }

  @override
  void deactivate() {
    unawaited(_player.pause());
    super.deactivate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _player.removeListener(_changed);
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (_player.value.isPlaying) {
        await _player.pause();
      } else {
        if (_player.value.position >= _player.value.duration) {
          await _player.seekTo(Duration.zero);
        }
        await _player.play();
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось воспроизвести видео.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _MediaError(_error!);
    if (!_player.value.isInitialized) {
      return const _MediaPanel(child: LinearProgressIndicator());
    }
    final value = _player.value;
    return _MediaPanel(
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: value.aspectRatio > 0 ? value.aspectRatio : 16 / 9,
            child: ClipRect(child: VideoPlayer(_player)),
          ),
          Row(
            children: [
              IconButton.filled(
                tooltip: value.isPlaying ? 'Пауза' : 'Смотреть',
                onPressed: _toggle,
                icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: VideoProgressIndicator(
                  _player,
                  allowScrubbing: true,
                  padding: const EdgeInsets.symmetric(vertical: 20),
                ),
              ),
            ],
          ),
          Text('${_time(value.position)} / ${_time(value.duration)}'),
        ],
      ),
    );
  }
}

class _MediaPanel extends StatelessWidget {
  const _MediaPanel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
    ),
    child: child,
  );
}

class _MediaError extends StatelessWidget {
  const _MediaError(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => _MediaPanel(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.warning_amber_rounded),
        const SizedBox(width: 12),
        Expanded(child: Text(message)),
      ],
    ),
  );
}

String _time(Duration value) =>
    '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
