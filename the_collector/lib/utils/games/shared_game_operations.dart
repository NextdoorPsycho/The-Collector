import 'package:cloud_firestore/cloud_firestore.dart';

import 'game_session.dart';

enum GameOperationKind { delta, rename, reset, leave }

class GameOperation {
  const GameOperation._({
    required this.id,
    required this.sessionId,
    required this.kind,
    this.player,
    this.delta,
    this.name,
  });

  factory GameOperation.delta({
    required String id,
    required String sessionId,
    required int player,
    required int delta,
  }) => GameOperation._(
    id: id,
    sessionId: sessionId,
    kind: GameOperationKind.delta,
    player: player,
    delta: delta,
  )._validated();

  factory GameOperation.rename({
    required String id,
    required String sessionId,
    required int player,
    required String name,
  }) => GameOperation._(
    id: id,
    sessionId: sessionId,
    kind: GameOperationKind.rename,
    player: player,
    name: name.trim(),
  )._validated();

  factory GameOperation.reset({
    required String id,
    required String sessionId,
  }) => GameOperation._(
    id: id,
    sessionId: sessionId,
    kind: GameOperationKind.reset,
  )._validated();

  factory GameOperation.leave({
    required String id,
    required String sessionId,
  }) => GameOperation._(
    id: id,
    sessionId: sessionId,
    kind: GameOperationKind.leave,
  )._validated();

  final String id;
  final String sessionId;
  final GameOperationKind kind;
  final int? player;
  final int? delta;
  final String? name;

  static String newId() =>
      '${SharedGameStore.newCode()}${SharedGameStore.newCode()}';

  GameOperation _validated() {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        !RegExp(r'^[0-9a-f]{16}$').hasMatch(sessionId)) {
      throw ArgumentError('Invalid game operation identity.');
    }
    if (kind == GameOperationKind.delta || kind == GameOperationKind.rename) {
      if (player == null || player! < 0 || player! > 7) {
        throw ArgumentError('Invalid player index.');
      }
    } else if (player != null) {
      throw ArgumentError('This operation has no player index.');
    }
    if (kind == GameOperationKind.delta) {
      if (delta == null || delta == 0 || delta!.abs() > 1000000) {
        throw ArgumentError('Invalid life adjustment.');
      }
    } else if (delta != null) {
      throw ArgumentError('This operation has no life adjustment.');
    }
    if (kind == GameOperationKind.rename) {
      if (name == null ||
          name!.isEmpty ||
          name!.length > 40 ||
          name != name!.trim()) {
        throw ArgumentError('Use a name of 1 to 40 characters.');
      }
    } else if (name != null) {
      throw ArgumentError('This operation has no player name.');
    }
    return this;
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'sessionId': sessionId,
    'kind': kind.name,
    'player': player,
    'delta': delta,
    'name': name,
  };

  factory GameOperation.fromMap(Map<String, Object?> data) {
    const Set<String> keys = <String>{
      'id',
      'sessionId',
      'kind',
      'player',
      'delta',
      'name',
    };
    if (data.length != keys.length ||
        !keys.containsAll(data.keys) ||
        data['id'] is! String ||
        data['sessionId'] is! String ||
        (data['player'] != null && data['player'] is! int) ||
        (data['delta'] != null && data['delta'] is! int) ||
        (data['name'] != null && data['name'] is! String)) {
      throw const FormatException('Invalid game operation.');
    }
    final GameOperationKind kind = switch (data['kind']) {
      'delta' => GameOperationKind.delta,
      'rename' => GameOperationKind.rename,
      'reset' => GameOperationKind.reset,
      'leave' => GameOperationKind.leave,
      _ => throw const FormatException('Unknown game operation.'),
    };
    try {
      return GameOperation._(
        id: data['id']! as String,
        sessionId: data['sessionId']! as String,
        kind: kind,
        player: data['player'] as int?,
        delta: data['delta'] as int?,
        name: data['name'] as String?,
      )._validated();
    } on ArgumentError {
      throw const FormatException('Invalid game operation.');
    }
  }

  bool _matchesReceipt(Map<String, Object?> receipt) =>
      receipt['sessionId'] == sessionId &&
      receipt['kind'] == kind.name &&
      receipt['player'] == player &&
      receipt['delta'] == delta &&
      receipt['name'] == name;
}

class GameOperationReceipt {
  const GameOperationReceipt({required this.operation, required this.revision});

  final GameOperation operation;
  final int revision;
}

class SharedGameOperations {
  SharedGameOperations({FirebaseFirestore? firestore, this.enabled = false})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;
  final bool enabled;

  void _requireCapability(String userId) {
    if (!enabled) throw StateError('Shared game operations are unavailable.');
    if (userId.isEmpty || userId.contains('/')) {
      throw ArgumentError('Invalid user.');
    }
  }

