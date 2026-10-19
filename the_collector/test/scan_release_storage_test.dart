import 'dart:io';
import 'dart:typed_data';

import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/journaled_scan_queue_storage.dart';
import 'package:the_collector/utils/scanning/scan_accounting.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_queue.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';

MTGCard _card() => MTGCard(
  name: 'Lightning Bolt',
  setId: 'set-id',
  description: 'Three damage.',
  flavorText: '',
  cmc: 1,
  typeLine: 'Instant',
  rarity: Rarity.common,
  setType: SetType.expansion,
  manaCost: '{R}',
  scryfallId: 'd88a8e2d-2577-4a67-af86-e33c0ba94114',
  finish: Finish.nonfoil,
  language: 'en',
  setCode: 'm11',
  setName: 'Magic 2011',
  collectorNumber: '146',
);

Future<int> _bytes(Directory directory) async {
  int total = 0;
  await for (final FileSystemEntity entry in directory.list()) {
    if (entry is File) total += await entry.length();
  }
  return total;
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'collector-storage-gate-',
    );
    Hive.init(directory.path);
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('3200 journaled queue operations survive lost acknowledgements and restart without added copies', () async {
    const String owner = 'bulk-queue';
    final List<ScanQueueApproval> approvals = <ScanQueueApproval>[
      for (int index = 0; index < 3200; index++)
        ScanQueueApproval(
          operationId: 'physical-$index',
          card: _card(),
          quantity: 1 + index % 4,
          deckId: index % 3 == 0 ? null : 'container-${index % 3}',
          deckSection: index.isEven
              ? DeckSection.mainboard
              : DeckSection.sideboard,
        ),
    ];
    final Map<String, ScanQueueApproval> expected = <String, ScanQueueApproval>{
      for (final ScanQueueApproval approval in approvals)
        approval.operationId!: approval,
    };
    final Set<String> interrupted = <String>{
      for (int index = 0; index < 3200; index += 37) 'physical-$index',
    };
    final Map<String, int> attempts = <String, int>{};
    final Set<String> remoteReceipts = <String>{};
    int deliveredCopies = 0;
    int active = 0;
    int maximumActive = 0;
    Future<void> write(ScanQueueEntry entry) async {
      active++;
      if (active > maximumActive) maximumActive = active;
      try {
        await Future<void>.delayed(Duration.zero);
        final ScanQueueApproval approval = expected[entry.operationId]!;
        expect(entry.quantity, approval.quantity);
        expect(entry.deckId, approval.deckId);
        expect(entry.deckSection, approval.deckSection);
        expect(entry.card.printingId, approval.card.printingId);
        final int attempt = (attempts[entry.operationId] ?? 0) + 1;
        attempts[entry.operationId] = attempt;
        if (remoteReceipts.add(entry.operationId)) {
          deliveredCopies += entry.quantity;
        }
        if (attempt == 1 && interrupted.contains(entry.operationId)) {
          throw const SocketException(
            'Acknowledgement lost after server commit',
          );
        }
      } finally {
        active--;
      }
    }

    ScanDraftStore drafts = ScanDraftStore(userId: owner);
    ScanQueue queue = ScanQueue(
      userId: owner,
      storage: JournaledScanQueueStorage(drafts: drafts),
      writer: write,
      uploadConcurrency: 6,
    );
    try {
      await queue.load();
      await queue.enqueueBatch(approvals);
      expect(queue.count, 3200);
      await queue.flush();
      expect(
        queue.entries.map((ScanQueueEntry entry) => entry.operationId).toSet(),
        interrupted,
      );
      expect(queue.completedCount, 3200 - interrupted.length);
      expect(remoteReceipts, hasLength(3200));
      expect(deliveredCopies, 8000);
      final int pendingCopies = approvals
          .where(
            (ScanQueueApproval approval) =>
                interrupted.contains(approval.operationId),
          )
          .fold<int>(
            0,
            (int sum, ScanQueueApproval approval) => sum + approval.quantity,
          );
      ScanAccounting totals = await drafts.readAccounting();
      expect(totals.added, 8000);
      expect(totals.pendingDelivery, pendingCopies);
      expect(
        totals.captured,
        0,
        reason: 'A queued addition alone is not a physical capture receipt.',
      );
      queue.dispose();
      await Hive.close();
      drafts = ScanDraftStore(userId: owner);
      queue = ScanQueue(
        userId: owner,
        storage: JournaledScanQueueStorage(drafts: drafts),
        writer: write,
        uploadConcurrency: 6,
      );
      await queue.load();
      expect(
        queue.entries.map((ScanQueueEntry entry) => entry.operationId).toSet(),
        interrupted,
      );
      await queue.enqueueBatch(approvals);
      expect(queue.count, interrupted.length);
      await queue.flush();
      expect(queue.count, 0);
      expect(queue.completedCount, 3200);
      expect(deliveredCopies, 8000);
      expect(
        attempts.values.where((int count) => count == 2),
        hasLength(interrupted.length),
      );
      expect(attempts.values, everyElement(inInclusiveRange(1, 2)));
      expect(maximumActive, inInclusiveRange(2, 6));
      await queue.pruneCompleted(<String>{});
      await drafts.clearCompleted();
      totals = await drafts.readAccounting();
      expect(totals.added, 8000);
      expect(totals.pendingDelivery, 0);
      expect(await drafts.readRecentReceipts(), isEmpty);
      expect(await HiveScanQueueStorage().readEntries(owner), isEmpty);
      expect(await HiveScanQueueStorage().readCompletedEntries(owner), isEmpty);
    } finally {
      queue.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('512 MiB evidence cap preserves camera-sized files and recovers after explicit retirement', () async {
    const int mib = 1024 * 1024;
    final File source = await File('${directory.path}/camera.jpg')
        .writeAsBytes(Uint8List(8 * mib));
    final File cropFile = await File('${directory.path}/crop.jpg')
        .writeAsBytes(Uint8List(2 * mib));
    ScanDraftStore store = ScanDraftStore(userId: 'camera-budget');
    final List<ScanDraftPhoto> photos = <ScanDraftPhoto>[];
    final List<ScanDraftItem> items = <ScanDraftItem>[];
    for (int index = 0; index < 51; index++) {
      final ScanDraftPhoto photo = (await store.importPhotos(<String>[
        source.path,
      ], multipleCards: false)).single;
      photos.add(photo);
      items.add(
        (await store.completePhoto(photo.id, <ScanDraftItem>[
          ScanDraftItem(
            id: 'card-$index',
            photoId: photo.id,
            crop: ScanCrop(
              imagePath: cropFile.path,
              width: 2000,
              height: 2800,
              rectified: true,
              sourceCorners: const <ScanPoint>[],
              lines: const <ScanTextLine>[],
            ),
          ),
        ])).single,
      );
    }
    final ScanDraftPhoto pending = (await store.importPhotos(<String>[
      cropFile.path,
    ], multipleCards: false)).single;
    final Directory evidence = File(photos.first.imagePath).parent;
    expect(await _bytes(evidence), ScanDraftStore.defaultMaximumImageBytes);
    await Hive.close();
    store = ScanDraftStore(userId: 'camera-budget');
    await expectLater(
      store.importPhotos(
        <String>[source.path],
        multipleCards: false,
        ownedCameraSource: true,
      ),
      throwsA(isA<ScanDraftStorageBudgetExceeded>()),
    );
    expect(await source.length(), 8 * mib);
    expect(
      (await store.readItems()).map((ScanDraftItem item) => item.id).toSet(),
      items.map((ScanDraftItem item) => item.id).toSet(),
    );
    expect((await store.readPhotos()).single.id, pending.id);
    for (final ScanDraftPhoto photo in photos) {
      expect(await File(photo.imagePath).length(), 8 * mib);
    }
    for (final ScanDraftItem item in items) {
      expect(await File(item.crop.imagePath).length(), 2 * mib);
    }
    await store.removeItems(<String>[items.first.id]);
    await store.cleanPendingImages();
    expect(await _bytes(evidence), 502 * mib);
    final ScanDraftPhoto retried = (await store.importPhotos(<String>[
      source.path,
    ], multipleCards: false)).single;
    expect(await File(retried.imagePath).length(), 8 * mib);
    expect(await _bytes(evidence), 510 * mib);
    expect(await store.readItems(), hasLength(50));
    expect(
      (await store.readPhotos())
          .map((ScanDraftPhoto photo) => photo.id)
          .toSet(),
      <String>{pending.id, retried.id},
    );
    expect(await source.exists(), isTrue);
    expect(await cropFile.exists(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
