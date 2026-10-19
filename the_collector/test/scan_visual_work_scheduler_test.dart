import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/scanning/scan_visual_work_scheduler.dart';

void main() {
  test(
    'reference and comparison limits are shared across callers and admit FIFO',
    () async {
      final List<int> references = <int>[];
      final List<int> comparisons = <int>[];
      final List<Completer<int>> referenceGates = List<Completer<int>>.generate(
        6,
        (_) => Completer<int>(),
      );
      final List<Completer<int>> comparisonGates =
          List<Completer<int>>.generate(4, (_) => Completer<int>());
      final List<Future<int>> loads = <Future<int>>[
        for (int index = 0; index < referenceGates.length; index++)
          ScanVisualWorkScheduler.reference(() {
            references.add(index);
            return referenceGates[index].future;
          }),
      ];
      final List<Future<int>> matches = <Future<int>>[
        for (int index = 0; index < comparisonGates.length; index++)
          ScanVisualWorkScheduler.compare(() {
            comparisons.add(index);
            return comparisonGates[index].future;
          }),
      ];
      expect(references, <int>[0, 1, 2, 3]);
      expect(comparisons, <int>[0, 1]);
      referenceGates[2].complete(2);
      comparisonGates[1].complete(1);
      await Future<void>.delayed(Duration.zero);
      expect(references, <int>[0, 1, 2, 3, 4]);
      expect(comparisons, <int>[0, 1, 2]);
      for (int index = 0; index < referenceGates.length; index++) {
        if (!referenceGates[index].isCompleted) {
          referenceGates[index].complete(index);
        }
      }
      for (int index = 0; index < comparisonGates.length; index++) {
        if (!comparisonGates[index].isCompleted) {
          comparisonGates[index].complete(index);
        }
      }
      expect(await Future.wait(loads), <int>[0, 1, 2, 3, 4, 5]);
      expect(await Future.wait(matches), <int>[0, 1, 2, 3]);
      expect(references, <int>[0, 1, 2, 3, 4, 5]);
      expect(comparisons, <int>[0, 1, 2, 3]);
    },
  );

  test(
    'synchronous and asynchronous failures release admission for later work',
    () async {
      final Completer<int> held = Completer<int>();
      final StateError failure = StateError('comparison failed');
      final Future<int> first = ScanVisualWorkScheduler.compare(
        () => held.future,
      );
      final Future<int> broken = ScanVisualWorkScheduler.compare<int>(
        () => throw failure,
      );
      final Future<void> synchronous = expectLater(
        broken,
        throwsA(same(failure)),
      );
      bool admitted = false;
      final Future<int> next = ScanVisualWorkScheduler.compare(() async {
        admitted = true;
        return 3;
      });
      await synchronous;
      expect(await next, 3);
      expect(admitted, isTrue);
      final Future<void> asynchronous = expectLater(
        first,
        throwsA(same(failure)),
      );
      held.completeError(failure);
      await asynchronous;
      expect(await ScanVisualWorkScheduler.compare(() async => 4), 4);
      await expectLater(
        ScanVisualWorkScheduler.reference<int>(() async => throw failure),
        throwsA(same(failure)),
      );
    },
  );
}
