import 'dart:async';
import 'dart:math';

import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/src/components/overlay/dialog.dart'
    show showDialog;
import 'package:flutter/services.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/pages/dock/hub_more.dart';
import 'package:the_collector/pages/dock/hub_rules.dart';
import 'package:the_collector/utils/games/game_session.dart';
import 'package:the_collector/utils/games/game_preferences.dart';

enum GameSessionExit { newGame }

class GameSessionScreen extends StatefulWidget {
  const GameSessionScreen({
    super.key,
    required this.format,
    required this.players,
    this.sharedId,
    this.store,
    this.userId,
    this.resume = true,
  });
  final GameFormat format;
  final int players;
  final String? sharedId;
  final SharedGameStore? store;
  final String? userId;
  final bool resume;
  @override
  State<GameSessionScreen> createState() => _GameSessionScreenState();
}

class _GameSessionScreenState extends State<GameSessionScreen> {
  late final SharedGameStore _store = widget.store ?? SharedGameStore();
  late final String _userId = widget.userId ?? u;
  late GameSession _local = GameSession(
    id: '',
    ownerId: _userId,
    format: widget.format,
    names: List<String>.generate(
      widget.players,
      (int index) => 'Player ${index + 1}',
    ),
    life: List<int>.filled(
      widget.players,
      widget.format == GameFormat.commander ? 40 : 20,
    ),
    members: <String>[_userId],
  );
  late String? _sharedId = widget.sharedId;
  Stream<GameSession?>? _stream;
  bool _busy = false;
  bool _loading = true;
  String? _error;
  late final GamePreferences _preferences = GamePreferences(_userId);
  late final ValueNotifier<GameSession> _editorGame = ValueNotifier<GameSession>(_local);
  final ValueNotifier<bool> _editorBusy = ValueNotifier<bool>(false);
  GameSession? _displayedGame;

