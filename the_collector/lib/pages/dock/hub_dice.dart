import 'dart:async';
import 'dart:math' as math;

import 'package:arcane/arcane.dart';
import 'package:flutter/services.dart' show TextInputAction;
import 'package:collector_models/user/app_user.dart';
import 'package:provider/provider.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/pages/dice/game_session_screen.dart';
import 'package:the_collector/pages/dice/tabletop_result.dart';
import 'package:the_collector/theme/collector_brand.dart';
import 'package:the_collector/utils/dice/dice_roller.dart';
import 'package:the_collector/utils/games/game_session.dart';
import 'package:the_collector/utils/games/game_preferences.dart';

class HubDice extends StatefulWidget {
  const HubDice({super.key, this.store, this.userId, this.roller, this.random});
  final SharedGameStore? store;
  final String? userId;
  final DiceRoller? roller;
  final math.Random? random;
  @override
  State<HubDice> createState() => _HubDiceState();
}

enum _GamesMode { dice, number, life }

class _HubDiceState extends State<HubDice> with TickerProviderStateMixin {
  late final SharedGameStore _store = widget.store ?? SharedGameStore();
  late final String _userId = widget.userId ?? u;
  late Stream<List<GameSession>> _sessions = _store.mySessions(_userId);
  late final DiceRoller _roller = widget.roller ?? DiceRoller();
  late final math.Random _random = widget.random ?? math.Random.secure();
  final ValueNotifier<int> _sheetRevision = ValueNotifier<int>(0);
  BuildContext? _drawerContext;
  _GamesMode _mode = _GamesMode.dice;
  GameFormat _format = GameFormat.standard;
  int _players = 2;
  int _sides = 6;
  int _dice = 1;
  bool _joining = false;
  String? _error;
  late final AnimationController _rollMotion;
  late final AnimationController _drawerMotion;
  bool _rolling = false;
  int _rangeMinimum = 1;
  int _rangeMaximum = 100;
  final TextEditingController _minimum = TextEditingController(text: '1');
  final TextEditingController _maximum = TextEditingController(text: '100');
  final TextEditingController _sessionCode = TextEditingController();
  final List<({int minimum, int maximum, int value})> _picks =
      <({int minimum, int maximum, int value})>[];
  String? _rangeError;
  GameSession? _savedGame;
  bool _loadingLife = false;
  bool _newGameSetup = false;
  int _lifeGeneration = 0;

