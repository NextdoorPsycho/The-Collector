import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

class _Catalog extends Fake implements ScanCatalog {}

class _ControlledResolver extends ScanResolver {
  _ControlledResolver() : super(catalog: _Catalog());

  final List<String> started = <String>[];
  final Map<String, Completer<ScanResolution>> pending =
      <String, Completer<ScanResolution>>{};
  int active = 0;
  int maximumActive = 0;
  String? synchronousFailure;

  @override
  Future<ScanResolution> resolve(
    ScanCrop crop, {
    String? name,
    String? setCode,
    String? collectorNumber,
    String? language,
    int page = 1,
  }) {
    started.add(crop.imagePath);
    if (crop.imagePath == synchronousFailure) {
      throw StateError('Synchronous lookup failure');
    }
    active++;
    if (active > maximumActive) maximumActive = active;
    final Completer<ScanResolution> result = Completer<ScanResolution>();
    pending[crop.imagePath] = result;
    return result.future.whenComplete(() => active--);
  }

  void complete(String path) => pending[path]!.complete(
    ScanResolution(
      status: ScanResolutionStatus.noMatch,
      hints: ScanHints(names: <String>[path]),
      candidates: const <ScanCandidate>[],
    ),
  );
}

ScanCrop _crop(String path) => ScanCrop(
  imagePath: path,
  width: 1000,
  height: 1400,
  rectified: true,
  sourceCorners: const <ScanPoint>[],
  lines: const <ScanTextLine>[],
);

