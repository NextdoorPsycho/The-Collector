import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/games/game_session.dart';
import 'package:the_collector/utils/games/shared_game_operations.dart';

class _Database extends FakeFirebaseFirestore {
  _Database({bool guardAccount = false})
    : super(
        securityRules: guardAccount
            ? '''
    service cloud.firestore {
      match /databases/{database}/documents {
        match /{document=**} { allow read, write: if request.auth.uid == 'alice'; }
      }
    }
  '''
            : null,
      );

  Future<void> _tail = Future<void>.value();
  bool retryNextCallback = false;
  bool failNextCommit = false;
  int commits = 0;
  int transactions = 0;
  Future<void> Function()? denyNextCommitAfter;

  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    transactions++;
    final Future<void> previous = _tail;
    final Completer<void> release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      if (retryNextCallback) {
        retryNextCallback = false;
        await transactionHandler(_Transaction());
      }
      final _Transaction transaction = _Transaction();
      final T result = await transactionHandler(transaction);
      final Future<void> Function()? concurrentCommit = denyNextCommitAfter;
      if (concurrentCommit != null) {
        denyNextCommitAfter = null;
        await concurrentCommit();
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'permission-denied',
        );
      }
      if (transaction.writes.isNotEmpty && failNextCommit) {
        failNextCommit = false;
        throw StateError('Connection lost before commit.');
      }
      for (final Future<void> Function() write in transaction.writes) {
        await write();
      }
      if (transaction.writes.isNotEmpty) commits++;
      return result;
    } finally {
      release.complete();
    }
  }
}

class _Transaction extends Fake implements Transaction {
  final List<Future<void> Function()> writes = <Future<void> Function()>[];

  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
    DocumentReference<T> reference,
  ) {
    if (writes.isNotEmpty) throw StateError('Read after write.');
    return reference.get();
  }

  @override
  Transaction set<T>(
    DocumentReference<T> reference,
    T data, [
    SetOptions? options,
  ]) {
    writes.add(() => reference.set(data, options));
    return this;
  }

  @override
  Transaction update(
    DocumentReference<Object?> reference,
    Map<Object, Object?> data,
  ) {
    writes.add(() => reference.update(data));
    return this;
  }
}