  @override
  void dispose() {
    _editorGame.dispose();
    _editorBusy.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (_sharedId != null) {
      _stream = _store.stream(_sharedId!);
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      if (widget.resume) {
        final GameSession? saved = await _preferences.read(widget.format, widget.players);
        if (saved != null) _local = saved;
      } else {
        await _preferences.save(_local);
      }
    } catch (_) {
      _error = widget.resume ? 'Could not restore the saved game. Starting a new session.'
          : 'Could not save the game on this device.';
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  void _save() {
    final GameSession snapshot = _local;
    unawaited(
      Future<void>.sync(() => _preferences.save(snapshot)).catchError((
        Object error,
      ) {
        if (mounted) {
          setState(() => _error = 'Could not save the game on this device.');
        }
      }),
    );
  }

  Future<void> _action(Future<void> Function() operation) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    _editorBusy.value = true;
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not update the shared game. Check your connection and retry.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _editorBusy.value = false;
      }
    }
  }

  void _change(int player, int delta) {
    if (_loading) {
      return;
    }
    if (_sharedId != null) {
      _action(() => _store.changeLife(_sharedId!, player, delta));
    } else {
      final List<int> life = List<int>.of(_local.life)..[player] += delta;
      setState(() => _local = _local.withLife(life));
      _save();
    }
  }

  Future<void> _rename(int player, String currentName) async {
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[_editorGame, _editorBusy]),
        builder: (BuildContext context, Widget? child) => _PlayerNameDialog(
          initialName: currentName, life: _editorGame.value.life[player],
          busy: _editorBusy.value, changeLife: (int delta) => _change(player, delta)),
      ),
    );
    if (!mounted || name == null) {
      return;
    }
    if (_sharedId != null) {
      await _action(() => _store.rename(_sharedId!, player, name));
    } else {
      final List<String> names = List<String>.of(_local.names)..[player] = name;
      setState(() {
        _local = GameSession(
          id: '',
          ownerId: _userId,
          format: _local.format,
          names: names,
          life: _local.life,
          members: <String>[_userId],
        );
      });
      _save();
    }
  }

  Future<void> _reset() async {
    await DialogConfirm(
      title: 'Reset this game?',
      description: 'Restore every player to the starting life total.',
      confirmText: 'Reset',
      onConfirm: () {
        if (_sharedId != null) {
          _action(() => _store.reset(_sharedId!));
        } else {
          setState(
            () => _local = _local.withLife(
              List<int>.filled(_local.life.length, _local.startingLife),
            ),
          );
          _save();
        }
      },
    ).open(context);
  }

  Future<void> _share() => _action(() async {
    final GameSession game = await _store.create(
      _userId,
      widget.format,
      widget.players,
      initial: _local,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _sharedId = game.id;
      _stream = _store.stream(game.id);
    });
  });

  void _syncEditor(GameSession game) {
    if (identical(_displayedGame, game)) return;
    _displayedGame = game;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && identical(_displayedGame, game)) _editorGame.value = game;
    });
  }

  Future<void> _join() async {
    final String? code = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _JoinGameDialog(),
    );
    if (!mounted || code == null) return;
    await _action(() async {
      final GameSession game = await _store.join(code, _userId);
      if (!mounted) return;
      setState(() {
        _sharedId = game.id;
        _stream = _store.stream(game.id);
      });
    });
  }

  Future<void> _copyCode() async {
    try {
      await Clipboard.setData(ClipboardData(text: _sharedId!));
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not copy the session code.');
    }
  }

  Future<void> _gameMenu(GameSession game) => showDialog<void>(
    context: context,
    builder: (BuildContext menuContext) {
      Widget action(String title, VoidCallback run, {String? semantics}) =>
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Semantics(label: semantics, button: true, child: TextButton(
              alignment: Alignment.centerLeft,
              onPressed: () {
                Navigator.pop(menuContext);
                run();
              },
              child: Text(title),
            )),
          );
      return ArcaneDialog(
        title: const Text('Game'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('${game.format == GameFormat.commander ? 'Commander' : 'Standard'} · ${game.names.length} players',
              style: const TextStyle(fontSize: 13)),
            if (_sharedId != null) ...<Widget>[
              const SizedBox(height: 8),
              SelectableText(_sharedId!, semanticsLabel: 'Session code $_sharedId'),
              action('Copy code', _copyCode),
            ] else
              action('Share game', _share),
            action('Join session', _join),
            action('Reset life totals', _reset),
            if (Navigator.canPop(context))
              action('New game', () => Navigator.pop(context, GameSessionExit.newGame)),
            action('Rules', () => openCollectorUtility(context, const HubRules())),
            if (_sharedId != null && game.ownerId == _userId)
              action('End session', () => DialogConfirm(
                title: 'End this shared session?',
                description: 'The session will close for every player.',
                confirmText: 'End session',
                onConfirm: () => _action(() => _store.end(_sharedId!)),
              ).open(context), semantics: 'End shared session'),
          ]),
        actions: <Widget>[TextButton(onPressed: () => Navigator.pop(menuContext), child: const Text('Done'))],
      );
    },
  );

  Widget _toolbar({GameSession? game, bool waiting = false}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Row(children: <Widget>[
      ConstrainedBox(constraints: const BoxConstraints(minHeight: 44), child: TextButton(
        key: const ValueKey<String>('game-done'),
        onPressed: () => Navigator.maybePop(context),
        child: const Text('Done'),
      )),
      const Spacer(),
      if (game != null)
        ConstrainedBox(constraints: const BoxConstraints(minHeight: 44), child: TextButton(
          key: const ValueKey<String>('game-actions'),
          onPressed: waiting || _busy ? null : () => _gameMenu(game),
          child: const Text('Game'),
        )),
    ]),
  );

  Widget _lifeRegion(GameSession game, int player, int delta, bool enabled) => Expanded(
    child: Semantics(
      button: true, enabled: enabled,
      label: '${delta > 0 ? 'Gain' : 'Lose'} ${delta.abs()} life for ${game.names[player]}',
      onTap: enabled ? () => _change(player, delta) : null,
      child: ExcludeSemantics(child: Button(
        key: ValueKey<String>('game-player-${delta > 0 ? 'gain' : 'lose'}-$player'),
        style: const ButtonStyle.ghost(),
        disableTransition: MediaQuery.disableAnimationsOf(context),
        onPressed: enabled ? () => _change(player, delta) : null,
        child: SizedBox.expand(child: Align(alignment: Alignment.bottomCenter,
          child: Padding(padding: const EdgeInsets.only(bottom: 8),
            child: Text(delta > 0 ? '+$delta' : '$delta', style: const TextStyle(fontSize: 16))))),
      )),
    ),
  );

  Widget _board(GameSession game, bool waiting) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final double textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final bool largeText = textScale > 1.3;
      const double minimumZoneWidth = 128;
      const double minimumZoneHeight = 120;
      int columns = game.names.length <= 3 || largeText || constraints.maxWidth < 300 ? 1 : 2;
      int rows = (game.names.length / columns).ceil();
      while (!largeText &&
          game.names.length >= 6 &&
          columns < game.names.length &&
          rows * minimumZoneHeight + rows - 1 > constraints.maxHeight &&
          (constraints.maxWidth - columns) / (columns + 1) >= minimumZoneWidth) {
        columns++;
        rows = (game.names.length / columns).ceil();
      }
      final double fitted = (constraints.maxHeight - (rows - 1)) / rows;
      final double extent = largeText ? max(260, textScale * 120 + 80) : max(minimumZoneHeight, fitted);
      final double numberSize = game.names.length >= 6 ? 44 : game.names.length == 4 ? 64 : 80;
      return GridView.builder(
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns, crossAxisSpacing: 1, mainAxisSpacing: 1,
          mainAxisExtent: extent),
        itemCount: game.names.length,
        itemBuilder: (BuildContext context, int index) => Transform.rotate(
          key: ValueKey<String>('game-player-panel-$index'),
          angle: game.names.length == 2 && index == 0 ? pi : 0,
          child: Container(
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.background,
              border: Border.all(color: Theme.of(context).colorScheme.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              ConstrainedBox(constraints: const BoxConstraints(minHeight: 44), child: TextButton(
                key: ValueKey<String>('game-player-name-$index'),
                density: ButtonDensity((EdgeInsets _) => const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                onPressed: waiting || _busy ? null : () => _rename(index, game.names[index]),
                child: Text(game.names[index], maxLines: 2, overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              )),
              Expanded(child: Stack(fit: StackFit.expand, children: <Widget>[
                Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                  _lifeRegion(game, index, -1, !waiting && !_busy),
                  _lifeRegion(game, index, 1, !waiting && !_busy),
                ]),
                IgnorePointer(child: Padding(
                  padding: const EdgeInsets.only(bottom: 30),
                  child: Center(child: Semantics(
                    liveRegion: true,
                    label: '${game.names[index]}: ${game.life[index]} life',
                    excludeSemantics: true,
                    child: Text('${game.life[index]}', style: TextStyle(
                      fontSize: numberSize, height: 1, fontWeight: FontWeight.w800)),
                  )),
                )),
              ])),
            ]),
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => StreamBuilder<GameSession?>(
    stream: _stream,
    builder: (BuildContext context, AsyncSnapshot<GameSession?> snapshot) {
      final bool ended = _sharedId != null &&
          snapshot.connectionState == ConnectionState.active && !snapshot.hasData && !snapshot.hasError;
      if (ended || snapshot.hasError) {
        return Scaffold(
          headers: <Widget>[_toolbar()],
          child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
              Text(ended ? 'This session has ended.' : 'Could not load this session. Check your connection.'),
              if (!ended)
                SecondaryButton(onPressed: () => setState(() { _stream = _store.stream(_sharedId!); }),
                  child: const Text('Retry')),
              TextButton(onPressed: () => Navigator.maybePop(context), child: const Text('Return to games')),
            ]))),
        );
      }
      final GameSession game = snapshot.data ?? _local;
      final bool waiting = _loading || _sharedId != null && !snapshot.hasData;
      _syncEditor(game);
      return Scaffold(
        headers: <Widget>[_toolbar(game: game, waiting: waiting)],
        child: Column(children: <Widget>[
          if (_error != null) Padding(padding: const EdgeInsets.all(8),
            child: Semantics(liveRegion: true, child: Text(_error!))),
          if (waiting || _busy) const LinearProgressIndicator(),
          Expanded(child: _board(game, waiting)),
        ]),
      );
    },
  );
}

