import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/scanning/scan_capture_feedback.dart';

void main() {
  final DateTime now = DateTime.utc(2026, 10, 13);

  test('only acknowledged cards get checks and a bounded cue', () {
    final ScanCaptureFeedback feedback = ScanCaptureFeedback();
    expect(feedback.cueVisible(now), isFalse);
    expect(feedback.safeTrackIds, isEmpty);
    expect(
      feedback.acknowledge(
        generation: feedback.generation,
        receipts: <({String receiptId, String? trackId})>[
          (receiptId: 'photo_a', trackId: 'card_a'),
          (receiptId: 'photo_b', trackId: null),
        ],
        now: now,
      ),
      isTrue,
    );
    expect(feedback.safeTrackIds, <String>{'card_a'});
    expect(feedback.containsReceipt('photo_b'), isTrue);
    expect(feedback.containsReceipt('unread_card'), isFalse);
    expect(feedback.cueVisible(now), isTrue);
    expect(
      feedback.cueVisible(now.add(ScanCaptureFeedback.cueDuration)),
      isFalse,
    );
    expect(feedback.safeTrackIds, <String>{'card_a'});
  });

  test(
    'retry and refinement of the same physical receipt do not cue again',
    () {
      final ScanCaptureFeedback feedback = ScanCaptureFeedback();
      bool acknowledge(String track, DateTime time) => feedback.acknowledge(
        generation: feedback.generation,
        receipts: <({String receiptId, String? trackId})>[
          (receiptId: 'physical_card', trackId: track),
        ],
        now: time,
      );
      expect(acknowledge('original_track', now), isTrue);
      final DateTime later = now.add(const Duration(seconds: 3));
      expect(acknowledge('refined_track', later), isFalse);
      expect(feedback.cueVisible(later), isFalse);
      expect(feedback.safeTrackIds, contains('refined_track'));
    },
  );

  test(
    'a late save cannot cue or mark cards in a different camera context',
    () {
      final ScanCaptureFeedback feedback = ScanCaptureFeedback();
      final int shutterGeneration = feedback.generation;
      feedback.invalidate();
      expect(
        feedback.acknowledge(
          generation: shutterGeneration,
          receipts: <({String receiptId, String? trackId})>[
            (receiptId: 'old_photo', trackId: 'old_track'),
          ],
          now: now,
        ),
        isFalse,
      );
      expect(feedback.safeTrackIds, isEmpty);
      expect(feedback.containsReceipt('old_photo'), isFalse);
      expect(feedback.cueVisible(now), isFalse);
    },
  );

  test(
    'failed clear cancels feedback but does not repeat an existing receipt',
    () {
      final ScanCaptureFeedback feedback = ScanCaptureFeedback();
      bool acknowledge() => feedback.acknowledge(
        generation: feedback.generation,
        receipts: <({String receiptId, String? trackId})>[
          (receiptId: 'photo', trackId: 'track'),
        ],
        now: now,
      );
      expect(acknowledge(), isTrue);
      feedback.invalidate();
      expect(feedback.cueVisible(now), isFalse);
      expect(feedback.safeTrackIds, isEmpty);
      expect(acknowledge(), isFalse);
      feedback.invalidate(forgetReceipts: true);
      expect(acknowledge(), isTrue);
    },
  );

  test('empty acknowledgements never announce capture', () {
    final ScanCaptureFeedback feedback = ScanCaptureFeedback();
    expect(
      feedback.acknowledge(
        generation: feedback.generation,
        receipts: <({String receiptId, String? trackId})>[
          (receiptId: '', trackId: 'track'),
        ],
        now: now,
      ),
      isFalse,
    );
    expect(feedback.safeTrackIds, isEmpty);
    expect(feedback.cueVisible(now), isFalse);
  });

  test(
    'saved checks are immediate while signals respect the exact boundary',
    () {
      final ScanCaptureFeedback feedback = ScanCaptureFeedback();
      expect(feedback.takeSignal(now), isFalse);
      feedback.acknowledge(
        generation: feedback.generation,
        receipts: <({String receiptId, String? trackId})>[
          (receiptId: 'first', trackId: 'card_a'),
          (receiptId: 'second', trackId: 'card_b'),
        ],
        now: now,
      );
      expect(feedback.safeTrackIds, <String>{'card_a', 'card_b'});
      expect(feedback.takeSignal(now), isTrue);
      expect(feedback.takeSignal(now), isFalse);
      final DateTime ready = now.add(ScanCaptureFeedback.signalGracePeriod);
      final DateTime before = ready.subtract(const Duration(microseconds: 1));
      feedback.acknowledge(
        generation: feedback.generation,
        receipts: <({String receiptId, String? trackId})>[
          (receiptId: 'third', trackId: 'card_c'),
        ],
        now: before,
      );
      expect(feedback.safeTrackIds, contains('card_c'));
      expect(feedback.takeSignal(before), isFalse);
      feedback.acknowledge(
        generation: feedback.generation,
        receipts: <({String receiptId, String? trackId})>[
          (receiptId: 'fourth', trackId: 'card_d'),
        ],
        now: ready,
      );
      expect(feedback.safeTrackIds, contains('card_d'));
      expect(feedback.takeSignal(ready), isTrue);
    },
  );

  test('burst acknowledgements are silent and never replay later', () {
    final ScanCaptureFeedback feedback = ScanCaptureFeedback();
    void save(String receipt, DateTime time) => feedback.acknowledge(
      generation: feedback.generation,
      receipts: <({String receiptId, String? trackId})>[
        (receiptId: receipt, trackId: receipt),
      ],
      now: time,
    );
    save('first', now);
    expect(feedback.takeSignal(now), isTrue);
    final DateTime burst = now.add(const Duration(milliseconds: 300));
    save('second', burst);
    expect(feedback.safeTrackIds, contains('second'));
    expect(feedback.takeSignal(burst), isFalse);
    final DateTime next = burst.add(ScanCaptureFeedback.signalGracePeriod);
    expect(feedback.takeSignal(next), isFalse);
    save('third', next);
    expect(feedback.takeSignal(next), isTrue);
  });

  test(
    'dismissed stale capture keeps receipts and signal throttle without replay',
    () {
      final ScanCaptureFeedback feedback = ScanCaptureFeedback();
      void save(String receipt, DateTime time) => feedback.acknowledge(
        generation: feedback.generation,
        receipts: <({String receiptId, String? trackId})>[
          (receiptId: receipt, trackId: receipt),
        ],
        now: time,
      );
      save('first', now);
      expect(feedback.takeSignal(now), isTrue);
      final DateTime stale = now.add(const Duration(milliseconds: 100));
      save('old_photo', stale);
      feedback.dismissCue();
      expect(feedback.containsReceipt('old_photo'), isTrue);
      expect(feedback.safeTrackIds, contains('old_photo'));
      expect(feedback.cueVisible(stale), isFalse);
      expect(feedback.takeSignal(stale), isFalse);
      final DateTime immediate = now.add(const Duration(milliseconds: 200));
      save('second', immediate);
      expect(feedback.takeSignal(immediate), isFalse);
      final DateTime ready = now.add(ScanCaptureFeedback.signalGracePeriod);
      expect(feedback.takeSignal(ready), isFalse);
      save('third', ready);
      expect(feedback.takeSignal(ready), isTrue);
    },
  );

  test('pause and clear cannot bypass the sound grace period', () {
    for (final bool clear in <bool>[false, true]) {
      final ScanCaptureFeedback feedback = ScanCaptureFeedback();
      void save(String id, DateTime time) => feedback.acknowledge(
        generation: feedback.generation,
        receipts: <({String receiptId, String? trackId})>[
          (receiptId: id, trackId: id),
        ],
        now: time,
      );
      save('first', now);
      expect(feedback.takeSignal(now), isTrue);
      feedback.invalidate(forgetReceipts: clear);
      final DateTime immediately = now.add(const Duration(milliseconds: 100));
      expect(feedback.takeSignal(immediately), isFalse);
      save('second', immediately);
      expect(feedback.safeTrackIds, contains('second'));
      expect(feedback.takeSignal(immediately), isFalse);
      final DateTime ready = now.add(ScanCaptureFeedback.signalGracePeriod);
      expect(feedback.takeSignal(ready), isFalse);
      save('third', ready);
      expect(feedback.takeSignal(ready), isTrue);
    }
  });
}
