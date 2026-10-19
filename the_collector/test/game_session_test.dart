import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/games/game_session.dart';

// The fake neither isolates nor awaits writes; model both transaction boundaries.
class _TransactionalFirestore extends FakeFirebaseFirestore {
  Future<void> _tail = Future<void>.value();

  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    final Future<void> previous = _tail;
    final Completer<void> release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      final _AwaitedTransaction transaction = _AwaitedTransaction();
      final T result = await transactionHandler(transaction);
      await Future.wait<void>(transaction.writes);
      return result;
    } finally {
      release.complete();
    }
  }
}

class _AwaitedTransaction extends Fake implements Transaction {
  final List<Future<void>> writes = <Future<void>>[];

  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
    DocumentReference<T> reference,
  ) => reference.get();

  @override
  Transaction set<T>(
    DocumentReference<T> reference,
    T data, [
    SetOptions? options,
  ]) {
    writes.add(reference.set(data, options));
    return this;
  }

  @override
  Transaction update(
    DocumentReference<Object?> reference,
    Map<Object, Object?> data,
  ) {
    writes.add(reference.update(data));
    return this;
  }
}

void main() {
  test(
    'membership limits reject new guests and ending removes resumed sessions',
    () async {
      final _TransactionalFirestore database = _TransactionalFirestore();
      final SharedGameStore store = SharedGameStore(firestore: database);
      final GameSession game = await store.create(
        'owner',
        GameFormat.standard,
        2,
      );
      await database.doc('gameSessions/${game.id}').update(<String, Object?>{
        'members': <String>[
          'owner',
          ...List<String>.generate(15, (int i) => 'guest$i'),
        ],
      });
      await expectLater(store.join(game.id, 'extra'), throwsStateError);
      await store.join(game.id, 'guest0');
      expect(
        (await store.mySessions('owner').first).map(
          (GameSession game) => game.id,
        ),
        <String>[game.id],
      );
      expect(await store.mySessions('outsider').first, isEmpty);
      await store.end(game.id);
      expect(await store.stream(game.id).first, isNull);
      expect(await store.mySessions('owner').first, isEmpty);
      await expectLater(store.changeLife(game.id, 0, 1), throwsStateError);
    },
  );
  test(
    'create and normalized join preserve players without duplicate membership',
    () async {
      final _TransactionalFirestore database = _TransactionalFirestore();
      final SharedGameStore store = SharedGameStore(firestore: database);
      final GameSession game = await store.create(
        'owner',
        GameFormat.commander,
        4,
      );
      expect(game.id, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(game.life, <int>[40, 40, 40, 40]);
      expect(game.names, <String>[
        'Player 1',
        'Player 2',
        'Player 3',
        'Player 4',
      ]);
      await store.join(' ${game.id.toUpperCase()} ', 'guest');
      await store.join(game.id, 'guest');
      final GameSession joined = (await store.stream(game.id).first)!;
      expect(joined.members, <String>['owner', 'guest']);
      expect(joined.life, game.life);
      await expectLater(store.join('bad-code', 'guest'), throwsFormatException);
      await expectLater(
        store.join('0000000000000000', 'guest'),
        throwsStateError,
      );
    },
  );

  test('concurrent transaction deltas retain every life update', () async {
    final _TransactionalFirestore database = _TransactionalFirestore();
    final SharedGameStore first = SharedGameStore(firestore: database);
    final SharedGameStore second = SharedGameStore(firestore: database);
    final GameSession game = await first.create(
      'owner',
      GameFormat.standard,
      2,
    );
    await Future.wait<void>(<Future<void>>[
      first.changeLife(game.id, 0, -1),
      second.changeLife(game.id, 0, -10),
      first.changeLife(game.id, 1, 1),
      second.changeLife(game.id, 1, 10),
    ]);
    expect((await first.stream(game.id).first)!.life, <int>[9, 31]);
  });

  test(
    'rename and reset preserve membership and reject invalid player names',
    () async {
      final SharedGameStore store = SharedGameStore(
        firestore: _TransactionalFirestore(),
      );
      final GameSession game = await store.create(
        'owner',
        GameFormat.commander,
        2,
      );
      await store.join(game.id, 'guest');
      await store.rename(game.id, 1, '  Bob  ');
      await store.changeLife(game.id, 0, -43);
      expect((await store.stream(game.id).first)!.life.first, -3);
      await expectLater(store.rename(game.id, 1, '  '), throwsArgumentError);
      await expectLater(
        store.rename(game.id, 1, 'x' * 41),
        throwsArgumentError,
      );
      await store.reset(game.id);
      final GameSession reset = (await store.stream(game.id).first)!;
      expect(reset.life, <int>[40, 40]);
      expect(reset.names, <String>['Player 1', 'Bob']);
      expect(reset.members, <String>['owner', 'guest']);
    },
  );

  test('sharing a local game retains its current names and life', () async {
    final SharedGameStore store = SharedGameStore(
      firestore: _TransactionalFirestore(),
    );
    const GameSession local = GameSession(
      id: '',
      ownerId: 'owner',
      format: GameFormat.standard,
      names: <String>['Alice', 'Bob'],
      life: <int>[7, 25],
      members: <String>['owner'],
    );
    final GameSession shared = await store.create(
      'owner',
      GameFormat.standard,
      2,
      initial: local,
    );
    expect(shared.life, local.life);
    expect(shared.names, local.names);
    expect((await store.stream(shared.id).first)!.life, local.life);
  });

  test('invalid player counts and malformed stored sessions fail', () async {
    final SharedGameStore store = SharedGameStore(
      firestore: _TransactionalFirestore(),
    );
    for (final int players in <int>[1, 9]) {
      await expectLater(
        store.create('owner', GameFormat.standard, players),
        throwsArgumentError,
      );
    }
    expect(
      () => GameSession.fromMap('bad', <String, Object?>{
        'names': <String>['Alice', 'Bob'],
        'life': <int>[20],
        'ownerId': 'owner',
        'format': 'standard',
        'members': <String>['owner'],
      }),
      throwsFormatException,
    );
  });
}
