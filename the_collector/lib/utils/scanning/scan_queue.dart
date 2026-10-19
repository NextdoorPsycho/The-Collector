import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import '../collection_ingestion.dart';
import '../auth/local_account_data.dart';

@immutable
class ScanQueueEntry {
  final String operationId;
  final MTGCard card;
  final int quantity;
  final String? deckId;
  final DeckSection deckSection;
  final DateTime createdAt;
  final DateTime? undoUntil;
  final String? error;

  const ScanQueueEntry({
    required this.operationId,
    required this.card,
    required this.quantity,
    required this.createdAt,
    this.undoUntil,
    this.deckId,
    this.deckSection = DeckSection.mainboard,
    this.error,
  });

  factory ScanQueueEntry.fromMap(Map<String, Object?> value) => ScanQueueEntry(
    operationId: value['operationId'] as String,
    card: MTGCardMapper.fromMap(
      Map<String, Object?>.from(value['card'] as Map<Object?, Object?>),
    ),
    quantity: value['quantity'] as int,
    createdAt: DateTime.parse(value['createdAt'] as String),
    undoUntil: value['undoUntil'] == null
        ? null
        : DateTime.parse(value['undoUntil'] as String),
    deckId: value['deckId'] as String?,
    deckSection: DeckSection.values.byName(value['deckSection'] as String),
    error: value['error'] as String?,
  );

  Map<String, Object?> toMap() => <String, Object?>{
    'operationId': operationId,
    'card': card.toMap(),
    'quantity': quantity,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'undoUntil': undoUntil?.toUtc().toIso8601String(),
    'deckId': deckId,
    'deckSection': deckSection.name,
    'error': error,
  };

  ScanQueueEntry withError(String? message) => ScanQueueEntry(
    operationId: operationId,
    card: card,
    quantity: quantity,
    createdAt: createdAt,
    undoUntil: undoUntil,
    deckId: deckId,
    deckSection: deckSection,
    error: message,
  );
}

@immutable
class ScanQueueApproval {
  final String? operationId;
  final MTGCard card;
  final int quantity;
  final String? deckId;
  final DeckSection deckSection;

  const ScanQueueApproval({
    this.operationId,
    required this.card,
    this.quantity = 1,
    this.deckId,
    this.deckSection = DeckSection.mainboard,
  });
}

abstract interface class ScanQueueStorage {
  Future<List<ScanQueueEntry>> readEntries(String userId);
  Future<List<ScanQueueEntry>> readCompletedEntries(String userId);
  Future<void> upsertEntries(String userId, List<ScanQueueEntry> entries);
  Future<void> removeEntries(String userId, List<String> operationIds);
  Future<void> completeEntry(String userId, ScanQueueEntry entry);
  Future<void> removeCompletedEntries(String userId, List<String> operationIds);
}

typedef ScanQueueBoxOpener = Future<Box<String>> Function(String name);

class HiveScanQueueStorage implements ScanQueueStorage {
  HiveScanQueueStorage({ScanQueueBoxOpener? openBox})
    : _openBox = openBox ?? Hive.openBox<String>;

  final ScanQueueBoxOpener _openBox;
  final Map<String, Future<Box<String>>> _boxes =
      <String, Future<Box<String>>>{};

  Future<Box<String>> _box(String userId) {
    LocalAccountData.requireWritable(userId);
    return _boxes.putIfAbsent(userId, () => _openOwnerBox(userId));
  }

  Future<Box<String>> _openOwnerBox(String userId) async {
    try {
      final String encoded = sha256.convert(utf8.encode(userId)).toString();
      final Box<String> box = await _openBox('scanner_queue_v2_$encoded');
      return box;
    } catch (_) {
      _boxes.remove(userId);
      rethrow;
    }
  }

