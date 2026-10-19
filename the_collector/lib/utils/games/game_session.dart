import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

enum GameFormat { standard, commander }

class GameSession {
  const GameSession({
    required this.id,
    required this.ownerId,
    required this.format,
    required this.names,
    required this.life,
    required this.members,
  });
  final String id;
  final String ownerId;
  final GameFormat format;
  final List<String> names;
  final List<int> life;
  final List<String> members;
  int get startingLife => format == GameFormat.commander ? 40 : 20;

  GameSession withLife(List<int> value) => GameSession(
    id: id,
    ownerId: ownerId,
    format: format,
    names: names,
    life: List<int>.unmodifiable(value),
    members: members,
  );

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'ownerId': ownerId,
    'format': format.name,
    'names': names,
    'life': life,
    'members': members,
  };

  factory GameSession.fromMap(String id, Map<String, Object?> data) {
    final List<String> names = (data['names'] as List<Object?>).cast<String>();
    final List<int> life = (data['life'] as List<Object?>).cast<int>();
    if (names.length < 2 || names.length > 8 || life.length != names.length) {
      throw const FormatException('Invalid player count.');
    }
    return GameSession(
      id: id,
      ownerId: data['ownerId'] as String,
      format: GameFormat.values.byName(data['format'] as String),
      names: List<String>.unmodifiable(names),
      life: List<int>.unmodifiable(life),
      members: List<String>.unmodifiable(
        (data['members'] as List<Object?>).cast<String>(),
      ),
    );
  }
}

class SharedGameStore {
  SharedGameStore({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;
  final FirebaseFirestore _firestore;
  CollectionReference<Map<String, dynamic>> get _sessions =>
      _firestore.collection('gameSessions');

  static String newCode() {
    final Random random = Random.secure();
    return List<String>.generate(
      16,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
  }

  Future<GameSession> create(
    String userId,
    GameFormat format,
    int players, {
    GameSession? initial,
  }) async {
    if (initial != null &&
        (initial.format != format ||
            initial.names.length != players ||
            initial.life.length != players)) {
      throw ArgumentError('Initial game does not match the session setup.');
    }
    if (players < 2 || players > 8) throw ArgumentError.value(players);
    final GameSession game = GameSession(
      id: newCode(),
      ownerId: userId,
      format: format,
      names:
          initial?.names ??
          List<String>.generate(players, (int index) => 'Player ${index + 1}'),
      life:
          initial?.life ??
          List<int>.filled(players, format == GameFormat.commander ? 40 : 20),
      members: <String>[userId],
    );
    await _firestore.runTransaction<void>((Transaction transaction) async {
      final DocumentReference<Map<String, dynamic>> reference = _sessions.doc(
        game.id,
      );
      if ((await transaction.get(reference)).exists) {
        throw StateError('Session code collision. Try again.');
      }
      transaction.set(reference, <String, Object?>{
        ...game.toMap(),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
    return game;
  }

  Future<GameSession> join(String code, String userId) async {
    final String id = code.replaceAll(' ', '').trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(id)) {
      throw const FormatException('Enter the 16-character session code.');
    }
    return _firestore.runTransaction<GameSession>((
      Transaction transaction,
    ) async {
      final DocumentReference<Map<String, dynamic>> reference = _sessions.doc(
        id,
      );
      final DocumentSnapshot<Map<String, dynamic>> snapshot = await transaction
          .get(reference);
      if (!snapshot.exists) throw StateError('Session not found.');
      final GameSession game = GameSession.fromMap(id, snapshot.data()!);
      if (!game.members.contains(userId)) {
        if (game.members.length >= 16) throw StateError('Session is full.');
        transaction.update(reference, <String, Object?>{
          'members': <String>[...game.members, userId],
        });
      }
      return game;
    });
  }

  Stream<List<GameSession>> mySessions(String userId) => _sessions
      .where('members', arrayContains: userId)
      .snapshots()
      .map(
        (QuerySnapshot<Map<String, dynamic>> snapshot) => snapshot.docs
            .map(
              (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
                  GameSession.fromMap(doc.id, doc.data()),
            )
            .toList(),
      );

  Future<void> end(String id) => _sessions.doc(id).delete();

  Stream<GameSession?> stream(String id) => _sessions
      .doc(id)
      .snapshots()
      .map(
        (DocumentSnapshot<Map<String, dynamic>> snapshot) => snapshot.exists
            ? GameSession.fromMap(snapshot.id, snapshot.data()!)
            : null,
      );

  Future<void> changeLife(String id, int player, int delta) =>
      _firestore.runTransaction<void>((Transaction transaction) async {
        final DocumentReference<Map<String, dynamic>> reference = _sessions.doc(
          id,
        );
        final DocumentSnapshot<Map<String, dynamic>> snapshot =
            await transaction.get(reference);
        if (!snapshot.exists) throw StateError('Session ended.');
        final GameSession game = GameSession.fromMap(id, snapshot.data()!);
        final List<int> life = List<int>.of(game.life);
        life[player] += delta;
        transaction.update(reference, <String, Object?>{
          'life': life,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

  Future<void> reset(String id) => _firestore.runTransaction<void>((
    Transaction transaction,
  ) async {
    final DocumentReference<Map<String, dynamic>> reference = _sessions.doc(id);
    final DocumentSnapshot<Map<String, dynamic>> snapshot = await transaction
        .get(reference);
    if (!snapshot.exists) throw StateError('Session ended.');
    final GameSession game = GameSession.fromMap(id, snapshot.data()!);
    transaction.update(reference, <String, Object?>{
      'life': List<int>.filled(game.life.length, game.startingLife),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  });

  Future<void> rename(String id, int player, String name) =>
      _firestore.runTransaction<void>((Transaction transaction) async {
        final DocumentReference<Map<String, dynamic>> reference = _sessions.doc(
          id,
        );
        final DocumentSnapshot<Map<String, dynamic>> snapshot =
            await transaction.get(reference);
        if (!snapshot.exists) throw StateError('Session ended.');
        final GameSession game = GameSession.fromMap(id, snapshot.data()!);
        final List<String> names = List<String>.of(game.names);
        names[player] = name.trim();
        if (names[player].isEmpty || names[player].length > 40) {
          throw ArgumentError('Use a name of 1 to 40 characters.');
        }
        transaction.update(reference, <String, Object?>{
          'names': names,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
}