void main() {
  Future<void> record(
    _Database database,
    String actor,
    GameOperation operation,
    int revision,
    List<int> life,
  ) async {
    final Map<String, Object?> fields = operation.toMap()..remove('id');
    await database.doc('user/$actor/gameOperations/${operation.id}').set(
      <String, Object?>{
        ...fields,
        'revision': revision,
        'createdAt': FieldValue.serverTimestamp(),
      },
    );
    await database.doc('gameSessions/${operation.sessionId}').update(
      <String, Object?>{
        'revision': revision,
        'lastOperationId': operation.id,
        'life': life,
        'updatedAt': FieldValue.serverTimestamp(),
      },
    );
  }

  test(
    'permission-denied after a conflicting commit rebases the same operation',
    () async {
      final _Database database = _Database();
      final SharedGameOperations store = SharedGameOperations(
        firestore: database,
        enabled: true,
      );
      final GameSession game = await store.create(
        'alice',
        GameFormat.standard,
        2,
      );
      await SharedGameStore(firestore: database).join(game.id, 'bob');
      final GameOperation first = GameOperation.delta(
        id: '1' * 32,
        sessionId: game.id,
        player: 0,
        delta: -1,
      );
      final GameOperation second = GameOperation.delta(
        id: '2' * 32,
        sessionId: game.id,
        player: 0,
        delta: -10,
      );
      database.denyNextCommitAfter = () =>
          record(database, 'alice', first, 1, <int>[19, 20]);
      expect((await store.apply('bob', second)).revision, 2);
      expect(
        (await database.doc('gameSessions/${game.id}').get()).data()!['life'],
        <int>[9, 20],
      );
      expect(
        (await database.collection('user/bob/gameOperations').get()).docs,
        hasLength(1),
      );
    },
  );

  test('permission-denied after an identical concurrent commit returns its receipt', () async {
    final _Database database = _Database();
    final SharedGameOperations store = SharedGameOperations(
      firestore: database,
      enabled: true,
    );
    final GameSession game = await store.create(
      'alice',
      GameFormat.standard,
      2,
    );
    final GameOperation operation = GameOperation.delta(
      id: '1' * 32,
      sessionId: game.id,
      player: 0,
      delta: -1,
    );
    database.denyNextCommitAfter = () =>
        record(database, 'alice', operation, 1, <int>[19, 20]);
    expect((await store.apply('alice', operation)).revision, 1);
    expect(
      (await database.doc('gameSessions/${game.id}').get()).data()!['life'],
      <int>[19, 20],
    );
  });

  test(
    'permission denial without a newer server revision does not retry',
    () async {
      final _Database database = _Database();
      final SharedGameOperations store = SharedGameOperations(
        firestore: database,
        enabled: true,
      );
      final GameSession game = await store.create(
        'alice',
        GameFormat.standard,
        2,
      );
      final int before = database.transactions;
      database.denyNextCommitAfter = () async {};
      await expectLater(
        store.apply(
          'alice',
          GameOperation.reset(id: '1' * 32, sessionId: game.id),
        ),
        throwsA(
          isA<FirebaseException>().having(
            (FirebaseException error) => error.code,
            'code',
            'permission-denied',
          ),
        ),
      );
      expect(database.transactions, before + 1);
    },
  );

  test(
    'removed membership cannot rebase even when the game advanced',
    () async {
      final _Database database = _Database();
      final SharedGameOperations store = SharedGameOperations(
        firestore: database,
        enabled: true,
      );
      final GameSession game = await store.create(
        'alice',
        GameFormat.standard,
        2,
      );
      await SharedGameStore(firestore: database).join(game.id, 'bob');
      final int before = database.transactions;
      database.denyNextCommitAfter = () async {
        await database.doc('gameSessions/${game.id}').update(<String, Object?>{
          'revision': 1,
          'members': <String>['alice'],
        });
      };
      await expectLater(
        store.apply(
          'bob',
          GameOperation.reset(id: '1' * 32, sessionId: game.id),
        ),
        throwsA(isA<FirebaseException>()),
      );
      expect(database.transactions, before + 1);
    },
  );

  test('a changed account cannot acknowledge or rebase the former actor operation', () async {
    final _Database database = _Database(guardAccount: true);
    database.authObject.add(<String, Object?>{'uid': 'alice'});
    final SharedGameOperations store = SharedGameOperations(
      firestore: database,
      enabled: true,
    );
    final GameSession game = await store.create(
      'alice',
      GameFormat.standard,
      2,
    );
    final GameOperation operation = GameOperation.delta(
      id: '1' * 32,
      sessionId: game.id,
      player: 0,
      delta: -1,
    );
    final int before = database.transactions;
    database.denyNextCommitAfter = () async {
      await record(database, 'alice', operation, 1, <int>[19, 20]);
      database.authObject.add(<String, Object?>{'uid': 'bob'});
    };
    // The fake rules engine reports access denial as Exception, unlike the SDK.
    await expectLater(
      store.apply('alice', operation),
      throwsA(
        isA<Exception>().having(
          (Exception error) => error.toString(),
          'account access denial',
          allOf(
            contains('user/alice/gameOperations/${operation.id}'),
            contains('uid: bob'),
            contains('is not allowed'),
          ),
        ),
      ),
    );
    expect(database.transactions, before + 1);
  });

  test(
    'reconciliation rejects a receipt with a different frozen intent',
    () async {
      final _Database database = _Database();
      final SharedGameOperations store = SharedGameOperations(
        firestore: database,
        enabled: true,
      );
      final GameSession game = await store.create(
        'alice',
        GameFormat.standard,
        2,
      );
      final GameOperation operation = GameOperation.delta(
        id: '1' * 32,
        sessionId: game.id,
        player: 0,
        delta: -1,
      );
      database.denyNextCommitAfter = () => record(
        database,
        'alice',
        GameOperation.delta(
          id: operation.id,
          sessionId: game.id,
          player: 1,
          delta: -1,
        ),
        1,
        <int>[20, 19],
      );
      await expectLater(store.apply('alice', operation), throwsStateError);
    },
  );

  test('contention reconciliation stops after five attempts', () async {
    final _Database database = _Database();
    final SharedGameOperations store = SharedGameOperations(
      firestore: database,
      enabled: true,
    );
    final GameSession game = await store.create(
      'alice',
      GameFormat.standard,
      2,
    );
    final int before = database.transactions;
    int revision = 0;
    late final Future<void> Function() advance;
    advance = () async {
      revision++;
      await database.doc('gameSessions/${game.id}').update(<String, Object?>{
        'revision': revision,
        'life': <int>[20 - revision, 20],
      });
      database.denyNextCommitAfter = advance;
    };
    database.denyNextCommitAfter = advance;
    await expectLater(
      store.apply(
        'alice',
        GameOperation.reset(id: '1' * 32, sessionId: game.id),
      ),
      throwsA(isA<FirebaseException>()),
    );
    expect(database.transactions, before + 5);
  });

  test('operation protocol is disabled unless explicitly enabled', () async {
    final _Database database = _Database();
    final SharedGameOperations disabled = SharedGameOperations(
      firestore: database,
    );
    await expectLater(
      disabled.create('alice', GameFormat.standard, 2),
      throwsStateError,
    );
    await expectLater(
      disabled.apply(
        'alice',
        GameOperation.delta(
          id: 'a' * 32,
          sessionId: 'a' * 16,
          player: 0,
          delta: 1,
        ),
      ),
      throwsStateError,
    );
    expect(database.commits, 0);
    final SharedGameStore legacy = SharedGameStore(firestore: database);
    final GameSession game = await legacy.create(
      'alice',
      GameFormat.standard,
      2,
    );
    expect(
      (await database.doc('gameSessions/${game.id}').get()).data(),
      isNot(contains('operationVersion')),
    );
  });

  test('concurrent operations and callback retries apply every distinct intent once', () async {
    final _Database database = _Database();
    final SharedGameOperations store = SharedGameOperations(
      firestore: database,
      enabled: true,
    );
    final GameSession game = await store.create(
      'alice',
      GameFormat.standard,
      2,
    );
    await SharedGameStore(firestore: database).join(game.id, 'bob');
    final GameOperation first = GameOperation.delta(
      id: '1' * 32,
      sessionId: game.id,
      player: 0,
      delta: -1,
    );
    final GameOperation second = GameOperation.delta(
      id: '2' * 32,
      sessionId: game.id,
      player: 0,
      delta: -10,
    );
    database.retryNextCallback = true;
    final List<GameOperationReceipt> receipts =
        await Future.wait<GameOperationReceipt>(<Future<GameOperationReceipt>>[
          store.apply('alice', first),
          store.apply('bob', second),
          store.apply('alice', first),
        ]);
    expect(
      receipts.map((GameOperationReceipt receipt) => receipt.revision),
      <int>[1, 2, 1],
    );
    expect(
      (await database.doc('gameSessions/${game.id}').get()).data()!['life'],
      <int>[9, 20],
    );
    expect(
      (await database.collection('user/alice/gameOperations').get()).docs,
      hasLength(1),
    );
    expect(
      (await database.collection('user/bob/gameOperations').get()).docs,
      hasLength(1),
    );
    await expectLater(
      store.apply(
        'alice',
        GameOperation.delta(
          id: first.id,
          sessionId: game.id,
          player: 0,
          delta: 10,
        ),
      ),
      throwsStateError,
    );
  });

  test(
    'uncommitted operation can be retried using its serialized identity',
    () async {
      final _Database database = _Database();
      final SharedGameOperations store = SharedGameOperations(
        firestore: database,
        enabled: true,
      );
      final GameSession game = await store.create(
        'alice',
        GameFormat.standard,
        2,
      );
      final GameOperation operation = GameOperation.delta(
        id: 'a' * 32,
        sessionId: game.id,
        player: 1,
        delta: 7,
      );
      database.failNextCommit = true;
      await expectLater(store.apply('alice', operation), throwsStateError);
      expect(
        (await database.doc('gameSessions/${game.id}').get()).data()!['life'],
        <int>[20, 20],
      );
      expect(
        (await database.doc('user/alice/gameOperations/${operation.id}').get())
            .exists,
        isFalse,
      );
      final GameOperation restored = GameOperation.fromMap(operation.toMap());
      expect((await store.apply('alice', restored)).revision, 1);
      expect(
        (await database.doc('gameSessions/${game.id}').get()).data()!['life'],
        <int>[20, 27],
      );
    },
  );

  test(
    'member rename and reset retain names, format, owner and membership',
    () async {
      final _Database database = _Database();
      final SharedGameOperations store = SharedGameOperations(
        firestore: database,
        enabled: true,
      );
      final GameSession game = await store.create(
        'alice',
        GameFormat.commander,
        3,
      );
      final SharedGameStore reader = SharedGameStore(firestore: database);
      await reader.join(game.id, 'bob');
      await store.apply(
        'bob',
        GameOperation.rename(
          id: 'a' * 32,
          sessionId: game.id,
          player: 2,
          name: '  Pat  ',
        ),
      );
      await store.apply(
        'bob',
        GameOperation.delta(
          id: 'b' * 32,
          sessionId: game.id,
          player: 1,
          delta: -30,
        ),
      );
      await store.apply(
        'bob',
        GameOperation.reset(id: 'c' * 32, sessionId: game.id),
      );
      final GameSession result = (await reader.stream(game.id).first)!;
      expect(result.life, <int>[40, 40, 40]);
      expect(result.names, <String>['Player 1', 'Player 2', 'Pat']);
      expect(result.members, <String>['alice', 'bob']);
      expect(result.ownerId, 'alice');
      expect(result.format, GameFormat.commander);
    },
  );

  test('Leave excludes the owner and is safely acknowledged after leaving or ending', () async {
    final _Database database = _Database();
    final SharedGameOperations store = SharedGameOperations(
      firestore: database,
      enabled: true,
    );
    final GameSession game = await store.create(
      'alice',
      GameFormat.standard,
      2,
    );
    final SharedGameStore legacy = SharedGameStore(firestore: database);
    await legacy.join(game.id, 'bob');
    await expectLater(
      store.apply(
        'alice',
        GameOperation.leave(id: 'a' * 32, sessionId: game.id),
      ),
      throwsStateError,
    );
    final GameOperation leave = GameOperation.leave(
      id: 'b' * 32,
      sessionId: game.id,
    );
    expect((await store.apply('bob', leave)).revision, 1);
    expect((await store.apply('bob', leave)).revision, 1);
    expect((await legacy.stream(game.id).first)!.members, <String>['alice']);
    await expectLater(
      store.apply(
        'bob',
        GameOperation.delta(
          id: 'c' * 32,
          sessionId: game.id,
          player: 0,
          delta: 1,
        ),
      ),
      throwsStateError,
    );
    await legacy.end(game.id);
    expect((await store.apply('bob', leave)).revision, 1);
    await expectLater(
      store.apply(
        'alice',
        GameOperation.reset(id: 'd' * 32, sessionId: game.id),
      ),
      throwsStateError,
    );
  });

  test('legacy sessions, invalid indices and out-of-range totals reject without receipts', () async {
    final _Database database = _Database();
    final SharedGameOperations store = SharedGameOperations(
      firestore: database,
      enabled: true,
    );
    final GameSession legacy = await SharedGameStore(firestore: database)
        .create('alice', GameFormat.standard, 2);
    await expectLater(
      store.apply(
        'alice',
        GameOperation.reset(id: 'a' * 32, sessionId: legacy.id),
      ),
      throwsStateError,
    );
    final GameSession game = await store.create(
      'alice',
      GameFormat.standard,
      2,
    );
    await expectLater(
      store.apply(
        'alice',
        GameOperation.delta(
          id: 'b' * 32,
          sessionId: game.id,
          player: 7,
          delta: 1,
        ),
      ),
      throwsArgumentError,
    );
    await expectLater(
      store.apply(
        'alice',
        GameOperation.delta(
          id: 'c' * 32,
          sessionId: game.id,
          player: 0,
          delta: 1000000,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      (await database.collection('user/alice/gameOperations').get()).docs,
      isEmpty,
    );
  });

  test('invalid serialized intents are rejected before database access', () {
    final Map<String, Object?> valid = GameOperation.delta(
      id: 'a' * 32,
      sessionId: 'b' * 16,
      player: 0,
      delta: -1,
    ).toMap();
    for (final Map<String, Object?> mutation in <Map<String, Object?>>[
      <String, Object?>{'id': 'bad'},
      <String, Object?>{'sessionId': 'bad'},
      <String, Object?>{'kind': 'delete'},
      <String, Object?>{'player': -1},
      <String, Object?>{'delta': 0},
      <String, Object?>{'delta': 1.5},
      <String, Object?>{'name': 'hidden name'},
      <String, Object?>{'extra': true},
    ]) {
      expect(
        () => GameOperation.fromMap(<String, Object?>{...valid, ...mutation}),
        throwsFormatException,
      );
    }
  });
}