  @override
  Future<List<ScanQueueEntry>> readEntries(
    String userId,
  ) => LocalAccountData.mutate(userId, () async {
    final Box<String> box = await _box(userId);
    final List<ScanQueueEntry> entries = <ScanQueueEntry>[];
    for (final Object? key in box.keys) {
      if (key is String &&
          (key.startsWith('completed:') || box.containsKey('completed:$key'))) {
        continue;
      }
      final ScanQueueEntry entry = ScanQueueEntry.fromMap(
        Map<String, Object?>.from(
          jsonDecode(box.get(key)!) as Map<Object?, Object?>,
        ),
      );
      if (key != entry.operationId) {
        throw const FormatException('Saved scan operation has an invalid key.');
      }
      entries.add(entry);
    }
    return entries;
  });

  @override
  Future<List<ScanQueueEntry>> readCompletedEntries(String userId) =>
      LocalAccountData.mutate(userId, () async {
        final Box<String> box = await _box(userId);
        return <ScanQueueEntry>[
          for (final String key in box.keys.whereType<String>().where(
            (String key) => key.startsWith('completed:'),
          ))
            _completedEntry(key, box.get(key)!),
        ];
      });

  ScanQueueEntry _completedEntry(String key, String value) {
    final ScanQueueEntry entry = ScanQueueEntry.fromMap(
      Map<String, Object?>.from(jsonDecode(value) as Map<Object?, Object?>),
    );
    if (key != 'completed:${entry.operationId}') {
      throw const FormatException('Invalid completed operation.');
    }
    return entry;
  }

  @override
  Future<void> completeEntry(String userId, ScanQueueEntry entry) =>
      LocalAccountData.mutate(userId, () async {
        final Box<String> box = await _box(userId);
        await box.put(
          'completed:${entry.operationId}',
          jsonEncode(entry.withError(null).toMap()),
        );
        await box.flush();
        try {
          await box.delete(entry.operationId);
          await box.flush();
        } catch (_) {
          // The durable completion supersedes a pending record left by failed cleanup.
        }
      });

  @override
  Future<void> removeCompletedEntries(
    String userId,
    List<String> operationIds,
  ) => LocalAccountData.mutate(userId, () async {
    final Box<String> box = await _box(userId);
    // Remove superseded pending records before their completion receipts.
    await box.deleteAll(operationIds);
    await box.flush();
    await box.deleteAll(operationIds.map((String id) => 'completed:$id'));
    await box.flush();
  });

  @override
  Future<void> upsertEntries(String userId, List<ScanQueueEntry> entries) =>
      LocalAccountData.mutate(userId, () async {
        final Box<String> box = await _box(userId);
        LocalAccountData.requireWritable(userId);
        await box.putAll(<String, String>{
          for (final ScanQueueEntry entry in entries)
            entry.operationId: jsonEncode(entry.toMap()),
        });
        await box.flush();
      });

  @override
  Future<void> removeEntries(String userId, List<String> operationIds) =>
      LocalAccountData.mutate(userId, () async {
        final Box<String> box = await _box(userId);
        await box.deleteAll(operationIds);
        await box.flush();
      });
}

typedef ScanQueueWriter = Future<void> Function(ScanQueueEntry entry);

class _QueueEntries extends ListBase<ScanQueueEntry> {
  _QueueEntries(this.ids, this.values);
  final List<String> ids;
  final Map<String, ScanQueueEntry> values;
  @override
  int get length => ids.length;
  @override
  set length(int value) =>
      throw UnsupportedError('Queue entries are read-only.');
  @override
  ScanQueueEntry operator [](int index) => values[ids[index]]!;
  @override
  void operator []=(int index, ScanQueueEntry value) =>
      throw UnsupportedError('Queue entries are read-only.');
}