  Future<GameSession> create(
    String userId,
    GameFormat format,
    int players, {
    GameSession? initial,
  }) async {
    _requireCapability(userId);
    if (players < 2 || players > 8) throw ArgumentError.value(players);
    if (initial != null &&
        (initial.format != format ||
            initial.names.length != players ||
            initial.life.length != players)) {
      throw ArgumentError('Initial game does not match the session setup.');
    }
    final GameSession game = GameSession(
      id: SharedGameStore.newCode(),
      ownerId: userId,
      format: format,
      names: List<String>.unmodifiable(
        initial?.names ??
            List<String>.generate(
              players,
              (int index) => 'Player ${index + 1}',
            ),
      ),
      life: List<int>.unmodifiable(
        initial?.life ??
            List<int>.filled(players, format == GameFormat.commander ? 40 : 20),
      ),
      members: <String>[userId],
    );
    if (game.names.any((String name) => name.isEmpty || name.length > 40) ||
        game.life.any((int life) => life.abs() > 1000000)) {
      throw ArgumentError('Invalid initial players.');
    }
    final DocumentReference<Map<String, dynamic>> reference = _firestore
        .collection('gameSessions')
        .doc(game.id);
    await _firestore.runTransaction<void>((Transaction transaction) async {
      if ((await transaction.get(reference)).exists) {
        throw StateError('Session code collision. Try again.');
      }
      transaction.set(reference, <String, Object?>{
        ...game.toMap(),
        'operationVersion': 1,
        'revision': 0,
        'lastOperationId': null,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
    return game;
  }

  Future<GameOperationReceipt> apply(
    String userId,
    GameOperation operation,
  ) async {
    _requireCapability(userId);
    final DocumentReference<Map<String, dynamic>> receipt = _firestore
        .collection('user')
        .doc(userId)
        .collection('gameOperations')
        .doc(operation.id);
    final DocumentReference<Map<String, dynamic>> session = _firestore
        .collection('gameSessions')
        .doc(operation.sessionId);
    for (int attempt = 0; attempt < 5; attempt++) {
      int? attemptedRevision;
      try {
        return await _firestore.runTransaction<GameOperationReceipt>((
          Transaction transaction,
        ) async {
          // Read a prior receipt even after Leave or the owner has ended the game.
          final DocumentSnapshot<Map<String, dynamic>> previous =
              await transaction.get(receipt);
          if (previous.exists) {
            return _acknowledge(operation, previous.data()!);
          }
          final DocumentSnapshot<Map<String, dynamic>> snapshot =
              await transaction.get(session);
          if (!snapshot.exists) throw StateError('Session ended.');
          final Map<String, Object?> data = snapshot.data()!;
          final Object? currentRevision = data['revision'];
          if (data['operationVersion'] != 1 ||
              currentRevision is! int ||
              currentRevision < 0) {
            throw StateError('This session uses the earlier game protocol.');
          }
          final GameSession game = GameSession.fromMap(
            operation.sessionId,
            data,
          );
          if (!game.members.contains(userId)) {
            throw StateError('Join the session before changing it.');
          }
          attemptedRevision = currentRevision;
          final int revision = currentRevision + 1;
          final Map<String, Object?> changes = <String, Object?>{
            'revision': revision,
            'lastOperationId': operation.id,
            'updatedAt': FieldValue.serverTimestamp(),
          };
          switch (operation.kind) {
            case GameOperationKind.delta:
              final int player = operation.player!;
              if (player >= game.life.length) {
                throw ArgumentError.value(player, 'player');
              }
              final List<int> life = List<int>.of(game.life);
              life[player] += operation.delta!;
              if (life[player].abs() > 1000000) {
                throw ArgumentError(
                  'Life total is outside the supported range.',
                );
              }
              changes['life'] = life;
            case GameOperationKind.rename:
              final int player = operation.player!;
              if (player >= game.names.length) {
                throw ArgumentError.value(player, 'player');
              }
              final List<String> names = List<String>.of(game.names);
              names[player] = operation.name!;
              changes['names'] = names;
            case GameOperationKind.reset:
              changes['life'] = List<int>.filled(
                game.life.length,
                game.startingLife,
              );
            case GameOperationKind.leave:
              if (game.ownerId == userId) {
                throw StateError('The owner must end the session.');
              }
              changes['members'] = game.members
                  .where((String member) => member != userId)
                  .toList(growable: false);
          }
          final Map<String, Object?> receiptData = operation.toMap()
            ..remove('id');
          transaction.set(receipt, <String, Object?>{
            ...receiptData,
            'revision': revision,
            'createdAt': FieldValue.serverTimestamp(),
          });
          transaction.update(session, changes);
          return GameOperationReceipt(operation: operation, revision: revision);
        });
      } on FirebaseException catch (error, stack) {
        final int? observedRevision = attemptedRevision;
        if (error.code != 'permission-denied' || observedRevision == null) {
          rethrow;
        }
        final Map<String, Object?>? current;
        try {
          final DocumentSnapshot<Map<String, dynamic>> saved = await receipt
              .get(const GetOptions(source: Source.server));
          if (saved.exists) return _acknowledge(operation, saved.data()!);
          if (attempt == 4) Error.throwWithStackTrace(error, stack);
          current = (await session.get(const GetOptions(source: Source.server)))
              .data();
        } on FirebaseException {
          Error.throwWithStackTrace(error, stack);
        }
        final Object? revision = current?['revision'];
        final Object? members = current?['members'];
        if (current?['operationVersion'] != 1 ||
            revision is! int ||
            revision <= observedRevision ||
            members is! List<Object?> ||
            !members.contains(userId)) {
          Error.throwWithStackTrace(error, stack);
        }
        // Strict rules can reject stale intent before the SDK reports a retryable conflict.
        // Only a newer authorized server revision permits rebasing the same immutable intent.
      }
    }
    throw StateError('Shared game retry limit reached.');
  }

  GameOperationReceipt _acknowledge(
    GameOperation operation,
    Map<String, Object?> data,
  ) {
    final Object? revision = data['revision'];
    if (!operation._matchesReceipt(data) || revision is! int || revision < 1) {
      throw StateError(
        'Operation identity was already used for another change.',
      );
    }
    return GameOperationReceipt(operation: operation, revision: revision);
  }
}