void main() {
  test('outcomes publish independently without occupying lookup workers or repeating at batch completion', () async {
    final _ControlledResolver resolver = _ControlledResolver();
    final Completer<void> persistence = Completer<void>();
    final List<int> published = <int>[];
    bool finished = false;
    final Future<List<ScanResolveOutcome>> result = resolver
        .resolveBatchOutcomes(
          <ScanCrop>[for (int index = 0; index < 5; index++) _crop('$index')],
          onOutcome: (int index, ScanResolveOutcome outcome) async {
            published.add(index);
            expect(outcome.resolution!.hints.names.single, '$index');
            if (index == 1) await persistence.future;
          },
        )
        .whenComplete(() => finished = true);

    resolver.complete('1');
    await Future<void>.delayed(Duration.zero);
    expect(published, <int>[1]);
    expect(resolver.started, <String>['0', '1', '2', '3', '4']);
    expect(finished, isFalse);
    for (final String path in <String>['2', '3', '4', '0']) {
      resolver.complete(path);
    }
    await Future<void>.delayed(Duration.zero);
    expect(published, <int>[1, 2, 3, 4, 0]);
    expect(finished, isFalse);
    persistence.complete();
    final List<ScanResolveOutcome> outcomes = await result;
    expect(
      outcomes.map(
        (ScanResolveOutcome value) => value.resolution!.hints.names.single,
      ),
      <String>['0', '1', '2', '3', '4'],
    );
    expect(published, <int>[1, 2, 3, 4, 0]);
    expect(resolver.maximumActive, 4);
  });

  test(
    'publication failure drains siblings without retrying successful lookups',
    () async {
      final _ControlledResolver resolver = _ControlledResolver();
      final StateError failure = StateError('Persistence failed');
      final List<int> published = <int>[];
      final Future<List<ScanResolveOutcome>> result = resolver
          .resolveBatchOutcomes(
            <ScanCrop>[_crop('0'), _crop('1')],
            onOutcome: (int index, ScanResolveOutcome outcome) async {
              published.add(index);
              if (index == 1) throw failure;
            },
          );
      final Future<void> assertion = expectLater(
        result,
        throwsA(same(failure)),
      );
      resolver.complete('1');
      await Future<void>.delayed(Duration.zero);
      expect(published, <int>[1]);
      resolver.complete('0');
      await assertion;
      expect(published, <int>[1, 0]);
      expect(resolver.started, <String>['0', '1']);
      expect(resolver.active, 0);
    },
  );

  test('dynamic workers bypass a slow first card while preserving order and the four-card limit', () async {
    final _ControlledResolver resolver = _ControlledResolver();
    final Future<List<ScanResolution>> result = resolver.resolveBatch(
      <ScanCrop>[for (int index = 0; index < 7; index++) _crop('$index')],
    );
    bool finished = false;
    result.then((_) => finished = true);
    expect(resolver.started, <String>['0', '1', '2', '3']);
    expect(resolver.active, 4);

    resolver.complete('1');
    await Future<void>.delayed(Duration.zero);
    expect(resolver.started, <String>['0', '1', '2', '3', '4']);
    expect(resolver.active, 4);
    resolver.complete('4');
    await Future<void>.delayed(Duration.zero);
    expect(resolver.started, <String>['0', '1', '2', '3', '4', '5']);
    resolver.complete('5');
    await Future<void>.delayed(Duration.zero);
    expect(resolver.started, <String>['0', '1', '2', '3', '4', '5', '6']);

    resolver.complete('3');
    resolver.complete('2');
    resolver.complete('6');
    await Future<void>.delayed(Duration.zero);
    expect(resolver.active, 1);
    expect(finished, isFalse);
    resolver.complete('0');

    expect(
      (await result.timeout(const Duration(seconds: 2)))
          .map((ScanResolution value) => value.hints.names.single),
      <String>['0', '1', '2', '3', '4', '5', '6'],
    );
    expect(resolver.maximumActive, 4);
    expect(resolver.active, 0);
  });

  test('concurrent failures drain every card before preserving the first error and stack', () async {
    final _ControlledResolver resolver = _ControlledResolver();
    final StateError failure = StateError('Lookup failed');
    final Future<List<ScanResolution>> result = resolver.resolveBatch(
      <ScanCrop>[for (int index = 0; index < 8; index++) _crop('$index')],
    );
    bool finished = false;
    StackTrace? observedStack;
    final Future<List<ScanResolution>> monitored = result.catchError((
      Object error,
      StackTrace stack,
    ) {
      observedStack = stack;
      Error.throwWithStackTrace(error, stack);
    });
    final Future<void> assertion = expectLater(
      monitored,
      throwsA(same(failure)),
    ).whenComplete(() => finished = true);

    resolver.pending['2']!.completeError(
      failure,
      StackTrace.fromString('original lookup stack'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    expect(resolver.active, 4);
    expect(resolver.started, <String>['0', '1', '2', '3', '4']);
    resolver.pending['1']!.completeError(StateError('Second lookup failure'));
    resolver.complete('3');
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    expect(resolver.active, 4);
    expect(resolver.started, <String>['0', '1', '2', '3', '4', '5', '6']);
    resolver.complete('0');
    await Future<void>.delayed(Duration.zero);
    expect(resolver.started, <String>['0', '1', '2', '3', '4', '5', '6', '7']);
    for (int index = 4; index < 8; index++) {
      resolver.complete('$index');
    }
    await assertion.timeout(const Duration(seconds: 2));
    expect(resolver.active, 0);
    expect(resolver.started, <String>['0', '1', '2', '3', '4', '5', '6', '7']);
    expect(resolver.maximumActive, 4);
    expect(observedStack.toString(), contains('original lookup stack'));
  });

  test('synchronous failure does not abandon later cards', () async {
    final _ControlledResolver resolver = _ControlledResolver()
      ..synchronousFailure = '0';
    final Future<List<ScanResolution>> result = resolver.resolveBatch(
      <ScanCrop>[for (int index = 0; index < 6; index++) _crop('$index')],
    );
    final Future<void> assertion = expectLater(result, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(resolver.started, <String>['0', '1', '2', '3', '4']);
    expect(resolver.active, 4);
    resolver.complete('1');
    resolver.complete('2');
    resolver.complete('3');
    resolver.complete('4');
    await Future<void>.delayed(Duration.zero);
    resolver.complete('5');
    await assertion.timeout(const Duration(seconds: 2));
    expect(resolver.active, 0);
    expect(resolver.started, <String>['0', '1', '2', '3', '4', '5']);
  });

  test('per-card outcomes preserve successful siblings without repeating their lookups', () async {
    final _ControlledResolver resolver = _ControlledResolver();
    final StateError failure = StateError('Unread first card');
    final Future<List<ScanResolveOutcome>> result = resolver
        .resolveBatchOutcomes(<ScanCrop>[
          for (int index = 0; index < 7; index++) _crop('$index'),
        ]);
    resolver.pending['0']!.completeError(
      failure,
      StackTrace.fromString('first card'),
    );
    await Future<void>.delayed(Duration.zero);
    for (int index = 1; index < 5; index++) {
      resolver.complete('$index');
    }
    await Future<void>.delayed(Duration.zero);
    resolver.complete('5');
    resolver.complete('6');
    final List<ScanResolveOutcome> outcomes = await result.timeout(
      const Duration(seconds: 2),
    );
    expect(outcomes.first.error, same(failure));
    expect(outcomes.first.stackTrace.toString(), contains('first card'));
    expect(outcomes.first.resolution, isNull);
    expect(
      outcomes
          .skip(1)
          .map(
            (ScanResolveOutcome value) => value.resolution!.hints.names.single,
          ),
      <String>['1', '2', '3', '4', '5', '6'],
    );
    expect(resolver.started, <String>['0', '1', '2', '3', '4', '5', '6']);
    expect(resolver.maximumActive, 4);
  });

  test(
    'per-card API honors successful overridden batch implementations',
    () async {
      final _OverrideResolver resolver = _OverrideResolver();
      final List<ScanResolveOutcome> result = await resolver
          .resolveBatchOutcomes(<ScanCrop>[_crop('a'), _crop('b')]);
      expect(
        result.every((ScanResolveOutcome value) => value.succeeded),
        isTrue,
      );
      expect(resolver.batchCalls, 1);
      expect(resolver.singleCalls, 0);
    },
  );

  test('failed overridden batch falls back independently and retains the good card', () async {
    final _OverrideResolver resolver = _OverrideResolver()..batchFailure = true;
    final List<ScanResolveOutcome> result = await resolver.resolveBatchOutcomes(
      <ScanCrop>[_crop('bad'), _crop('good')],
    );
    expect(result.first.error, isA<StateError>());
    expect(result.last.resolution!.hints.names, <String>['good']);
    expect(resolver.batchCalls, 1);
    expect(resolver.singleCalls, 2);
  });

  test('small batches admit only their available cards and preserve reversed completion order', () async {
    for (int count = 1; count < 4; count++) {
      final _ControlledResolver resolver = _ControlledResolver();
      final Future<List<ScanResolution>> result = resolver.resolveBatch(
        <ScanCrop>[for (int index = 0; index < count; index++) _crop('$index')],
      );
      expect(resolver.active, count);
      for (int index = count - 1; index >= 0; index--) {
        resolver.complete('$index');
      }
      expect(
        (await result.timeout(const Duration(seconds: 2)))
            .map((ScanResolution item) => item.hints.names.single),
        <String>[for (int index = 0; index < count; index++) '$index'],
      );
      expect(resolver.maximumActive, count);
      expect(resolver.active, 0);
    }
  });

  test('empty batch performs no card lookups', () async {
    final _ControlledResolver resolver = _ControlledResolver();
    expect(await resolver.resolveBatch(const <ScanCrop>[]), isEmpty);
    expect(await resolver.resolveBatchOutcomes(const <ScanCrop>[]), isEmpty);
    expect(resolver.started, isEmpty);
    expect(resolver.maximumActive, 0);
  });
}

class _OverrideResolver extends ScanResolver {
  _OverrideResolver() : super(catalog: _Catalog());
  int batchCalls = 0;
  int singleCalls = 0;
  bool batchFailure = false;

  ScanResolution _result(ScanCrop crop) => ScanResolution(
    status: ScanResolutionStatus.noMatch,
    hints: ScanHints(names: <String>[crop.imagePath]),
    candidates: const <ScanCandidate>[],
  );

  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) async {
    batchCalls++;
    if (batchFailure) throw StateError('Batch request failed');
    return crops.map(_result).toList();
  }

  @override
  Future<ScanResolution> resolve(
    ScanCrop crop, {
    String? name,
    String? setCode,
    String? collectorNumber,
    String? language,
    int page = 1,
  }) async {
    singleCalls++;
    if (crop.imagePath == 'bad') throw StateError('This card failed');
    return _result(crop);
  }
}