  Future<void> _enterLife() async {
    final int generation = ++_lifeGeneration;
    final bool commander = context.read<AppUser?>()?.showCommander ?? false;
    _update(() {
      _loadingLife = true;
      _error = null;
    });
    try {
      final GameSession? game = await GamePreferences(_userId)
          .latest(includeCommander: commander);
      if (!mounted || generation != _lifeGeneration || _mode != _GamesMode.life) {
        return;
      }
      _update(() {
        _savedGame = game;
        _loadingLife = false;
        _newGameSetup = game == null;
        if (game != null) {
          _format = game.format;
          _players = game.names.length;
        }
      });
      if (game != null) await _openGame(game.format, game.names.length);
    } catch (_) {
      if (mounted && generation == _lifeGeneration) {
        _update(() {
          _loadingLife = false;
          _newGameSetup = true;
          _error = 'Could not restore the saved game.';
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _sessionCode.addListener(_sessionCodeChanged);
    _drawerMotion = AnimationController(vsync: this);
    _rollMotion =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 200),
        )..addStatusListener((AnimationStatus status) {
          if (status == AnimationStatus.completed && mounted && _rolling) {
            _update(() => _rolling = false);
          }
        });
  }

  void _update(VoidCallback action) {
    setState(action);
    _sheetRevision.value++;
  }

  void _sessionCodeChanged() {
    if (mounted) _update(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_rolling && MediaQuery.disableAnimationsOf(context)) _stopMotion();
  }

  void _present(VoidCallback generate) {
    final bool motion = !MediaQuery.disableAnimationsOf(context);
    _update(() {
      generate();
      _rolling = motion;
    });
    if (motion) _rollMotion.forward(from: 0);
  }

  void _roll() => _present(() => _roller.roll(sides: _sides, count: _dice));

  void _stopMotion() {
    _rollMotion.stop();
    _rolling = false;
  }

  @override
  void dispose() {
    _rollMotion.dispose();
    _drawerMotion.dispose();
    _sheetRevision.dispose();
    _minimum.dispose();
    _maximum.dispose();
    _sessionCode.dispose();
    super.dispose();
  }

  Future<void> _drawer(
    String title,
    WidgetBuilder content, {
    WidgetBuilder? action,
    bool compact = false,
  }) async {
    _drawerMotion.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final Future<void> closed = openDrawer<void>(
      context: context,
      animationController: _drawerMotion,
      position: OverlayPosition.bottom,
      borderRadius: BorderRadius.zero,
      showDragHandle: false,
      transformBackdrop: false,
      builder: (BuildContext drawerContext) {
        _drawerContext = drawerContext;
        return ValueListenableBuilder<int>(
          valueListenable: _sheetRevision,
          builder: (BuildContext context, int revision, Widget? child) {
            final MediaQueryData media = MediaQuery.of(context);
            final double available =
                media.size.height - media.viewInsets.bottom;
            return MediaQuery(
              data: media.copyWith(
                textScaler: MediaQuery.textScalerOf(this.context),
                disableAnimations: MediaQuery.disableAnimationsOf(this.context),
              ),
              child: SizedBox(
                width: math.min(600, media.size.width),
                height: compact ? null : math.min(560, available - 16),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: math.min(560, available - 16),
                  ),
                  child: Column(
                    mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                title,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            IconButton(
                              key: const ValueKey<String>(
                                'tabletop-editor-close',
                              ),
                              icon: Semantics(
                                label: 'Close editor',
                                child: const Icon(Icons.x),
                              ),
                              density: ButtonDensity(
                                (EdgeInsets _) => const EdgeInsets.all(12),
                              ),
                              onPressed: () {
                                FocusManager.instance.primaryFocus?.unfocus();
                                closeDrawer(drawerContext);
                              },
                            ),
                          ],
                        ),
                      ),
                      const Divider(),
                      Flexible(
                        fit: compact ? FlexFit.loose : FlexFit.tight,
                        child: ListView(
                          shrinkWrap: compact,
                          padding: const EdgeInsets.all(16),
                          children: <Widget>[content(drawerContext)],
                        ),
                      ),
                      if (action != null)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: action(drawerContext),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    _drawerMotion.forward(from: 0);
    await closed;
    _drawerContext = null;
  }

  String _modeLabel(_GamesMode mode) => switch (mode) {
    _GamesMode.dice => 'Roll',
    _GamesMode.number => 'Number',
    _GamesMode.life => 'Life',
  };

  Widget _modePicker() => Semantics(
    key: const ValueKey<String>('games-mode-picker'),
    label: 'Tabletop mode: ${_modeLabel(_mode)}',
    child: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = MediaQuery.textScalerOf(context).scale(14) > 20
            ? 1
            : 3;
        return Wrap(
          spacing: 4,
          runSpacing: 4,
          children: <Widget>[
            for (final _GamesMode mode in _GamesMode.values)
              SizedBox(
                width: (constraints.maxWidth - 4 * (columns - 1)) / columns,
                child: _choice(
                  key: ValueKey<String>('games-mode-${mode.name}'),
                  label: _modeLabel(mode),
                  selected: _mode == mode,
                  onPressed: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    if (_mode == mode) return;
                    _update(() {
                      _stopMotion();
                      _mode = mode;
                      _lifeGeneration++;
                    });
                    if (mode == _GamesMode.life) unawaited(_enterLife());
                  },
                ),
              ),
          ],
        );
      },
    ),
  );

  void _editDice() => _drawer(
    'Dice',
    (BuildContext context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final int sides in DiceRoller.supportedSides)
              _choice(
                key: ValueKey<String>('die-d$sides'),
                label: 'd$sides',
                selected: _sides == sides,
                onPressed: () => _update(() => _sides = sides),
              ),
          ],
        ),
        const SizedBox(height: 24),
        _quantity(),
      ],
    ),
    compact: true,
  );

  Widget _result() {
    final DiceRoll? roll = _roller.history.firstOrNull;
    return TabletopResult(
      value: roll == null ? 'Ready' : '${roll.total}',
      valueKey: 'dice-total',
      label: roll == null ? 'Total' : 'Last roll · ${roll.notation}',
      semanticLabel: roll == null
          ? 'No roll yet. $_dice ${_dice == 1 ? 'die' : 'dice'} with $_sides sides.'
          : '${roll.notation}: ${roll.values.join(', ')}, total ${roll.total}',
      motion: _rollMotion,
      animating: _rolling,
      details: roll != null && roll.values.length > 1
          ? <String>[for (final int value in roll.values) '$value']
          : const <String>[],
    );
  }

  void _diceHistory() => _drawer(
    'Roll history',
    (BuildContext context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_roller.history.isEmpty) const Text('No rolls yet.'),
        for (final DiceRoll roll in _roller.history) ...<Widget>[
          Text('${roll.notation} · Total ${roll.total}'),
          Text(roll.values.join(' + ')),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(),
          ),
        ],
      ],
    ),
    action: (BuildContext context) => TextButton(
      onPressed: _roller.history.isEmpty
          ? null
          : () => _update(() {
              _stopMotion();
              _roller.clear();
            }),
      child: const Text('Clear rolls'),
    ),
  );

  Widget _diceControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      _result(),
      _utilityControls(
        edit: OutlineButton(
          key: const ValueKey<String>('dice-edit'),
          onPressed: _editDice,
          child: Text('${_dice}d$_sides'),
        ),
        history: TextButton(
          key: const ValueKey<String>('dice-history'),
          onPressed: _diceHistory,
          child: Text('History (${_roller.history.length})'),
        ),
      ),
    ],
  );

  void _pickNumber() => _present(() {
    _picks.insert(0, (
      minimum: _rangeMinimum,
      maximum: _rangeMaximum,
      value: _rangeMinimum + _random.nextInt(_rangeMaximum - _rangeMinimum + 1),
    ));
    if (_picks.length > DiceRoller.historyLimit) _picks.removeLast();
  });

  void _saveRange(BuildContext drawerContext) {
    final int? minimum = int.tryParse(_minimum.text.trim());
    final int? maximum = int.tryParse(_maximum.text.trim());
    if (minimum == null ||
        maximum == null ||
        minimum < -999999 ||
        minimum > 999999 ||
        maximum < -999999 ||
        maximum > 999999) {
      _update(() => _rangeError = 'Use whole numbers from −999999 to 999999.');
      return;
    }
    if (minimum > maximum) {
      _update(() => _rangeError = 'Minimum must not exceed maximum.');
      return;
    }
    _update(() {
      _rangeMinimum = minimum;
      _rangeMaximum = maximum;
      _rangeError = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    closeDrawer(drawerContext);
  }

  Widget _rangeField(
    String label,
    TextEditingController controller,
    BuildContext drawerContext,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Text(label),
      const SizedBox(height: 8),
      TextField(
        key: ValueKey<String>('number-${label.toLowerCase()}'),
        controller: controller,
        semanticLabel: label,
        keyboardType: const TextInputType.numberWithOptions(signed: true),
        textInputAction: TextInputAction.done,
        onSubmitted: (String _) => _saveRange(drawerContext),
        onChanged: (String _) {
          if (_rangeError != null) _update(() => _rangeError = null);
        },
      ),
    ],
  );

  void _editRange() {
    _minimum.text = '$_rangeMinimum';
    _maximum.text = '$_rangeMaximum';
    _rangeError = null;
    _drawer(
      'Number range',
      (BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _rangeField('Minimum', _minimum, context),
          const SizedBox(height: 16),
          _rangeField('Maximum', _maximum, context),
          if (_rangeError != null) ...<Widget>[
            const SizedBox(height: 12),
            Semantics(liveRegion: true, child: Text(_rangeError!)),
          ],
        ],
      ),
      action: (BuildContext context) => PrimaryButton(
        key: const ValueKey<String>('number-range-save'),
        onPressed: () => _saveRange(context),
        child: const Text('Apply range'),
      ),
    );
  }

  void _numberHistory() => _drawer(
    'Number history',
    (BuildContext context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_picks.isEmpty) const Text('No numbers yet.'),
        for (final ({int minimum, int maximum, int value}) pick
            in _picks) ...<Widget>[
          Text('${pick.value} · ${pick.minimum} to ${pick.maximum}'),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(),
          ),
        ],
      ],
    ),
    action: (BuildContext context) => TextButton(
      onPressed: _picks.isEmpty
          ? null
          : () => _update(() {
              _stopMotion();
              _picks.clear();
            }),
      child: const Text('Clear numbers'),
    ),
  );

  Widget _numberControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      TabletopResult(
        value: _picks.isEmpty ? 'Ready' : '${_picks.first.value}',
        valueKey: 'number-result',
        label: _picks.isEmpty
            ? 'Number'
            : '${_picks.first.minimum} to ${_picks.first.maximum} · inclusive',
        semanticLabel: _picks.isEmpty
            ? 'No number picked yet.'
            : '${_picks.first.value}, picked from ${_picks.first.minimum} to ${_picks.first.maximum}, inclusive.',
        motion: _rollMotion,
        animating: _rolling,
      ),
      _utilityControls(
        edit: OutlineButton(
          key: const ValueKey<String>('number-edit'),
          onPressed: _editRange,
          child: Text('$_rangeMinimum to $_rangeMaximum'),
        ),
        history: TextButton(
          key: const ValueKey<String>('number-history'),
          onPressed: _numberHistory,
          child: Text('History (${_picks.length})'),
        ),
      ),
    ],
  );

  Widget _utilityControls({required Widget edit, required Widget history}) {
    final Widget editControl = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: edit,
    );
    final Widget historyControl = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: history,
    );
    if (MediaQuery.textScalerOf(context).scale(14) > 20) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          editControl,
          const SizedBox(height: 8),
          historyControl,
        ],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(child: editControl),
        const SizedBox(width: 8),
        Expanded(child: historyControl),
      ],
    );
  }

  Widget _choice({
    required String label,
    required bool selected,
    required VoidCallback onPressed,
    Key? key,
    String? semanticLabel,
  }) => Semantics(
    selected: selected,
    child: Button(
      key: key,
      style: ButtonStyle(
        variance: selected ? ButtonVariance.primary : ButtonVariance.outline,
        density: ButtonDensity((EdgeInsets _) => const EdgeInsets.all(10)),
      ),
      disableTransition: MediaQuery.disableAnimationsOf(context),
      enableFeedback: MediaQuery.disableAnimationsOf(context) ? false : null,
      onPressed: onPressed,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        child: Center(
          widthFactor: 1,
          child: semanticLabel == null
              ? Text(label)
              : Semantics(
                  label: semanticLabel,
                  excludeSemantics: true,
                  child: Text(label),
                ),
        ),
      ),
    ),
  );

  Widget _quantity() {
    final bool reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Semantics(
          container: true,
          button: true,
          enabled: _dice > 1,
          label: 'Remove one die',
          child: IconButton(
            disableTransition: reducedMotion,
            enableFeedback: reducedMotion ? false : null,
            density: ButtonDensity((EdgeInsets _) => const EdgeInsets.all(12)),
            icon: const Icon(Icons.minus),
            onPressed: _dice == 1 ? null : () => _update(() => _dice--),
          ),
        ),
        Flexible(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Semantics(
              label: '$_dice ${_dice == 1 ? 'die' : 'dice'}',
              excludeSemantics: true,
              child: Text(
                '$_dice ${_dice == 1 ? 'die' : 'dice'}',
                textAlign: TextAlign.center,
                style: Theme.of(context).typography.h4,
              ),
            ),
          ),
        ),
        Semantics(
          container: true,
          button: true,
          enabled: _dice < DiceRoller.maximumDice,
          label: 'Add one die',
          child: IconButton(
            disableTransition: reducedMotion,
            enableFeedback: reducedMotion ? false : null,
            density: ButtonDensity((EdgeInsets _) => const EdgeInsets.all(12)),
            icon: const Icon(Icons.plus),
            onPressed: _dice == DiceRoller.maximumDice
                ? null
                : () => _update(() => _dice++),
          ),
        ),
      ],
    );
  }

  Widget _lifeControls(bool commander) {
    if (_loadingLife) return const CollectorLoading(label: 'Loading game…');
    final GameSession? saved = _savedGame;
    if (saved != null &&
        !_newGameSetup &&
        (commander || saved.format != GameFormat.commander)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '${saved.format == GameFormat.commander ? 'Commander' : 'Standard'} · ${saved.names.length} players',
            style: Theme.of(context).typography.large,
          ),
          const SizedBox(height: 16),
          PrimaryButton(
            key: const ValueKey<String>('game-resume'),
            onPressed: () => _openGame(saved.format, saved.names.length),
            child: const Text('Resume'),
          ),
          const SizedBox(height: 8),
          SecondaryButton(
            onPressed: () => _update(() => _newGameSetup = true),
            child: const Text('New game'),
          ),
          const SizedBox(height: 12),
          OutlineButton(
            key: const ValueKey<String>('life-sessions'),
            onPressed: () => _drawer(
              'Shared sessions',
              (BuildContext context) => _sessionControls(commander),
            ),
            child: const Text('Shared sessions'),
          ),
        ],
      );
    }
    final GameFormat format = commander ? _format : GameFormat.standard;
    final List<int> counts = format == GameFormat.commander
        ? const <int>[2, 4, 6, 8]
        : const <int>[2, 3, 4];
    final int players = counts.contains(_players) ? _players : 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (commander) ...<Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final GameFormat choice in GameFormat.values)
                _choice(
                  key: ValueKey<String>('game-format-${choice.name}'),
                  label: choice == GameFormat.standard
                      ? 'Standard'
                      : 'Commander',
                  selected: format == choice,
                  onPressed: () => _update(() {
                    _format = choice;
                    if (choice == GameFormat.standard && _players > 4 ||
                        choice == GameFormat.commander && _players == 3) {
                      _players = 2;
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        Text(
          format == GameFormat.commander
              ? 'Commander · 40 life'
              : 'Standard · 20 life',
          style: Theme.of(context).typography.large,
        ),
        const SizedBox(height: 12),
        const Text('Players'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final int count in counts)
              _choice(
                key: ValueKey<String>('game-players-$count'),
                label: '$count',
                semanticLabel: '$count players',
                selected: players == count,
                onPressed: () => _update(() => _players = count),
              ),
          ],
        ),
        const SizedBox(height: 16),
        PrimaryButton(
          key: const ValueKey<String>('game-new'),
          onPressed: () => _openGame(format, players, resume: false),
          child: const Text('New game'),
        ),
        if (saved != null &&
            (commander || saved.format != GameFormat.commander))
          TextButton(
            key: const ValueKey<String>('game-resume'),
            onPressed: () => _openGame(saved.format, saved.names.length),
            child: const Text('Resume'),
          ),
        const SizedBox(height: 12),
        OutlineButton(
          key: const ValueKey<String>('life-sessions'),
          onPressed: () => _drawer(
            'Shared sessions',
            (BuildContext context) => _sessionControls(commander),
          ),
          child: const Text('Shared sessions'),
        ),
        if (_error != null) Semantics(liveRegion: true, child: Text(_error!)),
      ],
    );
  }

  Future<void> _openGame(
    GameFormat format,
    int players, {
    String? id,
    bool resume = true,
  }) async {
    final BuildContext? drawerContext = _drawerContext;
    if (drawerContext != null) await closeDrawer(drawerContext);
    if (!mounted) return;
    final GameSessionExit? result = await Arcane.push<GameSessionExit>(
      context,
      GameSessionScreen(
        format: format,
        players: players,
        sharedId: id,
        store: _store,
        userId: _userId,
        resume: resume,
      ),
    );
    if (!mounted) return;
    try {
      final GameSession? saved = await GamePreferences(_userId).latest(
        includeCommander: context.read<AppUser?>()?.showCommander ?? false,
      );
      if (!mounted) return;
      _update(() {
        _savedGame = saved;
        _newGameSetup = result == GameSessionExit.newGame || saved == null;
      });
    } catch (_) {
      if (mounted) _update(() => _error = 'Could not restore the saved game.');
    }
  }

  Future<void> _join(String code) async {
    if (_joining) {
      return;
    }
    _update(() {
      _joining = true;
      _error = null;
    });
    try {
      final GameSession game = await _store.join(code, _userId);
      if (mounted) {
        await _openGame(game.format, game.names.length, id: game.id);
      }
    } catch (_) {
      if (mounted) {
        _update(
          () => _error = 'Could not join. Check the code and your connection.',
        );
      }
    } finally {
      if (mounted) {
        _update(() => _joining = false);
      }
    }
  }

  Widget _sessionControls(bool commander) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      TextField(
        key: const ValueKey<String>('game-session-code'),
        controller: _sessionCode,
        semanticLabel: 'Session code',
        placeholder: const ExcludeSemantics(child: Text('Session code')),
        enabled: !_joining,
        textInputAction: TextInputAction.go,
        onSubmitted: (String code) {
          if (code.trim().isNotEmpty) {
            FocusManager.instance.primaryFocus?.unfocus();
            _join(code);
          }
        },
        features: const <InputFeature>[InputFeature.clear()],
      ),
      const SizedBox(height: 8),
      PrimaryButton(
        key: const ValueKey<String>('game-session-join'),
        onPressed: _joining || _sessionCode.text.trim().isEmpty
            ? null
            : () {
                FocusManager.instance.primaryFocus?.unfocus();
                _join(_sessionCode.text);
              },
        child: Text(_joining ? 'Joining…' : 'Join a session'),
      ),
      if (_error != null) ...<Widget>[
        const SizedBox(height: 12),
        Semantics(liveRegion: true, child: Text(_error!)),
      ],
      const SizedBox(height: 8),
      TextButton(
        key: const ValueKey<String>('game-session-start'),
        onPressed: _joining
            ? null
            : () => _openGame(
                commander ? _format : GameFormat.standard,
                commander && _format == GameFormat.commander
                    ? (const <int>[2, 4, 6, 8].contains(_players)
                          ? _players
                          : 2)
                    : (const <int>[2, 3, 4].contains(_players) ? _players : 2),
              ),
        child: const Text('Start a game'),
      ),
      const SizedBox(height: 12),
      StreamBuilder<List<GameSession>>(
        stream: _sessions,
        builder: (BuildContext context, AsyncSnapshot<List<GameSession>> snapshot) {
          if (snapshot.hasError) {
            return Semantics(
              container: true,
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Could not load shared sessions. Check your connection.',
                  ),
                  const SizedBox(height: 12),
                  OutlineButton(
                    onPressed: () =>
                        _update(() => _sessions = _store.mySessions(_userId)),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }
          if (!snapshot.hasData) {
            return Semantics(
              container: true,
              child: const CollectorLoading(label: 'Loading shared sessions…'),
            );
          }
          final List<GameSession> sessions = snapshot.data!
              .where(
                (GameSession game) =>
                    commander || game.format != GameFormat.commander,
              )
              .toList();
          if (sessions.isEmpty) {
            return const Text('No shared sessions yet.');
          }
          return Column(
            children: <Widget>[
              for (final GameSession game in sessions)
                Tile(
                  title: Text(
                    '${game.names.length} players · ${game.format == GameFormat.standard ? 'Standard' : 'Commander'}',
                  ),
                  subtitle: Text(game.names.join(' · ')),
                  onPressed: () =>
                      _openGame(game.format, game.names.length, id: game.id),
                ),
            ],
          );
        },
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final bool commander = context.watch<AppUser?>()?.showCommander ?? false;
    final bool reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Scaffold(
      footers: <Widget>[
        if (_mode != _GamesMode.life)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: SizedBox(
              width: double.infinity,
              child: Button(
                key: ValueKey<String>(
                  _mode == _GamesMode.dice ? 'dice-roll' : 'number-pick',
                ),
                style: const ButtonStyle.primary(),
                disableTransition: reducedMotion,
                enableFeedback: reducedMotion ? false : null,
                onPressed: _mode == _GamesMode.dice ? _roll : _pickNumber,
                child: Text(
                  _mode == _GamesMode.dice
                      ? 'Roll ${_dice}d$_sides'
                      : 'Pick a number',
                ),
              ),
            ),
          ),
      ],
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: _modePicker(),
          ),
          const Divider(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: <Widget>[
                switch (_mode) {
                  _GamesMode.dice => _diceControls(),
                  _GamesMode.number => _numberControls(),
                  _GamesMode.life => _lifeControls(commander),
                },
              ],
            ),
          ),
        ],
      ),
    );
  }
}
