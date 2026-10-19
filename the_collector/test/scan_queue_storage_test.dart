import 'dart:io';

import 'package:collector_models/card/mtg_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/scan_queue.dart';

MTGCard _card() => MTGCard(
  name: 'Lightning Bolt',
  setId: 'set-id',
  description: 'Lightning Bolt deals 3 damage to any target.',
  flavorText: '',
  cmc: 1,
  typeLine: 'Instant',
  rarity: Rarity.common,
  setType: SetType.expansion,
  manaCost: '{R}',
  scryfallId: 'd88a8e2d-2577-4a67-af86-e33c0ba94114',
  finish: Finish.foil,
  language: 'en',
  setCode: 'm11',
  setName: 'Magic 2011',
  collectorNumber: '123a',
  imageUrl: 'https://cards.scryfall.io/normal/front/d/8/d88a8e2d-2577-4a67-af86-e33c0ba94114.jpg',
);

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('collector-queue-');
    Hive.init(directory.path);
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'completed additions survive restart until their capture is retired',
    () async {
      final HiveScanQueueStorage storage = HiveScanQueueStorage();
      final ScanQueue queue = ScanQueue(
        userId: 'Alice',
        storage: storage,
        writer: (ScanQueueEntry _) async {},
      );
      await queue.load();
      final ScanQueueApproval approval = ScanQueueApproval(
        operationId: 'capture_0',
        card: _card(),
        quantity: 3,
        deckId: 'binder',
      );
      await queue.enqueueBatch(<ScanQueueApproval>[approval]);
      final ScanQueueEntry pending = queue.entries.single;
      await queue.flush();
      expect(queue.hasCompleted('capture_0'), isTrue);
      expect(queue.count, 0);
      // Simulate a completion persisted before pending-record cleanup was interrupted.
      await storage.upsertEntries('Alice', <ScanQueueEntry>[pending]);
      queue.dispose();
      await Hive.close();

      int uploads = 0;
      final HiveScanQueueStorage reopened = HiveScanQueueStorage();
      final ScanQueue resumed = ScanQueue(
        userId: 'Alice',
        storage: reopened,
        writer: (ScanQueueEntry _) async {
          uploads++;
        },
      );
      await resumed.load();
      expect(resumed.count, 0);
      expect(resumed.hasCompleted('capture_0'), isTrue);
      expect(await reopened.readCompletedEntries('alice'), isEmpty);
      await resumed.enqueueBatch(<ScanQueueApproval>[approval]);
      await resumed.flush();
      expect(uploads, 0);
      expect(resumed.canUndo('capture_0'), isFalse);
      await expectLater(
        resumed.enqueueBatch(<ScanQueueApproval>[
          ScanQueueApproval(
            operationId: 'capture_0',
            card: _card(),
            quantity: 4,
            deckId: 'binder',
          ),
        ]),
        throwsStateError,
      );
      await resumed.pruneCompleted(<String>{'capture_0'});
      expect(resumed.completedCount, 1);
      await resumed.pruneCompleted(<String>{});
      expect(resumed.completedCount, 0);
      resumed.dispose();
      await Hive.close();
      final HiveScanQueueStorage cleaned = HiveScanQueueStorage();
      expect(await cleaned.readEntries('Alice'), isEmpty);
      expect(await cleaned.readCompletedEntries('Alice'), isEmpty);
    },
  );

  test(
    'real account boxes survive reopen and isolate case-distinct owners',
    () async {
      final HiveScanQueueStorage storage = HiveScanQueueStorage();
      final ScanQueue alice = ScanQueue(
        userId: 'Alice',
        storage: storage,
        writer: (ScanQueueEntry _) async {},
      );
      await alice.load();
      await alice.enqueue(card: _card(), quantity: 7, deckId: 'deck');
      final String operation = alice.entries.single.operationId;
      await Hive.close();
      final HiveScanQueueStorage reopened = HiveScanQueueStorage();
      final List<ScanQueueEntry> restored = await reopened.readEntries('Alice');
      expect(restored.single.operationId, operation);
      expect(restored.single.quantity, 7);
      expect(restored.single.deckId, 'deck');
      expect(await reopened.readEntries('alice'), isEmpty);
      alice.dispose();
    },
  );

  for (final int size in <int>[1000, 10000]) {
    test('real storage bulk approval and restart benchmark $size', () async {
      final ScanQueue queue = ScanQueue(
        userId: 'benchmark',
        storage: HiveScanQueueStorage(),
        writer: (ScanQueueEntry _) async {},
      );
      await queue.load();
      final Stopwatch writeTime = Stopwatch()..start();
      await queue.enqueueBatch(
        List<ScanQueueApproval>.generate(
          size,
          (_) => ScanQueueApproval(card: _card()),
        ),
      );
      writeTime.stop();
      final String first = queue.entryAt(0).operationId;
      await Hive.close();
      final ScanQueue resumed = ScanQueue(
        userId: 'benchmark',
        storage: HiveScanQueueStorage(),
        writer: (ScanQueueEntry _) async {},
      );
      final Stopwatch resumeTime = Stopwatch()..start();
      await resumed.load();
      resumeTime.stop();
      expect(resumed.count, size);
      expect(
        resumed.entries.any(
          (ScanQueueEntry entry) => entry.operationId == first,
        ),
        isTrue,
      );
      final File data = directory.listSync().whereType<File>().firstWhere(
        (File file) => file.path.endsWith('.hive'),
      );
      final int before = await data.length();
      final Stopwatch acknowledgementTime = Stopwatch()..start();
      await resumed.remove(first);
      acknowledgementTime.stop();
      final int growth = await data.length() - before;
      expect(resumed.count, size - 1);
      expect(growth, lessThan(1024));
      // Performance measurements are informational; durability assertions are deterministic.
      // ignore: avoid_print
      print(
        'queue benchmark $size: write=${writeTime.elapsedMilliseconds}ms reopen=${resumeTime.elapsedMilliseconds}ms ack=${acknowledgementTime.elapsedMicroseconds}us bytes=$before ackGrowth=$growth',
      );
      queue.dispose();
      resumed.dispose();
    });
  }
}