class ScanQueue extends ChangeNotifier {
  final String userId;
  final ScanQueueStorage storage;
  final ScanQueueWriter _writer;
  final DateTime Function() _now;
  final int uploadConcurrency;
  final Map<String, ScanQueueEntry> _entries = <String, ScanQueueEntry>{};
  final Map<String, ScanQueueEntry> _completed = <String, ScanQueueEntry>{};
  final Set<String> _sendingIds = <String>{};
  final Set<String> _removingIds = <String>{};
  Completer<void>? _scheduleChanged;
  final List<String> _entryIds = <String>[];
  final Map<String, int> _positions = <String, int>{};
  late final List<ScanQueueEntry> _view = UnmodifiableListView<ScanQueueEntry>(
    _QueueEntries(_entryIds, _entries),
  );
  Future<void> _mutations = Future<void>.value();
  Timer? _progressNotification;
  int _failedCount = 0;
  int _quantityCount = 0;
  bool _loaded = false;
  bool _disposed = false;
  bool _flushing = false;
  bool _paused = false;

  ScanQueue({
    required this.userId,
    ScanQueueStorage? storage,
    ScanQueueWriter? writer,
    DateTime Function()? now,
    this.uploadConcurrency = 4,
  }) : storage = storage ?? HiveScanQueueStorage(),
       _now = now ?? DateTime.now,
       _writer =
           writer ??
           ((ScanQueueEntry entry) async {
             await CollectionIngestion().add(
               userId: userId,
               operationId: entry.operationId,
               card: entry.card,
               quantity: entry.quantity,
               deckId: entry.deckId,
               deckSection: entry.deckSection,
             );
           }) {
    if (userId.isEmpty || userId.contains('/')) {
      throw ArgumentError.value(userId, 'userId');
    }
    if (uploadConcurrency < 1 || uploadConcurrency > 16) {
      throw ArgumentError.value(uploadConcurrency, 'uploadConcurrency');
    }
  }

  List<ScanQueueEntry> get entries => _view;
  int get count => _entries.length;
  int get failedCount => _failedCount;
  int get quantityCount => _quantityCount;
  ScanQueueEntry entryAt(int index) => entries[index];
  bool get loaded => _loaded;
  bool get sending => _flushing;
  bool get paused => _paused;
  String? get sendingId => _sendingIds.firstOrNull;
  bool isSending(String operationId) => _sendingIds.contains(operationId);
  bool hasCompleted(String operationId) => _completed.containsKey(operationId);
  int get completedCount => _completed.length;

  Future<void> pruneCompleted(Set<String> liveCaptureIds) =>
      _serialize(() async {
        _requireLoaded();
        final List<String> retired = _completed.keys
            .where((String id) => !liveCaptureIds.contains(id))
            .toList();
        if (retired.isEmpty) return;
        await storage.removeCompletedEntries(userId, retired);
        for (final String id in retired) {
          _completed.remove(id);
        }
        _notify();
      });

  bool canUndo(String operationId) {
    final DateTime? until = _entries[operationId]?.undoUntil;
    return !_disposed &&
        until != null &&
        _now().isBefore(until) &&
        !_sendingIds.contains(operationId) &&
        !_removingIds.contains(operationId);
  }

  Future<bool> undo(
    String operationId, {
    Future<void> Function()? beforeRemove,
  }) async {
    _requireLoaded();
    if (!canUndo(operationId)) return false;
    // Claim the entry before awaiting storage so expiry cannot start its upload.
    _removingIds.add(operationId);
    _wakeScheduler();
    try {
      await _serialize(() async {
        await beforeRemove?.call();
        await storage.removeEntries(userId, <String>[operationId]);
        _removeLocal(operationId);
        _notify();
      });
      return true;
    } finally {
      _removingIds.remove(operationId);
      _wakeScheduler();
    }
  }

