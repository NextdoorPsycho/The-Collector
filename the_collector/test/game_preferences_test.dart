import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:the_collector/utils/auth/local_account_data.dart';
import 'package:the_collector/utils/games/game_preferences.dart';
import 'package:the_collector/utils/games/game_session.dart';

class _DelayedPreferences extends InMemorySharedPreferencesStore {
  _DelayedPreferences({this.failFirst = false}) : super.empty();
  final bool failFirst;
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  int writes = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes++;
    if (writes == 1) {
      entered.complete();
      await release.future;
      if (failFirst) return false;
    }
    return super.setValue(valueType, key, value);
  }
}

GameSession _game(
  String uid,
  int life, {
  GameFormat format = GameFormat.standard,
}) => GameSession(
  id: '',
  ownerId: uid,
  format: format,
  names: const <String>['One', 'Two'],
  life: <int>[life, 20],
  members: <String>[uid],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SharedPreferencesStorePlatform previous;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'collector-game-ordering-',
    );
    Hive.init(directory.path);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    previous = SharedPreferencesStorePlatform.instance;
    await LocalAccountData.initialize();
  });
  tearDown(() async {
    SharedPreferencesStorePlatform.instance = previous;
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'latest local game is account scoped and honors Commander visibility',
    () async {
      const GamePreferences alice = GamePreferences('alice');
      const GamePreferences bob = GamePreferences('bob');
      expect(await alice.latest(), isNull);
      await alice.save(_game('alice', 25));
      await alice.save(_game('alice', 44, format: GameFormat.commander));
      await bob.save(_game('bob', 19));
      expect((await alice.latest())!.life.first, 44);
      expect((await alice.latest(includeCommander: false))!.life.first, 25);
      expect((await bob.latest())!.life.first, 19);
    },
  );

  test('late completion of an older game cannot replace the most recently played setup', () async {
    final _DelayedPreferences platform = _DelayedPreferences();
    SharedPreferencesStorePlatform.instance = platform;
    const GamePreferences preferences = GamePreferences('alice');
    final Future<void> first = preferences.save(_game('alice', 21));
    await platform.entered.future;
    await preferences.save(_game('alice', 42, format: GameFormat.commander));
    bool readCompleted = false;
    final Future<GameSession?> latest = preferences.latest().then((
      GameSession? game,
    ) {
      readCompleted = true;
      return game;
    });
    await Future<void>.delayed(Duration.zero);
    expect(readCompleted, isFalse);
    platform.release.complete();
    await first;
    expect((await latest)!.format, GameFormat.commander);
  });

  test('reads wait for all earlier snapshots while unrelated games remain writable', () async {
    final _DelayedPreferences platform = _DelayedPreferences();
    SharedPreferencesStorePlatform.instance = platform;
    final Future<void> first = const GamePreferences('alice')
        .save(_game('alice', 21));
    await platform.entered.future;
    final Future<void> second = const GamePreferences('alice')
        .save(_game('alice', 22));
    bool restored = false;
    final Future<GameSession?> reopening = const GamePreferences('alice')
        .read(GameFormat.standard, 2)
        .then((GameSession? game) {
          restored = true;
          return game;
        });
    await const GamePreferences('bob').save(_game('bob', 25));
    await const GamePreferences('alice')
        .save(_game('alice', 40, format: GameFormat.commander));
    expect(restored, isFalse);
    platform.release.complete();
    await Future.wait<void>(<Future<void>>[first, second]);
    expect((await reopening)!.life, <int>[22, 20]);
    await const GamePreferences('alice').save(_game('alice', 32));
    expect(
      (await const GamePreferences(
        'alice',
      ).read(GameFormat.standard, 2))!.life.first,
      32,
    );
    expect(
      (await const GamePreferences(
        'bob',
      ).read(GameFormat.standard, 2))!.life.first,
      25,
    );
  });

  test(
    'failed acknowledgement releases the key for the next admitted snapshot',
    () async {
      final _DelayedPreferences platform = _DelayedPreferences(failFirst: true);
      SharedPreferencesStorePlatform.instance = platform;
      final Future<void> first = const GamePreferences('alice')
          .save(_game('alice', 21));
      final Future<void> failure = expectLater(first, throwsStateError);
      await platform.entered.future;
      final Future<void> second = const GamePreferences('alice')
          .save(_game('alice', 22));
      platform.release.complete();
      await failure;
      await second;
      expect(platform.writes, 2);
      expect(
        (await const GamePreferences(
          'alice',
        ).read(GameFormat.standard, 2))!.life.first,
        22,
      );
    },
  );

  test('deletion waits for admitted writes and rejects queued late snapshots before purging', () async {
    final _DelayedPreferences platform = _DelayedPreferences();
    SharedPreferencesStorePlatform.instance = platform;
    final Future<void> first = const GamePreferences('alice')
        .save(_game('alice', 21));
    await platform.entered.future;
    final Future<void> second = const GamePreferences('alice')
        .save(_game('alice', 22));
    final Future<void> rejection = expectLater(second, throwsStateError);
    await const GamePreferences('bob').save(_game('bob', 25));
    await LocalAccountData.markDeleting('alice');
    bool purged = false;
    final Future<void> purge = LocalAccountData.purge('alice')
        .then((_) => purged = true);
    await Future<void>.delayed(Duration.zero);
    expect(purged, isFalse);
    expect(
      () => const GamePreferences('alice').save(_game('alice', 30)),
      throwsStateError,
    );
    platform.release.complete();
    await first;
    await rejection;
    await purge;
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('game.alice.standard.2'), isNull);
    expect(platform.writes, 2);
    expect(
      (await const GamePreferences(
        'bob',
      ).read(GameFormat.standard, 2))!.life.first,
      25,
    );
  });
}