class _PlayerNameDialog extends StatefulWidget {
  const _PlayerNameDialog({required this.initialName, required this.life,
    required this.busy, required this.changeLife});

  final String initialName;
  final int life;
  final bool busy;
  final ValueChanged<int> changeLife;

  @override
  State<_PlayerNameDialog> createState() => _PlayerNameDialogState();
}

class _PlayerNameDialogState extends State<_PlayerNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );
  final FocusNode _focus = FocusNode();
  String? _error;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    if (!mounted || _submitted || widget.busy) {
      return;
    }
    final String name = _controller.text.trim();
    if (name.isEmpty || name.length > 40) {
      setState(() {
        _error = name.isEmpty
            ? 'Enter a player name.'
            : 'Use at most 40 characters.';
      });
      return;
    }
    _submitted = true;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) => ArcaneDialog(
    title: const Text('Player'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(liveRegion: true, child: Text('${widget.life}',
          textAlign: TextAlign.center, style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800))),
        const SizedBox(height: 8),
        Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: <Widget>[
          for (final int delta in const <int>[-10, -1, 1, 10])
            Semantics(button: true,
              label: '${delta > 0 ? 'Gain' : 'Lose'} ${delta.abs()} life for ${widget.initialName}',
              child: SecondaryButton(
                onPressed: widget.busy ? null : () => widget.changeLife(delta),
                child: Text(delta > 0 ? '+$delta' : '$delta'),
              )),
        ]),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey<String>('game-player-name-input'),
          controller: _controller,
          focusNode: _focus,
          enabled: !widget.busy,
          semanticLabel: 'Player name',
          textInputAction: TextInputAction.done,
          onSubmitted: (String _) => _submit(),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 12),
          Semantics(liveRegion: true, child: Text(_error!)),
        ],
      ],
    ),
    actions: <Widget>[
      OutlineButton(
        onPressed: widget.busy ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      PrimaryButton(onPressed: widget.busy ? null : _submit, child: const Text('Save')),
    ],
  ).iw;
}

class _JoinGameDialog extends StatefulWidget {
  const _JoinGameDialog();
  @override
  State<_JoinGameDialog> createState() => _JoinGameDialogState();
}

class _JoinGameDialogState extends State<_JoinGameDialog> {
  final TextEditingController _code = TextEditingController();
  String? _error;

  @override
  void dispose() { _code.dispose(); super.dispose(); }

  void _submit() {
    final String code = _code.text.replaceAll(RegExp(r'\s'), '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(code)) {
      setState(() => _error = 'Enter the 16-character session code.');
      return;
    }
    Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) => ArcaneDialog(
    title: const Text('Join session'),
    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(controller: _code, semanticLabel: 'Session code',
          placeholder: const ExcludeSemantics(child: Text('Session code')),
          textInputAction: TextInputAction.go, onSubmitted: (_) => _submit()),
        if (_error != null) Semantics(liveRegion: true, child: Text(_error!)),
      ]),
    actions: <Widget>[
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      PrimaryButton(onPressed: _submit, child: const Text('Join')),
    ],
  );
}