  Future<void> load() => _serialize(() async {
    if (_loaded) {
      return;
    }
    final List<ScanQueueEntry> completed = await storage.readCompletedEntries(
      userId,
    );
    final List<ScanQueueEntry> decoded = await storage.readEntries(userId);
    for (final ScanQueueEntry entry in completed) {
      _completed[entry.operationId] = entry;
    }
    final Map<String, ScanQueueEntry> restored = <String, ScanQueueEntry>{};
    for (final ScanQueueEntry entry in decoded) {
      if (restored.containsKey(entry.operationId)) {
        throw const FormatException(
          'Saved scan queue contains duplicate operations.',
        );
      }
      restored[entry.operationId] = entry;
    }
    for (final ScanQueueEntry entry in restored.values) {
      if (_completed.containsKey(entry.operationId)) continue;
      _append(entry);
    }
    _loaded = true;
    _notify();
  });

  Future<void> enqueue({
    required MTGCard card,
    required int quantity,
    String? deckId,
    DeckSection deckSection = DeckSection.mainboard,
  }) => enqueueBatch(<ScanQueueApproval>[
    ScanQueueApproval(
      card: card,
      quantity: quantity,
      deckId: deckId,
      deckSection: deckSection,
    ),
  ]);

  Future<void> enqueueBatch(
    List<ScanQueueApproval> approvals, {
    Duration undoWindow = Duration.zero,
  }) => _serialize(() async {
    _requireLoaded();
    if (undoWindow.isNegative) {
      throw ArgumentError.value(undoWindow, 'undoWindow');
    }
    final DateTime createdAt = _now().toUtc();
    final List<ScanQueueEntry> additions = <ScanQueueEntry>[];
    final Map<String, ScanQueueEntry> batch = <String, ScanQueueEntry>{};
    for (final ScanQueueApproval approval in approvals) {
      CollectionIngestion.inventoryId(approval.card);
      if (approval.quantity <= 0 || approval.quantity > 1000000) {
        throw ArgumentError.value(approval.quantity, 'quantity');
      }
      if (approval.deckId != null &&
          (approval.deckId!.isEmpty || approval.deckId!.contains('/'))) {
        throw ArgumentError.value(approval.deckId, 'deckId');
      }
      final String operationId = approval.operationId ?? const Uuid().v4();
      if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(operationId)) {
        throw ArgumentError.value(operationId, 'operationId');
      }
      final ScanQueueEntry? existing =
          _entries[operationId] ??
          _completed[operationId] ??
          batch[operationId];
      if (existing != null) {
        if (CollectionIngestion.inventoryId(existing.card) !=
                CollectionIngestion.inventoryId(approval.card) ||
            existing.card.language != approval.card.language ||
            existing.quantity != approval.quantity ||
            existing.deckId != approval.deckId ||
            existing.deckSection != approval.deckSection) {
          throw StateError('Operation ID already belongs to another approval.');
        }
        continue;
      }
      final ScanQueueEntry entry = ScanQueueEntry(
        operationId: operationId,
        card: approval.card,
        quantity: approval.quantity,
        deckId: approval.deckId,
        deckSection: approval.deckSection,
        createdAt: createdAt,
        undoUntil: undoWindow == Duration.zero
            ? null
            : createdAt.add(undoWindow),
      );
      additions.add(entry);
      batch[operationId] = entry;
    }
    if (additions.isEmpty) {
      return;
    }
    await storage.upsertEntries(userId, additions);
    for (final ScanQueueEntry entry in additions) {
      _append(entry);
    }
    _notify();
    _wakeScheduler();
  });

  /// Stops scheduling new uploads. Already submitted writes finish safely.
  void pauseUploads() {
    _paused = true;
    _wakeScheduler();
    _notify();
  }

  void cancelUploads() => pauseUploads();

  Future<void> resumeUploads() {
    LocalAccountData.requireWritable(userId);
    if (_flushing || _disposed) {
      return Future<void>.value();
    }
    _paused = false;
    _notify();
    return flush();
  }

  /// Durable approvals precede server attempts; operation receipts make retries safe.
  Future<void> flush({bool retryFailures = true}) async {
    LocalAccountData.requireWritable(userId);
    _requireLoaded();
    if (_flushing || _paused || _disposed) {
      return;
    }
    _flushing = true;
    final Set<String> operations = _entries.values
        .where((ScanQueueEntry entry) => retryFailures || entry.error == null)
        .map((ScanQueueEntry entry) => entry.operationId)
        .toSet();
    final Set<String> attempted = <String>{};
    Future<void> worker(List<String> ready, int Function() takeNext) async {
      while (!_paused && !_disposed && !LocalAccountData.isDeleting(userId)) {
        final int index = takeNext();
        if (index >= ready.length) return;
        final String id = ready[index];
        if (_removingIds.contains(id)) continue;
        final ScanQueueEntry? entry = _entries[id];
        operations.remove(id);
        attempted.add(id);
        if (entry == null || (!retryFailures && entry.error != null)) {
          continue;
        }
        _sendingIds.add(id);
        _notifyProgress();
        // Firestore writes cannot be cancelled; a deadline pauses scheduling without releasing their slots.
        final Timer deadline = Timer(const Duration(seconds: 25), () {
          _paused = true;
          _wakeScheduler();
          _notify();
        });
        bool writerCompleted = false;
        try {
          await _writer(entry);
          writerCompleted = true;
          if (_disposed || LocalAccountData.isDeleting(userId)) return;
          await _serialize(() async {
            await storage.completeEntry(userId, entry);
            _completed[id] = entry;
            _removeLocal(id);
          });
        } catch (error) {
          if (_disposed || LocalAccountData.isDeleting(userId)) return;
          await _serialize(() async {
            final ScanQueueEntry? current = _entries[id];
            if (current == null) {
              return;
            }
            final ScanQueueEntry failed = current.withError(
              _uploadError(error, writerCompleted: writerCompleted),
            );
            try {
              await storage.upsertEntries(userId, <ScanQueueEntry>[failed]);
            } catch (_) {
              // The original durable operation remains available after a storage failure.
            }
            if (current.error == null) {
              _failedCount++;
            }
            _entries[id] = failed;
          });
        } finally {
          deadline.cancel();
          _sendingIds.remove(id);
          _notifyProgress();
        }
      }
    }

    _notify();
    try {
      while (!_paused && !_disposed && !LocalAccountData.isDeleting(userId)) {
        operations.addAll(
          _entries.values
              .where(
                (ScanQueueEntry entry) =>
                    !attempted.contains(entry.operationId) &&
                    (retryFailures || entry.error == null),
              )
              .map((ScanQueueEntry entry) => entry.operationId),
        );
        if (operations.isEmpty) break;
        final DateTime now = _now();
        final List<String> ready = <String>[];
        DateTime? earliest;
        operations.removeWhere((String id) => !_entries.containsKey(id));
        for (final String id in operations) {
          if (_removingIds.contains(id)) continue;
          final DateTime? until = _entries[id]!.undoUntil;
          if (until == null || !now.isBefore(until)) {
            ready.add(id);
          } else if (earliest == null || until.isBefore(earliest)) {
            earliest = until;
          }
        }
        if (ready.isEmpty) {
          if (operations.isEmpty) break;
          await _waitForSchedule(earliest?.difference(now));
          continue;
        }
        int next = 0;
        await Future.wait<void>(
          List<Future<void>>.generate(
            uploadConcurrency.clamp(1, ready.length),
            (_) => worker(ready, () => next++),
          ),
        );
      }
    } finally {
      _flushing = false;
      _progressNotification?.cancel();
      _progressNotification = null;
      _notify();
    }
  }

  String _uploadError(Object error, {required bool writerCompleted}) {
    if (writerCompleted) {
      return 'Addition saved, but its pending record could not be cleared on this device. Free storage, then retry; the same operation will not add another copy.';
    }
    if (error is FirebaseException) {
      switch (error.code) {
        case 'permission-denied':
          return 'Upload blocked by Firebase permissions (permission-denied). Check account access and Firestore rules, then retry.';
        case 'unauthenticated':
          return 'Sign in to this account again, then retry (unauthenticated). Your addition remains saved on this device.';
        case 'unavailable':
        case 'deadline-exceeded':
        case 'network-request-failed':
          return 'Upload connection failed (${error.code}). Check your connection, then retry; the same operation will not add another copy.';
        case 'resource-exhausted':
          return 'Firebase upload limit reached (resource-exhausted). Wait for the limit to reset, then retry.';
        case 'failed-precondition':
          return 'Firebase could not accept this upload (failed-precondition). Check database configuration, then retry.';
      }
    }
    if (error is StateError) {
      switch (error.message) {
        case 'Destination group no longer exists.':
          return 'The destination group no longer exists. Restore it before retrying; this addition remains saved on this device.';
        case 'Operation ID was already used for another addition.':
          return 'This operation was already saved with different card details. Its receipt must be reconciled before retrying; do not submit it as a new addition.';
        case 'Stored printing metadata does not match this addition.':
          return 'The collection has conflicting metadata for this printing. Correct the stored printing before retrying.';
        case 'Account changed.':
          return 'Sign in to the account that captured this card, then retry. Its addition remains saved on this device.';
      }
    }
    return 'Could not upload this addition. Check your connection and destination, then retry.';
  }

  Future<void> remove(String operationId) => _serialize(() async {
    _requireLoaded();
    if (isSending(operationId)) {
      throw StateError('Wait for the current save before removing this entry.');
    }
    if (!_entries.containsKey(operationId)) {
      return;
    }
    _removingIds.add(operationId);
    try {
      await storage.removeEntries(userId, <String>[operationId]);
      _removeLocal(operationId);
      _notify();
    } finally {
      _removingIds.remove(operationId);
      _wakeScheduler();
    }
  });

  Future<void> _waitForSchedule(Duration? delay) async {
    final Completer<void> changed = Completer<void>();
    _scheduleChanged = changed;
    final Timer? timer = delay == null
        ? null
        : Timer(delay, () {
            if (!changed.isCompleted) changed.complete();
          });
    try {
      await changed.future;
    } finally {
      timer?.cancel();
      if (identical(_scheduleChanged, changed)) _scheduleChanged = null;
    }
  }

  void _wakeScheduler() {
    final Completer<void>? changed = _scheduleChanged;
    if (changed != null && !changed.isCompleted) changed.complete();
  }

  void _append(ScanQueueEntry entry) {
    _positions[entry.operationId] = _entryIds.length;
    _entryIds.add(entry.operationId);
    _entries[entry.operationId] = entry;
    _quantityCount += entry.quantity;
    if (entry.error != null) {
      _failedCount++;
    }
  }

  void _removeLocal(String operationId) {
    final int? index = _positions.remove(operationId);
    if (index == null) {
      return;
    }
    final String last = _entryIds.removeLast();
    if (index < _entryIds.length) {
      _entryIds[index] = last;
      _positions[last] = index;
    }
    final ScanQueueEntry removed = _entries.remove(operationId)!;
    _quantityCount -= removed.quantity;
    if (removed.error != null) {
      _failedCount--;
    }
  }

  Future<void> _serialize(Future<void> Function() action) {
    final Future<void> next = _mutations.then(
      (_) => LocalAccountData.mutate(userId, action),
    );
    _mutations = next.catchError((Object _) {});
    return next;
  }

  void _requireLoaded() {
    if (!_loaded) {
      throw StateError('Load the scan queue before using it.');
    }
  }

  void _notifyProgress() {
    if (_disposed || _progressNotification != null) {
      return;
    }
    _progressNotification = Timer(const Duration(milliseconds: 16), () {
      _progressNotification = null;
      _notify();
    });
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _paused = true;
    _wakeScheduler();
    _progressNotification?.cancel();
    super.dispose();
  }
}
