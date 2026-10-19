import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../auth/local_account_data.dart';
import 'game_session.dart';

class GamePreferences {
  const GamePreferences(this.userId);

  final String userId;
  static final Map<String, Future<void>> _tails = <String, Future<void>>{};
  static int _lastTimestamp = 0;

  Future<T> _ordered<T>(String key, Future<T> Function() action) =>
      LocalAccountData.mutate(userId, () {
        final Future<void> previous = _tails[key] ?? Future<void>.value();
        final Future<T> operation = previous.then((_) {
          LocalAccountData.requireWritable(userId);
          return action();
        });
        final Future<void> settled = operation.then<void>(
          (T _) {},
          onError: (Object error, StackTrace stack) {},
        );
        _tails[key] = settled;
        unawaited(
          settled.whenComplete(() {
            if (identical(_tails[key], settled)) _tails.remove(key);
          }),
        );
        return operation;
      });

  String _key(GameFormat format, int players) {
    if (players < 2 || players > 8) {
      throw ArgumentError.value(players, 'players');
    }
    return 'game.$userId.${format.name}.$players';
  }

  Future<(GameSession, int)?> _read(GameFormat format, int players) =>
      _ordered<(GameSession, int)?>(_key(format, players), () async {
        final SharedPreferences preferences =
            await SharedPreferences.getInstance();
        LocalAccountData.requireWritable(userId);
        final String? saved = preferences.getString(_key(format, players));
        if (saved == null) return null;
        final Map<String, Object?> data = Map<String, Object?>.from(
          jsonDecode(saved) as Map<Object?, Object?>);
        final GameSession game = GameSession.fromMap('', data);
        if (game.ownerId != userId ||
            game.format != format ||
            game.life.length != players) {
          throw const FormatException('Invalid saved game owner or format.');
        }
        return (game, data['savedAtMicros'] as int? ?? 0);
      });

  Future<GameSession?> read(GameFormat format, int players) async =>
      (await _read(format, players))?.$1;

  Future<GameSession?> latest({bool includeCommander = true}) async {
    final List<Future<(GameSession, int)?>> reads = <Future<(GameSession, int)?>>[
      for (final GameFormat format in GameFormat.values)
        if (includeCommander || format != GameFormat.commander)
          for (final int count in format == GameFormat.standard
              ? const <int>[2, 3, 4] : const <int>[2, 4, 6, 8])
            _read(format, count),
    ];
    final List<(GameSession, int)> saved = (await Future.wait(reads))
      .whereType<(GameSession, int)>().toList();
    saved.sort(((GameSession, int) left, (GameSession, int) right) => right.$2.compareTo(left.$2));
    return saved.isEmpty ? null : saved.first.$1;
  }

  Future<void> save(GameSession game) {
    if (game.ownerId != userId) {
      throw ArgumentError('Game belongs to another account.');
    }
    final String key = _key(game.format, game.life.length);
    final int now = DateTime.now().microsecondsSinceEpoch;
    _lastTimestamp = now > _lastTimestamp ? now : _lastTimestamp + 1;
    final String snapshot = jsonEncode(<String, Object?>{
      ...game.toMap(), 'savedAtMicros': _lastTimestamp,
    });
    return _ordered<void>(key, () async {
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      LocalAccountData.requireWritable(userId);
      if (!await preferences.setString(key, snapshot)) {
        throw StateError('Could not save the game.');
      }
    });
  }
}
