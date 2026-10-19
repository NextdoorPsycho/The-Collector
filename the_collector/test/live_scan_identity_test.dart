import 'dart:async';

import 'helpers/live_historical_scene.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/live_scan_detector.dart';
import 'package:the_collector/utils/scanning/live_scan_tracker.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

typedef _Receipt = ({String id, ScanCrop crop, ScanResolution resolution});

class _Card extends Fake implements MtgCard {
  _Card(this.title);

  final String title;

  @override
  String get name => title;
}

class _Resolver extends ScanResolver {
  _Resolver(this.candidates, {this.status = ScanResolutionStatus.needsReview});

  final List<ScanCandidate> candidates;
  final ScanResolutionStatus status;
  ScanResolution? supplied;
  int calls = 0;
  Completer<ScanResolution>? pending;

  @override
  Future<ScanResolution> resolve(
    ScanCrop crop, {
    String? name,
    String? setCode,
    String? collectorNumber,
    String? language,
    int page = 1,
  }) async {
    calls++;
    return pending?.future ??
        supplied ??
        ScanResolution(
          candidates: candidates,
          hints: ScanHints.fromCrop(crop),
          status: status,
        );
  }
}

LiveCardDetection _card({
  String name = 'Lightning Bolt',
  String number = '001',
}) => LiveCardDetection(
  confidence: 1,
  corners: const <ScanPoint>[
    ScanPoint(.1, .1),
    ScanPoint(.3, .1),
    ScanPoint(.3, .4),
    ScanPoint(.1, .4),
  ],
  lines: <ScanTextLine>[
    ScanTextLine(
      text: name,
      confidence: 1,
      bounds: const ScanBounds(.05, .04, .7, .03),
    ),
    const ScanTextLine(
      text: 'Instant',
      confidence: 1,
      bounds: ScanBounds(.05, .5, .5, .03),
    ),
    const ScanTextLine(
      text: 'Lightning Bolt deals 3 damage',
      confidence: 1,
      bounds: ScanBounds(.05, .6, .8, .03),
    ),
    const ScanTextLine(
      text: 'to any target.',
      confidence: 1,
      bounds: ScanBounds(.05, .65, .8, .03),
    ),
    ScanTextLine(
      text: '$number M21 EN',
      confidence: 1,
      bounds: const ScanBounds(.05, .91, .4, .03),
    ),
  ],
);

ScanCandidate _candidate(
  Set<ScanEvidence> evidence, {
  String name = 'Lightning Bolt',
}) => ScanCandidate(_Card(name), evidence);

class _Scene {
  _Scene(_Resolver resolver)
    : tracker = LiveScanTracker(
        resolver: resolver,
        retireIdentified: true,
        clock: () => DateTime.utc(2026),
      );

  _Scene.at(_Resolver resolver, DateTime Function() clock)
    : tracker = LiveScanTracker(
        resolver: resolver,
        retireIdentified: true,
        clock: clock,
      );

  final LiveScanTracker tracker;
  late final LiveCaptureSnapshot capture;

  Future<void> prepare({
    bool acknowledge = true,
    LiveCardDetection? detection,
  }) async {
    final LiveCardDetection card = detection ?? _card();
    for (int frame = 0; frame < 2; frame++) {
      tracker.update(
        <LiveCardDetection>[card],
        currentGeometry: <List<ScanPoint>>[card.corners],
        appearanceSamplingSupported: true,
      );
    }
    await Future<void>.delayed(Duration.zero);
    final int token = tracker.beginCapture();
    capture = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[card.corners],
    );
    expect(capture.count, 1);
    if (acknowledge) {
      expect(tracker.markCaptured(capture), 1);
    }
    tracker.endCapture(token, resumeTracking: true);
  }
}

