import 'scan_draft_store.dart';
import 'scan_queue.dart';

class JournaledScanQueueStorage implements ScanQueueStorage {
  JournaledScanQueueStorage({required this.drafts, ScanQueueStorage? storage})
    : storage = storage ?? HiveScanQueueStorage();

  final ScanDraftStore drafts;
  final ScanQueueStorage storage;

  void _requireOwner(String userId) {
    if (userId != drafts.userId) {
      throw ArgumentError.value(userId, 'userId', 'Different scan account.');
    }
  }

  Future<({List<ScanQueueEntry> pending, List<ScanQueueEntry> completed})>
  _recover(String userId) async {
    _requireOwner(userId);
    final List<ScanQueueEntry> completed = await storage.readCompletedEntries(
      userId,
    );
    final List<ScanQueueEntry> pending = await storage.readEntries(userId);
    await drafts.reconcileQueueRemovals(<String>{
      ...pending.map((ScanQueueEntry entry) => entry.operationId),
      ...completed.map((ScanQueueEntry entry) => entry.operationId),
    });
    await drafts.recordQueueEntries(pending, completed: false);
    await drafts.recordQueueEntries(completed, completed: true);
    return (pending: pending, completed: completed);
  }

  @override
  Future<List<ScanQueueEntry>> readEntries(String userId) async =>
      (await _recover(userId)).pending;

  @override
  Future<List<ScanQueueEntry>> readCompletedEntries(String userId) async =>
      (await _recover(userId)).completed;

  @override
  Future<void> upsertEntries(
    String userId,
    List<ScanQueueEntry> entries,
  ) async {
    _requireOwner(userId);
    await storage.upsertEntries(userId, entries);
    await drafts.recordQueueEntries(entries, completed: false);
  }

  @override
  Future<void> completeEntry(String userId, ScanQueueEntry entry) async {
    _requireOwner(userId);
    await storage.completeEntry(userId, entry);
    await drafts.recordQueueEntries(<ScanQueueEntry>[entry], completed: true);
  }

  @override
  Future<void> removeEntries(String userId, List<String> operationIds) async {
    _requireOwner(userId);
    final List<ScanQueueEntry> entries = await storage.readEntries(userId);
    await drafts.recordQueueEntries(
      entries
          .where(
            (ScanQueueEntry entry) => operationIds.contains(entry.operationId),
          )
          .toList(),
      completed: false,
    );
    await drafts.beginQueueRemoval(operationIds);
    await storage.removeEntries(userId, operationIds);
    await drafts.finishQueueRemoval(operationIds);
  }

  @override
  Future<void> removeCompletedEntries(
    String userId,
    List<String> operationIds,
  ) async {
    _requireOwner(userId);
    final List<ScanQueueEntry> completed = await storage.readCompletedEntries(
      userId,
    );
    await drafts.recordQueueEntries(
      completed
          .where(
            (ScanQueueEntry entry) => operationIds.contains(entry.operationId),
          )
          .toList(),
      completed: true,
    );
    await storage.removeCompletedEntries(userId, operationIds);
  }
}