void main() {
  test('conflicting literal lighting titles retain candidates and capture but cannot identify until a fresh unconflicted read', () async {
    DateTime now = DateTime.utc(2026);
    final LiveCardDetection clean = _card();
    final LiveCardDetection conflict = LiveCardDetection(
      confidence: clean.confidence,
      corners: clean.corners,
      lines: <ScanTextLine>[
        clean.lines.first,
        const ScanTextLine(
          text: 'Lava Spike',
          confidence: .99,
          glyphHeight: .03,
          bounds: ScanBounds(.05, .04, .7, .03),
        ),
        ...clean.lines.skip(1),
      ],
      warnings: const <String>['lighting_title_conflict'],
    );
    final _Resolver resolver = _Resolver(<ScanCandidate>[
      _candidate(<ScanEvidence>{
        ScanEvidence.nameMatch,
        ScanEvidence.typeLineMatch,
      }),
    ]);
    final _Scene scene = _Scene.at(resolver, () => now);
    addTearDown(scene.tracker.dispose);
    await scene.prepare(detection: conflict);
    final LiveScanTrack track = scene.tracker.tracks.single;
    expect(track.hasCatalogMatch, isTrue);
    expect(track.resolution!.candidates, hasLength(1));
    expect(
      track.crop.lines.take(2).map((ScanTextLine line) => line.text),
      <String>['Lightning Bolt', 'Lava Spike'],
    );
    expect(track.hasVerifiedLiveIdentity, isFalse);
    expect(scene.capture.count, 1);
    expect(track.captured, isTrue);
    int writes = 0;
    expect(
      await scene.tracker.identifyCapturedLive(
        scene.capture,
        retain: (_Receipt receipt) async {
          writes++;
          return true;
        },
      ),
      0,
    );
    expect(writes, 0);
    expect(scene.capture.retainedCrops, isEmpty);
    expect(
      scene.tracker.identifyCaptured(
        track.crop,
        track.resolution!,
        capture: scene.capture,
      ),
      0,
    );
    expect(track.capturedIdentified, isFalse);
    expect(scene.tracker.completedFootprints, isEmpty);

    final ScanCrop cleanCrop = ScanCrop(
      imagePath: '',
      width: 1000,
      height: 1400,
      rectified: true,
      sourceCorners: clean.corners,
      lines: clean.lines,
    );
    now = now.add(const Duration(milliseconds: 100));
    scene.tracker.update(
      <LiveCardDetection>[conflict],
      currentGeometry: <List<ScanPoint>>[conflict.corners],
    );
    expect(
      scene.tracker.corroboratesSavedIdentity(scene.capture, cleanCrop),
      isFalse,
    );
    expect(
      scene.tracker.identifyCaptured(
        cleanCrop,
        track.resolution!,
        capture: scene.capture,
      ),
      0,
    );
    now = now.add(const Duration(milliseconds: 100));
    scene.tracker.update(
      <LiveCardDetection>[clean],
      currentGeometry: <List<ScanPoint>>[clean.corners],
    );
    await Future<void>.delayed(Duration.zero);
    expect(track.hasVerifiedLiveIdentity, isTrue);
    expect(
      scene.tracker.corroboratesSavedIdentity(scene.capture, cleanCrop),
      isTrue,
    );
    expect(
      scene.tracker.identifyCaptured(
        cleanCrop,
        track.resolution!,
        capture: scene.capture,
      ),
      1,
    );
    expect(track.capturedIdentified, isTrue);
  });

  test('lighting title conflict invalidates an otherwise complete historical live identity receipt', () async {
    final ScanCrop clean = liveHistoricalScene();
    final ScanResolution resolution = await resolveHistoricalScene(clean);
    expect(
      verifiedLiveHistoricalBodyIdentity(clean, resolution),
      'Circle of Protection: Blue',
    );
    final ScanCrop conflict = ScanCrop(
      imagePath: clean.imagePath,
      width: clean.width,
      height: clean.height,
      rectified: clean.rectified,
      sourceCorners: clean.sourceCorners,
      lines: clean.lines,
      warnings: <String>[...clean.warnings, 'lighting_title_conflict'],
    );
    final LiveScanTrack track = LiveScanTrack(
      id: 'historical-conflict',
      lastSeen: DateTime.utc(2026),
      detection: LiveCardDetection(
        confidence: 1,
        corners: conflict.sourceCorners,
        lines: conflict.lines,
        warnings: conflict.warnings,
      ),
    )..resolution = resolution;
    expect(verifiedLiveHistoricalBodyIdentity(conflict, resolution), isNull);
    expect(track.hasVerifiedLiveIdentity, isFalse);
    expect(track.resolution!.candidates, isNotEmpty);
    expect(
      verifiedLiveHistoricalBodyIdentity(clean, resolution),
      'Circle of Protection: Blue',
    );
  });

  test('all strong frozen observations persist before blocked lookup and survive scene replacement', () async {
    final _Resolver resolver = _Resolver(const <ScanCandidate>[])
      ..pending = Completer<ScanResolution>();
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: resolver,
      retireIdentified: true,
      clock: () => DateTime.utc(2026),
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection first = _card();
    final LiveCardDetection second = LiveCardDetection(
      confidence: 1,
      lines: first.lines,
      corners: first.corners
          .map((ScanPoint point) => ScanPoint(point.x + .4, point.y))
          .toList(),
    );
    for (int frame = 0; frame < 2; frame++) {
      tracker.update(
        <LiveCardDetection>[first, second],
        currentGeometry: <List<ScanPoint>>[first.corners, second.corners],
        appearanceSamplingSupported: true,
      );
    }
    final int token = tracker.beginCapture();
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[first.corners, second.corners],
    );
    expect(tracker.markCaptured(capture), 2);
    tracker.endCapture(token, resumeTracking: true);
    final Completer<bool> disk = Completer<bool>();
    List<LiveCaptureObservation> observations = <LiveCaptureObservation>[];
    int writes = 0;
    final Future<bool> saving = tracker.retainCapturedObservations(
      capture,
      retain: (List<LiveCaptureObservation> values) {
        writes++;
        observations = values;
        return disk.future;
      },
    );
    expect(observations, hasLength(2));
    expect(
      observations.map((LiveCaptureObservation value) => value.id).toSet(),
      hasLength(2),
    );
    expect(
      observations.map((LiveCaptureObservation value) => value.captureId),
      everyElement(capture.captureId),
    );
    expect(
      observations.map(
        (LiveCaptureObservation value) => value.crop.lines.first.text,
      ),
      everyElement('Lightning Bolt'),
    );
    expect(capture.retainedObservations, isEmpty);
    expect(capture.identifiedCrops, isEmpty);
    tracker.clear();
    disk.complete(true);
    expect(await saving, isTrue);
    expect(capture.retainedObservations, hasLength(2));
    expect(capture.identifiedCrops, isEmpty);
    expect(tracker.completedFootprints, isEmpty);
    expect(
      await tracker.retainCapturedObservations(
        capture,
        retain: (_) async {
          writes++;
          return true;
        },
      ),
      isTrue,
    );
    expect(writes, 1);
    expect(() => capture.retainedObservations.clear(), throwsUnsupportedError);
    resolver.pending!.complete(
      ScanResolution(
        candidates: const <ScanCandidate>[],
        hints: const ScanHints(names: <String>[]),
        status: ScanResolutionStatus.noMatch,
      ),
    );
    await Future<void>.delayed(Duration.zero);
  });

  test('failed observation storage retries same admitted snapshot after movement and shares in-flight writes', () async {
    final _Scene scene = _Scene(_Resolver(const <ScanCandidate>[]));
    addTearDown(scene.tracker.dispose);
    await scene.prepare();
    final List<String> ids = <String>[];
    expect(
      await scene.tracker.retainCapturedObservations(
        scene.capture,
        retain: (List<LiveCaptureObservation> values) async {
          ids.add(values.single.id);
          return false;
        },
      ),
      isFalse,
    );
    expect(scene.capture.liveRetentionFailed, isTrue);
    scene.tracker.clear();
    final Completer<bool> retryDisk = Completer<bool>();
    final Future<bool> retry = scene.tracker.retainCapturedObservations(
      scene.capture,
      retain: (List<LiveCaptureObservation> values) {
        ids.add(values.single.id);
        return retryDisk.future;
      },
    );
    final Future<bool> repeated = scene.tracker.retainCapturedObservations(
      scene.capture,
      retain: (_) => throw StateError('Duplicate storage job'),
    );
    expect(identical(retry, repeated), isTrue);
    retryDisk.complete(true);
    expect(await retry, isTrue);
    expect(ids, hasLength(2));
    expect(ids.first, ids.last);
    expect(scene.capture.liveRetentionFailed, isFalse);
    expect(scene.capture.identifiedCrops, isEmpty);
  });

  test(
    'unacknowledged and foreign snapshots cannot retain observations',
    () async {
      final _Scene scene = _Scene(_Resolver(const <ScanCandidate>[]));
      final LiveScanTracker foreign = LiveScanTracker();
      addTearDown(scene.tracker.dispose);
      addTearDown(foreign.dispose);
      await scene.prepare(acknowledge: false);
      int writes = 0;
      Future<bool> retain(List<LiveCaptureObservation> _) async {
        writes++;
        return true;
      }

      expect(
        await scene.tracker.retainCapturedObservations(
          scene.capture,
          retain: retain,
        ),
        isFalse,
      );
      expect(
        await foreign.retainCapturedObservations(scene.capture, retain: retain),
        isFalse,
      );
      expect(writes, 0);
    },
  );

  test(
    'weak title-only snapshots do not produce durable observation tokens',
    () async {
      final _Scene scene = _Scene(_Resolver(const <ScanCandidate>[]));
      addTearDown(scene.tracker.dispose);
      final LiveCardDetection source = _card();
      await scene.prepare(
        detection: LiveCardDetection(
          confidence: 1,
          corners: source.corners,
          lines: <ScanTextLine>[source.lines.first],
        ),
      );
      int writes = 0;
      expect(
        await scene.tracker.retainCapturedObservations(
          scene.capture,
          retain: (_) async {
            writes++;
            return true;
          },
        ),
        isTrue,
      );
      expect(writes, 0);
      expect(scene.capture.retainedObservations, isEmpty);
    },
  );

  test('filtered mixed snapshot captures only verified IDs and leaves unknown cards available', () async {
    final _Resolver resolver = _Resolver(<ScanCandidate>[
      _candidate(<ScanEvidence>{
        ScanEvidence.nameMatch,
        ScanEvidence.typeLineMatch,
      }),
    ]);
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: resolver,
      retireIdentified: true,
      clock: () => DateTime.utc(2026),
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection known = _card();
    final LiveCardDetection unknown = LiveCardDetection(
      confidence: 1,
      lines: _card(name: 'Lava Spike').lines,
      corners: known.corners
          .map((ScanPoint point) => ScanPoint(point.x + .4, point.y))
          .toList(),
    );
    for (int frame = 0; frame < 2; frame++) {
      tracker.update(
        <LiveCardDetection>[known, unknown],
        currentGeometry: <List<ScanPoint>>[known.corners, unknown.corners],
        appearanceSamplingSupported: true,
      );
    }
    await Future<void>.delayed(Duration.zero);
    final LiveScanTrack knownTrack = tracker.tracks.firstWhere(
      (LiveScanTrack track) => track.crop.lines.first.text == 'Lightning Bolt',
    );
    final LiveScanTrack unknownTrack = tracker.tracks.firstWhere(
      (LiveScanTrack track) => track.crop.lines.first.text == 'Lava Spike',
    );
    unknownTrack.resolution = ScanResolution(
      candidates: const <ScanCandidate>[],
      hints: ScanHints.fromCrop(unknownTrack.crop),
      status: ScanResolutionStatus.noMatch,
    );
    expect(knownTrack.hasVerifiedLiveIdentity, isTrue);
    expect(unknownTrack.hasVerifiedLiveIdentity, isFalse);
    final int token = tracker.beginCapture();
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      targetIds: <String>{knownTrack.id},
      currentGeometry: <List<ScanPoint>>[known.corners, unknown.corners],
    );
    expect(capture.count, 1);
    expect(capture.crops.single.lines.first.text, 'Lightning Bolt');
    expect(tracker.markCaptured(capture), 1);
    tracker.endCapture(token, resumeTracking: true);
    expect(knownTrack.captured, isTrue);
    expect(unknownTrack.captured, isFalse);
    expect(
      tracker.eligibleTracks.map((LiveScanTrack track) => track.id),
      contains(unknownTrack.id),
    );
    expect(
      await tracker.identifyCapturedLive(
        capture,
        retain: (_Receipt receipt) async => true,
      ),
      1,
    );
    final int nextToken = tracker.beginCapture();
    final LiveCaptureSnapshot next = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[known.corners, unknown.corners],
    );
    expect(next.crops.map((ScanCrop crop) => crop.lines.first.text), <String>[
      'Lava Spike',
    ]);
    final LiveCaptureSnapshot empty = tracker.snapshotCapture(
      targetIds: <String>{},
      currentGeometry: <List<ScanPoint>>[unknown.corners],
    );
    expect(empty.isEmpty, isTrue);
    expect(tracker.markCaptured(empty), 0);
    expect(unknownTrack.captured, isFalse);
    tracker.endCapture(nextToken, resumeTracking: true);
  });

  test('verified live identity gate rejects unresolved, contradictory, and ambiguous candidates', () {
    final LiveScanTrack track = LiveScanTrack(
      id: 'card1',
      detection: _card(),
      lastSeen: DateTime.utc(2026),
    );
    expect(track.hasVerifiedLiveIdentity, isFalse);
    for (final Set<ScanEvidence> evidence in <Set<ScanEvidence>>[
      <ScanEvidence>{ScanEvidence.nameMatch},
      <ScanEvidence>{ScanEvidence.fuzzyName, ScanEvidence.typeLineMatch},
      <ScanEvidence>{
        ScanEvidence.nameMatch,
        ScanEvidence.typeLineMatch,
        ScanEvidence.rulesTextMismatch,
      },
    ]) {
      track.resolution = ScanResolution(
        candidates: <ScanCandidate>[_candidate(evidence)],
        hints: ScanHints.fromCrop(track.crop),
        status: ScanResolutionStatus.needsReview,
      );
      expect(track.hasVerifiedLiveIdentity, isFalse, reason: '$evidence');
    }
    for (final ScanEvidence companion in <ScanEvidence>[
      ScanEvidence.typeLineMatch,
      ScanEvidence.rulesTextMatch,
      ScanEvidence.footerMatch,
    ]) {
      final List<ScanCandidate> candidates = <ScanCandidate>[
        _candidate(<ScanEvidence>{ScanEvidence.nameMatch, companion}),
      ];
      track.resolution = ScanResolution(
        candidates: candidates,
        hints: ScanHints.fromCrop(track.crop),
        status: ScanResolutionStatus.needsReview,
      );
      expect(track.hasVerifiedLiveIdentity, isTrue);
      track.resolution = ScanResolution(
        candidates: candidates,
        hints: ScanHints.fromCrop(track.crop),
        status: ScanResolutionStatus.noMatch,
      );
      expect(track.hasVerifiedLiveIdentity, isFalse);
      track.resolution = ScanResolution(
        candidates: <ScanCandidate>[
          ...candidates,
          _candidate(<ScanEvidence>{
            ScanEvidence.nameMatch,
            companion,
          }, name: 'Lava Spike'),
        ],
        hints: ScanHints.fromCrop(track.crop),
        status: ScanResolutionStatus.needsReview,
      );
      expect(track.hasVerifiedLiveIdentity, isFalse);
    }
  });

  test('verified live identity gate admits only complete historical proof on the actual live body', () async {
    final ScanCrop crop = liveHistoricalScene();
    final ScanResolution valid = await resolveHistoricalScene(crop);
    final LiveScanTrack track = LiveScanTrack(
      id: 'card1',
      detection: LiveCardDetection(
        confidence: 1,
        corners: crop.sourceCorners,
        lines: crop.lines,
        warnings: crop.warnings,
      ),
      lastSeen: DateTime.utc(2026),
    );
    track.resolution = valid;
    expect(track.hasVerifiedLiveIdentity, isTrue);
    track.resolution = ScanResolution(
      candidates: valid.candidates,
      hints: valid.hints,
      status: valid.status,
    );
    expect(track.hasVerifiedLiveIdentity, isFalse);
  });

  test('verified titleless live historical identity freezes and persists its own receipt before green', () async {
    final ScanCrop crop = liveHistoricalScene();
    final ScanResolution resolution = await resolveHistoricalScene(crop);
    expect(
      verifiedLiveHistoricalBodyIdentity(crop, resolution),
      'Circle of Protection: Blue',
    );
    final _Resolver resolver = _Resolver(resolution.candidates)
      ..supplied = resolution;
    final _Scene scene = _Scene(resolver);
    addTearDown(scene.tracker.dispose);
    await scene.prepare(
      detection: LiveCardDetection(
        confidence: 1,
        corners: crop.sourceCorners,
        lines: crop.lines,
        warnings: crop.warnings,
      ),
    );
    int writes = 0;
    expect(
      await scene.tracker.identifyCapturedLive(
        scene.capture,
        retain: (_Receipt receipt) async {
          writes++;
          expect(receipt.crop.imagePath, isEmpty);
          expect(receipt.resolution.status, ScanResolutionStatus.needsReview);
          expect(
            verifiedLiveHistoricalBodyIdentity(
              receipt.crop,
              receipt.resolution,
            ),
            'Circle of Protection: Blue',
          );
          return true;
        },
      ),
      1,
    );
    expect(writes, 1);
    expect(
      scene
          .capture
          .identifiedCrops
          .single
          .resolution
          .candidates
          .single
          .evidence,
      isNot(contains(ScanEvidence.nameMatch)),
    );
    expect(scene.tracker.completedFootprints, hasLength(1));
  });

  test('a titleless historical candidate without complete identity proof cannot capture', () async {
    final ScanCrop crop = liveHistoricalScene();
    final ScanResolution valid = await resolveHistoricalScene(crop);
    final _Resolver resolver = _Resolver(valid.candidates);
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: resolver,
      retireIdentified: true,
      clock: () => DateTime.utc(2026),
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection detection = LiveCardDetection(
      confidence: 1,
      corners: crop.sourceCorners,
      lines: crop.lines,
      warnings: crop.warnings,
    );
    for (int frame = 0; frame < 2; frame++) {
      tracker.update(
        <LiveCardDetection>[detection],
        currentGeometry: <List<ScanPoint>>[detection.corners],
        appearanceSamplingSupported: true,
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(tracker.eligibleTracks, isEmpty);
    final int token = tracker.beginCapture();
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[detection.corners],
    );
    tracker.markCaptured(capture);
    int writes = 0;
    expect(
      await tracker.identifyCapturedLive(
        capture,
        retain: (_Receipt receipt) async {
          writes++;
          return true;
        },
      ),
      0,
    );
    expect(writes, 0);
    expect(capture.retainedCrops, isEmpty);
    expect(capture.identifiedCrops, isEmpty);
    expect(tracker.completedFootprints, isEmpty);
    expect(
      tracker.tracks.any((LiveScanTrack track) => track.capturedIdentified),
      isFalse,
    );
    tracker.endCapture(token, resumeTracking: true);
  });

  test(
    'independent live receipts have stable, distinct local capture IDs',
    () async {
      final _Resolver resolver = _Resolver(<ScanCandidate>[
        _candidate(<ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.typeLineMatch,
        }),
      ]);
      final _Scene first = _Scene(resolver);
      final _Scene second = _Scene(resolver);
      await first.prepare();
      await second.prepare();
      final String id = first.capture.captureId;
      expect(id, matches(RegExp(r'^[a-f0-9]{32}$')));
      expect(first.capture.captureId, id);
      expect(second.capture.captureId, isNot(id));
      first.tracker.dispose();
      second.tracker.dispose();
    },
  );
  for (final ScanEvidence companion in <ScanEvidence>[
    ScanEvidence.typeLineMatch,
    ScanEvidence.rulesTextMatch,
    ScanEvidence.footerMatch,
  ]) {
    test(
      'live name plus $companion confirms only after its retained receipt',
      () async {
        final _Resolver resolver = _Resolver(<ScanCandidate>[
          _candidate(<ScanEvidence>{ScanEvidence.nameMatch, companion}),
        ], status: ScanResolutionStatus.exactPrinting);
        final _Scene scene = _Scene(resolver);
        addTearDown(scene.tracker.dispose);
        await scene.prepare();
        final Completer<bool> retained = Completer<bool>();
        int writes = 0;
        _Receipt? receipt;
        Future<bool> retain(_Receipt value) {
          writes++;
          receipt = value;
          return retained.future;
        }

        final Future<int> first = scene.tracker.identifyCapturedLive(
          scene.capture,
          retain: retain,
        );
        await Future<void>.delayed(Duration.zero);
        expect(writes, 1);
        expect(scene.tracker.tracks.single.capturedIdentified, isFalse);
        expect(scene.capture.identifiedCrops, isEmpty);
        final Future<int> repeated = scene.tracker.identifyCapturedLive(
          scene.capture,
          retain: retain,
        );
        expect(identical(first, repeated), isTrue);
        expect(resolver.calls, 1);
        retained.complete(true);
        expect(await first, 1);
        expect(await repeated, 1);
        expect(scene.tracker.tracks.single.capturedIdentified, isTrue);
        expect(scene.tracker.completedFootprints, hasLength(1));
        expect(scene.capture.identifiedCrops, hasLength(1));
        expect(receipt!.crop.imagePath, isEmpty);
        expect(
          receipt!.crop.lines.map((ScanTextLine line) => line.text),
          contains('Lightning Bolt'),
        );
        expect(receipt!.resolution.status, ScanResolutionStatus.needsReview);
        expect(
          receipt!.resolution.candidates.single.card.name,
          'Lightning Bolt',
        );
        expect(
          await scene.tracker.identifyCapturedLive(
            scene.capture,
            retain: retain,
          ),
          1,
        );
        expect(writes, 1);
        expect(resolver.calls, 1);
      },
    );
  }

  for (final String failure in <String>['false', 'throw']) {
    test(
      'live confirmation remains yellow when receipt persistence $failure',
      () async {
        final _Scene scene = _Scene(
          _Resolver(<ScanCandidate>[
            _candidate(<ScanEvidence>{
              ScanEvidence.nameMatch,
              ScanEvidence.footerMatch,
            }),
          ]),
        );
        addTearDown(scene.tracker.dispose);
        await scene.prepare();
        int writes = 0;
        final int result = await scene.tracker.identifyCapturedLive(
          scene.capture,
          retain: (_Receipt receipt) async {
            writes++;
            if (failure == 'throw') {
              throw StateError('Storage unavailable');
            }
            return false;
          },
        );
        expect(result, 0);
        expect(writes, 1);
        expect(scene.tracker.tracks.single.captured, isTrue);
        expect(scene.tracker.tracks.single.capturedIdentified, isFalse);
        expect(scene.tracker.completedFootprints, isEmpty);
        expect(scene.capture.identifiedCrops, isEmpty);
      },
    );
  }

  final Map<String, List<ScanCandidate>> rejected =
      <String, List<ScanCandidate>>{
        'noMatch': <ScanCandidate>[
          _candidate(<ScanEvidence>{
            ScanEvidence.nameMatch,
            ScanEvidence.typeLineMatch,
          }),
        ],
        'empty': <ScanCandidate>[],
        'name only': <ScanCandidate>[
          _candidate(<ScanEvidence>{ScanEvidence.nameMatch}),
        ],
        'body only': <ScanCandidate>[
          _candidate(<ScanEvidence>{
            ScanEvidence.rulesTextMatch,
            ScanEvidence.typeLineMatch,
          }),
        ],
        'fuzzy name': <ScanCandidate>[
          _candidate(<ScanEvidence>{
            ScanEvidence.fuzzyName,
            ScanEvidence.typeLineMatch,
          }),
        ],
        'contradictory printing': <ScanCandidate>[
          _candidate(<ScanEvidence>{
            ScanEvidence.nameMatch,
            ScanEvidence.typeLineMatch,
            ScanEvidence.printingMismatch,
          }),
        ],
        'contradictory body': <ScanCandidate>[
          _candidate(<ScanEvidence>{
            ScanEvidence.nameMatch,
            ScanEvidence.rulesTextMatch,
            ScanEvidence.rulesTextMismatch,
          }),
        ],
        'different canonical names': <ScanCandidate>[
          _candidate(<ScanEvidence>{
            ScanEvidence.nameMatch,
            ScanEvidence.typeLineMatch,
          }),
          _candidate(<ScanEvidence>{
            ScanEvidence.nameMatch,
            ScanEvidence.typeLineMatch,
          }, name: 'Lava Spike'),
        ],
      };
  for (final MapEntry<String, List<ScanCandidate>> invalid
      in rejected.entries) {
    test(
      'unsupported live ${invalid.key} never persists or turns green',
      () async {
        final _Scene scene = _Scene(
          _Resolver(
            invalid.value,
            status: invalid.key == 'noMatch'
                ? ScanResolutionStatus.noMatch
                : ScanResolutionStatus.needsReview,
          ),
        );
        addTearDown(scene.tracker.dispose);
        await scene.prepare();
        int writes = 0;
        expect(
          await scene.tracker.identifyCapturedLive(
            scene.capture,
            retain: (_Receipt receipt) async {
              writes++;
              return true;
            },
          ),
          0,
        );
        expect(writes, 0);
        expect(scene.tracker.completedFootprints, isEmpty);
        expect(scene.capture.identifiedCrops, isEmpty);
      },
    );
  }

  test('live identity can confirm while its distinct printing candidates remain reviewable', () async {
    final _Scene scene = _Scene(
      _Resolver(<ScanCandidate>[
        _candidate(<ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.typeLineMatch,
        }),
        _candidate(<ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.typeLineMatch,
        }),
      ]),
    );
    addTearDown(scene.tracker.dispose);
    await scene.prepare();
    expect(
      await scene.tracker.identifyCapturedLive(
        scene.capture,
        retain: (_Receipt receipt) async => true,
      ),
      1,
    );
    expect(
      scene.capture.identifiedCrops.single.resolution.candidates,
      hasLength(2),
    );
    expect(
      scene.capture.identifiedCrops.single.resolution.status,
      ScanResolutionStatus.needsReview,
    );
  });

  for (final String invalid in <String>[
    'unacknowledged',
    'foreign',
    'expired',
    'reset',
    'removed',
    'replacement',
    'printing',
  ]) {
    test('$invalid live capture cannot retain or confirm a card', () async {
      DateTime now = DateTime.utc(2026);
      final _Scene scene = _Scene.at(
        _Resolver(<ScanCandidate>[
          _candidate(<ScanEvidence>{
            ScanEvidence.nameMatch,
            ScanEvidence.footerMatch,
          }),
        ]),
        () => now,
      );
      addTearDown(scene.tracker.dispose);
      await scene.prepare(acknowledge: invalid != 'unacknowledged');
      LiveCaptureSnapshot authority = scene.capture;
      if (invalid == 'foreign') {
        final _Scene foreign = _Scene(_Resolver(<ScanCandidate>[]));
        addTearDown(foreign.tracker.dispose);
        await foreign.prepare();
        authority = foreign.capture;
      } else if (invalid == 'expired') {
        now = now.add(const Duration(seconds: 31));
      } else if (invalid == 'reset') {
        scene.tracker.clear();
      } else if (invalid == 'removed') {
        scene.tracker.update(const <LiveCardDetection>[]);
        now = now.add(const Duration(seconds: 2));
        scene.tracker.update(const <LiveCardDetection>[]);
      } else if (invalid == 'replacement' || invalid == 'printing') {
        final LiveCardDetection replacement = _card(
          name: invalid == 'replacement' ? 'Lava Spike' : 'Lightning Bolt',
          number: invalid == 'printing' ? '002' : '001',
        );
        scene.tracker.update(
          <LiveCardDetection>[replacement],
          currentGeometry: <List<ScanPoint>>[replacement.corners],
        );
      }
      int writes = 0;
      expect(
        await scene.tracker.identifyCapturedLive(
          authority,
          retain: (_Receipt receipt) async {
            writes++;
            return true;
          },
        ),
        0,
      );
      expect(writes, 0);
      expect(scene.capture.identifiedCrops, isEmpty);
      expect(
        scene.tracker.tracks.where(
          (LiveScanTrack track) => track.capturedIdentified,
        ),
        isEmpty,
      );
    });
  }

  test('a scene reset while persistence is pending cannot publish a late green receipt', () async {
    final _Scene scene = _Scene(
      _Resolver(<ScanCandidate>[
        _candidate(<ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.rulesTextMatch,
        }),
      ]),
    );
    addTearDown(scene.tracker.dispose);
    await scene.prepare();
    final Completer<bool> stored = Completer<bool>();
    int writes = 0;
    final Future<int> result = scene.tracker.identifyCapturedLive(
      scene.capture,
      retain: (_Receipt receipt) {
        writes++;
        return stored.future;
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(writes, 1);
    scene.tracker.clear();
    stored.complete(true);
    expect(await result, 0);
    expect(scene.capture.identifiedCrops, isEmpty);
    expect(scene.tracker.completedFootprints, isEmpty);
  });

  test('replacement during admitted lookup retains the actual old read without confirming the replacement', () async {
    final _Resolver resolver = _Resolver(<ScanCandidate>[
      _candidate(<ScanEvidence>{
        ScanEvidence.nameMatch,
        ScanEvidence.footerMatch,
      }),
    ]);
    final Completer<ScanResolution> lookup = Completer<ScanResolution>();
    resolver.pending = lookup;
    final _Scene scene = _Scene(resolver);
    addTearDown(scene.tracker.dispose);
    await scene.prepare();
    int writes = 0;
    final Future<int> result = scene.tracker.identifyCapturedLive(
      scene.capture,
      retain: (_Receipt receipt) async {
        writes++;
        return true;
      },
    );
    final LiveCardDetection replacement = _card(name: 'Lava Spike');
    scene.tracker.update(
      <LiveCardDetection>[replacement],
      currentGeometry: <List<ScanPoint>>[replacement.corners],
    );
    lookup.complete(
      ScanResolution(
        candidates: resolver.candidates,
        hints: ScanHints.fromCrop(scene.capture.crops.single),
        status: ScanResolutionStatus.needsReview,
      ),
    );
    expect(await result, 0);
    expect(writes, 1);
    expect(
      scene.capture.retainedCrops.single.resolution.candidates.single.card.name,
      'Lightning Bolt',
    );
    expect(scene.capture.identifiedCrops, isEmpty);
    expect(scene.tracker.completedFootprints, isEmpty);
  });

  test('admitted frozen targets all survive orientation reset while lookup is pending', () async {
    final _Resolver resolver = _Resolver(<ScanCandidate>[
      _candidate(<ScanEvidence>{
        ScanEvidence.nameMatch,
        ScanEvidence.typeLineMatch,
      }),
    ]);
    final Completer<ScanResolution> lookup = Completer<ScanResolution>();
    resolver.pending = lookup;
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: resolver,
      retireIdentified: true,
      clock: () => DateTime.utc(2026),
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection first = _card();
    final LiveCardDetection second = LiveCardDetection(
      confidence: 1,
      lines: first.lines,
      corners: first.corners
          .map((ScanPoint point) => ScanPoint(point.x + .4, point.y))
          .toList(),
    );
    for (int frame = 0; frame < 2; frame++) {
      tracker.update(
        <LiveCardDetection>[first, second],
        currentGeometry: <List<ScanPoint>>[first.corners, second.corners],
        appearanceSamplingSupported: true,
      );
    }
    final int token = tracker.beginCapture();
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[first.corners, second.corners],
    );
    expect(capture.count, 2);
    expect(tracker.markCaptured(capture), 2);
    tracker.endCapture(token, resumeTracking: true);
    final List<String> retained = <String>[];
    final Future<int> job = tracker.identifyCapturedLive(
      capture,
      retain: (_Receipt receipt) async {
        retained.add(receipt.id);
        return true;
      },
    );
    tracker.clear();
    lookup.complete(
      ScanResolution(
        candidates: resolver.candidates,
        hints: ScanHints.fromCrop(capture.crops.first),
        status: ScanResolutionStatus.needsReview,
      ),
    );
    expect(await job, 0);
    expect(retained.toSet(), hasLength(2));
    expect(capture.retainedCrops, hasLength(2));
    expect(capture.identifiedCrops, isEmpty);
    expect(tracker.completedFootprints, isEmpty);
  });

  test('failed durable handoff retries its original verified receipt without repeated in-flight writes', () async {
    final _Scene scene = _Scene(
      _Resolver(<ScanCandidate>[
        _candidate(<ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.rulesTextMatch,
        }),
      ]),
    );
    addTearDown(scene.tracker.dispose);
    await scene.prepare();
    int writes = 0;
    expect(
      await scene.tracker.identifyCapturedLive(
        scene.capture,
        retain: (_Receipt receipt) async {
          writes++;
          return false;
        },
      ),
      0,
    );
    expect(scene.capture.liveRetentionFailed, isTrue);
    expect(scene.capture.retainedCrops, isEmpty);
    final Completer<bool> saved = Completer<bool>();
    final Future<int> retry = scene.tracker.identifyCapturedLive(
      scene.capture,
      retryFailed: true,
      retain: (_Receipt receipt) {
        writes++;
        return saved.future;
      },
    );
    final Future<int> repeat = scene.tracker.identifyCapturedLive(
      scene.capture,
      retryFailed: true,
      retain: (_Receipt receipt) async {
        writes++;
        return true;
      },
    );
    expect(identical(retry, repeat), isTrue);
    saved.complete(true);
    expect(await retry, 1);
    expect(writes, 2);
    expect(scene.capture.liveRetentionFailed, isFalse);
    expect(scene.capture.retainedCrops, hasLength(1));
    await scene.tracker.identifyCapturedLive(
      scene.capture,
      retryFailed: true,
      retain: (_Receipt receipt) async {
        writes++;
        return true;
      },
    );
    expect(writes, 2);
  });

  test('a failed admitted receipt can be retained after rotation without painting an old card green', () async {
    final _Scene scene = _Scene(
      _Resolver(<ScanCandidate>[
        _candidate(<ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.footerMatch,
        }),
      ]),
    );
    addTearDown(scene.tracker.dispose);
    await scene.prepare();
    expect(
      await scene.tracker.identifyCapturedLive(
        scene.capture,
        retain: (_Receipt receipt) async => false,
      ),
      0,
    );
    scene.tracker.clear();
    expect(
      await scene.tracker.identifyCapturedLive(
        scene.capture,
        retryFailed: true,
        retain: (_Receipt receipt) async => true,
      ),
      0,
    );
    expect(scene.capture.retainedCrops, hasLength(1));
    expect(scene.capture.identifiedCrops, isEmpty);
    expect(scene.tracker.completedFootprints, isEmpty);
  });
}
