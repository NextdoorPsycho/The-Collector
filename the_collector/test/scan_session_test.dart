import 'dart:async';

import 'helpers/live_historical_scene.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_capture_defaults.dart';
import 'package:the_collector/utils/scanning/scan_queue.dart';
import 'package:the_collector/utils/collection_ingestion.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_session.dart';
import 'package:the_collector/utils/scanning/live_scan_detector.dart';
import 'package:the_collector/utils/scanning/live_scan_tracker.dart';

class _Printing extends Fake implements MtgCard {
  @override
  String get name => 'Lightning Bolt';
  @override
  String? get printedName => null;
  @override
  List<CardFace>? get cardFaces => null;
  @override
  String get set => 'm11';
  @override
  String get collectorNumber => '146';
  @override
  Language get lang => Language.english;
}

const ScanCrop _crop = ScanCrop(
  imagePath: '',
  width: 1000,
  height: 1400,
  rectified: true,
  sourceCorners: <ScanPoint>[],
  lines: <ScanTextLine>[
    ScanTextLine(
      text: 'Lightning Bolt',
      confidence: .99,
      bounds: ScanBounds(.1, .05, .7, .02),
    ),
    ScanTextLine(
      text: '0146',
      confidence: .99,
      bounds: ScanBounds(.05, .85, .2, .02),
    ),
    ScanTextLine(
      text: 'M11 EN',
      confidence: .99,
      bounds: ScanBounds(.05, .9, .2, .02),
    ),
  ],
);

class _Recognizer implements CardRecognizer {
  ScanCrop resultCrop = _crop;
  List<ScanCrop>? resultCrops;
  List<SavedTargetAppearance> targetAppearances = <SavedTargetAppearance>[];
  String? responsePath;
  int calls = 0;
  int active = 0;
  int maximumActive = 0;
  bool failNext = false;
  void Function()? afterCall;
  final List<String> paths = <String>[];
  final List<List<List<ScanPoint>>> targetRequests = <List<List<ScanPoint>>>[];
  @override
  Future<ScanRecognition> recognize(
    String path, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    paths.add(path);
    targetRequests.add(targetRegions);
    calls++;
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      await Future<void>.delayed(Duration.zero);
      afterCall?.call();
      if (failNext) {
        failNext = false;
        throw StateError('native SDK detail');
      }
      return ScanRecognition(
        imagePath: responsePath ?? path,
        width: 2000,
        height: 1400,
        targetAppearances: targetAppearances,
        crops:
            resultCrops ??
            <ScanCrop>[resultCrop, if (multipleCards) resultCrop],
      );
    } finally {
      active--;
    }
  }
}

class _FailedDrafts extends _Drafts {
  @override
  Future<List<ScanDraftItem>> completePhoto(
    String photoId,
    List<ScanDraftItem> items,
  ) async {
    throw StateError('storage full');
  }
}

class _Resolver extends ScanResolver {
  final bool manyCandidates;
  final HistoricalBodyIdentityProof? historicalProof;
  final MtgCard? printing;
  int maximumBatch = 0;
  int resolved = 0;
  _Resolver({this.manyCandidates = false, this.historicalProof, this.printing});
  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) async {
    if (crops.length > maximumBatch) maximumBatch = crops.length;
    resolved += crops.length;
    return crops
        .map(
          (ScanCrop crop) => ScanResolution(
            hints: ScanHints.fromCrop(crop),
            candidates: List<ScanCandidate>.generate(
              manyCandidates ? 175 : 1,
              (int _) => ScanCandidate(printing ?? _Printing(), <ScanEvidence>{
                ScanEvidence.footerMatch,
                ScanEvidence.nameMatch,
              }),
            ),
            historicalBodyIdentityProof: historicalProof,
            status: manyCandidates
                ? ScanResolutionStatus.needsReview
                : ScanResolutionStatus.exactPrinting,
          ),
        )
        .toList();
  }
}

class _Drafts extends ScanDraftStore {
  final Map<String, ScanDraftPhoto> photos = <String, ScanDraftPhoto>{};
  final Map<String, ScanDraftItem> saved = <String, ScanDraftItem>{};
  final Map<String, ScanDraftRescan> rescans = <String, ScanDraftRescan>{};
  final List<bool> cameraOwnership = <bool>[];
  bool failPartial = false;
  String? failedImportPath;
  Completer<void>? importing;
  Completer<void>? removing;
  _Drafts() : super(userId: 'fixture');
  @override
  Future<List<ScanDraftPhoto>> readPhotos() async => photos.values.toList();
  @override
  Future<List<ScanDraftItem>> readItems() async => saved.values.toList();
  @override
  Future<List<ScanDraftRecovery>> readRecoveries() async =>
      <ScanDraftRecovery>[];
  @override
  Future<List<ScanDraftDetail>> readDetails() async => <ScanDraftDetail>[];
  @override
  Future<List<ScanDraftRescan>> readRescans() async => rescans.values.toList();
  @override
  Future<List<List<ScanPoint>>> readReplacedRegions(String photoId) async =>
      <List<ScanPoint>>[];
  @override
  Future<ScanDraftRecovery?> scheduleRecovery(
    String itemId, {
    bool manual = false,
  }) async => null;
  @override
  Future<List<ScanDraftPhoto>> readFocusStack(String rootPhotoId) async =>
      const <ScanDraftPhoto>[];
  @override
  Future<List<ScanDraftPhoto>> importPhotos(
    Iterable<String> paths, {
    required bool multipleCards,
    bool ownedCameraSource = false,
    List<List<ScanPoint>> excludedRegions = const <List<ScanPoint>>[],
    ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
  }) async {
    if (importing != null) await importing!.future;
    if (paths.contains(failedImportPath)) {
      throw const FileSystemException('Storage full');
    }
    cameraOwnership.add(ownedCameraSource);
    final List<ScanDraftPhoto> added = paths
        .map(
          (String path) => ScanDraftPhoto(
            id: path.replaceAll('.', '_'),
            imagePath: path,
            multipleCards: multipleCards,
            defaults: defaults,
            createdAt: DateTime.now(),
            excludedRegions: ScanDraftPhoto.freezeExcludedRegions(
              excludedRegions,
            ),
          ),
        )
        .toList();
    for (final ScanDraftPhoto photo in added) {
      photos[photo.id] = photo;
    }
    return added;
  }

  @override
  Future<List<ScanDraftItem>> upsertItems(List<ScanDraftItem> items) async {
    for (final ScanDraftItem item in items) {
      saved[item.id] = item;
    }
    return items;
  }

  @override
  Future<List<ScanDraftItem>> completePhoto(
    String photoId,
    List<ScanDraftItem> items,
  ) async {
    if (failPartial) {
      failPartial = false;
      saved[items.first.id] = items.first;
      throw StateError('disk interrupted after first crop');
    }
    await upsertItems(items);
    photos.remove(photoId);
    return items;
  }

  @override
  Future<void> removeItems(List<String> ids) async {
    if (removing != null) await removing!.future;
    for (final String id in ids) {
      saved.remove(id);
      rescans.remove(id);
    }
  }
}

class _DelayedResolver extends _Resolver {
  final Completer<void> pending = Completer<void>();
  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) async {
    await pending.future;
    return super.resolveBatch(crops);
  }
}

class _ProgressiveCatalog extends Fake implements ScanCatalog {}

class _ProgressiveResolver extends ScanResolver {
  _ProgressiveResolver() : super(catalog: _ProgressiveCatalog());
  final Map<String, Completer<ScanResolution>> pending =
      <String, Completer<ScanResolution>>{};
  final Map<String, ScanCrop> inputs = <String, ScanCrop>{};
  final List<String> calls = <String>[];

  @override
  Future<ScanResolution> resolve(
    ScanCrop crop, {
    String? name,
    String? setCode,
    String? collectorNumber,
    String? language,
    int page = 1,
  }) {
    calls.add(crop.imagePath);
    inputs[crop.imagePath] = crop;
    final Completer<ScanResolution> result = Completer<ScanResolution>();
    pending[crop.imagePath] = result;
    return result.future;
  }

  Future<void> complete(String path) async {
    pending[path]!.complete(
      (await _Resolver().resolveBatch(<ScanCrop>[inputs[path]!])).single,
    );
  }
}

class _ItemScopedRetryResolver extends _Resolver {
  final Completer<void> held = Completer<void>();
  bool holding = false;

  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) async {
    if (crops.any((ScanCrop crop) => crop.imagePath == 'unrelated.jpg')) {
      holding = true;
      await held.future;
    }
    return super.resolveBatch(crops);
  }
}

ScanCrop _usableRescanCrop(String path, {String name = 'Fresh card'}) =>
    ScanCrop(
      imagePath: path,
      width: 640,
      height: 900,
      rectified: true,
      sourceCorners: _quad(.1, .1, .5, .7),
      lines: <ScanTextLine>[
        ScanTextLine(
          text: name,
          confidence: .99,
          bounds: const ScanBounds(.1, .05, .6, .03),
        ),
        const ScanTextLine(
          text: 'Instant',
          confidence: .99,
          bounds: ScanBounds(.1, .54, .4, .03),
        ),
        const ScanTextLine(
          text: '0146',
          confidence: .99,
          bounds: ScanBounds(.06, .90, .2, .02),
        ),
        const ScanTextLine(
          text: 'M11 EN',
          confidence: .99,
          bounds: ScanBounds(.06, .94, .2, .02),
        ),
      ],
    );

class _HeldRescanCommitStore extends ScanDraftStore {
  _HeldRescanCommitStore() : super(userId: 'rescan-clear-race');
  final Completer<void> committed = Completer<void>();
  final Completer<void> finish = Completer<void>();
  @override
  Future<ScanDraftItem> commitRescan(
    ScanDraftRescan request,
    ScanDraftItem replacement,
  ) async {
    final ScanDraftItem saved = await super.commitRescan(request, replacement);
    committed.complete();
    await finish.future;
    return saved;
  }

  @override
  Future<void> clearCaptures() async {
    throw const FileSystemException('The existing captures cannot be cleared.');
  }
}

class _HeldRescanRecognizer implements CardRecognizer {
  _HeldRescanRecognizer(this.crop);
  final ScanCrop crop;
  final Completer<void> started = Completer<void>();
  final Completer<void> finish = Completer<void>();
  @override
  Future<ScanRecognition> recognize(
    String path, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    started.complete();
    await finish.future;
    return ScanRecognition(
      imagePath: path,
      width: 1000,
      height: 1400,
      crops: <ScanCrop>[crop],
    );
  }
}

class _OldRescanResolver extends _Resolver {
  _OldRescanResolver(MtgCard printing) : super(printing: printing);
  final Completer<void> started = Completer<void>();
  final Completer<void> finish = Completer<void>();
  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) async {
    if (crops.any(
      (ScanCrop crop) => crop.lines.first.text == 'Original card',
    )) {
      if (!started.isCompleted) started.complete();
      await finish.future;
    }
    return super.resolveBatch(crops);
  }
}

class _BulkReplayDrafts extends _Drafts {
  @override
  Future<void> clearCaptures() async {
    saved.clear();
    photos.clear();
    rescans.clear();
  }
}

class _BudgetDrafts extends _Drafts {
  bool full = false;
  @override
  Future<List<ScanDraftPhoto>> importPhotos(
    Iterable<String> paths, {
    required bool multipleCards,
    bool ownedCameraSource = false,
    List<List<ScanPoint>> excludedRegions = const <List<ScanPoint>>[],
    ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
  }) {
    if (full) {
      return Future<List<ScanDraftPhoto>>.error(
        const ScanDraftStorageBudgetExceeded(),
      );
    }
    return super.importPhotos(
      paths,
      multipleCards: multipleCards,
      ownedCameraSource: ownedCameraSource,
      excludedRegions: excludedRegions,
      defaults: defaults,
    );
  }
}

class _BulkReplayRecognizer implements CardRecognizer {
  int calls = 0;
  int active = 0;
  int maximumActive = 0;

  @override
  Future<ScanRecognition> recognize(
    String path, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    final int photo = int.parse(RegExp(r'\d+').firstMatch(path)!.group(0)!);
    calls++;
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      await Future<void>.delayed(Duration.zero);
      return ScanRecognition(
        imagePath: path,
        width: 2000,
        height: 1400,
        crops: <ScanCrop>[
          for (int offset = 0; offset < 2; offset++)
            ScanCrop(
              imagePath: 'mock-card-${photo * 2 + offset}.jpg',
              width: _crop.width,
              height: _crop.height,
              rectified: true,
              sourceCorners: const <ScanPoint>[],
              lines: _crop.lines,
            ),
        ],
      );
    } finally {
      active--;
    }
  }
}

class _StagedRecognizer implements CardRecognizer, CapturePresenceRecognizer {
  final Completer<void> deep = Completer<void>();
  Completer<void>? presence;
  bool emptyPresence = false;
  List<ScanCrop>? detailCrops;
  int cards = 1;
  int presenceCalls = 0;
  int deepCalls = 0;
  int activeDeep = 0;
  int maximumDeep = 0;
  final List<List<List<ScanPoint>>> presenceTargets = <List<List<ScanPoint>>>[];
  final List<List<List<ScanPoint>>> detailTargets = <List<List<ScanPoint>>>[];
  @override
  bool get supportsCapturePresence => true;

  ScanRecognition result(String path, {required bool pending}) =>
      ScanRecognition(
        imagePath: path,
        width: 2000,
        height: 1400,
        crops: !pending && detailCrops != null
            ? detailCrops!
            : pending && emptyPresence
            ? const <ScanCrop>[]
            : <ScanCrop>[
                for (int index = 0; index < cards; index++)
                  ScanCrop(
                    imagePath: path,
                    width: 1000,
                    height: 1400,
                    rectified: true,
                    sourceCorners: _quad(.1 + index * .4, .2, .22, .45),
                    lines: _crop.lines,
                    warnings: pending
                        ? const <String>['details_pending']
                        : const <String>[],
                  ),
              ],
      );

  @override
  Future<ScanRecognition> recognizePresence(
    String path, {
    bool multipleCards = true,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    presenceCalls++;
    presenceTargets.add(targetRegions);
    await presence?.future;
    return result(path, pending: true);
  }

  @override
  Future<ScanRecognition> recognize(
    String path, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    deepCalls++;
    detailTargets.add(targetRegions);
    activeDeep++;
    if (activeDeep > maximumDeep) maximumDeep = activeDeep;
    try {
      await deep.future;
      return result(path, pending: false);
    } finally {
      activeDeep--;
    }
  }
}

class _StagedClearFailure extends ScanDraftStore {
  _StagedClearFailure() : super(userId: 'staged');
  @override
  Future<void> clearCaptures() =>
      Future<void>.error(const FileSystemException('Storage unavailable'));
}

class _BulkReplayResolver extends ScanResolver {
  _BulkReplayResolver(this.printing);
  final MtgCard printing;
  final Completer<void> initialCatalog = Completer<void>();
  bool recovered = false;
  int active = 0;
  int maximumActive = 0;
  int maximumBatch = 0;

  @override
  Future<List<ScanResolveOutcome>> resolveBatchOutcomes(
    List<ScanCrop> crops, {
    ScanOutcomeListener? onOutcome,
  }) async {
    active++;
    if (active > maximumActive) maximumActive = active;
    if (crops.length > maximumBatch) maximumBatch = crops.length;
    try {
      await initialCatalog.future;
      return crops.map((ScanCrop crop) {
        final int card = int.parse(
          RegExp(r'\d+').firstMatch(crop.imagePath)!.group(0)!,
        );
        final int kind = card % 4;
        if (kind == 3 && !recovered) {
          return ScanResolveOutcome.failure(
            StateError('Catalog offline'),
            StackTrace.current,
          );
        }
        return ScanResolveOutcome.success(
          ScanResolution(
            hints: ScanHints.fromCrop(crop),
            candidates: kind == 2 && !recovered
                ? const <ScanCandidate>[]
                : <ScanCandidate>[
                    ScanCandidate(
                      printing,
                      kind == 0
                          ? const <ScanEvidence>{
                              ScanEvidence.nameMatch,
                              ScanEvidence.footerMatch,
                            }
                          : const <ScanEvidence>{ScanEvidence.nameMatch},
                    ),
                    if (kind == 1)
                      ScanCandidate(printing, const <ScanEvidence>{
                        ScanEvidence.nameMatch,
                      }),
                  ],
            status: kind == 2 && !recovered
                ? ScanResolutionStatus.noMatch
                : kind == 0
                ? ScanResolutionStatus.exactPrinting
                : ScanResolutionStatus.needsReview,
          ),
        );
      }).toList();
    } finally {
      active--;
    }
  }
}

class _BlockedResolver extends _Resolver {
  _BlockedResolver({super.printing});

  final List<Completer<void>> gates = <Completer<void>>[];
  final List<List<ScanCrop>> inputs = <List<ScanCrop>>[];
  int active = 0;
  int maximumActive = 0;
  bool released = false;
  bool failFallback = false;

  @override
  Future<ScanResolution> resolve(
    ScanCrop crop, {
    String? name,
    String? setCode,
    String? collectorNumber,
    String? language,
    int page = 1,
  }) async {
    if (failFallback) throw StateError('Catalog unavailable');
    return (await super.resolveBatch(<ScanCrop>[crop])).single;
  }

  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) async {
    final Completer<void> gate = Completer<void>();
    gates.add(gate);
    inputs.add(List<ScanCrop>.of(crops));
    active++;
    if (active > maximumActive) maximumActive = active;
    if (released) gate.complete();
    try {
      await gate.future;
      return await super.resolveBatch(crops);
    } finally {
      active--;
    }
  }

  void releaseAll() {
    released = true;
    for (final Completer<void> gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

Future<void> _until(bool Function() ready) async {
  final Stopwatch elapsed = Stopwatch()..start();
  while (!ready()) {
    if (elapsed.elapsed > const Duration(seconds: 3)) {
      throw StateError('Scanner worker checkpoint was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

class _DelayedRawCompletion extends _Drafts {
  final Completer<void> started = Completer<void>();
  final Completer<void> pending = Completer<void>();

  @override
  Future<List<ScanDraftItem>> completePhoto(
    String photoId,
    List<ScanDraftItem> items,
  ) async {
    started.complete();
    await pending.future;
    return super.completePhoto(photoId, items);
  }
}

class _EmptyResolver extends ScanResolver {
  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) async => crops
      .map(
        (ScanCrop crop) => ScanResolution(
          candidates: const <ScanCandidate>[],
          hints: ScanHints.fromCrop(crop),
          status: ScanResolutionStatus.noMatch,
        ),
      )
      .toList();
}

class _RecoveryRecognizer implements CardRecognizer {
  _RecoveryRecognizer(this.original, this.recovered);
  final ScanCrop original;
  final ScanCrop recovered;
  final List<String> paths = <String>[];
  final Completer<void> retryStarted = Completer<void>();
  final Completer<void> releaseRetry = Completer<void>();
  @override
  Future<ScanRecognition> recognize(
    String path, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    paths.add(path);
    if (paths.length == 2) {
      retryStarted.complete();
      await releaseRetry.future;
    }
    return ScanRecognition(
      imagePath: path,
      width: 2000,
      height: 3000,
      crops: <ScanCrop>[paths.length == 1 ? original : recovered],
    );
  }
}

class _RecoveryResolver extends _Resolver {
  _RecoveryResolver(MtgCard card) : super(printing: card);
  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) async {
    if (crops.every(
      (ScanCrop crop) => ScanHints.fromCrop(crop).names.isEmpty,
    )) {
      return _EmptyResolver().resolveBatch(crops);
    }
    return super.resolveBatch(crops);
  }
}

class _MixedOutcomesResolver extends _Resolver {
  @override
  Future<List<ScanResolveOutcome>> resolveBatchOutcomes(
    List<ScanCrop> crops, {
    ScanOutcomeListener? onOutcome,
  }) async {
    return <ScanResolveOutcome>[
      for (final ScanCrop crop in crops)
        if (crop.sourceCorners.first.x > .5)
          ScanResolveOutcome.failure(
            StateError('Lookup unavailable'),
            StackTrace.current,
          )
        else
          ScanResolveOutcome.success(
            (await super.resolveBatch(<ScanCrop>[crop])).single,
          ),
    ];
  }
}

class _UnresolvedLiveResolver extends ScanResolver {
  @override
  Future<ScanResolution> resolve(
    ScanCrop crop, {
    String? name,
    String? setCode,
    String? collectorNumber,
    String? language,
    int page = 1,
  }) async => ScanResolution(
    candidates: const <ScanCandidate>[],
    hints: ScanHints.fromCrop(crop),
    status: ScanResolutionStatus.noMatch,
  );
}

Future<List<LiveCaptureObservation>> _admittedObservations(
  List<ScanCrop> crops,
) async {
  final LiveScanTracker tracker = LiveScanTracker(
    resolver: _UnresolvedLiveResolver(),
    retireIdentified: true,
    clock: () => DateTime.utc(2026),
  );
  try {
    for (int frame = 0; frame < 2; frame++) {
      tracker.update(
        crops
            .map(
              (ScanCrop crop) => LiveCardDetection(
                confidence: 1,
                corners: crop.sourceCorners,
                lines: crop.lines,
              ),
            )
            .toList(),
        currentGeometry: crops.map((ScanCrop crop) => crop.sourceCorners),
        appearanceSamplingSupported: true,
      );
    }
    final int token = tracker.beginCapture();
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      currentGeometry: crops.map((ScanCrop crop) => crop.sourceCorners),
    );
    expect(tracker.markCaptured(capture), crops.length);
    tracker.endCapture(token, resumeTracking: true);
    List<LiveCaptureObservation> observations = <LiveCaptureObservation>[];
    expect(
      await tracker.retainCapturedObservations(
        capture,
        retain: (List<LiveCaptureObservation> values) async {
          observations = values;
          return true;
        },
      ),
      isTrue,
    );
    expect(observations, hasLength(crops.length));
    return observations;
  } finally {
    tracker.dispose();
  }
}

Future<void> _settle(ScanSession session) async {
  while (session.running || session.remainingPhotos > 0) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

List<ScanPoint> _quad(double x, double y, double width, double height) =>
    <ScanPoint>[
      ScanPoint(x, y),
      ScanPoint(x + width, y),
      ScanPoint(x + width, y + height),
      ScanPoint(x, y + height),
    ];

ScanCrop _positionedCrop(List<ScanPoint> corners, {String path = ''}) =>
    ScanCrop(
      imagePath: path,
      width: _crop.width,
      height: _crop.height,
      rectified: true,
      sourceCorners: corners,
      lines: _crop.lines,
    );

class _FailedLiveDrafts extends _Drafts {
  @override
  Future<List<ScanDraftItem>> upsertItems(List<ScanDraftItem> items) async =>
      throw const FileSystemException('Storage full');
}

class _GatedLiveDrafts extends _Drafts {
  final Completer<void> saving = Completer<void>();
  final Completer<void> release = Completer<void>();
  @override
  Future<List<ScanDraftItem>> upsertItems(List<ScanDraftItem> items) async {
    if (!saving.isCompleted) saving.complete();
    await release.future;
    return super.upsertItems(items);
  }

  @override
  Future<List<ScanDraftPhoto>> importFocusStack(
    List<String> paths, {
    bool ownedCameraSource = false,
    bool diagnosticOnly = false,
    String? captureId,
    List<String> refinementReceiptIds = const <String>[],
    List<List<ScanPoint>>? targetRegions,
    List<List<ScanPoint>> excludedRegions = const <List<ScanPoint>>[],
    ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
  }) async => throw const FileSystemException('Diagnostic copy failed');
}

class _ToggleLiveDrafts extends _Drafts {
  bool failWrites = false;
  @override
  Future<List<ScanDraftItem>> upsertItems(List<ScanDraftItem> items) async {
    if (failWrites) throw const FileSystemException('Storage full');
    return super.upsertItems(items);
  }
}

class _FailingReviewBox extends Fake implements Box<String> {
  _FailingReviewBox(this.delegate);
  final Box<String> delegate;
  final Set<String> failingItemIds = <String>{};
  final Set<String> failedItemIds = <String>{};

  @override
  String? get path => delegate.path;
  @override
  Iterable<String> get keys => delegate.keys.whereType<String>();
  @override
  bool containsKey(Object? key) => delegate.containsKey(key);
  @override
  String? get(Object? key, {String? defaultValue}) =>
      delegate.get(key, defaultValue: defaultValue);
  @override
  Future<void> put(Object? key, String value) async {
    if (key is String && key.startsWith('item:')) {
      final String id = key.substring(5);
      if (failingItemIds.contains(id)) {
        failedItemIds.add(id);
        throw const FileSystemException('Review result cannot be persisted.');
      }
    }
    await delegate.put(key, value);
  }

  @override
  Future<void> putAll(Map<Object?, String> entries) => delegate.putAll(entries);
  @override
  Future<void> delete(Object? key) => delegate.delete(key);
  @override
  Future<void> deleteAll(Iterable<Object?> keys) => delegate.deleteAll(keys);
  @override
  Future<void> flush() => delegate.flush();
}

class _OtherPrinting extends _Printing {
  @override
  String get name => 'Counterspell';
}

class _WrongPhotoResolver extends _Resolver {
  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) async => crops
      .map(
        (ScanCrop crop) => ScanResolution(
          candidates: <ScanCandidate>[
            ScanCandidate(_OtherPrinting(), <ScanEvidence>{
              ScanEvidence.nameMatch,
              ScanEvidence.footerMatch,
            }),
          ],
          hints: ScanHints.fromCrop(crop),
          status: ScanResolutionStatus.exactPrinting,
        ),
      )
      .toList();
}

({String id, ScanCrop crop, ScanResolution resolution}) _liveReceipt(
  ScanCrop crop, {
  String id = 'card-1',
  MtgCard? card,
}) => (
  id: id,
  crop: crop,
  resolution: ScanResolution(
    candidates: <ScanCandidate>[
      ScanCandidate(card ?? _Printing(), <ScanEvidence>{
        ScanEvidence.nameMatch,
        ScanEvidence.footerMatch,
      }),
    ],
    hints: ScanHints.fromCrop(crop),
    status: ScanResolutionStatus.needsReview,
  ),
);

void main() {
  for (final String evidence in <String>[
    'matching source',
    'wrong source',
    'wrong target',
    'invalid pixels',
    'duplicate samples',
    'gallery image',
  ]) {
    test('saved target appearance binding requires $evidence', () async {
      final List<ScanPoint> target = _quad(.1, .2, .22, .45);
      final List<double> pixels = List<double>.filled(288, .35);
      final SavedTargetAppearance sample = SavedTargetAppearance(
        corners: evidence == 'wrong target' ? _quad(.5, .2, .22, .45) : target,
        values: evidence == 'invalid pixels' ? <double>[double.nan] : pixels,
        present: true,
      );
      final _Recognizer recognizer = _Recognizer()
        ..resultCrops = <ScanCrop>[_positionedCrop(target)]
        ..targetAppearances = <SavedTargetAppearance>[
          sample,
          if (evidence == 'duplicate samples') sample,
        ]
        ..responsePath = evidence == 'wrong source' ? 'other.jpg' : null;
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: _Resolver(),
      );
      addTearDown(session.dispose);
      const List<String> paths = <String>['captured-source.jpg'];
      if (evidence == 'gallery image') {
        await session.addPhotos(paths, multipleCards: true);
      } else {
        await session.addFocusStack(
          paths,
          targetRegions: <List<ScanPoint>>[target],
        );
      }
      await _settle(session);
      final List<SavedTargetAppearance> retained = session
          .captureTargetAppearances(paths);
      expect(retained, hasLength(evidence == 'matching source' ? 1 : 0));
      expect(session.captureTargetAppearances(<String>['other.jpg']), isEmpty);
      pixels[0] = .9;
      if (retained.isNotEmpty) expect(retained.single.values.first, .35);
      await session.clearCaptures();
      expect(session.captureTargetAppearances(paths), isEmpty);
    });
  }

  test(
    'frozen source guides reach presence and detailed recognition',
    () async {
      final _StagedRecognizer recognizer = _StagedRecognizer()
        ..emptyPresence = true;
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: _Resolver(),
      );
      final List<List<ScanPoint>> targets = <List<ScanPoint>>[
        _quad(.1, .2, .22, .45),
      ];
      final List<List<(double, double)>> expected = <List<(double, double)>>[
        targets.single.map((ScanPoint point) => (point.x, point.y)).toList(),
      ];
      try {
        expect(
          await session.addFocusStack(
            <String>['guided-camera.jpg'],
            captureId: 'guided-camera',
            targetRegions: targets,
            excludedRegions: <List<ScanPoint>>[_quad(.6, .2, .22, .45)],
            preferFastPresence: true,
          ),
          isTrue,
        );
        targets.single[0] = const ScanPoint(.3, .4);
        await _until(() => recognizer.deepCalls == 1);
        for (final List<List<List<ScanPoint>>> requests
            in <List<List<List<ScanPoint>>>>[
              recognizer.presenceTargets,
              recognizer.detailTargets,
            ]) {
          expect(requests, hasLength(1));
          expect(
            requests.single
                .map(
                  (List<ScanPoint> region) => region
                      .map((ScanPoint point) => (point.x, point.y))
                      .toList(),
                )
                .toList(),
            expected,
          );
        }
        recognizer.deep.complete();
        await _until(() => session.pendingDetailSources == 0);
        await _settle(session);
        expect(session.items, hasLength(1));
      } finally {
        if (!recognizer.deep.isCompleted) recognizer.deep.complete();
        session.dispose();
      }
    },
  );

  test('every focus exposure receives its frozen source guide', () async {
    final List<ScanPoint> target = _quad(.1, .2, .22, .45);
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[_positionedCrop(target)];
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _Resolver(),
    );
    addTearDown(session.dispose);
    expect(
      await session.addFocusStack(
        <String>['focus-near.jpg', 'focus-far.jpg'],
        targetRegions: <List<ScanPoint>>[target],
      ),
      isTrue,
    );
    await _settle(session);
    expect(recognizer.paths, <String>['focus-near.jpg', 'focus-far.jpg']);
    expect(recognizer.targetRequests, hasLength(2));
    for (final List<List<ScanPoint>> regions in recognizer.targetRequests) {
      expect(regions, hasLength(1));
      expect(
        regions.single.map((ScanPoint point) => (point.x, point.y)),
        target.map((ScanPoint point) => (point.x, point.y)),
      );
    }
  });

  test(
    'restored camera source keeps guides and gallery imports have none',
    () async {
      final List<ScanPoint> target = _quad(.1, .2, .22, .45);
      final _Drafts drafts = _Drafts();
      drafts.photos['restored-camera'] = ScanDraftPhoto(
        id: 'restored-camera',
        imagePath: 'restored-camera.jpg',
        multipleCards: true,
        createdAt: DateTime.now(),
        targetRegions: <List<ScanPoint>>[target],
      );
      final _Recognizer recognizer = _Recognizer()
        ..resultCrops = <ScanCrop>[_positionedCrop(target)];
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: _Resolver(),
        store: drafts,
      );
      addTearDown(session.dispose);
      await session.load();
      await _settle(session);
      await session.addPhotos(<String>['gallery.jpg'], multipleCards: true);
      await _settle(session);
      expect(recognizer.paths, <String>['restored-camera.jpg', 'gallery.jpg']);
      expect(recognizer.targetRequests.first, hasLength(1));
      expect(
        recognizer.targetRequests.first.single.map(
          (ScanPoint point) => (point.x, point.y),
        ),
        target.map((ScanPoint point) => (point.x, point.y)),
      );
      expect(recognizer.targetRequests.last, isEmpty);
    },
  );

  test(
    'a persisted sibling leaves Reading while another lookup remains held',
    () async {
      final _GatedLiveDrafts drafts = _GatedLiveDrafts();
      for (final String id in <String>['slow', 'fast']) {
        drafts.saved[id] = ScanSessionItem(
          _positionedCrop(_quad(.1, .1, .24, .35), path: id),
          id: id,
        ).draft;
      }
      final _ProgressiveResolver resolver = _ProgressiveResolver();
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(),
        resolver: resolver,
        store: drafts,
      );
      addTearDown(session.dispose);
      await session.load();
      await _until(() => resolver.pending.length == 2);
      final ScanSessionItem fast = session.items.singleWhere(
        (ScanSessionItem item) => item.id == 'fast',
      );
      final ScanSessionItem slow = session.items.singleWhere(
        (ScanSessionItem item) => item.id == 'slow',
      );
      final List<ScanResolution> changes = <ScanResolution>[];
      session.addListener(() {
        final ScanResolution? result = fast.resolution;
        if (result != null &&
            (changes.isEmpty || !identical(changes.last, result))) {
          expect(drafts.saved[fast.id]!.resolution, same(result));
          changes.add(result);
        }
      });
      await resolver.complete('fast');
      await drafts.saving.future;
      expect(fast.phase, ScanItemPhase.processing);
      expect(changes, isEmpty);
      drafts.release.complete();
      await _until(() => fast.resolution != null);
      expect(changes, hasLength(1));
      expect(fast.phase, ScanItemPhase.ready);
      expect(slow.phase, ScanItemPhase.processing);
      expect(session.running, isTrue);

      final Future<void> retry = session.retryItem(fast);
      await _until(
        () => resolver.calls.where((String path) => path == 'fast').length == 2,
      );
      expect(fast.phase, ScanItemPhase.retrying);
      await resolver.complete('fast');
      await retry.timeout(const Duration(seconds: 2));
      expect(fast.phase, ScanItemPhase.ready);
      expect(slow.phase, ScanItemPhase.processing);
      expect(changes, hasLength(2));
      await resolver.complete('slow');
      await _settle(session);
      expect(changes, hasLength(2));
      expect(resolver.calls, <String>['slow', 'fast', 'fast']);
    },
  );

  test(
    'photo refinement starts its follow-up while another batch sibling is held',
    () async {
      final _Drafts drafts = _Drafts();
      final ScanSessionItem initialSlow = ScanSessionItem(
        _positionedCrop(_quad(.6, .1, .24, .35), path: 'slow'),
        id: 'slow',
      );
      final ScanSessionItem initialFast = ScanSessionItem(
        _positionedCrop(_quad(.1, .1, .24, .35), path: 'fast'),
        id: 'fast',
        photoId: 'refine_jpg',
      )..liveCaptureReceiptId = 'receipt-fast';
      drafts.saved[initialSlow.id] = initialSlow.draft;
      drafts.saved[initialFast.id] = initialFast.draft;
      final _ProgressiveResolver resolver = _ProgressiveResolver();
      final _Recognizer recognizer = _Recognizer()
        ..resultCrops = <ScanCrop>[
          _positionedCrop(initialFast.crop.sourceCorners, path: 'refined'),
        ];
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: resolver,
        store: drafts,
      );
      addTearDown(session.dispose);
      await session.load();
      await _until(() => resolver.pending.length == 2);
      final ScanSessionItem fast = session.items.last;
      expect(
        await session.addPhotos(<String>['refine.jpg'], multipleCards: false),
        isTrue,
      );
      await _until(() => session.photosRead == 1);
      expect(session.items, hasLength(2));
      await resolver.complete('fast');
      await _until(() => resolver.pending.containsKey('refined'));
      expect(fast.resolution, isNull);
      expect(drafts.saved[fast.id]!.resolution, isNull);
      expect(session.items.first.phase, ScanItemPhase.processing);
      await resolver.complete('refined');
      await _until(() => fast.resolution != null);
      expect(fast.crop.imagePath, 'refined');
      expect(drafts.saved[fast.id]!.resolution, same(fast.resolution));
      expect(session.items.first.phase, ScanItemPhase.processing);
      await resolver.complete('slow');
      await _settle(session);
      expect(resolver.calls, <String>['slow', 'fast', 'refined']);
      expect(session.items, hasLength(2));
    },
  );

  test('progressive callbacks cannot restore a removed card or mutate a disposed session', () async {
    for (final bool dispose in <bool>[false, true]) {
      final _Drafts drafts = _Drafts();
      for (final String id in <String>['slow', 'fast']) {
        drafts.saved[id] = ScanSessionItem(
          _positionedCrop(_quad(.1, .1, .24, .35), path: id),
          id: id,
        ).draft;
      }
      final _ProgressiveResolver resolver = _ProgressiveResolver();
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(),
        resolver: resolver,
        store: drafts,
      );
      await session.load();
      await _until(() => resolver.pending.length == 2);
      await resolver.complete('fast');
      await _until(() => session.items.last.resolution != null);
      final ScanSessionItem slow = session.items.first;
      if (dispose) {
        session.dispose();
      } else {
        await session.remove(slow);
      }
      final Map<String, ScanDraftItem> before = Map<String, ScanDraftItem>.from(
        drafts.saved,
      );
      await resolver.complete('slow');
      await _settle(session);
      expect(drafts.saved, before);
      expect(slow.resolution, isNull);
      if (!dispose) {
        expect(session.items.map((ScanSessionItem item) => item.id), <String>[
          'fast',
        ]);
        session.dispose();
      }
    }
  });

  test('owned camera rescan retries failed OCR from admitted pixels after raw cleanup', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-rescan-owned-',
    );
    Hive.init(directory.path);
    final File originalPixels = await File('${directory.path}/original.jpg')
        .writeAsBytes(<int>[1, 2, 3], flush: true);
    final File camera = await File('${directory.path}/camera.jpg')
        .writeAsBytes(<int>[7, 8, 9], flush: true);
    final ScanDraftStore store = ScanDraftStore(userId: 'rescan-owned');
    final ScanDraftPhoto source = (await store.importPhotos(<String>[
      originalPixels.path,
    ], multipleCards: false)).single;
    await store.completePhoto(source.id, <ScanDraftItem>[
      ScanDraftItem(
        id: 'original',
        photoId: source.id,
        crop: _usableRescanCrop(originalPixels.path),
      ),
    ]);
    final _Recognizer recognizer = _Recognizer()..failNext = true;
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
      store: store,
    )..pause();
    try {
      await session.load();
      final ScanSessionItem original = session.items.single;
      await session.beginRescan(original);
      expect(
        await session.replaceRescanPhoto(
          original,
          camera.path,
          ownedCameraSource: true,
        ),
        isFalse,
      );
      expect(await camera.exists(), isFalse);
      expect(original.rescanPending, isTrue);
      final ScanDraftPhoto admitted = (await store.readRescans()).single.photo!;
      expect(await File(admitted.imagePath).readAsBytes(), <int>[7, 8, 9]);
      recognizer.resultCrops = <ScanCrop>[
        _usableRescanCrop(admitted.imagePath),
      ];
      expect(
        await session.replaceRescanPhoto(
          original,
          camera.path,
          ownedCameraSource: true,
        ),
        isTrue,
      );
      expect(recognizer.paths, <String>[
        admitted.imagePath,
        admitted.imagePath,
      ]);
      expect(session.items.single.id, original.id);
      expect(session.items.single.photoId, admitted.id);
      expect(
        await File(session.items.single.crop.imagePath).readAsBytes(),
        <int>[7, 8, 9],
      );
      expect(await originalPixels.readAsBytes(), <int>[1, 2, 3]);
      await _until(() => !session.running);
    } finally {
      session.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });

  test('replacement rejects ambiguous pixels and cancelling a failed read preserves the original', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-rescan-cancel-',
    );
    Hive.init(directory.path);
    final File pixels = await File('${directory.path}/original.jpg')
        .writeAsBytes(<int>[1, 2, 3]);
    final ScanDraftStore store = ScanDraftStore(userId: 'rescan-cancel');
    final ScanDraftPhoto photo = (await store.importPhotos(<String>[
      pixels.path,
    ], multipleCards: false)).single;
    await store.completePhoto(photo.id, <ScanDraftItem>[
      ScanDraftItem(
        id: 'original',
        photoId: photo.id,
        crop: _usableRescanCrop(pixels.path, name: 'Original card'),
      ),
    ]);
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[
        _usableRescanCrop(pixels.path),
        _usableRescanCrop(pixels.path),
      ];
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
      store: store,
    )..pause();
    try {
      await session.load();
      final ScanSessionItem original = session.items.single;
      await session.beginRescan(original);
      expect(await session.replaceRescanPhoto(original, pixels.path), isFalse);
      expect(session.items.single, same(original));
      expect(original.rescanPending, isTrue);
      expect((await store.readItems()).single.photoId, photo.id);
      recognizer.failNext = true;
      expect(await session.replaceRescanPhoto(original, pixels.path), isFalse);
      expect(session.storageError, isNotNull);
      await session.cancelRescan(original);
      expect(original.rescanPending, isFalse);
      expect(session.storageError, isNull);
      await session.persist(<ScanSessionItem>[original]);
      expect((await store.readItems()).single.photoId, photo.id);
      expect(await File(original.crop.imagePath).readAsBytes(), <int>[1, 2, 3]);
      expect(await store.readPhotos(), isEmpty);
    } finally {
      session.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });

  test('same-ID replacement completes before old lookup and late results cannot overwrite it or lose siblings', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-rescan-late-',
    );
    Hive.init(directory.path);
    final File originalPixels = await File('${directory.path}/original.jpg')
        .writeAsBytes(<int>[1, 2, 3]);
    final File freshPixels = await File('${directory.path}/fresh.jpg')
        .writeAsBytes(<int>[9, 8, 7]);
    final ScanDraftStore store = ScanDraftStore(userId: 'rescan-late');
    final ScanDraftPhoto source = (await store.importPhotos(<String>[
      originalPixels.path,
    ], multipleCards: true)).single;
    await store.completePhoto(source.id, <ScanDraftItem>[
      ScanDraftItem(
        id: 'original',
        photoId: source.id,
        crop: _usableRescanCrop(originalPixels.path, name: 'Original card'),
      ),
      ScanDraftItem(
        id: 'sibling',
        photoId: source.id,
        crop: _positionedCrop(_quad(.7, .1, .2, .7), path: originalPixels.path),
      ),
    ]);
    final MtgCard printing = MtgCard.fromJson(
      jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<String, dynamic>,
    );
    final _OldRescanResolver resolver = _OldRescanResolver(printing);
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[_usableRescanCrop(freshPixels.path)];
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: resolver,
      store: store,
    );
    try {
      await session.load();
      await resolver.started.future.timeout(const Duration(seconds: 3));
      final ScanSessionItem old = session.items.singleWhere(
        (ScanSessionItem item) => item.id == 'original',
      );
      await session.beginRescan(old);
      expect(
        await session
            .replaceRescanPhoto(old, freshPixels.path)
            .timeout(const Duration(seconds: 3)),
        isTrue,
      );
      expect(resolver.finish.isCompleted, isFalse);
      final ScanSessionItem fresh = session.items.singleWhere(
        (ScanSessionItem item) => item.id == old.id,
      );
      expect(fresh, isNot(same(old)));
      expect(fresh.photoId, isNot(source.id));
      expect(fresh.approval, isNull);
      expect(await File(fresh.crop.imagePath).readAsBytes(), <int>[9, 8, 7]);
      resolver.finish.complete();
      await _settle(session).timeout(const Duration(seconds: 3));
      expect(session.items, hasLength(2));
      expect(fresh.resolution!.hints.names, contains('Fresh card'));
      expect(
        session.items
            .singleWhere((ScanSessionItem item) => item.id == 'sibling')
            .resolution,
        isNotNull,
      );
      expect(await File(source.imagePath).exists(), isTrue);
      expect(
        (await store.readItems())
            .singleWhere((ScanDraftItem item) => item.id == old.id)
            .photoId,
        fresh.photoId,
      );
    } finally {
      if (!resolver.finish.isCompleted) resolver.finish.complete();
      session.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });

  test('failed Clear after durable replacement restores fresh source owner and clears pending Rescan', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-rescan-clear-race-',
    );
    Hive.init(directory.path);
    final File pixels = await File('${directory.path}/original.jpg')
        .writeAsBytes(<int>[1, 2, 3]);
    final File freshPixels = await File('${directory.path}/fresh.jpg')
        .writeAsBytes(<int>[9, 8, 7]);
    final _HeldRescanCommitStore store = _HeldRescanCommitStore();
    final ScanDraftPhoto source = (await store.importPhotos(<String>[
      pixels.path,
    ], multipleCards: false)).single;
    await store.completePhoto(source.id, <ScanDraftItem>[
      ScanDraftItem(
        id: 'original',
        photoId: source.id,
        crop: _usableRescanCrop(pixels.path),
      ),
    ]);
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[_usableRescanCrop(freshPixels.path)];
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
      store: store,
    )..pause();
    try {
      await session.load();
      final ScanSessionItem old = session.items.single;
      await session.beginRescan(old);
      final Future<bool> replacement = session.replaceRescanPhoto(
        old,
        freshPixels.path,
      );
      await store.committed.future.timeout(const Duration(seconds: 3));
      final Future<void> clear = session.clearCaptures();
      final Future<void> failedClear = expectLater(
        clear,
        throwsA(isA<FileSystemException>()),
      );
      store.finish.complete();
      expect(await replacement, isFalse);
      await failedClear;
      final ScanSessionItem restored = session.items.single;
      expect(restored, isNot(same(old)));
      expect(restored.photoId, isNot(source.id));
      expect(restored.rescanPending, isFalse);
      expect(restored.approval, isNull);
      expect(await File(restored.crop.imagePath).readAsBytes(), <int>[9, 8, 7]);
      await session.persist(<ScanSessionItem>[restored]);
      expect((await store.readItems()).single.photoId, restored.photoId);
      expect(
        (await store.readSource(restored.photoId))!.imagePath,
        isNot(source.imagePath),
      );
    } finally {
      if (!store.finish.isCompleted) store.finish.complete();
      session.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });

  test('Clear during independent replacement read cannot resurrect the old or new card', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-rescan-clear-',
    );
    Hive.init(directory.path);
    final File pixels = await File('${directory.path}/original.jpg')
        .writeAsBytes(<int>[1, 2, 3]);
    final ScanDraftStore store = ScanDraftStore(userId: 'rescan-clear');
    final ScanDraftPhoto source = (await store.importPhotos(<String>[
      pixels.path,
    ], multipleCards: false)).single;
    await store.completePhoto(source.id, <ScanDraftItem>[
      ScanDraftItem(
        id: 'original',
        photoId: source.id,
        crop: _usableRescanCrop(pixels.path),
      ),
    ]);
    final _HeldRescanRecognizer recognizer = _HeldRescanRecognizer(
      _usableRescanCrop(pixels.path),
    );
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
      store: store,
    )..pause();
    try {
      await session.load();
      final ScanSessionItem item = session.items.single;
      await session.beginRescan(item);
      final Future<bool> replacement = session.replaceRescanPhoto(
        item,
        pixels.path,
      );
      await recognizer.started.future.timeout(const Duration(seconds: 3));
      await session.clearCaptures();
      recognizer.finish.complete();
      expect(await replacement, isFalse);
      expect(session.items, isEmpty);
      expect(await store.readItems(), isEmpty);
      expect(await store.readPhotos(), isEmpty);
      expect(await store.readRescans(), isEmpty);
      expect(await pixels.readAsBytes(), <int>[1, 2, 3]);
    } finally {
      if (!recognizer.finish.isCompleted) recognizer.finish.complete();
      session.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });

  test('one uncertain collector suffix proves basic-land framing without exact-print authority', () {
    for (final (String text, bool framed) in <(String, bool)>[
      ('252/254 L', true),
      ('282/284 4', true),
      ('82//254', true),
      ('282/284 4 6', false),
      ('282/284 foil', false),
    ]) {
      final ScanCrop crop = ScanCrop(
        imagePath: '/saved/basic.jpg',
        width: 2650,
        height: 4096,
        rectified: true,
        sourceCorners: _quad(.1, .2, .22, .45),
        warnings: const <String>[
          'partial_card',
          'basic_land_outline',
          'unread_footer',
          'details_pending',
        ],
        lines: <ScanTextLine>[
          const ScanTextLine(
            text: 'Snow-Covered Swamp',
            confidence: 1,
            bounds: ScanBounds(.066, .041, .57, .034),
          ),
          const ScanTextLine(
            text: 'Basic Snow Land',
            confidence: 1,
            bounds: ScanBounds(.061, .825, .37, .051),
          ),
          ScanTextLine(
            text: text,
            confidence: .30,
            bounds: const ScanBounds(.046, .9475, .151, .01875),
          ),
        ],
      );
      expect(hasVerifiedSavedCardCapturePresence(crop), framed, reason: text);
      expect(
        hasVerifiedSavedBasicLandCapturePresence(crop),
        framed,
        reason: text,
      );
      final ScanSessionItem item = ScanSessionItem(crop)
        ..resolution = ScanResolution(
          candidates: <ScanCandidate>[
            ScanCandidate(_Printing(), <ScanEvidence>{
              ScanEvidence.nameMatch,
              ScanEvidence.footerMatch,
            }),
          ],
          hints: ScanHints.fromCrop(crop),
          status: ScanResolutionStatus.exactPrinting,
        );
      expect(item.exactMatch, isFalse, reason: text);
      expect(crop.lines.last.text, text);
      expect(crop.lines.last.confidence, .30);
    }
  });

  for (final bool failed in <bool>[false, true]) {
    test(
      '${failed ? 'failed' : 'pending'} detail ownership survives more than 32 newer admissions',
      () async {
        final _StagedRecognizer recognizer = _StagedRecognizer()
          ..emptyPresence = true;
        final ScanSession session = ScanSession(
          recognizer: recognizer,
          resolver: _Resolver(),
        );
        const List<String> paths = <String>['older-staged-source.jpg'];
        try {
          expect(
            await session.addFocusStack(
              paths,
              captureId: 'older-staged-source',
              targetRegions: <List<ScanPoint>>[_quad(.1, .2, .22, .45)],
              preferFastPresence: true,
            ),
            isTrue,
          );
          await _until(() => recognizer.deepCalls == 1);
          if (failed) {
            recognizer.deep.completeError(StateError('Detail unavailable'));
            await _until(() => session.failedPhotos == 1);
          }
          session.pause();
          for (int index = 0; index < 40; index++) {
            expect(
              await session.addPhotos(<String>[
                'newer-gallery-$index.jpg',
              ], multipleCards: false),
              isTrue,
            );
          }
          expect(session.captureReadComplete(paths), isTrue);
          expect(session.captureDetailsPending(paths), !failed);
          expect(session.captureDetailsFailed(paths), failed);
          expect(
            session.captureDetailsPending(<String>['newer-gallery-39.jpg']),
            isFalse,
          );
          expect(
            session.captureDetailsFailed(<String>['newer-gallery-39.jpg']),
            isFalse,
          );
        } finally {
          session.dispose();
          if (!recognizer.deep.isCompleted) recognizer.deep.complete();
          await _until(() => recognizer.activeDeep == 0);
        }
      },
    );
  }

  for (final String action in <String>[
    'finish',
    'approve',
    'clear',
    'clear then fresh',
    'failed clear',
    'remove',
    'restart',
    'empty presence',
    'gallery',
    'no identity',
  ]) {
    test(
      'staged capture $action saves presence before detail and preserves source ownership',
      () async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'scanner-staged-',
        );
        Hive.init(directory.path);
        final File first = File('${directory.path}/first.jpg')
          ..writeAsBytesSync(<int>[1, 2, 3, 4]);
        final File second = File('${directory.path}/second.jpg')
          ..writeAsBytesSync(<int>[5, 6, 7, 8]);
        final MtgCard printing = MtgCard.fromJson(<String, Object?>{
          ...(jsonDecode(
            File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
          ) as Map<String, Object?>),
          'name': 'Lightning Bolt',
          'set': 'm11',
          'collector_number': '146',
          'type_line': 'Instant',
          'layout': 'normal',
          'card_faces': null,
        });
        final _StagedRecognizer recognizer = _StagedRecognizer()
          ..emptyPresence = action == 'empty presence';
        ScanSession session = ScanSession(
          recognizer: recognizer,
          resolver: action == 'no identity'
              ? _EmptyResolver()
              : _Resolver(printing: printing),
          store: action == 'failed clear'
              ? _StagedClearFailure()
              : ScanDraftStore(userId: 'staged'),
        );
        try {
          await session.load();
          expect(
            await session.addFocusStack(
              <String>[first.path],
              captureId: 'first',
              targetRegions: <List<ScanPoint>>[_quad(.1, .2, .22, .45)],
              preferFastPresence: true,
            ),
            isTrue,
          );
          await _until(() => recognizer.deepCalls == 1);
          expect(recognizer.presenceCalls, 1);
          expect(session.pendingPhotoCaptures, 0);
          expect(session.pendingDetailSources, 1);
          expect(session.captureReadComplete(<String>[first.path]), isTrue);
          expect(session.captureDetailsPending(<String>[first.path]), isTrue);
          expect(session.captureDetailsPending(<String>[second.path]), isFalse);
          expect(
            (await session.store!.readDetails()).single.presenceComplete,
            isTrue,
          );
          expect(
            (await session.store!.readSource('first_0'))!.imagePath,
            isNot(first.path),
          );
          final String? id = session.items.firstOrNull?.id;
          if (action != 'empty presence') {
            expect(session.items, hasLength(1));
            expect(session.items.single.phase, ScanItemPhase.processing);
            expect(session.items.single.exactMatch, isFalse);
            expect(
              session.items.single.crop.warnings,
              contains('details_pending'),
            );
          } else {
            expect(session.items, isEmpty);
          }
          if (action == 'approve') {
            final ScanSessionItem item = session.items.single;
            item.approval = ScanQueueApproval(
              operationId: item.id,
              card: cardFromScryfall(printing, finish: Finish.nonfoil),
              quantity: 7,
              deckId: 'binder',
            );
            item.manuallyReviewed = true;
            await session.persist(<ScanSessionItem>[item]);
          } else if (action == 'clear') {
            await session.clearCaptures();
          } else if (action == 'clear then fresh') {
            await session.clearCaptures();
            expect(
              await session.addFocusStack(
                <String>[second.path],
                captureId: 'second',
                targetRegions: <List<ScanPoint>>[_quad(.1, .2, .22, .45)],
                preferFastPresence: true,
              ),
              isTrue,
            );
            await _until(
              () => recognizer.presenceCalls == 2 && session.items.length == 1,
            );
            expect(session.items.single.id, startsWith('second_0_'));
            expect(
              recognizer.deepCalls,
              1,
              reason: 'A new epoch can verify saved presence while the canceled old deep call drains.',
            );
          } else if (action == 'failed clear') {
            await expectLater(
              session.clearCaptures(),
              throwsA(isA<FileSystemException>()),
            );
            expect(session.items, hasLength(1));
            expect(session.pendingDetailSources, 1);
          } else if (action == 'remove') {
            await session.remove(session.items.single);
          } else if (action == 'restart') {
            session.dispose();
            recognizer.deep.complete();
            await _until(() => recognizer.activeDeep == 0 && !session.running);
            await Hive.close();
            final _StagedRecognizer resumed = _StagedRecognizer()
              ..deep.complete();
            session = ScanSession(
              recognizer: resumed,
              resolver: _Resolver(printing: printing),
              store: ScanDraftStore(userId: 'staged'),
            );
            await session.load();
            await _settle(session);
            expect(
              resumed.presenceCalls,
              0,
              reason: 'Durably saved presence is not photographed or recounted on restart.',
            );
            expect(resumed.deepCalls, 1);
          } else if (action == 'finish') {
            expect(
              await session.addFocusStack(
                <String>[second.path],
                captureId: 'second',
                targetRegions: <List<ScanPoint>>[_quad(.1, .2, .22, .45)],
                preferFastPresence: true,
              ),
              isTrue,
            );
            await _until(
              () =>
                  recognizer.presenceCalls == 2 &&
                  session.items.length == 2 &&
                  session.captureReadComplete(<String>[second.path]),
            );
            expect(
              recognizer.deepCalls,
              1,
              reason: 'The second source gets independent presence while first deep OCR is held.',
            );
            expect(session.pendingPhotoCaptures, 0);
            expect(session.pendingDetailSources, 2);
          } else if (action == 'gallery') {
            expect(
              await session.addPhotos(<String>[
                second.path,
              ], multipleCards: false),
              isTrue,
            );
            await Future<void>.delayed(const Duration(milliseconds: 10));
            expect(recognizer.presenceCalls, 1);
            expect(
              recognizer.deepCalls,
              1,
              reason: 'An ordinary gallery read waits for the one full reader.',
            );
          }
          if (!recognizer.deep.isCompleted) recognizer.deep.complete();
          await _settle(session);
          expect(session.pendingDetailSources, 0);
          expect(session.captureDetailsPending(<String>[first.path]), isFalse);
          expect(session.captureDetailsPending(<String>[second.path]), isFalse);
          expect(recognizer.maximumDeep, lessThanOrEqualTo(1));
          if (action == 'clear' || action == 'remove') {
            expect(session.items, isEmpty);
            expect(await session.store!.readDetails(), isEmpty);
            expect(await session.store!.readItems(), isEmpty);
          } else {
            expect(
              session.items,
              hasLength(action == 'finish' || action == 'gallery' ? 2 : 1),
            );
            if (id != null && action != 'clear then fresh') {
              expect(session.items.first.id, id);
            }
            if (action == 'clear then fresh') {
              expect(session.items.single.id, startsWith('second_0_'));
            }
            if (action == 'approve') {
              expect(session.items.single.approval!.quantity, 7);
              expect(session.items.single.approval!.deckId, 'binder');
            } else {
              expect(
                session.items.every(
                  (ScanSessionItem item) =>
                      !item.crop.warnings.contains('details_pending'),
                ),
                isTrue,
              );
            }
            expect(await session.store!.readDetails(), isEmpty);
            if (action == 'no identity') {
              expect(session.items.single.phase, ScanItemPhase.noIdentity);
              expect(
                recognizer.deepCalls,
                1,
                reason: 'Detailed native OCR consumes the automatic saved-source recovery attempt.',
              );
              await session.retryItem(session.items.single);
              await _settle(session);
              expect(recognizer.deepCalls, 2);
              expect(session.items.single.id, id);
              expect(session.items.single.phase, ScanItemPhase.noIdentity);
            }
          }
        } finally {
          if (!recognizer.deep.isCompleted) recognizer.deep.complete();
          session.dispose();
          await Hive.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }
  for (final bool restart in <bool>[false, true]) {
    test(
      'removing one staged card excludes its delayed detail crop${restart ? ' across restart' : ''}',
      () async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'scanner-partial-remove-',
        );
        Hive.init(directory.path);
        final File photo = await File('${directory.path}/cards.jpg')
            .writeAsBytes(<int>[1, 2, 3, 4]);
        final _StagedRecognizer recognizer = _StagedRecognizer()..cards = 2;
        ScanSession session = ScanSession(
          recognizer: recognizer,
          resolver: _EmptyResolver(),
          store: ScanDraftStore(userId: 'partial-remove'),
        );
        try {
          await session.load();
          expect(
            await session.addFocusStack(
              <String>[photo.path],
              captureId: 'two-cards',
              targetRegions: <List<ScanPoint>>[
                _quad(.1, .2, .22, .45),
                _quad(.5, .2, .22, .45),
              ],
              preferFastPresence: true,
            ),
            isTrue,
          );
          await _until(() => recognizer.deepCalls == 1);
          expect(session.items, hasLength(2));
          final String removedId = session.items.first.id;
          final String retainedId = session.items.last.id;
          final String sourceId = session.items.first.photoId;
          await session.remove(session.items.first);
          expect(session.items.single.id, retainedId);
          if (restart) {
            session.dispose();
            recognizer.deep.complete();
            await _until(() => recognizer.activeDeep == 0 && !session.running);
            await Hive.close();
            final _StagedRecognizer resumed = _StagedRecognizer()
              ..cards = 2
              ..deep.complete();
            session = ScanSession(
              recognizer: resumed,
              resolver: _EmptyResolver(),
              store: ScanDraftStore(userId: 'partial-remove'),
            );
            await session.load();
          } else {
            recognizer.deep.complete();
          }
          await _settle(session);
          expect(session.items.map((ScanSessionItem item) => item.id), <String>[
            retainedId,
          ]);
          expect(
            session.items.single.crop.warnings,
            isNot(contains('details_pending')),
          );
          expect(
            (await session.store!.readItems()).map(
              (ScanDraftItem item) => item.id,
            ),
            <String>[retainedId],
          );
          expect(await session.store!.readDetails(), isEmpty);
          expect(await session.store!.readSource(sourceId), isNotNull);
          final List<List<ScanPoint>> retired = await session.store!
              .readReplacedRegions(sourceId);
          expect(retired, hasLength(1));
          expect(retired.single.first.x, .1);
          expect((await session.store!.readAccounting()).discarded, 1);
          expect(
            session.items.any(
              (ScanSessionItem item) =>
                  item.id == removedId || item.id.contains('_detail_'),
            ),
            isFalse,
          );
        } finally {
          if (!recognizer.deep.isCompleted) recognizer.deep.complete();
          session.dispose();
          await Hive.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }

  test('storage budget failure preserves existing cards and resumes admission after space is available', () async {
    final _BudgetDrafts drafts = _BudgetDrafts();
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _Resolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    expect(
      await session.addPhotos(<String>['first.jpg'], multipleCards: false),
      isTrue,
    );
    await _settle(session);
    final String first = session.items.single.id;
    drafts.full = true;
    expect(
      await session.addPhotos(<String>['second.jpg'], multipleCards: false),
      isFalse,
    );
    expect(session.storageError, ScanDraftStorageBudgetExceeded.userMessage);
    expect(session.items.single.id, first);
    expect(drafts.saved.keys, <String>[first]);
    expect(session.paused, isFalse);
    drafts.full = false;
    expect(
      await session.addPhotos(<String>['second.jpg'], multipleCards: false),
      isTrue,
    );
    await _settle(session);
    expect(session.storageError, isNull);
    expect(session.items, hasLength(2));
    expect(session.items.first.id, first);
  });
  for (final String recovery in <String>[
    'retry',
    'remove',
    'clear',
    'protected discard',
    'manual correction',
    'recovered storage budget',
    'unrelated source error',
  ]) {
    test(
      'review publication storage recovery handles $recovery without losing other failures',
      () async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'scanner-review-write-',
        );
        Hive.init(directory.path);
        late _FailingReviewBox box;
        final ScanDraftStore drafts = ScanDraftStore(
          userId: 'review-write-recovery',
          maximumImageBytes: recovery == 'recovered storage budget'
              ? 6
              : ScanDraftStore.defaultMaximumImageBytes,
          openBox: (String name) async =>
              box = _FailingReviewBox(await Hive.openBox<String>(name)),
        );
        final MtgCard printing = MtgCard.fromJson(
          jsonDecode(
            File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
          ) as Map<String, Object?>,
        );
        final ScanSession session = ScanSession(
          recognizer: _Recognizer(),
          resolver: _Resolver(printing: printing),
          store: drafts,
        );
        try {
          await drafts.upsertItems(<ScanDraftItem>[
            for (final String id in <String>['first', 'second'])
              ScanDraftItem(id: id, photoId: 'review-source', crop: _crop),
          ]);
          box.failingItemIds.addAll(<String>['first', 'second']);
          if (recovery == 'recovered storage budget') {
            final File oversized = File('${directory.path}/oversized.jpg')
              ..writeAsBytesSync(<int>[255, 216, 1, 2, 3, 255, 217]);
            expect(
              await session.addPhotos(<String>[
                oversized.path,
              ], multipleCards: false),
              isFalse,
            );
            expect(
              session.storageError,
              ScanDraftStorageBudgetExceeded.userMessage,
            );
          }
          await session.load();
          await _settle(session);
          expect(box.failedItemIds, <String>{'first', 'second'});
          expect(session.items, hasLength(2));
          expect(
            session.items.every(
              (ScanSessionItem item) => item.resolution == null,
            ),
            isTrue,
          );
          expect(
            session.items.map((ScanSessionItem item) => item.phase),
            everyElement(ScanItemPhase.needsReview),
            reason: 'Idle unsaved review results must remain available for correction.',
          );
          expect(
            session.items.map((ScanSessionItem item) => item.error),
            everyElement(isNull),
          );
          expect(
            (await drafts.readItems()).every(
              (ScanDraftItem item) => item.resolution == null,
            ),
            isTrue,
          );
          if (recovery == 'recovered storage budget') {
            expect(
              session.storageError,
              ScanDraftStorageBudgetExceeded.userMessage,
            );
            final File source = File('${directory.path}/source.jpg')
              ..writeAsBytesSync(<int>[255, 216, 1, 2, 255, 217]);
            expect(
              await session.addPhotos(<String>[
                source.path,
              ], multipleCards: false),
              isTrue,
            );
            await _settle(session);
          }
          final String? reviewError = session.storageError;
          expect(reviewError, contains('latest review results'));
          final ScanSessionItem first = session.items.firstWhere(
            (ScanSessionItem item) => item.id == 'first',
          );
          final ScanSessionItem second = session.items.firstWhere(
            (ScanSessionItem item) => item.id == 'second',
          );
          box.failingItemIds.remove(first.id);
          await session.retryItem(first);
          await _settle(session);
          expect(first.resolution, isNotNull);
          expect(second.resolution, isNull);
          expect(second.phase, ScanItemPhase.needsReview);
          final Map<String, ScanDraftItem> afterFirst = <String, ScanDraftItem>{
            for (final ScanDraftItem item in await drafts.readItems())
              item.id: item,
          };
          expect(afterFirst[first.id]!.resolution, isNotNull);
          expect(afterFirst[second.id]!.resolution, isNull);
          expect(
            session.storageError,
            reviewError,
            reason: 'The second card still has an unsaved review result.',
          );

          if (recovery == 'manual correction') {
            box.failingItemIds.remove(second.id);
            second.selected = true;
            await session.persist(<ScanSessionItem>[second]);
            expect(session.storageError, reviewError);
            expect(second.phase, ScanItemPhase.needsReview);
            expect(
              (await drafts.readItems())
                  .firstWhere((ScanDraftItem item) => item.id == second.id)
                  .resolution,
              isNull,
              reason: 'Saving selection alone does not recover a lost review result.',
            );
            second.approval = ScanQueueApproval(
              operationId: second.id,
              card: cardFromScryfall(printing, finish: printing.finishes.first),
              quantity: 2,
              deckId: 'binder',
            );
            second.manuallyReviewed = true;
            box.failingItemIds.add(second.id);
            await expectLater(
              session.persist(<ScanSessionItem>[second]),
              throwsA(isA<FileSystemException>()),
            );
            expect(session.storageError, reviewError);
            expect(second.phase, ScanItemPhase.needsReview);
            box.failingItemIds.remove(second.id);
            await session.persist(<ScanSessionItem>[second]);
            final ScanDraftItem corrected = (await drafts.readItems())
                .firstWhere((ScanDraftItem item) => item.id == second.id);
            expect(corrected.approval!.quantity, 2);
            expect(corrected.approval!.deckId, 'binder');
            expect(session.storageError, isNull);
            expect(second.phase, ScanItemPhase.ready);
          } else if (recovery == 'protected discard') {
            await session.discardRemaining(protectedIds: <String>{second.id});
            expect(session.items.single.id, second.id);
            expect((await drafts.readItems()).single.id, second.id);
            expect(session.storageError, reviewError);
            expect(second.phase, ScanItemPhase.needsReview);
            box.failingItemIds.remove(second.id);
            await session.retryItem(second);
            await _settle(session);
            expect((await drafts.readItems()).single.resolution, isNotNull);
            expect(session.storageError, isNull);
          } else if (recovery == 'remove') {
            await session.removeBatch(<ScanSessionItem>[second]);
            expect(session.items.single.id, first.id);
            expect((await drafts.readItems()).single.id, first.id);
            expect(session.storageError, isNull);
          } else if (recovery == 'clear') {
            await session.clearCaptures();
            expect(session.items, isEmpty);
            expect(await drafts.readItems(), isEmpty);
            expect(session.storageError, isNull);
            await drafts.upsertItems(<ScanDraftItem>[
              ScanDraftItem(id: 'later', photoId: 'later-source', crop: _crop),
            ]);
            box.failingItemIds.add('later');
            await session.retryUnresolved();
            await _settle(session);
            expect(session.items.single.id, 'later');
            expect(session.storageError, reviewError);
            box.failingItemIds.remove('later');
            await session.retryItem(session.items.single);
            await _settle(session);
            expect((await drafts.readItems()).single.resolution, isNotNull);
            expect(
              session.storageError,
              isNull,
              reason:
                  'Cleared captures cannot keep a later review retry blocked.',
            );
          } else {
            String? sourceError;
            if (recovery == 'unrelated source error') {
              expect(
                await session.addPhotos(<String>[
                  '${directory.path}/missing.jpg',
                ], multipleCards: false),
                isFalse,
              );
              sourceError = session.storageError;
              expect(sourceError, isNotNull);
              expect(sourceError, isNot(reviewError));
              expect(second.phase, ScanItemPhase.needsReview);
            }
            box.failingItemIds.remove(second.id);
            await session.retryItem(second);
            await _settle(session);
            expect(
              (await drafts.readItems()).every(
                (ScanDraftItem item) => item.resolution != null,
              ),
              isTrue,
            );
            expect(session.storageError, sourceError);
          }
        } finally {
          session.dispose();
          await Hive.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }

  for (final String lane in <String>['photo', 'focus stack']) {
    test(
      'weak saved basic-land footer survives $lane persistence and restart without exact approval',
      () async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'scanner-weak-footer-',
        );
        Hive.init(directory.path);
        final File source = File('${directory.path}/source.jpg')
          ..writeAsBytesSync(<int>[255, 216, 1, 2, 255, 217]);
        final Map<String, Object?> fixture = jsonDecode(
          File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
        ) as Map<String, Object?>;
        final MtgCard printing = MtgCard.fromJson(<String, Object?>{
          ...fixture,
          'name': 'Snow-Covered Swamp',
          'type_line': 'Basic Snow Land — Swamp',
          'set': 'mh1',
          'collector_number': '252',
          'layout': 'normal',
          'card_faces': null,
        });
        final _Recognizer recognizer = _Recognizer()
          ..resultCrop = ScanCrop(
            imagePath: source.path,
            width: 2650,
            height: 4096,
            rectified: true,
            sourceCorners: _quad(.1, .2, .22, .45),
            warnings: const <String>[
              'border_recovered',
              'partial_card',
              'basic_land_outline',
              'unread_footer',
            ],
            lines: const <ScanTextLine>[
              ScanTextLine(
                text: 'Snow-Covered Swamp',
                confidence: 1,
                bounds: ScanBounds(.066, .041, .57, .034),
              ),
              ScanTextLine(
                text: 'Basic Snow Land',
                confidence: 1,
                bounds: ScanBounds(.061, .825, .37, .051),
              ),
              ScanTextLine(
                text: '82//254',
                confidence: .30,
                bounds: ScanBounds(.046, .9475, .151, .01875),
              ),
              ScanTextLine(
                text: 'Unusable row',
                confidence: .29,
                bounds: ScanBounds(.1, .96, .2, .02),
              ),
              ScanTextLine(
                text: 'Invalid row',
                confidence: double.nan,
                bounds: ScanBounds(.1, .96, .2, .02),
              ),
            ],
          );
        recognizer.resultCrops = <ScanCrop>[recognizer.resultCrop];
        ScanSession? session;
        try {
          session = ScanSession(
            recognizer: recognizer,
            resolver: _Resolver(printing: printing),
            store: ScanDraftStore(userId: 'weak-footer'),
          );
          await session.load();
          expect(
            lane == 'photo'
                ? await session.addPhotos(<String>[
                    source.path,
                  ], multipleCards: false)
                : await session.addFocusStack(
                    <String>[source.path],
                    captureId: 'weak_footer',
                    targetRegions: <List<ScanPoint>>[
                      recognizer.resultCrop.sourceCorners,
                    ],
                  ),
            isTrue,
          );
          await _settle(session);
          final String itemId = session.items.single.id;
          expect(
            session.items.single.crop.lines.map(
              (ScanTextLine line) => line.text,
            ),
            <String>['Snow-Covered Swamp', 'Basic Snow Land', '82//254'],
          );
          expect(session.items.single.crop.lines.last.confidence, .30);
          expect(session.items.single.exactMatch, isFalse);
          expect(session.items.single.approval, isNull);
          expect(session.items.single.phase, ScanItemPhase.needsReview);
          session.dispose();
          session = null;
          await Hive.close();
          session = ScanSession(
            recognizer: recognizer,
            resolver: _Resolver(printing: printing),
            store: ScanDraftStore(userId: 'weak-footer'),
          );
          await session.load();
          await _settle(session);
          expect(session.items.single.id, itemId);
          expect(session.items.single.crop.lines.last.text, '82//254');
          expect(session.items.single.crop.lines.last.confidence, .30);
          expect(session.items.single.exactMatch, isFalse);
          expect(session.items.single.approval, isNull);
          expect(recognizer.calls, 1);
        } finally {
          session?.dispose();
          await Hive.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }
  test('per-card outcomes publish a successful sibling and expose lookup failure separately', () async {
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[
        _positionedCrop(_quad(.1, .2, .2, .4)),
        _positionedCrop(_quad(.6, .2, .2, .4)),
      ];
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _MixedOutcomesResolver(),
      store: _Drafts(),
    );
    addTearDown(session.dispose);
    await session.addPhotos(<String>['siblings.jpg'], multipleCards: true);
    await _settle(session);
    expect(session.items, hasLength(2));
    expect(session.items.first.resolution!.candidates, hasLength(1));
    expect(session.items.first.error, isNull);
    expect(session.items.first.phase, isNot(ScanItemPhase.lookupFailed));
    expect(session.items.last.resolution, isNull);
    expect(session.items.last.phase, ScanItemPhase.lookupFailed);
    expect(session.items.last.error, contains('Printing lookup failed'));
  });

  for (final String action in <String>[
    'finish',
    'pause',
    'remove',
    'clear',
    'dispose',
  ]) {
    test(
      'item Retry completes independently of unrelated held work on $action',
      () async {
        final _ItemScopedRetryResolver resolver = _ItemScopedRetryResolver();
        final _BulkReplayDrafts drafts = _BulkReplayDrafts();
        final _Recognizer recognizer = _Recognizer();
        final ScanCrop target = ScanCrop(
          imagePath: 'retry.jpg',
          width: 1000,
          height: 1400,
          rectified: true,
          sourceCorners: _quad(.1, .2, .2, .4),
          lines: const <ScanTextLine>[],
        );
        final ScanCrop unrelated = ScanCrop(
          imagePath: 'unrelated.jpg',
          width: 1000,
          height: 1400,
          rectified: true,
          sourceCorners: _quad(.6, .2, .2, .4),
          lines: const <ScanTextLine>[],
        );
        final List<ScanResolution> initial = await _Resolver().resolveBatch(
          <ScanCrop>[target, unrelated],
        );
        drafts.saved['target'] = ScanDraftItem(
          id: 'target',
          photoId: 'target-photo',
          crop: target,
          resolution: initial[0],
        );
        drafts.saved['unrelated'] = ScanDraftItem(
          id: 'unrelated',
          photoId: 'unrelated-photo',
          crop: unrelated,
          resolution: initial[1],
        );
        final ScanSession session = ScanSession(
          recognizer: recognizer,
          resolver: resolver,
          store: drafts,
        );
        bool disposed = false;
        Future<void>? unrelatedRetry;
        try {
          await session.load();
          await _settle(session);
          final ScanSessionItem heldItem = session.items.singleWhere(
            (ScanSessionItem item) => item.id == 'unrelated',
          );
          final Future<void> heldRetry = session.retryItem(heldItem);
          unrelatedRetry = heldRetry;
          await _until(() => resolver.holding);
          if (action == 'finish') {
            final ScanSessionItem item = session.items.singleWhere(
              (ScanSessionItem item) => item.id == 'target',
            );
            bool completed = false;
            final Future<void> retry = session.retryItem(item).then<void>((_) {
              completed = true;
            });
            await _until(() => completed);
            await retry;
            expect(item.resolution!.candidates, hasLength(1));
            expect(item.phase, isNot(ScanItemPhase.retrying));
            expect(session.running, isTrue);
            expect(resolver.held.isCompleted, isFalse);
            expect(session.items, hasLength(2));
          } else {
            bool completed = false;
            final Future<void> trackedRetry = heldRetry.then<void>((_) {
              completed = true;
            });
            if (action == 'pause') {
              session.pause();
            } else if (action == 'remove') {
              await session.remove(heldItem);
            } else if (action == 'clear') {
              await session.clearCaptures();
            } else {
              session.dispose();
              disposed = true;
            }
            await _until(() => completed);
            await trackedRetry;
            expect(resolver.held.isCompleted, isFalse);
          }
        } finally {
          if (!resolver.held.isCompleted) {
            resolver.held.complete();
          }
          if (unrelatedRetry != null) await unrelatedRetry;
          if (!disposed) {
            await _settle(session);
            session.dispose();
          }
        }
      },
    );
  }

  for (final String outcome in <String>[
    'recover',
    'still no identity',
    'manual approval',
    'clear',
    'uncertain ownership',
  ]) {
    test(
      'saved-source identity recovery $outcome preserves physical ownership',
      () async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'collector-identity-recovery-',
        );
        Hive.init(directory.path);
        final File source = File('${directory.path}/source.jpg')
          ..writeAsBytesSync(<int>[1, 2, 3, 4]);
        final File art = File('${directory.path}/art.jpg')
          ..writeAsBytesSync(<int>[7, 8, 9]);
        final ScanCrop original = ScanCrop(
          imagePath: art.path,
          width: outcome == 'uncertain ownership' ? 1837 : 1000,
          height: outcome == 'uncertain ownership' ? 2937 : 1400,
          rectified: true,
          sourceCorners: outcome == 'uncertain ownership'
              ? const <ScanPoint>[
                  ScanPoint(.28776299953460693, .4186553955078125),
                  ScanPoint(.6068200469017029, .4066927433013916),
                  ScanPoint(.6412168741226196, .5542965531349182),
                  ScanPoint(.28422269225120544, .6170784831047058),
                ]
              : _quad(.15, .3, .3, .3),
          warnings: const <String>['incomplete_card', 'no_text'],
          lines: const <ScanTextLine>[],
        );
        final ScanCrop corrected = ScanCrop(
          imagePath: source.path,
          width: outcome == 'uncertain ownership' ? 2650 : 1000,
          height: outcome == 'uncertain ownership' ? 4096 : 1400,
          rectified: true,
          sourceCorners: outcome == 'uncertain ownership'
              ? const <ScanPoint>[
                  ScanPoint(.2501275691807172, .373655632040075),
                  ScanPoint(.6379525885069128, .3628713527335803),
                  ScanPoint(.7089326890915784, .8249382275747209),
                  ScanPoint(.2653828387694734, .8234807529074478),
                ]
              : _quad(.1, .2, .4, .6),
          warnings: outcome == 'uncertain ownership'
              ? const <String>[
                  'border_recovered',
                  'partial_card',
                  'basic_land_outline',
                  'unread_footer',
                ]
              : const <String>[],
          lines: outcome == 'uncertain ownership'
              ? const <ScanTextLine>[
                  ScanTextLine(
                    text: 'Snow-Covered Swamp',
                    confidence: 1,
                    bounds: ScanBounds(
                      .06644518362655796,
                      .040948276617609025,
                      .5714285810525318,
                      .034482757023402644,
                    ),
                  ),
                  ScanTextLine(
                    text: 'Basic Snow Land',
                    confidence: 1,
                    bounds: ScanBounds(
                      .06107828511068069,
                      .8248379270442533,
                      .3716024496440158,
                      .05130212203316063,
                    ),
                  ),
                  ScanTextLine(
                    text: '82//254',
                    confidence: .30000001192092896,
                    bounds: ScanBounds(
                      .04642166666850929,
                      .9474999999479167,
                      .15087040225292336,
                      .01875,
                    ),
                  ),
                ]
              : const <ScanTextLine>[
                  ScanTextLine(
                    text: 'Snow-Covered Swamp',
                    confidence: .99,
                    bounds: ScanBounds(.1, .04, .7, .03),
                  ),
                  ScanTextLine(
                    text: 'Basic Snow Land',
                    confidence: .99,
                    bounds: ScanBounds(.1, .78, .7, .03),
                  ),
                  ScanTextLine(
                    text: '252',
                    confidence: .99,
                    bounds: ScanBounds(.05, .88, .2, .03),
                  ),
                  ScanTextLine(
                    text: 'MH1 EN',
                    confidence: .99,
                    bounds: ScanBounds(.05, .93, .3, .03),
                  ),
                ],
        );
        final Map<String, Object?> printingData = jsonDecode(
          File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
        ) as Map<String, Object?>;
        if (outcome == 'uncertain ownership') {
          printingData
            ..['name'] = 'Snow-Covered Swamp'
            ..['set'] = 'mh1'
            ..['collector_number'] = '252';
        }
        final MtgCard printing = MtgCard.fromJson(printingData);
        final _RecoveryRecognizer recognizer = _RecoveryRecognizer(
          original,
          outcome == 'still no identity' ? original : corrected,
        );
        final ScanDraftStore drafts = ScanDraftStore(userId: 'recovery');
        final ScanSession session = ScanSession(
          recognizer: recognizer,
          resolver: _RecoveryResolver(printing),
          store: drafts,
        );
        final Set<ScanItemPhase> phases = <ScanItemPhase>{};
        session.addListener(() {
          if (session.items.isNotEmpty) phases.add(session.items.first.phase);
        });
        try {
          await session.load();
          await session.addFocusStack(
            <String>[source.path],
            captureId: 'physical-card',
            targetRegions: <List<ScanPoint>>[
              outcome == 'uncertain ownership'
                  ? const <ScanPoint>[
                      ScanPoint(.24428825080394745, .38708001375198364),
                      ScanPoint(.636904239654541, .38155651092529297),
                      ScanPoint(.6778724193572998, .5804845690727234),
                      ScanPoint(.2472800314426422, .7712423354387283),
                    ]
                  : original.sourceCorners,
            ],
            excludedRegions: outcome == 'uncertain ownership'
                ? const <List<ScanPoint>>[
                    <ScanPoint>[
                      ScanPoint(.24814288318157196, .43391478061676025),
                      ScanPoint(.5671161413192749, .4308413863182068),
                      ScanPoint(.5834730863571167, .580015629529953),
                      ScanPoint(.2396721988916397, .609197735786438),
                    ],
                    <ScanPoint>[
                      ScanPoint(.3347474932670593, .17556136846542358),
                      ScanPoint(.46776875853538513, .15561509132385254),
                      ScanPoint(.5197556018829346, .3986508250236511),
                      ScanPoint(.3227357864379883, .3480387330055237),
                    ],
                  ]
                : const <List<ScanPoint>>[],
          );
          await recognizer.retryStarted.future.timeout(
            const Duration(seconds: 3),
          );
          final ScanSessionItem item = session.items.single;
          final String id = item.id;
          expect(item.phase, ScanItemPhase.retrying);
          expect(session.pendingPhotoCaptures, 1);
          expect(recognizer.paths, hasLength(2));
          expect(
            recognizer.paths.last,
            (await drafts.readSource(item.photoId))!.imagePath,
          );
          expect(File(recognizer.paths.last).readAsBytesSync(), <int>[
            1,
            2,
            3,
            4,
          ]);
          expect(File(item.crop.imagePath).readAsBytesSync(), <int>[7, 8, 9]);
          if (outcome == 'manual approval') {
            item
              ..approval = ScanQueueApproval(
                operationId: id,
                card: cardFromScryfall(
                  printing,
                  finish: printing.finishes.first,
                ),
                quantity: 7,
                deckId: 'binder',
              )
              ..manuallyReviewed = true;
            await session.persist(<ScanSessionItem>[item]);
          } else if (outcome == 'clear') {
            await session.clearCaptures();
            expect(session.items, isEmpty);
            expect(session.pendingPhotoCaptures, 0);
          }
          recognizer.releaseRetry.complete();
          await _until(
            () => !session.running && session.pendingPhotoCaptures == 0,
          );
          expect(recognizer.paths, hasLength(2));
          expect(await drafts.readRecoveries(), isEmpty);
          if (outcome == 'clear') {
            expect(session.items, isEmpty);
            expect(await drafts.readItems(), isEmpty);
          } else {
            expect(session.items.single.id, id);
            expect((await drafts.readItems()).single.id, id);
            if (outcome == 'manual approval') {
              expect(item.phase, ScanItemPhase.ready);
              expect(item.approval!.quantity, 7);
              expect(item.approval!.deckId, 'binder');
              expect(item.crop.lines, isEmpty);
            } else if (outcome == 'still no identity') {
              expect(item.phase, ScanItemPhase.noIdentity);
              await session.retryUnresolved();
              expect(recognizer.paths, hasLength(3));
              expect(session.items.single.id, id);
              expect(item.phase, ScanItemPhase.noIdentity);
            } else {
              expect(item.resolution!.candidates, hasLength(1));
              expect(item.crop.sourceCorners, corrected.sourceCorners);
              if (outcome == 'uncertain ownership') {
                expect(
                  item.crop.warnings,
                  contains('capture_ownership_uncertain'),
                );
                expect(item.phase, ScanItemPhase.needsReview);
                expect(
                  hasExactPrintingEvidence(corrected, item.resolution),
                  isFalse,
                );
                expect(
                  hasVerifiedSavedBasicLandCapturePresence(corrected),
                  isTrue,
                );
                expect(
                  hasVerifiedSavedBasicLandCapturePresence(item.crop),
                  isFalse,
                );
                expect(item.crop.lines.last.text, '82//254');
                expect(item.crop.lines.last.confidence, .30000001192092896);
                expect(
                  hasExactPrintingEvidence(item.crop, item.resolution),
                  isFalse,
                );
                expect(session.items, hasLength(1));
              }
              expect(
                phases,
                containsAll(<ScanItemPhase>[
                  ScanItemPhase.processing,
                  ScanItemPhase.retrying,
                ]),
              );
            }
          }
        } finally {
          if (!recognizer.releaseRetry.isCompleted) {
            recognizer.releaseRetry.complete();
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
          session.dispose();
          await Hive.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }
  test('recovery photos refine a canonical pending receipt across restart without another quantity', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-owned-recovery-',
    );
    Hive.init(directory.path);
    final ScanDraftStore drafts = ScanDraftStore(userId: 'owned-recovery');
    final ScanCrop crop = _positionedCrop(_quad(.1, .2, .2, .4));
    final LiveCardDetection detection = LiveCardDetection(
      confidence: 1,
      corners: crop.sourceCorners,
      lines: crop.lines,
    );
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _UnresolvedLiveResolver(),
      retireIdentified: true,
    );
    final ScanSession first = ScanSession(
      recognizer: _Recognizer(),
      resolver: _Resolver(),
      store: drafts,
    )..paused = true;
    ScanSession? reopened;
    bool firstDisposed = false;
    try {
      tracker.update(
        <LiveCardDetection>[detection],
        currentGeometry: <List<ScanPoint>>[crop.sourceCorners],
      );
      tracker.update(
        <LiveCardDetection>[detection],
        currentGeometry: <List<ScanPoint>>[crop.sourceCorners],
      );
      final int token = tracker.beginCapture();
      final LiveCaptureSnapshot original = tracker.snapshotCapture();
      expect(tracker.markCaptured(original), 1);
      tracker.endCapture(token, resumeTracking: true);
      expect(
        await tracker.retainCapturedObservations(
          original,
          retain: first.adoptLiveObservations,
        ),
        isTrue,
      );
      final String itemId = first.items.single.id;
      final String receiptId = first.items.single.liveCaptureReceiptId!;
      final List<LiveScanTrack> rearmed = tracker.rearmMissingCaptured(
        original,
        const <ScanCrop>[],
      );
      expect(rearmed, hasLength(1));
      expect(rearmed.single.hasRetainedCapture, isTrue);
      final int recoveryToken = tracker.beginCapture();
      final LiveCaptureSnapshot recovery = tracker.snapshotCapture(
        targetIds: <String>{rearmed.single.id},
      );
      expect(recovery.captureId, isNot(original.captureId));
      expect(tracker.markCaptured(recovery), 1);
      tracker.endCapture(recoveryToken, resumeTracking: true);
      expect(
        await tracker.retainCapturedObservations(
          recovery,
          retain: first.adoptLiveObservations,
        ),
        isTrue,
      );
      expect(recovery.retainedObservations.single.isRefinement, isTrue);
      expect(recovery.retainedObservations.single.receiptId, receiptId);
      expect(
        recovery.retainedObservations.single.photoCaptureId,
        recovery.captureId,
      );
      expect(first.items.single.id, itemId);
      final File photo = await File('${directory.path}/recovery.jpg')
          .writeAsBytes(<int>[1, 2, 3]);
      expect(
        await first.addFocusStack(
          <String>[photo.path],
          captureId: recovery.captureId,
          diagnosticOnly: true,
          targetRegions: <List<ScanPoint>>[crop.sourceCorners],
        ),
        isTrue,
      );
      final ScanDraftPhoto pending = (await drafts.readPhotos()).single;
      expect(pending.refinementReceiptIds, <String>[receiptId]);
      first.dispose();
      firstDisposed = true;
      final MtgCard printing = MtgCard.fromJson(
        jsonDecode(
          File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
        ) as Map<String, Object?>,
      );
      final _Recognizer reader = _Recognizer()
        ..resultCrops = <ScanCrop>[
          _positionedCrop(crop.sourceCorners, path: photo.path),
        ];
      reopened = ScanSession(
        recognizer: reader,
        resolver: _Resolver(printing: printing),
        store: drafts,
      );
      await reopened.load();
      await _settle(reopened);
      expect(reopened.items, hasLength(1));
      expect(reopened.items.single.id, itemId);
      expect(reopened.items.single.liveCaptureReceiptId, receiptId);
      expect(reopened.items.single.crop.imagePath, isNotEmpty);
      expect((await drafts.readItems()).single.id, itemId);
      expect(await drafts.readPhotos(), isEmpty);
      // Deleted canonical receipts cannot be recreated by replaying the old recovery token.
      await reopened.remove(reopened.items.single);
      expect(
        await reopened.adoptLiveObservations(recovery.retainedObservations),
        isFalse,
      );
      expect(reopened.items, isEmpty);
    } finally {
      tracker.dispose();
      if (!firstDisposed) first.dispose();
      reopened?.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });

  test('released failed-shutter recovery reservations do not exhaust a long session', () async {
    final _Drafts drafts = _Drafts();
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: drafts,
    )..paused = true;
    addTearDown(session.dispose);
    final ScanCrop crop = _positionedCrop(_quad(.1, .2, .2, .4));
    final LiveCardDetection detection = LiveCardDetection(
      confidence: 1,
      corners: crop.sourceCorners,
      lines: crop.lines,
    );
    for (int index = 0; index < 34; index++) {
      final LiveScanTracker tracker = LiveScanTracker(
        resolver: _UnresolvedLiveResolver(),
        retireIdentified: true,
      );
      try {
        tracker.update(<LiveCardDetection>[detection]);
        tracker.update(<LiveCardDetection>[detection]);
        final LiveCaptureSnapshot original = tracker.snapshotCapture();
        expect(tracker.markCaptured(original), 1);
        expect(
          await tracker.retainCapturedObservations(
            original,
            retain: session.adoptLiveObservations,
          ),
          isTrue,
        );
        final LiveScanTrack target = tracker
            .rearmMissingCaptured(original, const <ScanCrop>[])
            .single;
        final LiveCaptureSnapshot recovery = tracker.snapshotCapture(
          targetIds: <String>{target.id},
        );
        expect(tracker.markCaptured(recovery), 1);
        expect(
          await tracker.retainCapturedObservations(
            recovery,
            retain: session.adoptLiveObservations,
          ),
          isTrue,
        );
        session.releaseLivePhotoReservation(recovery);
        session.releaseLivePhotoReservation(recovery);
        expect(session.items, hasLength(index + 1));
      } finally {
        tracker.dispose();
      }
    }
    expect(drafts.saved, hasLength(34));
    expect(drafts.photos, isEmpty);
  });

  test('more than 32 restored pending refinement photos retain every canonical card', () async {
    final _Drafts drafts = _Drafts();
    final ScanCrop crop = _positionedCrop(_quad(.1, .2, .2, .4));
    for (int index = 0; index < 33; index++) {
      final String receipt = 'live_original${index}_card1';
      drafts.saved[receipt] = ScanDraftItem(
        id: receipt,
        photoId: 'original${index}_0',
        crop: crop,
        liveCaptureReceiptId: receipt,
      );
      final String photoId = 'recovery${index}_0';
      drafts.photos[photoId] = ScanDraftPhoto(
        id: photoId,
        imagePath: '/tmp/recovery-$index.jpg',
        multipleCards: false,
        createdAt: DateTime.utc(2026),
        refinementReceiptIds: <String>[receipt],
      );
    }
    final Set<String> ids = drafts.saved.keys.toSet();
    final _Recognizer reader = _Recognizer()
      ..resultCrops = <ScanCrop>[
        _positionedCrop(crop.sourceCorners, path: '/tmp/refined.jpg'),
      ];
    final ScanSession session = ScanSession(
      recognizer: reader,
      resolver: _EmptyResolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    await session.load();
    await _settle(session);
    expect(session.photosRead, 33);
    expect(session.items.map((ScanSessionItem item) => item.id).toSet(), ids);
    expect(
      session.items.every(
        (ScanSessionItem item) => item.crop.imagePath.isNotEmpty,
      ),
      isTrue,
    );
    expect(drafts.saved.keys.toSet(), ids);
    expect(drafts.photos, isEmpty);
  });

  test('admitted observations persist every unresolved same-name card before lookup or optional photo', () async {
    final List<LiveCaptureObservation> observations =
        await _admittedObservations(<ScanCrop>[
          _positionedCrop(_quad(.1, .2, .2, .4)),
          _positionedCrop(_quad(.6, .2, .2, .4)),
        ]);
    final _Drafts drafts = _Drafts();
    final _DelayedResolver resolver = _DelayedResolver();
    final _Recognizer recognizer = _Recognizer();
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: resolver,
      store: drafts,
    );
    addTearDown(session.dispose);
    await session.load();
    expect(
      await session.adoptLiveObservations(
        observations,
        defaults: const ScanCaptureDefaults(
          finish: Finish.foil,
          deckId: 'binder',
        ),
      ),
      isTrue,
    );
    expect(session.items, hasLength(2));
    expect(drafts.saved, hasLength(2));
    expect(drafts.photos, isEmpty);
    expect(recognizer.calls, 0);
    expect(
      session.items.map((ScanSessionItem item) => item.resolution),
      everyElement(isNull),
    );
    expect(
      session.items.map((ScanSessionItem item) => item.liveIdentityName),
      everyElement(isNull),
    );
    expect(
      session.items.map((ScanSessionItem item) => item.approval),
      everyElement(isNull),
    );
    expect(
      session.items.map((ScanSessionItem item) => item.id).toSet(),
      hasLength(2),
    );
    final Set<String> ids = session.items
        .map((ScanSessionItem item) => item.id)
        .toSet();
    expect(await session.adoptLiveObservations(observations), isTrue);
    expect(session.items.map((ScanSessionItem item) => item.id).toSet(), ids);
    expect(
      session.items.map((ScanSessionItem item) => item.defaults.deckId),
      everyElement('binder'),
    );
    expect(
      drafts.saved.values.map((ScanDraftItem item) => item.defaults.finish),
      everyElement(Finish.foil),
    );
    resolver.pending.complete();
    await _settle(session);
    expect(
      session.items.map((ScanSessionItem item) => item.printing?.name),
      everyElement('Lightning Bolt'),
    );
    expect(
      session.items.map((ScanSessionItem item) => item.selected),
      everyElement(isFalse),
    );
  });

  test('observation storage failure retries stable IDs and discarded observations cannot reappear', () async {
    final List<LiveCaptureObservation> observations =
        await _admittedObservations(<ScanCrop>[
          _positionedCrop(_quad(.1, .2, .2, .4)),
        ]);
    final _ToggleLiveDrafts drafts = _ToggleLiveDrafts()..failWrites = true;
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: drafts,
    )..pause();
    addTearDown(session.dispose);
    expect(await session.adoptLiveObservations(observations), isFalse);
    expect(session.items, isEmpty);
    expect(session.liveStorageFailed, isTrue);
    expect(session.storageError, isNotNull);
    drafts.failWrites = false;
    expect(await session.adoptLiveObservations(observations), isTrue);
    final ScanSessionItem item = session.items.single;
    expect(
      item.id,
      'live_${observations.single.captureId}_${observations.single.id}',
    );
    expect(session.liveStorageFailed, isFalse);
    expect(session.storageError, isNull);
    await session.remove(item);
    expect(await session.adoptLiveObservations(observations), isFalse);
    expect(session.items, isEmpty);
    expect(drafts.saved, isEmpty);
  });

  test('unresolved observation survives restart and diagnostic photo merges into its existing quantity', () async {
    final ScanCrop crop = _positionedCrop(_quad(.1, .2, .2, .4));
    final List<LiveCaptureObservation> observations =
        await _admittedObservations(<ScanCrop>[crop]);
    final String captureId = observations.single.captureId;
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-unresolved-observation-',
    );
    Hive.init(directory.path);
    final ScanDraftStore store = ScanDraftStore(
      userId: 'unresolved-observation',
    );
    final ScanSession first = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: store,
    )..pause();
    expect(await first.adoptLiveObservations(observations), isTrue);
    final String id = first.items.single.id;
    expect((await store.readItems()).single.resolution, isNull);
    first.dispose();
    await Hive.close();
    Hive.init(directory.path);
    final ScanDraftStore reopenedStore = ScanDraftStore(
      userId: 'unresolved-observation',
    );
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[crop];
    final ScanSession reopened = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
      store: reopenedStore,
    )..pause();
    try {
      await reopened.load();
      expect(reopened.items.single.id, id);
      expect(reopened.items.single.liveCaptureReceiptId, id);
      expect(reopened.items.single.resolution, isNull);
      final File photo = await File('${directory.path}/optional.jpg')
          .writeAsBytes(<int>[1, 2, 3]);
      expect(
        await reopened.addFocusStack(
          <String>[photo.path],
          captureId: captureId,
          diagnosticOnly: true,
          targetRegions: <List<ScanPoint>>[crop.sourceCorners],
        ),
        isTrue,
      );
      reopened.resume();
      await _settle(reopened);
      expect(recognizer.calls, 2);
      expect(reopened.items, hasLength(1));
      expect(reopened.items.single.id, id);
      expect((await reopenedStore.readItems()).single.liveCaptureReceiptId, id);
      await reopened.remove(reopened.items.single);
      expect(await reopened.adoptLiveObservations(observations), isFalse);
      expect(reopened.items, isEmpty);
    } finally {
      reopened.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });

  test('observation retention preserves an existing manual review and its quantity', () async {
    final ScanCrop crop = _positionedCrop(_quad(.1, .2, .2, .4));
    final List<LiveCaptureObservation> observations =
        await _admittedObservations(<ScanCrop>[crop]);
    final MtgCard card = MtgCard.fromJson(
      jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<String, Object?>,
    );
    final _Drafts drafts = _Drafts();
    drafts.saved['reviewed'] = ScanDraftItem(
      id: 'reviewed',
      photoId: '${observations.single.captureId}_0',
      crop: crop,
      approval: ScanQueueApproval(
        operationId: 'reviewed',
        card: cardFromScryfall(card, finish: card.finishes.first),
        quantity: 4,
        deckId: 'binder',
      ),
      selected: true,
    );
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: drafts,
    )..pause();
    addTearDown(session.dispose);
    await session.load();
    expect(await session.adoptLiveObservations(observations), isTrue);
    expect(session.items, hasLength(1));
    expect(session.items.single.id, 'reviewed');
    expect(session.items.single.approval!.quantity, 4);
    expect(session.items.single.approval!.deckId, 'binder');
    expect(session.items.single.selected, isTrue);
    expect(drafts.saved.values.single.approval!.quantity, 4);
  });

  test('metadata retry clears only the successfully recovered receipt storage error', () async {
    final _ToggleLiveDrafts drafts = _ToggleLiveDrafts()..failWrites = true;
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _Resolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    final ({String id, ScanCrop crop, ScanResolution resolution}) first =
        _liveReceipt(_positionedCrop(_quad(.1, .2, .2, .4)));
    final ({String id, ScanCrop crop, ScanResolution resolution}) second = (
      id: 'card2',
      crop: _positionedCrop(_quad(.6, .2, .2, .4)),
      resolution: first.resolution,
    );
    expect(
      await session.adoptLiveCapture(
        'retry_cards',
        <({String id, ScanCrop crop, ScanResolution resolution})>[first],
      ),
      isFalse,
    );
    expect(
      await session.adoptLiveCapture(
        'retry_cards',
        <({String id, ScanCrop crop, ScanResolution resolution})>[second],
      ),
      isFalse,
    );
    expect(session.liveStorageFailed, isTrue);
    expect(session.storageError, isNotNull);
    drafts.failWrites = false;
    expect(
      await session.adoptLiveCapture(
        'retry_cards',
        <({String id, ScanCrop crop, ScanResolution resolution})>[first],
      ),
      isTrue,
    );
    expect(session.liveStorageFailed, isTrue);
    expect(session.storageError, isNotNull);
    expect(
      await session.adoptLiveCapture(
        'retry_cards',
        <({String id, ScanCrop crop, ScanResolution resolution})>[second],
      ),
      isTrue,
    );
    expect(session.liveStorageFailed, isFalse);
    expect(session.storageError, isNull);
    expect(session.items, hasLength(2));
    expect(
      await session.adoptLiveCapture(
        'retry_cards',
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          first,
          second,
        ],
      ),
      isTrue,
    );
    expect(session.items, hasLength(2));
  });

  test(
    'metadata retry never clears an unrelated source storage error',
    () async {
      final _ToggleLiveDrafts drafts = _ToggleLiveDrafts()..failWrites = true;
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(),
        resolver: _Resolver(),
        store: drafts,
      )..storageError = 'Could not save selected photos.';
      addTearDown(session.dispose);
      final ({String id, ScanCrop crop, ScanResolution resolution}) receipt =
          _liveReceipt(_positionedCrop(_quad(.1, .2, .2, .4)));
      expect(
        await session.adoptLiveCapture(
          'retry_cards',
          <({String id, ScanCrop crop, ScanResolution resolution})>[receipt],
        ),
        isFalse,
      );
      drafts.failWrites = false;
      expect(
        await session.adoptLiveCapture(
          'retry_cards',
          <({String id, ScanCrop crop, ScanResolution resolution})>[receipt],
        ),
        isTrue,
      );
      expect(session.liveStorageFailed, isFalse);
      expect(session.storageError, 'Could not save selected photos.');
    },
  );

  test('photo-free historical live receipt retains complete proof through session clipping', () async {
    final ScanCrop crop = liveHistoricalScene();
    final ScanResolution resolution = await resolveHistoricalScene(crop);
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _Resolver(),
    );
    addTearDown(session.dispose);
    expect(
      await session.adoptLiveCapture(
        'historical_capture',
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          (id: 'card1', crop: crop, resolution: resolution),
        ],
      ),
      isTrue,
    );
    expect(session.items, hasLength(1));
    expect(session.items.single.liveIdentityName, 'circle of protection: blue');
    expect(session.items.single.crop.imagePath, isEmpty);
    expect(
      session.items.single.resolution!.status,
      ScanResolutionStatus.needsReview,
    );
    expect(
      verifiedLiveHistoricalBodyIdentity(
        session.items.single.crop,
        session.items.single.resolution!,
      ),
      'Circle of Protection: Blue',
    );
    expect(
      await session.adoptLiveCapture(
        'historical_capture',
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          (id: 'card1', crop: crop, resolution: resolution),
        ],
      ),
      isTrue,
    );
    expect(session.items, hasLength(1));
  });

  test('photo-free historical session admission rejects missing and stale identity proof', () async {
    final ScanCrop crop = liveHistoricalScene();
    final ScanResolution valid = await resolveHistoricalScene(crop);
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _Resolver(),
    );
    addTearDown(session.dispose);
    final ScanResolution missing = ScanResolution(
      candidates: valid.candidates,
      hints: valid.hints,
      status: valid.status,
    );
    expect(
      await session.adoptLiveCapture(
        'historical_capture',
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          (id: 'card1', crop: crop, resolution: missing),
        ],
      ),
      isFalse,
    );
    final ScanCrop stale = ScanCrop(
      imagePath: '',
      width: crop.width,
      height: crop.height,
      rectified: false,
      sourceCorners: crop.sourceCorners,
      warnings: crop.warnings,
      lines: crop.lines
          .where((ScanTextLine line) => !line.text.contains('Pete'))
          .toList(),
    );
    expect(
      await session.adoptLiveCapture(
        'historical_capture',
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          (id: 'card1', crop: stale, resolution: valid),
        ],
      ),
      isFalse,
    );
    expect(session.items, isEmpty);
  });

  test('live identity is durable without a photo read and adoption replay cannot add quantity', () async {
    final _Drafts drafts = _Drafts();
    final _Recognizer recognizer = _Recognizer();
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    final ScanCrop live = _positionedCrop(_quad(.1, .2, .2, .4));
    final ({String id, ScanCrop crop, ScanResolution resolution}) receipt =
        _liveReceipt(live);
    expect(
      await session.adoptLiveIdentities(
        <String>['camera.jpg'],
        <({String id, ScanCrop crop, ScanResolution resolution})>[receipt],
      ),
      isTrue,
    );
    expect(
      await session.adoptLiveIdentities(
        <String>['camera.jpg'],
        <({String id, ScanCrop crop, ScanResolution resolution})>[receipt],
      ),
      isTrue,
    );
    expect(recognizer.calls, 0);
    expect(session.items, hasLength(1));
    expect(drafts.saved, hasLength(1));
    expect(drafts.saved.values.single.crop.imagePath, isEmpty);
    expect(
      session.capturedItems(<String>['camera.jpg']).single.printing!.name,
      'Lightning Bolt',
    );
    expect(
      session.items.single.resolution!.status,
      ScanResolutionStatus.needsReview,
    );
  });

  test('optional same-capture photos merge quantities and cannot erase live identity with no match or a different name', () async {
    for (final ScanResolver resolver in <ScanResolver>[
      _EmptyResolver(),
      _WrongPhotoResolver(),
    ]) {
      final _Drafts drafts = _Drafts();
      final ScanCrop live = _positionedCrop(_quad(.1, .2, .2, .4));
      final _Recognizer recognizer = _Recognizer()
        ..resultCrops = <ScanCrop>[live];
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: resolver,
        store: drafts,
      )..pause();
      await session.addPhotos(
        <String>['camera.jpg'],
        multipleCards: true,
        ownedCameraSource: true,
      );
      expect(
        await session.adoptLiveIdentities(
          <String>['camera.jpg'],
          <({String id, ScanCrop crop, ScanResolution resolution})>[
            _liveReceipt(live),
          ],
        ),
        isTrue,
      );
      session.resume();
      await _settle(session);
      expect(session.items, hasLength(1));
      expect(drafts.saved, hasLength(1));
      expect(session.items.single.printing!.name, 'Lightning Bolt');
      expect(session.items.single.error, isNull);
      session.dispose();
    }
  });

  test('live adoption after weaker saved lookup replaces the same physical draft without a duplicate', () async {
    final _Drafts drafts = _Drafts();
    final ScanCrop live = _positionedCrop(_quad(.1, .2, .2, .4));
    final ScanSession session = ScanSession(
      recognizer: _Recognizer()..resultCrops = <ScanCrop>[live],
      resolver: _EmptyResolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    await session.addPhotos(
      <String>['camera.jpg'],
      multipleCards: false,
      ownedCameraSource: true,
    );
    await _settle(session);
    expect(
      session.items.single.resolution!.status,
      ScanResolutionStatus.noMatch,
    );
    expect(
      await session.adoptLiveIdentities(
        <String>['camera.jpg'],
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          _liveReceipt(live),
        ],
      ),
      isTrue,
    );
    expect(session.items, hasLength(1));
    expect(drafts.saved, hasLength(1));
    expect(session.items.single.printing!.name, 'Lightning Bolt');
  });

  test('live adoption preserves manual decisions and independently counts adjacent copies', () async {
    final _Drafts drafts = _Drafts();
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    final ScanCrop first = _positionedCrop(_quad(.1, .2, .2, .4));
    final ScanCrop second = _positionedCrop(_quad(.6, .2, .2, .4));
    final List<({String id, ScanCrop crop, ScanResolution resolution})>
    receipts = <({String id, ScanCrop crop, ScanResolution resolution})>[
      _liveReceipt(first),
      _liveReceipt(second, id: 'card-2'),
    ];
    expect(
      await session.adoptLiveIdentities(<String>['camera.jpg'], receipts),
      isTrue,
    );
    final ScanSessionItem reviewed = session.items.first;
    reviewed.manuallyReviewed = true;
    reviewed.selected = true;
    final ScanResolution manual = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_OtherPrinting(), <ScanEvidence>{}),
      ],
      hints: ScanHints.fromCrop(first),
      status: ScanResolutionStatus.needsReview,
    );
    reviewed.resolution = manual;
    await session.persist(<ScanSessionItem>[reviewed]);
    expect(
      await session.adoptLiveIdentities(<String>['camera.jpg'], receipts),
      isTrue,
    );
    expect(session.items, hasLength(2));
    expect(identical(reviewed.resolution, manual), isTrue);
    expect(reviewed.selected, isTrue);
  });

  test('removed, disposed, invalid and storage-failed live receipts cannot be reintroduced', () async {
    final ScanCrop live = _positionedCrop(_quad(.1, .2, .2, .4));
    final List<({String id, ScanCrop crop, ScanResolution resolution})>
    receipts = <({String id, ScanCrop crop, ScanResolution resolution})>[
      _liveReceipt(live),
    ];
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: _Drafts(),
    );
    expect(
      await session.adoptLiveIdentities(<String>['camera.jpg'], receipts),
      isTrue,
    );
    await session.remove(session.items.single);
    expect(
      await session.adoptLiveIdentities(<String>['camera.jpg'], receipts),
      isFalse,
    );
    expect(session.items, isEmpty);
    session.dispose();
    expect(
      await session.adoptLiveIdentities(<String>['camera.jpg'], receipts),
      isFalse,
    );
    final ScanSession failed = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: _FailedLiveDrafts(),
    );
    addTearDown(failed.dispose);
    expect(
      await failed.adoptLiveIdentities(<String>['camera.jpg'], receipts),
      isFalse,
    );
    expect(failed.items, isEmpty);
    expect(failed.storageError, isNotNull);
    expect(
      await failed.adoptLiveIdentities(
        <String>['camera.jpg'],
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          _liveReceipt(_crop),
        ],
      ),
      isFalse,
    );
  });

  test('empty-image live identity survives an actual Hive restart with its printing candidates', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-live-durable-',
    );
    Hive.init(directory.path);
    final MtgCard card = MtgCard.fromJson(
      jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<String, Object?>,
    );
    final ScanDraftStore store = ScanDraftStore(userId: 'live-durable');
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: store,
    );
    final ScanCrop live = _positionedCrop(_quad(.1, .2, .2, .4));
    expect(
      await session.adoptLiveIdentities(
        <String>['camera.jpg'],
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          _liveReceipt(live, card: card),
        ],
      ),
      isTrue,
    );
    session.dispose();
    await Hive.close();
    Hive.init(directory.path);
    final ScanSession reopened = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: ScanDraftStore(userId: 'live-durable'),
    );
    try {
      await reopened.load();
      expect(reopened.items, hasLength(1));
      expect(reopened.items.single.crop.imagePath, isEmpty);
      expect(reopened.items.single.printing!.id, card.id);
      expect(
        reopened.items.single.resolution!.status,
        ScanResolutionStatus.needsReview,
      );
      expect(reopened.capturedItems(<String>['camera.jpg']), hasLength(1));
    } finally {
      reopened.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });

  test('live metadata accepts owned unrectified capture evidence but rejects competing names and receipt overflow', () async {
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
    );
    addTearDown(session.dispose);
    final ScanCrop live = ScanCrop(
      imagePath: '',
      width: 1000,
      height: 1400,
      rectified: false,
      sourceCorners: _quad(.1, .2, .2, .4),
      lines: _crop.lines,
      warnings: const <String>['partial_card'],
    );
    expect(
      await session.adoptLiveIdentities(
        <String>['camera.jpg'],
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          _liveReceipt(live),
        ],
      ),
      isTrue,
    );
    final ScanResolution competing = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_Printing(), <ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.footerMatch,
        }),
        ScanCandidate(_OtherPrinting(), <ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.typeLineMatch,
        }),
      ],
      hints: ScanHints.fromCrop(live),
      status: ScanResolutionStatus.needsReview,
    );
    expect(
      await session.adoptLiveIdentities(
        <String>['other.jpg'],
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          (id: 'card-2', crop: live, resolution: competing),
        ],
      ),
      isFalse,
    );
    expect(
      await session.adoptLiveIdentities(
        <String>['other.jpg'],
        List<({String id, ScanCrop crop, ScanResolution resolution})>.generate(
          9,
          (int index) => _liveReceipt(live, id: 'card-$index'),
        ),
      ),
      isFalse,
    );
    expect(session.items, hasLength(1));
  });

  test('broad ambiguous and duplicate optional crops do not create new quantities for two owned live cards', () async {
    final ScanCrop first = _positionedCrop(_quad(.1, .2, .2, .4));
    final ScanCrop second = _positionedCrop(_quad(.6, .2, .2, .4));
    final ScanCrop broad = _positionedCrop(_quad(.05, .1, .85, .6));
    final _Drafts drafts = _Drafts();
    final ScanSession session = ScanSession(
      recognizer: _Recognizer()
        ..resultCrops = <ScanCrop>[broad, first, first, second],
      resolver: _EmptyResolver(),
      store: drafts,
    )..pause();
    addTearDown(session.dispose);
    await session.addPhotos(
      <String>['camera.jpg'],
      multipleCards: true,
      ownedCameraSource: true,
    );
    expect(
      await session.adoptLiveIdentities(
        <String>['camera.jpg'],
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          _liveReceipt(first),
          _liveReceipt(second, id: 'card-2'),
        ],
      ),
      isTrue,
    );
    session.resume();
    await _settle(session);
    expect(session.items, hasLength(2));
    expect(drafts.saved, hasLength(2));
    expect(
      session.items.every(
        (ScanSessionItem item) => item.liveIdentityName == 'lightning bolt',
      ),
      isTrue,
    );
  });

  test('failed live refinement of a preexisting photo keeps its stable durable ID and never leaves a second record', () async {
    final _ToggleLiveDrafts drafts = _ToggleLiveDrafts();
    final ScanCrop live = _positionedCrop(_quad(.1, .2, .2, .4));
    final ScanSession session = ScanSession(
      recognizer: _Recognizer()..resultCrops = <ScanCrop>[live],
      resolver: _EmptyResolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    await session.addPhotos(
      <String>['camera.jpg'],
      multipleCards: false,
      ownedCameraSource: true,
    );
    await _settle(session);
    final String original = session.items.single.id;
    drafts.failWrites = true;
    expect(
      await session.adoptLiveIdentities(
        <String>['camera.jpg'],
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          _liveReceipt(live),
        ],
      ),
      isFalse,
    );
    expect(drafts.saved.keys, <String>[original]);
    expect(session.items.single.id, original);
    drafts.failWrites = false;
    expect(
      await session.adoptLiveIdentities(
        <String>['camera.jpg'],
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          _liveReceipt(live),
        ],
      ),
      isTrue,
    );
    expect(drafts.saved.keys, <String>[original]);
    expect(session.items.single.liveIdentityName, 'lightning bolt');
  });

  test('pending optional photo replay after Hive restart merges into its already durable live quantity', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-live-replay-',
    );
    Hive.init(directory.path);
    final File photo = await File('${directory.path}/camera.jpg')
        .writeAsBytes(<int>[1, 2, 3]);
    final MtgCard card = MtgCard.fromJson(
      jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<String, Object?>,
    );
    final ScanCrop live = _positionedCrop(_quad(.1, .2, .2, .4));
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: ScanDraftStore(userId: 'live-replay'),
    )..pause();
    await session.addPhotos(
      <String>[photo.path],
      multipleCards: false,
      ownedCameraSource: true,
    );
    expect(
      await session.adoptLiveIdentities(
        <String>[photo.path],
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          _liveReceipt(live, card: card),
        ],
      ),
      isTrue,
    );
    final String id = session.items.single.id;
    session.dispose();
    await Hive.close();
    Hive.init(directory.path);
    final ScanDraftStore reopenedStore = ScanDraftStore(userId: 'live-replay');
    final ScanSession reopened = ScanSession(
      recognizer: _Recognizer()..resultCrops = <ScanCrop>[live],
      resolver: _EmptyResolver(),
      store: reopenedStore,
    );
    try {
      await reopened.load();
      await _settle(reopened);
      expect(reopened.items, hasLength(1));
      expect((await reopenedStore.readItems()).single.id, id);
      expect(reopened.items.single.printing!.id, card.id);
      expect(reopened.items.single.liveIdentityName, card.name.toLowerCase());
    } finally {
      reopened.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });

  test('late live adoption privately finds its admitted earlier photo without changing public latest-camera ownership', () async {
    final _Drafts drafts = _Drafts();
    final ScanCrop live = _positionedCrop(_quad(.1, .2, .2, .4));
    final ScanSession session = ScanSession(
      recognizer: _Recognizer()..resultCrops = <ScanCrop>[live],
      resolver: _EmptyResolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    await session.addPhotos(
      <String>['first.jpg'],
      multipleCards: false,
      ownedCameraSource: true,
    );
    await _settle(session);
    final String firstId = session.items.single.id;
    await session.addPhotos(
      <String>['second.jpg'],
      multipleCards: false,
      ownedCameraSource: true,
    );
    await _settle(session);
    expect(session.capturedItems(<String>['first.jpg']), isEmpty);
    expect(
      await session.adoptLiveIdentities(
        <String>['first.jpg'],
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          _liveReceipt(live),
        ],
      ),
      isTrue,
    );
    expect(session.items, hasLength(2));
    expect(drafts.saved, hasLength(2));
    expect(
      session.items
          .singleWhere((ScanSessionItem item) => item.id == firstId)
          .liveIdentityName,
      'lightning bolt',
    );
    expect(session.capturedItems(<String>['first.jpg']), isEmpty);
  });

  test('standalone live capture persists without importing or reading a photograph', () async {
    const String captureId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final _Drafts drafts = _Drafts();
    final _Recognizer recognizer = _Recognizer();
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    final ScanCrop live = _positionedCrop(_quad(.1, .2, .2, .4));
    final List<({String id, ScanCrop crop, ScanResolution resolution})>
    receipts = <({String id, ScanCrop crop, ScanResolution resolution})>[
      _liveReceipt(live),
    ];
    expect(await session.adoptLiveCapture(captureId, receipts), isTrue);
    expect(await session.adoptLiveCapture(captureId, receipts), isTrue);
    expect(session.items, hasLength(1));
    expect(session.items.single.photoId, '${captureId}_0');
    expect(session.items.single.crop.imagePath, isEmpty);
    expect(drafts.photos, isEmpty);
    expect(recognizer.calls, 0);
    expect(await session.adoptLiveCapture('../foreign', receipts), isFalse);
    expect(session.items, hasLength(1));
  });

  test('failed optional diagnostic import does not set a global metadata storage error', () async {
    const String captureId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-diagnostic-failure-',
    );
    Hive.init(directory.path);
    final MtgCard card = MtgCard.fromJson(
      jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<String, Object?>,
    );
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: ScanDraftStore(userId: 'diagnostic-failure'),
    );
    try {
      final ScanCrop live = _positionedCrop(_quad(.1, .2, .2, .4));
      expect(
        await session.adoptLiveCapture(
          captureId,
          <({String id, ScanCrop crop, ScanResolution resolution})>[
            _liveReceipt(live, card: card),
          ],
        ),
        isTrue,
      );
      expect(
        await session.addFocusStack(
          <String>['${directory.path}/absent.jpg'],
          captureId: captureId,
          diagnosticOnly: true,
        ),
        isFalse,
      );
      expect(session.storageError, isNull);
      expect(session.items.single.printing!.id, card.id);
      expect(
        await session.addFocusStack(<String>['${directory.path}/absent.jpg']),
        isFalse,
      );
      expect(session.storageError, isNotNull);
    } finally {
      session.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });

  test('later diagnostic attachment uses the standalone capture ID and merges on Hive replay without duplicate quantities', () async {
    const String captureId = 'cccccccccccccccccccccccccccccccc';
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-live-independent-',
    );
    Hive.init(directory.path);
    final MtgCard card = MtgCard.fromJson(
      jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<String, Object?>,
    );
    final ScanCrop live = _positionedCrop(_quad(.1, .2, .2, .4));
    final ScanDraftStore drafts = ScanDraftStore(userId: 'live-independent');
    final ScanSession first = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: drafts,
    )..pause();
    expect(
      await first.adoptLiveCapture(
        captureId,
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          _liveReceipt(live, card: card),
        ],
      ),
      isTrue,
    );
    final String id = first.items.single.id;
    first.dispose();
    await Hive.close();
    Hive.init(directory.path);
    final ScanDraftStore nextStore = ScanDraftStore(userId: 'live-independent');
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[live];
    final ScanSession next = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
      store: nextStore,
    )..pause();
    bool nextClosed = false;
    try {
      await next.load();
      expect(next.items.single.id, id);
      expect(next.items.single.crop.imagePath, isEmpty);
      final File photo = await File('${directory.path}/optional.jpg')
          .writeAsBytes(<int>[1, 2, 3]);
      expect(
        await next.addFocusStack(
          <String>[photo.path],
          captureId: captureId,
          diagnosticOnly: true,
        ),
        isTrue,
      );
      expect((await nextStore.readPhotos()).single.id, '${captureId}_0');
      expect(next.capturedItems(<String>[photo.path]), hasLength(1));
      next.dispose();
      nextClosed = true;
      await Hive.close();
      Hive.init(directory.path);
      final ScanDraftStore replayStore = ScanDraftStore(
        userId: 'live-independent',
      );
      final ScanSession replay = ScanSession(
        recognizer: recognizer,
        resolver: _EmptyResolver(),
        store: replayStore,
      );
      try {
        await replay.load();
        await _settle(replay);
        expect(replay.items, hasLength(1));
        expect(replay.items.single.id, id);
        expect(replay.items.single.printing!.id, card.id);
        expect(
          await replay.addFocusStack(
            <String>[photo.path],
            captureId: captureId,
            diagnosticOnly: true,
          ),
          isTrue,
        );
        await _settle(replay);
        expect(replay.items, hasLength(1));
        expect(recognizer.calls, 1);
        final File other = await File('${directory.path}/other.jpg')
            .writeAsBytes(<int>[4, 5, 6]);
        expect(
          await replay.addFocusStack(
            <String>[other.path],
            captureId: captureId,
            diagnosticOnly: true,
          ),
          isFalse,
        );
        expect(replay.storageError, isNull);
        expect((await replayStore.readItems()).single.id, id);
        expect(await other.exists(), isTrue);
        await expectLater(
          replay.addFocusStack(<String>[other.path], captureId: '../foreign'),
          throwsArgumentError,
        );
      } finally {
        replay.dispose();
      }
    } finally {
      if (!nextClosed) next.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });

  test('concurrent failed diagnostic import cannot interrupt a successful durable live metadata handoff', () async {
    const String captureId = 'dddddddddddddddddddddddddddddddd';
    final _GatedLiveDrafts drafts = _GatedLiveDrafts();
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    final Future<bool> adoption = session.adoptLiveCapture(
      captureId,
      <({String id, ScanCrop crop, ScanResolution resolution})>[
        _liveReceipt(_positionedCrop(_quad(.1, .2, .2, .4))),
      ],
    );
    await drafts.saving.future;
    expect(
      await session.addFocusStack(
        <String>['optional.jpg'],
        captureId: captureId,
        diagnosticOnly: true,
      ),
      isFalse,
    );
    expect(session.storageError, isNull);
    expect(session.items, isEmpty);
    drafts.release.complete();
    expect(await adoption, isTrue);
    expect(drafts.saved, hasLength(1));
    expect(session.items.single.liveIdentityName, 'lightning bolt');
    expect(session.items.single.crop.imagePath, isEmpty);
    expect(session.storageError, isNull);
  });

  test('owned saved no-text card remains a durable ordinary review draft across restart', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-unreadable-owned-',
    );
    Hive.init(directory.path);
    final File photo = await File('${directory.path}/photo.jpg')
        .writeAsBytes(<int>[1, 2, 3]);
    final File cropImage = await File('${directory.path}/card.jpg')
        .writeAsBytes(<int>[4, 5, 6]);
    final List<ScanPoint> corners = _quad(.1, .2, .2, .4);
    final ScanCrop crop = ScanCrop(
      imagePath: cropImage.path,
      width: 1000,
      height: 1400,
      rectified: true,
      sourceCorners: corners,
      lines: const <ScanTextLine>[],
      warnings: const <String>['incomplete_card', 'no_text'],
    );
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[crop];
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
      store: ScanDraftStore(userId: 'unreadable-owned'),
    );
    ScanSession? reopened;
    bool disposed = false;
    try {
      expect(
        await session.addFocusStack(
          <String>[photo.path],
          targetRegions: <List<ScanPoint>>[corners],
        ),
        isTrue,
      );
      await _settle(session);
      expect(session.photosRead, 1);
      expect(session.captureReadComplete(<String>[photo.path]), isTrue);
      expect(session.items, hasLength(1));
      final ScanSessionItem item = session.items.single;
      final String id = item.id;
      final String retainedPath = item.crop.imagePath;
      expect(item.liveCaptureReceiptId, isNull);
      expect(item.liveIdentityName, isNull);
      expect(item.printing, isNull);
      expect(item.resolution!.status, ScanResolutionStatus.noMatch);
      expect(item.approval, isNull);
      expect(await File(retainedPath).readAsBytes(), <int>[4, 5, 6]);
      session.dispose();
      disposed = true;
      await Hive.close();
      Hive.init(directory.path);
      reopened = ScanSession(
        recognizer: _Recognizer(),
        resolver: _EmptyResolver(),
        store: ScanDraftStore(userId: 'unreadable-owned'),
      );
      await reopened.load();
      await _settle(reopened);
      expect(reopened.items, hasLength(1));
      expect(reopened.items.single.id, id);
      expect(reopened.items.single.crop.imagePath, retainedPath);
      expect(reopened.items.single.crop.lines, isEmpty);
      expect(reopened.items.single.approval, isNull);
      expect(reopened.items.single.printing, isNull);
      expect(reopened.items.single.liveCaptureReceiptId, isNull);
      expect(
        reopened.items.single.resolution!.status,
        ScanResolutionStatus.noMatch,
      );
      expect(await File(retainedPath).exists(), isTrue);
      expect(recognizer.calls, 2);
      expect(await reopened.store!.readRecoveries(), isEmpty);
    } finally {
      if (!disposed) session.dispose();
      reopened?.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });

  test('completed photo retains immutable raw regions even when unreadable crops are discarded from review', () async {
    final List<ScanPoint> readable = _quad(.1, .2, .2, .4);
    final List<ScanPoint> unreadable = _quad(.6, .2, .2, .4);
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[
        _positionedCrop(readable),
        ScanCrop(
          imagePath: '',
          width: 1000,
          height: 1400,
          rectified: true,
          sourceCorners: unreadable,
          lines: const <ScanTextLine>[],
          warnings: const <String>['incomplete_card', 'no_text'],
        ),
      ];
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
    );
    addTearDown(session.dispose);
    recognizer.afterCall = () {
      if (recognizer.calls == 2) recognizer.resultCrops = const <ScanCrop>[];
    };
    final List<String> paths = <String>[
      'raw-regions-first.jpg',
      'raw-regions-empty.jpg',
    ];
    session.pause();
    await session.addFocusStack(paths);
    expect(session.capturedRawRegions(paths), isEmpty);
    session.resume();
    await _settle(session);
    expect(session.captureReadComplete(paths), isTrue);
    expect(session.items, hasLength(1));
    final List<List<ScanPoint>> regions = session.capturedRawRegions(paths);
    expect(regions, hasLength(2));
    expect(regions[1], orderedEquals(unreadable));
    expect(() => regions.clear(), throwsUnsupportedError);
    expect(() => regions[1].clear(), throwsUnsupportedError);
    unreadable[0] = const ScanPoint(.9, .9);
    expect(
      regions[1].first.x,
      .6,
      reason: 'Native mutable lists cannot alter captured geometry.',
    );
    expect(
      session.capturedRawRegions(<String>['different-photo.jpg']),
      isEmpty,
    );
  });
  test('durable photo reading continues while two catalog workers wait and capture receipts do not wait for print matching', () async {
    final _Recognizer recognizer = _Recognizer();
    final _BlockedResolver resolver = _BlockedResolver();
    final _Drafts drafts = _Drafts();
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: resolver,
      store: drafts,
    );
    addTearDown(() {
      resolver.releaseAll();
      session.dispose();
    });
    await session.addPhotos(
      <String>['one.jpg', 'two.jpg'],
      multipleCards: false,
      ownedCameraSource: true,
    );
    await _until(() => session.photosRead == 2 && resolver.gates.length == 2);
    await session.addPhotos(
      <String>['three.jpg', 'four.jpg'],
      multipleCards: false,
      ownedCameraSource: true,
    );
    await _until(() => session.photosRead == 4 && resolver.gates.length == 2);
    expect(recognizer.maximumActive, 1);
    expect(resolver.maximumActive, 2);
    expect(session.captureReadComplete(<String>['four.jpg']), isTrue);
    expect(drafts.photos, isEmpty);
    expect(drafts.saved, hasLength(4));
    expect(
      session.items.every((ScanSessionItem item) => item.resolution == null),
      isTrue,
    );
    expect(session.running, isTrue);
    resolver.gates[1].complete();
    await _until(() => resolver.gates.length == 3);
    resolver.gates[2].complete();
    await _until(
      () =>
          session.items
              .where((ScanSessionItem item) => item.resolution != null)
              .length ==
          3,
    );
    expect(session.items.first.resolution, isNull);
    expect(resolver.maximumActive, 2);
    resolver.releaseAll();
    await _settle(session);
    expect(
      session.items.every((ScanSessionItem item) => item.exactMatch),
      isTrue,
    );
    expect(session.pendingRecognitionCards, 0);
  });

  test('catalog backlog bounds OCR staging and resumes the queued originals when capacity returns', () async {
    final _Recognizer recognizer = _Recognizer();
    final _BlockedResolver resolver = _BlockedResolver();
    final _Drafts drafts = _Drafts();
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: resolver,
      store: drafts,
    );
    addTearDown(() {
      resolver.releaseAll();
      session.dispose();
    });
    await session.addPhotos(
      List<String>.generate(240, (int index) => 'source-$index.jpg'),
      multipleCards: true,
      ownedCameraSource: true,
    );
    await _until(() => session.recognitionBackpressure);
    final int read = recognizer.calls;
    expect(read, lessThan(240));
    expect(session.remainingPhotos, 240 - read);
    expect(drafts.photos, hasLength(session.remainingPhotos));
    expect(session.pendingRecognitionCards, inInclusiveRange(225, 226));
    expect(recognizer.maximumActive, 1);
    expect(resolver.maximumActive, 2);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(recognizer.calls, read);
    resolver.releaseAll();
    await _settle(session);
    expect(recognizer.calls, 240);
    expect(session.items, hasLength(480));
    expect(resolver.maximumActive, 2);
    expect(resolver.maximumBatch, lessThanOrEqualTo(8));
    expect(resolver.resolved, 480);
    expect(session.recognitionBackpressure, isFalse);
    expect(drafts.photos, isEmpty);
  });

  test('pausing admits no new catalog batch and a failed worker does not poison the other or queued OCR', () async {
    final _Recognizer recognizer = _Recognizer();
    final _BlockedResolver resolver = _BlockedResolver();
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: resolver,
      store: _Drafts(),
    );
    addTearDown(() {
      resolver.releaseAll();
      session.dispose();
    });
    await session.addPhotos(<String>[
      'one.jpg',
      'two.jpg',
      'three.jpg',
      'four.jpg',
    ], multipleCards: false);
    await _until(() => session.photosRead == 4 && resolver.gates.length == 2);
    session.pause();
    resolver.failFallback = true;
    resolver.gates[0].completeError(StateError('Catalog unavailable'));
    resolver.gates[1].complete();
    await _until(() => !session.running);
    expect(resolver.gates, hasLength(2));
    expect(session.items.first.error, isNotNull);
    expect(session.items[1].resolution, isNotNull);
    expect(session.pendingRecognitionCards, 2);
    resolver.failFallback = false;
    resolver.releaseAll();
    session.resume();
    await _settle(session);
    expect(session.items[2].resolution, isNotNull);
    expect(session.items[3].resolution, isNotNull);
    await session.retryUnresolved();
    expect(
      session.items.every(
        (ScanSessionItem item) => item.error == null && item.resolution != null,
      ),
      isTrue,
    );
  });

  test('a photo refinement arriving during lookup replaces stale input without another quantity', () async {
    final ScanCrop crop = _positionedCrop(_quad(.1, .2, .2, .4));
    final List<LiveCaptureObservation> observations =
        await _admittedObservations(<ScanCrop>[crop]);
    final ScanCrop refined = ScanCrop(
      imagePath: '',
      width: crop.width,
      height: crop.height,
      rectified: true,
      sourceCorners: crop.sourceCorners,
      lines: <ScanTextLine>[
        crop.lines.first,
        const ScanTextLine(
          text: '0149',
          confidence: .99,
          bounds: ScanBounds(.05, .85, .2, .02),
        ),
        crop.lines.last,
      ],
    );
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-refinement-during-lookup-',
    );
    Hive.init(directory.path);
    final ScanDraftStore drafts = ScanDraftStore(
      userId: 'refinement-during-lookup',
    );
    final MtgCard printing = MtgCard.fromJson(
      jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<String, Object?>,
    );
    final _BlockedResolver resolver = _BlockedResolver(printing: printing);
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[refined];
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: resolver,
      store: drafts,
    );
    try {
      expect(await session.adoptLiveObservations(observations), isTrue);
      await _until(() => resolver.gates.length == 1);
      final ScanSessionItem item = session.items.single;
      final String id = item.id;
      expect(
        ScanHints.fromCrop(resolver.inputs.first.single).collectorNumber,
        '0146',
      );
      final File photo = await File('${directory.path}/refinement.jpg')
          .writeAsBytes(<int>[1, 2, 3]);
      expect(
        await session.addFocusStack(
          <String>[photo.path],
          captureId: observations.single.captureId,
          diagnosticOnly: true,
          targetRegions: <List<ScanPoint>>[crop.sourceCorners],
        ),
        isTrue,
      );
      await _until(() => session.photosRead == 1);
      expect(session.items.single.id, id);
      resolver.gates.first.complete();
      await _until(() => resolver.gates.length == 2);
      expect(item.resolution, isNull);
      expect((await drafts.readItems()).single.resolution, isNull);
      expect(
        ScanHints.fromCrop(resolver.inputs.last.single).collectorNumber,
        '0149',
      );
      resolver.releaseAll();
      await _settle(session);
      expect(session.items, hasLength(1));
      expect(item.id, id);
      expect(session.storageError, isNull);
      expect(item.resolution, isNotNull);
      expect(item.resolution!.hints.collectorNumber, '0149');
      expect(
        (await drafts.readItems()).single.resolution!.hints.collectorNumber,
        '0149',
      );
    } finally {
      resolver.releaseAll();
      session.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });

  test(
    'failed background result storage never publishes an undurable identity',
    () async {
      final _ToggleLiveDrafts drafts = _ToggleLiveDrafts();
      final _DelayedResolver resolver = _DelayedResolver();
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(),
        resolver: resolver,
        store: drafts,
      );
      addTearDown(session.dispose);
      final List<LiveCaptureObservation> observations =
          await _admittedObservations(<ScanCrop>[
            _positionedCrop(_quad(.1, .1, .24, .35)),
          ]);
      expect(await session.adoptLiveObservations(observations), isTrue);
      final ScanSessionItem item = session.items.single;
      final List<ScanResolution?> published = <ScanResolution?>[];
      session.addListener(() => published.add(item.resolution));
      drafts.failWrites = true;
      resolver.pending.complete();
      await _settle(session);
      expect(item.resolution, isNull);
      expect(item.liveIdentityName, isNull);
      expect(drafts.saved[item.id]!.resolution, isNull);
      expect(
        published.every((ScanResolution? result) => result == null),
        isTrue,
      );
      expect(session.storageError, isNotNull);
      drafts.failWrites = false;
      await session.retryUnresolved();
      expect(item.resolution, isNotNull);
      expect(drafts.saved[item.id]!.resolution, same(item.resolution));
    },
  );

  test('background persistence publishes after saving and preserves intervening manual review', () async {
    final _GatedLiveDrafts drafts = _GatedLiveDrafts();
    final ScanSessionItem initial = ScanSessionItem(_crop, id: 'saved-card');
    drafts.saved[initial.id] = initial.draft;
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _Resolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    await session.load();
    await drafts.saving.future;
    final ScanSessionItem item = session.items.single;
    expect(item.resolution, isNull);
    final ScanResolution manual = ScanResolution(
      candidates: const <ScanCandidate>[],
      hints: ScanHints.fromCrop(item.crop),
      status: ScanResolutionStatus.noMatch,
    );
    item.manuallyReviewed = true;
    item.resolution = manual;
    item.selected = true;
    drafts.release.complete();
    await _settle(session);
    expect(item.resolution, same(manual));
    expect(item.selected, isTrue);
    expect(drafts.saved[item.id]!.resolution, same(manual));
    expect(drafts.saved[item.id]!.selected, isTrue);
  });

  test('delayed parallel lookups preserve manual review and cannot recreate removed or disposed drafts', () async {
    final _BlockedResolver resolver = _BlockedResolver();
    final _Drafts drafts = _Drafts();
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: resolver,
      store: drafts,
    );
    await session.addPhotos(<String>[
      'one.jpg',
      'two.jpg',
      'three.jpg',
    ], multipleCards: false);
    await _until(() => session.photosRead == 3 && resolver.gates.length == 2);
    final ScanSessionItem reviewed = session.items.first;
    final ScanResolution manual = ScanResolution(
      candidates: const <ScanCandidate>[],
      hints: ScanHints.fromCrop(reviewed.crop),
      status: ScanResolutionStatus.noMatch,
    );
    reviewed.manuallyReviewed = true;
    reviewed.resolution = manual;
    await session.persist(<ScanSessionItem>[reviewed]);
    final ScanSessionItem removed = session.items[1];
    await session.remove(removed);
    resolver.releaseAll();
    await _settle(session);
    expect(reviewed.resolution, same(manual));
    expect(drafts.saved[reviewed.id]!.resolution, same(manual));
    expect(drafts.saved.containsKey(removed.id), isFalse);
    expect(session.items, hasLength(2));
    session.dispose();

    final _BlockedResolver closingResolver = _BlockedResolver();
    final ScanSession closing = ScanSession(
      recognizer: _Recognizer(),
      resolver: closingResolver,
      store: drafts,
    );
    await closing.addPhotos(<String>[
      'closing-a.jpg',
      'closing-b.jpg',
    ], multipleCards: false);
    await _until(() => closingResolver.gates.length == 2);
    final Map<String, ScanDraftItem> before = Map<String, ScanDraftItem>.from(
      drafts.saved,
    );
    closing.dispose();
    closingResolver.releaseAll();
    await _until(() => !closing.running);
    expect(drafts.saved, before);
  });

  test('overlapped OCR durably retains original bytes and closed lookup workers cannot overwrite reopened review', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-worker-reopen-',
    );
    Hive.init(directory.path);
    final File first = await File('${directory.path}/first.jpg')
        .writeAsBytes(<int>[1, 2, 3, 4]);
    final File second = await File('${directory.path}/second.jpg')
        .writeAsBytes(<int>[5, 6, 7, 8]);
    final _BlockedResolver resolver = _BlockedResolver();
    final ScanDraftStore drafts = ScanDraftStore(userId: 'worker-reopen');
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: resolver,
      store: drafts,
    );
    bool closed = false;
    ScanSession? reopened;
    addTearDown(() async {
      resolver.releaseAll();
      if (!closed) session.dispose();
      reopened?.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    });
    session.pause();
    await session.addPhotos(
      <String>[first.path],
      multipleCards: false,
      ownedCameraSource: false,
    );
    final ScanDraftPhoto firstPhoto = (await drafts.readPhotos()).single;
    await session.addPhotos(
      <String>[second.path],
      multipleCards: false,
      ownedCameraSource: false,
    );
    final ScanDraftPhoto secondPhoto = (await drafts.readPhotos()).singleWhere(
      (ScanDraftPhoto photo) => photo.id != firstPhoto.id,
    );
    final Map<String, List<int>> expectedBytes = <String, List<int>>{
      firstPhoto.id: <int>[1, 2, 3, 4],
      secondPhoto.id: <int>[5, 6, 7, 8],
    };
    session.resume();
    await _until(() => resolver.gates.length == 2 && session.photosRead == 2);
    final List<ScanDraftItem> raw = await drafts.readItems();
    expect(raw, hasLength(2));
    expect(
      raw.map((ScanDraftItem item) => item.photoId),
      unorderedEquals(expectedBytes.keys),
    );
    for (final MapEntry<String, List<int>> entry in expectedBytes.entries) {
      expect(
        await File((await drafts.readSource(entry.key))!.imagePath)
            .readAsBytes(),
        entry.value,
      );
    }
    session.dispose();
    closed = true;
    final ScanDraftStore nextStore = ScanDraftStore(userId: 'worker-reopen');
    final ScanSession next = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: nextStore,
    )..pause();
    reopened = next;
    await next.load();
    final ScanSessionItem reviewed = next.items.singleWhere(
      (ScanSessionItem item) => item.photoId == firstPhoto.id,
    );
    reviewed.manuallyReviewed = true;
    reviewed.resolution = ScanResolution(
      candidates: const <ScanCandidate>[],
      hints: ScanHints.fromCrop(reviewed.crop),
      status: ScanResolutionStatus.noMatch,
    );
    await next.persist(<ScanSessionItem>[reviewed]);
    resolver.releaseAll();
    await _until(() => !session.running);
    expect(
      (await nextStore.readItems())
          .singleWhere((ScanDraftItem item) => item.id == reviewed.id)
          .resolution!
          .status,
      ScanResolutionStatus.noMatch,
    );
    for (final MapEntry<String, List<int>> entry in expectedBytes.entries) {
      expect(
        await File((await nextStore.readSource(entry.key))!.imagePath)
            .readAsBytes(),
        entry.value,
      );
    }
    expect(next.items, hasLength(2));
  });

  test(
    'raw read receipt waits for durable completion but not catalog lookup',
    () async {
      final _DelayedRawCompletion drafts = _DelayedRawCompletion();
      final _DelayedResolver resolver = _DelayedResolver();
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(),
        resolver: resolver,
        store: drafts,
      );
      bool disposed = false;
      addTearDown(() {
        if (!disposed) {
          session.dispose();
        }
      });
      const List<String> paths = <String>['camera.jpg'];
      expect(session.captureReadComplete(paths), isFalse);
      session.pause();
      await session.addPhotos(
        paths,
        multipleCards: false,
        ownedCameraSource: true,
      );
      expect(session.captureReadComplete(paths), isFalse);
      session.resume();
      await drafts.started.future;
      expect(session.captureReadComplete(paths), isFalse);
      final Completer<void> completed = Completer<void>();
      session.addListener(() {
        if (!completed.isCompleted && session.captureReadComplete(paths)) {
          completed.complete();
        }
      });
      drafts.pending.complete();
      await completed.future.timeout(const Duration(seconds: 2));
      expect(session.captureReadComplete(paths), isTrue);
      expect(session.running, isTrue);
      expect(session.items.single.resolution, isNull);
      resolver.pending.complete();
      await _settle(session);
      expect(session.captureReadComplete(paths), isTrue);
      session.dispose();
      disposed = true;
      expect(session.captureReadComplete(paths), isFalse);
    },
  );

  test(
    'raw read receipt rejects failed partial persistence until retry succeeds',
    () async {
      final _Drafts drafts = _Drafts()..failPartial = true;
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(),
        resolver: _Resolver(),
        store: drafts,
      );
      addTearDown(session.dispose);
      const List<String> paths = <String>['retry-camera.jpg'];
      await session.addPhotos(
        paths,
        multipleCards: true,
        ownedCameraSource: true,
      );
      await _settle(session);
      expect(drafts.saved, isNotEmpty);
      expect(session.failedPhotos, 1);
      expect(session.captureReadComplete(paths), isFalse);
      await session.retryUnresolved();
      expect(session.failedPhotos, 0);
      expect(session.captureReadComplete(paths), isTrue);
    },
  );

  test(
    'raw read receipts retain only the latest thirty-two captures',
    () async {
      final ScanSession session = ScanSession(
        recognizer: _Recognizer()
          ..resultCrop = _positionedCrop(_quad(.1, .2, .2, .4)),
        resolver: _Resolver(),
      );
      addTearDown(session.dispose);
      for (int index = 0; index < 33; index++) {
        await session.addPhotos(<String>[
          'camera-$index.jpg',
        ], multipleCards: false);
        await _settle(session);
      }
      expect(session.captureReadComplete(<String>['camera-0.jpg']), isFalse);
      expect(session.capturedRawRegions(<String>['camera-0.jpg']), isEmpty);
      for (int index = 1; index < 33; index++) {
        expect(
          session.captureReadComplete(<String>['camera-$index.jpg']),
          isTrue,
        );
        expect(
          session.capturedRawRegions(<String>['camera-$index.jpg']),
          hasLength(1),
        );
      }
      expect(session.captureReadComplete(const <String>[]), isFalse);
      expect(
        session.captureReadComplete(<String>['camera-32.jpg', 'camera-32.jpg']),
        isFalse,
      );
    },
  );
  test('actual diagnostic neighbor Bats is ignored until its own frozen capture, while another physical copy remains independent', () async {
    const List<ScanPoint> nevermore = <ScanPoint>[
      ScanPoint(.24793934969704434, .4947166276707499),
      ScanPoint(.49757848551053785, .49673148586744914),
      ScanPoint(.5147854916439922, .6923631690587777),
      ScanPoint(.15930173501725045, .6788366987960652),
    ];
    const List<ScanPoint> circle = <ScanPoint>[
      ScanPoint(.5496864198034536, .4425635940902895),
      ScanPoint(.8131868722640017, .4443503093816757),
      ScanPoint(.8984329533552241, .6165433355450736),
      ScanPoint(.5284671295514455, .6080831144828955),
    ];
    const List<ScanPoint> firstBats = <ScanPoint>[
      ScanPoint(.3859553635120392, .1982588768005371),
      ScanPoint(.5986363887786865, .175176203250885),
      ScanPoint(.6236574053764343, .39399540424346924),
      ScanPoint(.4317268431186676, .4107216000556946),
    ];
    const List<ScanPoint> nextBats = <ScanPoint>[
      ScanPoint(.3854147791862488, .1952553391456604),
      ScanPoint(.5861850380897522, .1839314103126526),
      ScanPoint(.6245847344398499, .39632344245910645),
      ScanPoint(.43143317103385925, .40933501720428467),
    ];
    const List<ScanPoint> ownedBats = <ScanPoint>[
      ScanPoint(.39491108610227915, .1911992521476165),
      ScanPoint(.6454062621073089, .18495261638803567),
      ScanPoint(.6527514070203067, .4453786297831088),
      ScanPoint(.4112003579934448, .4503922263360457),
    ];
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[_positionedCrop(firstBats)];
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
    );
    addTearDown(session.dispose);
    await session.addFocusStack(
      <String>['circle-first.jpg'],
      captureId: 'first_owned',
      diagnosticOnly: true,
      targetRegions: const <List<ScanPoint>>[nevermore, circle],
    );
    await _settle(session);
    expect(session.items, isEmpty);
    expect(session.capturedRawRegions(<String>['circle-first.jpg']), isEmpty);
    expect(session.captureReadComplete(<String>['circle-first.jpg']), isTrue);
    recognizer.resultCrops = <ScanCrop>[_positionedCrop(nextBats)];
    await session.addFocusStack(
      <String>['bats-next.jpg'],
      captureId: 'bats_owned',
      diagnosticOnly: true,
      targetRegions: const <List<ScanPoint>>[ownedBats],
    );
    await _settle(session);
    expect(session.items, hasLength(1));
    expect(session.items.single.crop.sourceCorners, nextBats);
    expect(
      session.capturedRawRegions(<String>['bats-next.jpg']),
      const <List<ScanPoint>>[nextBats],
    );
    final List<ScanPoint> adjacent = nextBats
        .map((ScanPoint point) => ScanPoint(point.x + .25, point.y))
        .toList();
    recognizer.resultCrops = <ScanCrop>[_positionedCrop(adjacent)];
    await session.addFocusStack(
      <String>['other-physical-copy.jpg'],
      captureId: 'adjacent_owned',
      diagnosticOnly: true,
      targetRegions: <List<ScanPoint>>[adjacent],
    );
    await _settle(session);
    expect(session.items, hasLength(2));
  });

  const List<ScanPoint> mountedSavedCard = <ScanPoint>[
    ScanPoint(.5387236358733644, .5418080884134278),
    ScanPoint(.8790780401254856, .5418080884134278),
    ScanPoint(.8790780401254856, .8993232189303619),
    ScanPoint(.5387236358733644, .8993232189303619),
  ];
  const List<List<ScanPoint>> mountedTargets = <List<ScanPoint>>[
    <ScanPoint>[
      ScanPoint(.507558146972008, .5679945985170191),
      ScanPoint(.9348547460666059, .5679945985170191),
      ScanPoint(.9348547460666059, .878219570832103),
      ScanPoint(.507558146972008, .878219570832103),
    ],
    <ScanPoint>[
      ScanPoint(.5169881719494431, .5628968613794858),
      ScanPoint(.9234254264610657, .5628968613794858),
      ScanPoint(.9234254264610657, .884368480792041),
      ScanPoint(.5169881719494431, .884368480792041),
    ],
    <ScanPoint>[
      ScanPoint(.5163573621525289, .5619155502301415),
      ScanPoint(.9245230943267027, .5619155502301415),
      ScanPoint(.9245230943267027, .884132400137069),
      ScanPoint(.5163573621525289, .884132400137069),
    ],
  ];
  const List<List<ScanPoint>> mountedNeighbors = <List<ScanPoint>>[
    <ScanPoint>[
      ScanPoint(.22054968774318695, .4159088134765625),
      ScanPoint(.4720310568809509, .41998547315597534),
      ScanPoint(.5003853440284729, .5981457531452179),
      ScanPoint(.10422345995903015, .5978040397167206),
    ],
    <ScanPoint>[
      ScanPoint(.5790742635726929, .06618452072143555),
      ScanPoint(.7925545573234558, .06084936857223511),
      ScanPoint(.856826901435852, .2751639485359192),
      ScanPoint(.6090532541275024, .2956992983818054),
    ],
  ];
  final List<
    ({
      String name,
      List<ScanPoint> crop,
      List<List<ScanPoint>> targets,
      List<List<ScanPoint>> exclusions,
      bool retained,
    })
  >
  targetCases =
      <
        ({
          String name,
          List<ScanPoint> crop,
          List<List<ScanPoint>> targets,
          List<List<ScanPoint>> exclusions,
          bool retained,
        })
      >[
        for (int index = 0; index < mountedTargets.length; index++)
          (
            name: 'mounted perspective $index',
            crop: mountedSavedCard,
            targets: <List<ScanPoint>>[mountedTargets[index]],
            exclusions: mountedNeighbors,
            retained: true,
          ),
        (
          name: 'already excluded card',
          crop: mountedSavedCard,
          targets: <List<ScanPoint>>[mountedTargets.first],
          exclusions: const <List<ScanPoint>>[mountedSavedCard],
          retained: false,
        ),
        (
          name: 'materially overlapping excluded neighbor',
          crop: mountedSavedCard,
          targets: <List<ScanPoint>>[mountedTargets.first],
          exclusions: <List<ScanPoint>>[_quad(.8, .6, .18, .28)],
          retained: false,
        ),
        (
          name: 'two plausible targets',
          crop: mountedSavedCard,
          targets: mountedTargets.take(2).toList(),
          exclusions: mountedNeighbors,
          retained: false,
        ),
        (
          name: 'another intersecting target',
          crop: mountedSavedCard,
          targets: <List<ScanPoint>>[
            mountedTargets.first,
            _quad(.8, .6, .18, .28),
          ],
          exclusions: mountedNeighbors,
          retained: false,
        ),
        (
          name: 'unrelated silver rectangle',
          crop: mountedSavedCard,
          targets: const <List<ScanPoint>>[
            <ScanPoint>[
              ScanPoint(.807073712348938, .11106634140014648),
              ScanPoint(.9337747097015381, .103127121925354),
              ScanPoint(.9363046884536743, .2807021737098694),
              ScanPoint(.8262190818786621, .28937727212905884),
            ],
          ],
          exclusions: const <List<ScanPoint>>[],
          retained: false,
        ),
        (
          name: 'unrelated desk rectangle',
          crop: mountedSavedCard,
          targets: const <List<ScanPoint>>[
            <ScanPoint>[
              ScanPoint(.14297519624233246, .28641706705093384),
              ScanPoint(.47940701246261597, .27925556898117065),
              ScanPoint(.47629955410957336, .4017072916030884),
              ScanPoint(.16787810623645782, .4405859708786011),
            ],
          ],
          exclusions: const <List<ScanPoint>>[],
          retained: false,
        ),
        (
          name: 'rotated neighbor with overlapping bounding boxes',
          crop: const <ScanPoint>[
            ScanPoint(.4, .1),
            ScanPoint(.6, .3),
            ScanPoint(.3, .6),
            ScanPoint(.1, .4),
          ],
          targets: const <List<ScanPoint>>[
            <ScanPoint>[
              ScanPoint(.37, .1),
              ScanPoint(.6, .33),
              ScanPoint(.33, .6),
              ScanPoint(.1, .37),
            ],
          ],
          exclusions: const <List<ScanPoint>>[
            <ScanPoint>[
              ScanPoint(.7, .2),
              ScanPoint(.9, .4),
              ScanPoint(.6, .7),
              ScanPoint(.4, .5),
            ],
          ],
          retained: true,
        ),
      ];
  for (final bool staged in <bool>[false, true]) {
    for (final ({
          String name,
          List<ScanPoint> crop,
          List<List<ScanPoint>> targets,
          List<List<ScanPoint>> exclusions,
          bool retained,
        })
        fixture
        in targetCases) {
      test(
        'saved target drift ${staged ? 'detail' : 'direct'} ${fixture.name}',
        () async {
          final ScanCrop crop = _positionedCrop(fixture.crop);
          final CardRecognizer recognizer;
          if (staged) {
            final _StagedRecognizer reader = _StagedRecognizer()
              ..emptyPresence = true
              ..detailCrops = <ScanCrop>[crop]
              ..deep.complete();
            recognizer = reader;
          } else {
            recognizer = _Recognizer()..resultCrops = <ScanCrop>[crop];
          }
          final ScanSession session = ScanSession(
            recognizer: recognizer,
            resolver: _EmptyResolver(),
          );
          addTearDown(session.dispose);
          expect(
            await session.addFocusStack(
              const <String>['saved-target-drift.jpg'],
              captureId: 'saved_target_drift',
              preferFastPresence: staged,
              targetRegions: fixture.targets,
              excludedRegions: fixture.exclusions,
            ),
            isTrue,
          );
          await _settle(session);
          expect(session.items, hasLength(fixture.retained ? 1 : 0));
          expect(session.failedPhotos, fixture.retained ? 0 : 1);
          if (fixture.retained) {
            expect(session.items.single.crop.sourceCorners, fixture.crop);
            expect(session.items.single.liveCaptureReceiptId, isNull);
            expect(session.items.single.exactMatch, isFalse);
          }
        },
      );
    }
  }

  const List<ScanPoint> glimpseTarget = <ScanPoint>[
    ScanPoint(.598923272004741, .07749976262675008),
    ScanPoint(.8474905366355892, .0748538820691534),
    ScanPoint(.8698967685977336, .347382721926535),
    ScanPoint(.6099934338465509, .3524132167356857),
  ];
  const List<ScanPoint> glimpseSaved = <ScanPoint>[
    ScanPoint(.5700474953651429, .08601166605949406),
    ScanPoint(.7851457619667053, .07823423743247981),
    ScanPoint(.8590487551689149, .380308758020401),
    ScanPoint(.6005714583396911, .30933622002601624),
  ];
  const List<List<ScanPoint>> glimpseExclusions = <List<ScanPoint>>[
    <ScanPoint>[
      ScanPoint(.23879332840442657, .41531068086624146),
      ScanPoint(.47714143991470337, .41979002952575684),
      ScanPoint(.49812188744544983, .5981437563896179),
      ScanPoint(.1097031682729721, .5978087186813354),
    ],
    <ScanPoint>[
      ScanPoint(.5067968336854203, .5538409083347597),
      ScanPoint(.933103073918631, .5538409083347597),
      ScanPoint(.933103073918631, .8756676291274148),
      ScanPoint(.5067968336854203, .8756676291274148),
    ],
    <ScanPoint>[
      ScanPoint(.21133785026863222, .426248575451973),
      ScanPoint(.47964335635180855, .4191453238369501),
      ScanPoint(.5030766038542037, .5974707370556447),
      ScanPoint(.1146795097477282, .5987036450562236),
    ],
  ];
  const List<ScanTextLine> glimpseObservedLines = <ScanTextLine>[
    ScanTextLine(
      text: 'Glimpse of Nature',
      confidence: 1,
      bounds: ScanBounds(
        .09851577205195916,
        .03681124523029422,
        .49862879702919405,
        .049925152380861815,
      ),
      glyphHeight: .04289822723191876,
    ),
    ScanTextLine(
      text: 'Sorcery',
      confidence: 1,
      bounds: ScanBounds(
        .09405364823309104,
        .5840270439562598,
        .19504860325863488,
        .05343399335391563,
      ),
      glyphHeight: .031125071572332505,
    ),
    ScanTextLine(
      text: 'Whenever you',
      confidence: 1,
      bounds: ScanBounds(
        .09265888265967957,
        .6128060494197469,
        .36502779241193806,
        .09015566380179707,
      ),
      glyphHeight: .033432597924074756,
    ),
    ScanTextLine(
      text: 'cast a creature spell',
      confidence: 1,
      bounds: ScanBounds(
        .45382077258670384,
        .5368925616175866,
        .3968261986448054,
        .10105194398506201,
      ),
      glyphHeight: .03088704135641241,
    ),
    ScanTextLine(
      text: 'this turn, draw',
      confidence: 1,
      bounds: ScanBounds(
        .09759746917957761,
        .6321298823517698,
        .3724524514716968,
        .11368437628051142,
      ),
      glyphHeight: .04364118825793877,
    ),
    ScanTextLine(
      text: 'a card.',
      confidence: 1,
      bounds: ScanBounds(
        .4513036078803077,
        .6078126055763623,
        .15898203264202987,
        .059517548910936524,
      ),
      glyphHeight: .031126262547369624,
    ),
    ScanTextLine(
      text: '0053',
      confidence: 1,
      bounds: ScanBounds(
        .09608765947444489,
        .9438162422847313,
        .10464283457973547,
        .041467149487100376,
      ),
      glyphHeight: .01764478514433066,
    ),
    ScanTextLine(
      text: 'ROA',
      confidence: 1,
      bounds: ScanBounds(
        .07017543824561404,
        .9723849370502092,
        .0736842105263158,
        .02635983263598325,
      ),
      glyphHeight: .02635983263598325,
    ),
    ScanTextLine(
      text: '- EN',
      confidence: 1,
      bounds: ScanBounds(
        .14056716909476266,
        .9556886560340202,
        .07745734766909951,
        .035559125126156374,
      ),
      glyphHeight: .018365529694623545,
    ),
  ];
  for (final bool staged in <bool>[false, true]) {
    for (final String variant in <String>[
      'retains review',
      'ordinary border',
      'no observed card type',
      'adjacent card',
      'ambiguous target',
      'excluded card',
      'overlapping exclusion',
    ]) {
      test(
        'repaired Glimpse source ${staged ? 'detail' : 'direct'} $variant',
        () async {
          final ScanCrop crop = ScanCrop(
            imagePath: 'glimpse-source-crop.jpg',
            width: 1139,
            height: 1591,
            rectified: true,
            sharpness: .9152291543343685,
            sourceCorners: variant == 'adjacent card'
                ? const <ScanPoint>[
                    ScanPoint(.24746069312095642, .41863393783569336),
                    ScanPoint(.4773408770561218, .4228976368904114),
                    ScanPoint(.4986928403377533, .5951398611068726),
                    ScanPoint(.12076099961996078, .5956950187683105),
                  ]
                : glimpseSaved,
            lines: variant == 'no observed card type'
                ? <ScanTextLine>[glimpseObservedLines.first]
                : glimpseObservedLines,
            warnings: variant == 'ordinary border'
                ? const <String>[]
                : const <String>['border_recovered'],
          );
          final CardRecognizer recognizer = staged
              ? (_StagedRecognizer()
                  ..emptyPresence = true
                  ..detailCrops = <ScanCrop>[crop]
                  ..deep.complete())
              : (_Recognizer()..resultCrops = <ScanCrop>[crop]);
          final ScanSession session = ScanSession(
            recognizer: recognizer,
            resolver: _Resolver(),
          );
          addTearDown(session.dispose);
          expect(
            await session.addFocusStack(
              const <String>['glimpse-source.jpg'],
              captureId: 'glimpse_source',
              preferFastPresence: staged,
              targetRegions: <List<ScanPoint>>[
                glimpseTarget,
                if (variant == 'ambiguous target')
                  glimpseTarget
                      .map(
                        (ScanPoint point) => ScanPoint(point.x + .005, point.y),
                      )
                      .toList(),
              ],
              excludedRegions: <List<ScanPoint>>[
                ...glimpseExclusions,
                if (variant == 'excluded card') glimpseSaved,
                if (variant == 'overlapping exclusion') _quad(.78, .2, .15, .2),
              ],
            ),
            isTrue,
          );
          await _settle(session);
          final bool retained = variant == 'retains review';
          expect(session.items, hasLength(retained ? 1 : 0));
          expect(session.failedPhotos, retained ? 0 : 1);
          if (retained) {
            final ScanSessionItem item = session.items.single;
            expect(item.crop.sourceCorners, glimpseSaved);
            expect(item.crop.warnings, contains('border_recovered'));
            expect(item.resolution?.candidates, isNotEmpty);
            expect(item.exactMatch, isFalse);
            expect(item.phase, ScanItemPhase.needsReview);
            expect(item.liveCaptureReceiptId, isNull);
          }
        },
      );
    }
  }

  test('targeted diagnostic crop must have one owned footprint and accepts contained readable body evidence', () async {
    final List<ScanPoint> first = _quad(.1, .1, .3, .6);
    final List<ScanPoint> second = _quad(.3, .1, .3, .6);
    final List<ScanCrop> crops = <ScanCrop>[
      _positionedCrop(_quad(.13, .3, .15, .15)),
      _positionedCrop(_quad(.32, .3, .075, .3)),
      _positionedCrop(_quad(.1, .1, .5, .6)),
      _positionedCrop(_quad(.7, .1, .2, .6)),
    ];
    final _Recognizer recognizer = _Recognizer()..resultCrops = crops;
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
    );
    addTearDown(session.dispose);
    await session.addFocusStack(
      <String>['bounded-body.jpg'],
      captureId: 'bounded_body',
      diagnosticOnly: true,
      targetRegions: <List<ScanPoint>>[first, second],
    );
    await _settle(session);
    expect(session.items.single.crop.sourceCorners, crops.first.sourceCorners);
    expect(
      session.capturedRawRegions(<String>['bounded-body.jpg']),
      <List<ScanPoint>>[crops.first.sourceCorners],
    );
  });

  test(
    'nonempty targets with no owned crop retain a retryable photo',
    () async {
      final List<ScanPoint> owned = _quad(.1, .1, .2, .5);
      final _Recognizer recognizer = _Recognizer()
        ..resultCrops = <ScanCrop>[_positionedCrop(_quad(.65, .1, .2, .5))];
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: _EmptyResolver(),
      );
      addTearDown(session.dispose);
      const List<String> paths = <String>['targeted-retry.jpg'];
      await session.addFocusStack(
        paths,
        captureId: 'targeted_retry',
        targetRegions: <List<ScanPoint>>[owned],
      );
      await _settle(session);
      expect(session.items, isEmpty);
      expect(session.failedPhotos, 1);
      expect(session.photosRead, 1);
      expect(session.captureReadComplete(paths), isFalse);
      recognizer.resultCrops = <ScanCrop>[_positionedCrop(owned)];
      await session.retryUnresolved();
      await _settle(session);
      expect(recognizer.paths, <String>[paths.single, paths.single]);
      expect(session.failedPhotos, 0);
      expect(session.photosRead, 2);
      expect(session.captureReadComplete(paths), isTrue);
      expect(session.items, hasLength(1));
      expect(session.items.single.liveCaptureReceiptId, isNull);
      expect(session.items.single.liveIdentityName, isNull);
    },
  );

  test('empty diagnostic target list admits nothing while manual null targets preserve broad recognition', () async {
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[_positionedCrop(_quad(.1, .1, .3, .6))];
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
    );
    addTearDown(session.dispose);
    await session.addFocusStack(
      <String>['empty-targets.jpg'],
      captureId: 'empty_targets',
      diagnosticOnly: true,
      targetRegions: const <List<ScanPoint>>[],
    );
    await _settle(session);
    expect(session.items, isEmpty);
    expect(session.failedPhotos, 0);
    await session.addFocusStack(<String>['manual-all.jpg']);
    await _settle(session);
    expect(session.items, hasLength(1));
  });

  test('actual approximate Bats photo is suppressed by its owned exclusion without merging adjacent or rotated cards', () async {
    const List<ScanPoint> owned = <ScanPoint>[
      ScanPoint(.382481240997236, .18727198397286623),
      ScanPoint(.5941299487741998, .17536851451511415),
      ScanPoint(.635293049278605, .4098237807856352),
      ScanPoint(.43039146963245856, .43228402993807047),
    ];
    const List<ScanPoint> approximate = <ScanPoint>[
      ScanPoint(.39744663959725407, .18785854118071943),
      ScanPoint(.6650865953803173, .18785854118071943),
      ScanPoint(.6650865953803173, .4689929485158699),
      ScanPoint(.39744663959725407, .4689929485158699),
    ];
    ScanCrop proposal(
      List<ScanPoint> corners, {
      bool rectified = false,
      List<String> warnings = const <String>[
        'no_card_rectangle',
        'partial_card',
        'incomplete_card',
      ],
    }) => ScanCrop(
      imagePath: '',
      width: 1000,
      height: 1400,
      rectified: rectified,
      sourceCorners: corners,
      warnings: warnings,
      lines: const <ScanTextLine>[
        ScanTextLine(
          text: 'Mirkwood Bats',
          confidence: 1,
          bounds: ScanBounds(.1, .04, .7, .03),
        ),
        ScanTextLine(
          text: 'Creature — Bat',
          confidence: 1,
          bounds: ScanBounds(.1, .5, .6, .03),
        ),
        ScanTextLine(
          text: 'Whenever you create or sacrifice a',
          confidence: 1,
          bounds: ScanBounds(.1, .6, .7, .03),
        ),
        ScanTextLine(
          text: 'token, each opponent loses 1 life.',
          confidence: 1,
          bounds: ScanBounds(.1, .65, .7, .03),
        ),
      ],
    );
    final List<ScanCrop> crops = <ScanCrop>[
      proposal(approximate),
      proposal(
        approximate
            .map((ScanPoint point) => ScanPoint(point.x + .25, point.y))
            .toList(),
      ),
      proposal(const <ScanPoint>[
        ScanPoint(.5, .1),
        ScanPoint(.7, .3),
        ScanPoint(.5, .5),
        ScanPoint(.3, .3),
      ]),
      proposal(_quad(.3, .13, .5, .5)),
      proposal(approximate, rectified: true),
      proposal(approximate, warnings: const <String>['partial_card']),
      proposal(_quad(.405, .17, .29, .32)),
    ];
    final _Recognizer recognizer = _Recognizer()..resultCrops = crops;
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
    );
    addTearDown(session.dispose);
    await session.addPhotos(
      <String>['approximate-bats.jpg'],
      multipleCards: true,
      excludedRegions: const <List<ScanPoint>>[owned],
    );
    await _settle(session);
    expect(
      session.items.map((ScanSessionItem item) => item.crop.sourceCorners),
      crops.skip(1).map((ScanCrop crop) => crop.sourceCorners),
    );
    expect(
      session.capturedRawRegions(<String>['approximate-bats.jpg']),
      crops.skip(1).map((ScanCrop crop) => crop.sourceCorners),
    );
    expect(session.failedPhotos, 0);
    expect(
      session.captureReadComplete(<String>['approximate-bats.jpg']),
      isTrue,
    );
  });

  test('actual approximate owned exclusion also completes a diagnostic focus stack with no duplicate quantity', () async {
    const List<ScanPoint> owned = <ScanPoint>[
      ScanPoint(.382481240997236, .18727198397286623),
      ScanPoint(.5941299487741998, .17536851451511415),
      ScanPoint(.635293049278605, .4098237807856352),
      ScanPoint(.43039146963245856, .43228402993807047),
    ];
    final ScanCrop approximate = ScanCrop(
      imagePath: '',
      width: 1000,
      height: 1400,
      rectified: false,
      sourceCorners: const <ScanPoint>[
        ScanPoint(.39744663959725407, .18785854118071943),
        ScanPoint(.6650865953803173, .18785854118071943),
        ScanPoint(.6650865953803173, .4689929485158699),
        ScanPoint(.39744663959725407, .4689929485158699),
      ],
      lines: _crop.lines,
      warnings: const <String>[
        'partial_card',
        'no_card_rectangle',
        'incomplete_card',
      ],
    );
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[approximate];
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
    );
    addTearDown(session.dispose);
    final ScanCrop actual = _positionedCrop(owned);
    expect(
      await session.adoptLiveCapture(
        'first_read',
        <({String id, ScanCrop crop, ScanResolution resolution})>[
          _liveReceipt(actual),
        ],
      ),
      isTrue,
    );
    await session.addFocusStack(
      <String>['later-diagnostic.jpg'],
      captureId: 'later_read',
      diagnosticOnly: true,
      excludedRegions: const <List<ScanPoint>>[owned],
    );
    await _settle(session);
    expect(session.items, hasLength(1));
    expect(session.items.single.id, 'live_first_read_card-1');
    expect(
      session.capturedRawRegions(<String>['later-diagnostic.jpg']),
      isEmpty,
    );
    expect(
      session.captureReadComplete(<String>['later-diagnostic.jpg']),
      isTrue,
    );
    expect(session.failedPhotos, 0);
  });

  test('actual repaired saved-card expansion is excluded without dropping adjacent copies or broad unions', () async {
    const List<ScanPoint> saved = <ScanPoint>[
      ScanPoint(.2329179027067909, .5068205010219058),
      ScanPoint(.4827259401010579, .513056735620314),
      ScanPoint(.5120534672123151, .6938787874531532),
      ScanPoint(.14470587879674673, .6863510795474588),
    ];
    const List<ScanPoint> repaired = <ScanPoint>[
      ScanPoint(.21777673065662384, .49959713220596313),
      ScanPoint(.5100278854370117, .5016207993030548),
      ScanPoint(.5340244770050049, .7119134068489075),
      ScanPoint(.10340569168329239, .7017777562141418),
    ];
    final List<ScanCrop> crops = <ScanCrop>[
      _positionedCrop(repaired),
      _positionedCrop(_quad(.55, .5, .3, .2)),
      _positionedCrop(_quad(.1, .49, .8, .25)),
      _positionedCrop(_quad(.08, .505, .433, .19)),
    ];
    final _Recognizer recognizer = _Recognizer()..resultCrops = crops;
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _Resolver(),
    );
    addTearDown(session.dispose);
    await session.addPhotos(
      <String>['repaired.jpg'],
      multipleCards: true,
      excludedRegions: const <List<ScanPoint>>[saved],
    );
    await _settle(session);
    expect(
      session.items.map((ScanSessionItem item) => item.crop.sourceCorners),
      crops.skip(1).map((ScanCrop crop) => crop.sourceCorners),
    );
    expect(session.failedPhotos, 0);
    expect(session.captureReadComplete(<String>['repaired.jpg']), isTrue);
  });

  test('saved footprints exclude full and contained crops but preserve adjacent, tiny, outside and invalid geometry', () async {
    final List<ScanPoint> saved = _quad(.1, .1, .3, .6);
    final List<ScanCrop> crops = <ScanCrop>[
      _positionedCrop(saved),
      _positionedCrop(_quad(.12, .12, .3, .6)),
      _positionedCrop(_quad(.15, .25, .2, .2)),
      _positionedCrop(_quad(.35, .1, .3, .6)),
      _positionedCrop(_quad(.15, .2, .02, .02)),
      _positionedCrop(_quad(.7, .1, .2, .6)),
      _positionedCrop(<ScanPoint>[saved[0], saved[2], saved[1], saved[3]]),
      _positionedCrop(const <ScanPoint>[]),
    ];
    final _Recognizer recognizer = _Recognizer()..resultCrops = crops;
    final _Drafts drafts = _Drafts();
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _Resolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    await session.addPhotos(
      <String>['scene.jpg'],
      multipleCards: true,
      excludedRegions: <List<ScanPoint>>[saved.reversed.toList()],
    );
    await _settle(session);
    expect(session.failedPhotos, 0);
    expect(session.items.map((ScanSessionItem item) => item.id), <String>[
      'scene_jpg_3',
      'scene_jpg_4',
      'scene_jpg_5',
      'scene_jpg_6',
      'scene_jpg_7',
    ]);
    expect(
      session.items.map((ScanSessionItem item) => item.crop.sourceCorners),
      crops.skip(3).map((ScanCrop crop) => crop.sourceCorners),
    );
  });

  test(
    'rotated adjacent quads with overlapping bounding boxes are retained',
    () async {
      const List<ScanPoint> saved = <ScanPoint>[
        ScanPoint(.4, .1),
        ScanPoint(.6, .3),
        ScanPoint(.3, .6),
        ScanPoint(.1, .4),
      ];
      const List<ScanPoint> adjacent = <ScanPoint>[
        ScanPoint(.65, .2),
        ScanPoint(.85, .4),
        ScanPoint(.55, .7),
        ScanPoint(.35, .5),
      ];
      final _Recognizer recognizer = _Recognizer()
        ..resultCrops = <ScanCrop>[
          _positionedCrop(saved),
          _positionedCrop(adjacent),
        ];
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: _Resolver(),
      );
      addTearDown(session.dispose);
      await session.addPhotos(
        <String>['rotated.jpg'],
        multipleCards: true,
        excludedRegions: const <List<ScanPoint>>[saved],
      );
      await _settle(session);
      expect(session.items.single.crop.sourceCorners, adjacent);
    },
  );

  test('all excluded crops complete normally, while blank recognition remains retryable', () async {
    final List<ScanPoint> saved = _quad(.1, .1, .3, .6);
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[_positionedCrop(saved)];
    final _Drafts drafts = _Drafts();
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _Resolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    await session.addPhotos(
      <String>['excluded.jpg'],
      multipleCards: true,
      excludedRegions: <List<ScanPoint>>[saved],
    );
    await _settle(session);
    expect(session.items, isEmpty);
    expect(session.failedPhotos, 0);
    expect(drafts.photos, isEmpty);
    expect(session.captureReadComplete(<String>['excluded.jpg']), isTrue);
    recognizer.resultCrops = const <ScanCrop>[];
    await session.addPhotos(
      <String>['blank.jpg'],
      multipleCards: true,
      excludedRegions: <List<ScanPoint>>[saved],
    );
    await _settle(session);
    expect(session.failedPhotos, 1);
    expect(session.captureReadComplete(<String>['blank.jpg']), isFalse);
    expect(session.capturedRawRegions(<String>['blank.jpg']), isEmpty);
    expect(drafts.photos.keys, <String>['blank_jpg']);
    recognizer.resultCrops = <ScanCrop>[
      _positionedCrop(saved),
      _positionedCrop(_quad(.6, .1, .3, .6)),
    ];
    await session.retryUnresolved();
    expect(session.failedPhotos, 0);
    expect(session.items.single.id, 'blank_jpg_1');
    expect(session.captureReadComplete(<String>['blank.jpg']), isTrue);
  });

  test('focus exclusion metadata survives failed recognition and real Hive restart', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'focus-exclusions-',
    );
    Hive.init(directory.path);
    final File first = await File('${directory.path}/first.jpg')
        .writeAsBytes(<int>[1, 2, 3]);
    final File second = await File('${directory.path}/second.jpg')
        .writeAsBytes(<int>[4, 5, 6]);
    final List<ScanPoint> saved = _quad(.1, .1, .3, .6);
    final List<ScanPoint> adjacent = _quad(.6, .1, .3, .6);
    final _Recognizer recognizer = _Recognizer()
      ..failNext = true
      ..resultCrops = <ScanCrop>[
        _positionedCrop(saved),
        _positionedCrop(adjacent),
      ];
    final ScanSession original = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
      store: ScanDraftStore(userId: 'exclusions'),
    );
    ScanSession? restored;
    addTearDown(() async {
      original.dispose();
      restored?.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    });
    await original.addFocusStack(
      <String>[first.path, second.path],
      excludedRegions: <List<ScanPoint>>[saved],
    );
    await _settle(original);
    expect(original.failedPhotos, 1);
    await Hive.close();
    Hive.init(directory.path);
    final ScanDraftStore reopened = ScanDraftStore(userId: 'exclusions');
    final ScanSession resumed = ScanSession(
      recognizer: recognizer,
      resolver: _EmptyResolver(),
      store: reopened,
    );
    restored = resumed;
    await resumed.load();
    await _settle(resumed);
    expect(resumed.failedPhotos, 0);
    expect(resumed.items, hasLength(1));
    expect(resumed.items.single.crop.sourceCorners, adjacent);
    expect(
      (await reopened.readSource(resumed.items.single.photoId))!
          .excludedRegions
          .single
          .map((ScanPoint point) => point.x),
      saved.map((ScanPoint point) => point.x),
    );
    expect(await reopened.readPhotos(), isEmpty);
    expect(await first.exists(), isTrue);
    expect(await second.exists(), isTrue);
  });

  test('excluded-only focus stack completes but a genuinely blank focus stack fails', () async {
    final List<ScanPoint> saved = _quad(.1, .1, .3, .6);
    final _Recognizer recognizer = _Recognizer()
      ..resultCrops = <ScanCrop>[_positionedCrop(saved)];
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _Resolver(),
    );
    addTearDown(session.dispose);
    await session.addFocusStack(
      <String>['first.jpg', 'second.jpg'],
      excludedRegions: <List<ScanPoint>>[saved],
    );
    await _settle(session);
    expect(session.items, isEmpty);
    expect(session.failedPhotos, 0);
    expect(
      session.captureReadComplete(<String>['first.jpg', 'second.jpg']),
      isTrue,
    );
    recognizer.resultCrops = const <ScanCrop>[];
    await session.addFocusStack(
      <String>['blank-a.jpg', 'blank-b.jpg'],
      excludedRegions: <List<ScanPoint>>[saved],
    );
    await _settle(session);
    expect(session.failedPhotos, 1);
    expect(
      session.captureReadComplete(<String>['blank-a.jpg', 'blank-b.jpg']),
      isFalse,
    );
  });

  test(
    'completed zero-item focus receipt restores from persisted source metadata',
    () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'read-receipt-',
      );
      Hive.init(directory.path);
      final File first = await File('${directory.path}/first.jpg')
          .writeAsBytes(<int>[1, 2, 3]);
      final File second = await File('${directory.path}/second.jpg')
          .writeAsBytes(<int>[4, 5, 6]);
      final List<String> paths = <String>[first.path, second.path];
      final List<ScanPoint> saved = _quad(.1, .1, .3, .6);
      final _Recognizer recognizer = _Recognizer()
        ..resultCrops = <ScanCrop>[_positionedCrop(saved)];
      final ScanSession original = ScanSession(
        recognizer: recognizer,
        resolver: _EmptyResolver(),
        store: ScanDraftStore(userId: 'read-receipt'),
      );
      ScanSession? restored;
      addTearDown(() async {
        original.dispose();
        restored?.dispose();
        await Hive.close();
        await directory.delete(recursive: true);
      });
      await original.addFocusStack(
        paths,
        excludedRegions: <List<ScanPoint>>[saved],
      );
      await _settle(original);
      expect(original.items, isEmpty);
      expect(original.captureReadComplete(paths), isTrue);
      final int calls = recognizer.calls;
      await Hive.close();
      Hive.init(directory.path);
      final ScanSession reopened = ScanSession(
        recognizer: recognizer,
        resolver: _EmptyResolver(),
        store: ScanDraftStore(userId: 'read-receipt'),
      );
      restored = reopened;
      expect(reopened.captureReadComplete(paths), isFalse);
      await reopened.addFocusStack(
        paths,
        excludedRegions: <List<ScanPoint>>[saved],
      );
      expect(reopened.captureReadComplete(paths), isTrue);
      expect(reopened.items, isEmpty);
      expect(reopened.remainingPhotos, 0);
      expect(recognizer.calls, calls);
    },
  );

  test('single camera results bind to their durable UUID and exclude earlier captures and gallery imports', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'single_camera_binding_',
    );
    Hive.init(directory.path);
    final ScanDraftStore drafts = ScanDraftStore(userId: 'camera-binding');
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _EmptyResolver(),
      store: drafts,
    );
    addTearDown(() async {
      session.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    });
    final File first = await File('${directory.path}/first.jpg')
        .writeAsBytes(<int>[1, 2, 3]);
    final File second = await File('${directory.path}/second.jpg')
        .writeAsBytes(<int>[4, 5, 6]);
    session.pause();
    expect(
      await session.addPhotos(
        <String>[first.path],
        multipleCards: false,
        ownedCameraSource: true,
      ),
      isTrue,
    );
    final ScanDraftPhoto firstPhoto = (await drafts.readPhotos()).single;
    expect(
      firstPhoto.id,
      matches(RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$')),
    );
    expect(session.capturedItems(<String>[first.path]), isEmpty);
    session.resume();
    await _settle(session);
    expect(
      session.capturedItems(<String>[first.path]).single.photoId,
      firstPhoto.id,
    );
    expect((await drafts.readItems()).single.photoId, firstPhoto.id);
    expect(await drafts.readSource(firstPhoto.id), isNotNull);
    expect(
      await session.addPhotos(
        <String>[second.path],
        multipleCards: false,
        ownedCameraSource: true,
      ),
      isTrue,
    );
    await _settle(session);
    expect(session.items, hasLength(2));
    expect(session.capturedItems(<String>[first.path]), isEmpty);
    expect(
      session.capturedItems(<String>[second.path]).single.photoId,
      isNot(firstPhoto.id),
    );
    expect(session.capturedItems(<String>[first.path, second.path]), isEmpty);
    final File gallery = await File('${directory.path}/gallery.jpg')
        .writeAsBytes(<int>[7, 8, 9]);
    expect(
      await session.addPhotos(<String>[gallery.path], multipleCards: false),
      isTrue,
    );
    await _settle(session);
    expect(session.items, hasLength(3));
    expect(session.capturedItems(<String>[gallery.path]), isEmpty);
    expect(session.capturedItems(<String>[second.path]), isEmpty);
    final File stackA = await File('${directory.path}/stack-a.jpg')
        .writeAsBytes(<int>[10, 11]);
    final File stackB = await File('${directory.path}/stack-b.jpg')
        .writeAsBytes(<int>[12, 13]);
    final List<String> stackPaths = <String>[stackA.path, stackB.path];
    expect(
      await session.addFocusStack(stackPaths, ownedCameraSource: true),
      isTrue,
    );
    await _settle(session);
    final String stackId = ScanDraftStore.focusStackCaptureId(stackPaths);
    expect(session.capturedItems(stackPaths), isNotEmpty);
    expect(
      session
          .capturedItems(stackPaths)
          .every(
            (ScanSessionItem item) =>
                item.photoId == '${stackId}_0' ||
                item.photoId == '${stackId}_1',
          ),
      isTrue,
    );
    expect(session.capturedItems(<String>[first.path]), isEmpty);
    expect(session.capturedItems(<String>[second.path]), isEmpty);
  });

  test('camera binding is admitted before notifications, only after durable import, and never after disposal', () async {
    final _Drafts drafts = _Drafts()..importing = Completer<void>();
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _Resolver(),
      store: drafts,
    );
    session.pause();
    final ScanSessionItem admitted = ScanSessionItem(
      _crop,
      photoId: 'camera_jpg',
    );
    session.add(admitted);
    int boundNotifications = 0;
    session.addListener(() {
      if (session.capturedItems(<String>['camera.jpg']).contains(admitted)) {
        boundNotifications++;
      }
    });
    final Future<bool> importing = session.addPhotos(
      <String>['camera.jpg'],
      multipleCards: false,
      ownedCameraSource: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(session.capturedItems(<String>['camera.jpg']), isEmpty);
    drafts.importing!.complete();
    expect(await importing, isTrue);
    expect(boundNotifications, 1);
    final String captureId = ScanDraftStore.focusStackCaptureId(<String>[
      'stack-a.jpg',
      'stack-b.jpg',
    ]);
    final ScanSessionItem stack = ScanSessionItem(
      _crop,
      photoId: '${captureId}_1',
    );
    session.add(stack);
    expect(
      session.capturedItems(<String>['stack-a.jpg', 'stack-b.jpg']),
      <ScanSessionItem>[stack],
    );
    expect(session.capturedItems(<String>['unrelated.jpg']), isEmpty);
    session.dispose();
    expect(session.capturedItems(<String>['camera.jpg']), isEmpty);
    expect(
      await session.addPhotos(
        <String>['later.jpg'],
        multipleCards: false,
        ownedCameraSource: true,
      ),
      isFalse,
    );
    expect(drafts.photos.keys, <String>['camera_jpg']);
    final _Drafts closingDrafts = _Drafts()..importing = Completer<void>();
    final ScanSession closing = ScanSession(
      recognizer: _Recognizer(),
      resolver: _Resolver(),
      store: closingDrafts,
    );
    closing.pause();
    int closingNotifications = 0;
    closing.addListener(() {
      closingNotifications++;
    });
    final Future<bool> lateAdmission = closing.addPhotos(
      <String>['closing.jpg'],
      multipleCards: false,
      ownedCameraSource: true,
    );
    await Future<void>.delayed(Duration.zero);
    closing.dispose();
    closingDrafts.importing!.complete();
    expect(await lateAdmission, isTrue);
    expect(closingDrafts.photos.keys, <String>['closing_jpg']);
    expect(closing.capturedItems(<String>['closing.jpg']), isEmpty);
    expect(closing.remainingPhotos, 0);
    expect(closingNotifications, 0);
  });

  test(
    'session transfers source ownership only for explicit camera imports',
    () async {
      final _Drafts drafts = _Drafts();
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(),
        resolver: _Resolver(),
        store: drafts,
      );
      addTearDown(session.dispose);
      session.pause();
      await session.addPhotos(
        <String>['camera.jpg'],
        multipleCards: true,
        ownedCameraSource: true,
      );
      await session.addPhotos(<String>['gallery.jpg'], multipleCards: true);
      expect(drafts.cameraOwnership, <bool>[true, false]);
      expect(drafts.photos, hasLength(2));
    },
  );

  test('camera capture acknowledgement waits for durable import and reports failure without staging it', () async {
    final _Drafts drafts = _Drafts()..importing = Completer<void>();
    final _Recognizer recognizer = _Recognizer();
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _Resolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    session.pause();
    bool completed = false;
    final Future<bool> acknowledgement = session
        .addPhotos(
          <String>['camera.jpg'],
          multipleCards: true,
          ownedCameraSource: true,
        )
        .then((bool saved) {
          completed = true;
          return saved;
        });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(session.remainingPhotos, 0);
    drafts.importing!.complete();
    expect(await acknowledgement, isTrue);
    expect(session.remainingPhotos, 1);
    expect(drafts.photos.keys, contains('camera_jpg'));
    drafts.importing = null;
    drafts.failedImportPath = 'failed.jpg';
    expect(
      await session.addPhotos(
        <String>['failed.jpg'],
        multipleCards: true,
        ownedCameraSource: true,
      ),
      isFalse,
    );
    expect(session.remainingPhotos, 1);
    expect(drafts.photos.keys, isNot(contains('failed_jpg')));
    expect(session.storageError, isNotNull);
    expect(recognizer.calls, 0);
    drafts.failedImportPath = null;
    expect(
      await session.addPhotos(
        <String>['failed.jpg'],
        multipleCards: true,
        ownedCameraSource: true,
      ),
      isTrue,
    );
    expect(session.remainingPhotos, 2);
    expect(drafts.photos.keys, contains('failed_jpg'));
  });

  test('partial gallery import returns failure while preserving already durable photos', () async {
    final _Drafts drafts = _Drafts()..failedImportPath = 'missing.jpg';
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _Resolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    session.pause();
    expect(
      await session.addPhotos(<String>[
        'first.jpg',
        'missing.jpg',
      ], multipleCards: false),
      isFalse,
    );
    expect(session.remainingPhotos, 1);
    expect(drafts.photos.keys, <String>['first_jpg']);
  });

  test('automatic exact evidence rejects unreadable set, language and unrelated confident title-zone text', () {
    ScanCrop observation(List<ScanTextLine> lines) => ScanCrop(
      imagePath: '',
      width: 1000,
      height: 1400,
      rectified: true,
      sourceCorners: const <ScanPoint>[],
      lines: lines,
    );
    final ScanResolution exact = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_Printing(), <ScanEvidence>{
          ScanEvidence.footerMatch,
          ScanEvidence.nameMatch,
        }),
      ],
      hints: ScanHints.fromCrop(_crop),
      status: ScanResolutionStatus.exactPrinting,
    );
    expect(hasExactPrintingEvidence(_crop, exact), isTrue);
    final ScanCrop weakSet = observation(<ScanTextLine>[
      _crop.lines[0],
      _crop.lines[1],
      const ScanTextLine(
        text: 'M11 EN',
        confidence: .4,
        bounds: ScanBounds(.05, .9, .2, .02),
      ),
    ]);
    expect(hasExactPrintingEvidence(weakSet, exact), isFalse);
    final ScanCrop noLanguage = observation(<ScanTextLine>[
      _crop.lines[0],
      _crop.lines[1],
      const ScanTextLine(
        text: 'M11',
        confidence: .99,
        bounds: ScanBounds(.05, .9, .2, .02),
      ),
    ]);
    expect(hasExactPrintingEvidence(noLanguage, exact), isFalse);
    final ScanCrop weakTitle = observation(<ScanTextLine>[
      const ScanTextLine(
        text: 'Lightning Bolt',
        confidence: .5,
        bounds: ScanBounds(.1, .05, .7, .02),
      ),
      const ScanTextLine(
        text: 'Confident artwork text',
        confidence: .99,
        bounds: ScanBounds(.1, .17, .7, .02),
      ),
      _crop.lines[1],
      _crop.lines[2],
    ]);
    expect(hasExactPrintingEvidence(weakTitle, exact), isFalse);
    final ScanCrop wrongSet = observation(<ScanTextLine>[
      _crop.lines[0],
      _crop.lines[1],
      const ScanTextLine(
        text: 'M10 EN',
        confidence: .99,
        bounds: ScanBounds(.05, .9, .2, .02),
      ),
    ]);
    expect(hasExactPrintingEvidence(wrongSet, exact), isFalse);
  });

  test(
    'printing row clipping retains established historical identity proof',
    () async {
      const HistoricalBodyIdentityProof proof = HistoricalBodyIdentityProof(
        name: 'Lightning Bolt',
        bodySignature: 'established-full-list-body',
      );
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(),
        resolver: _Resolver(manyCandidates: true, historicalProof: proof),
      );
      addTearDown(session.dispose);
      await session.addPhotos(<String>['photo.jpg'], multipleCards: false);
      await _settle(session);
      final ScanResolution saved = session.items.single.resolution!;
      expect(saved.candidates, hasLength(3));
      expect(saved.hasMore, isTrue);
      expect(identical(saved.historicalBodyIdentityProof, proof), isTrue);
      expect(saved.status, ScanResolutionStatus.needsReview);
      expect(
        hasExactPrintingEvidence(session.items.single.crop, saved),
        isFalse,
      );
    },
  );

  test('3200 mocked cards preserve independent phases, bounded intake, retry, restart and clear', () async {
    final Map<String, Object?> fixture = jsonDecode(
      File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final MtgCard printing = MtgCard.fromJson(<String, Object?>{
      ...fixture,
      'name': 'Lightning Bolt',
      'set': 'm11',
      'collector_number': '146',
      'type_line': 'Instant',
      'layout': 'normal',
      'card_faces': null,
    });
    final _BulkReplayRecognizer recognizer = _BulkReplayRecognizer();
    final _BulkReplayResolver resolver = _BulkReplayResolver(printing);
    final _BulkReplayDrafts drafts = _BulkReplayDrafts();
    ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: resolver,
      store: drafts,
    );
    int maximumSources = 0;
    int maximumStaged = 0;
    bool reachedBackpressure = false;
    void observe() {
      if (session.pendingPhotoCaptures > maximumSources) {
        maximumSources = session.pendingPhotoCaptures;
      }
      if (session.pendingRecognitionCards > maximumStaged) {
        maximumStaged = session.pendingRecognitionCards;
      }
      if (session.recognitionBackpressure &&
          !resolver.initialCatalog.isCompleted) {
        reachedBackpressure = true;
        resolver.initialCatalog.complete();
      }
    }

    session.addListener(observe);
    try {
      for (int photo = 0; photo < 1600; photo++) {
        await _until(() => session.pendingPhotoCaptures < 8);
        expect(
          await session.addPhotos(<String>[
            'mock-$photo.jpg',
          ], multipleCards: true),
          isTrue,
        );
      }
      if (!resolver.initialCatalog.isCompleted) {
        resolver.initialCatalog.complete();
      }
      await _settle(session);
      expect(reachedBackpressure, isTrue);
      expect(maximumSources, lessThanOrEqualTo(8));
      expect(maximumStaged, lessThanOrEqualTo(226));
      expect(recognizer.maximumActive, 1);
      expect(recognizer.calls, 1600);
      expect(resolver.maximumActive, lessThanOrEqualTo(2));
      expect(resolver.maximumBatch, lessThanOrEqualTo(8));
      expect(session.items, hasLength(3200));
      final Set<String> ids = session.items
          .map((ScanSessionItem item) => item.id)
          .toSet();
      expect(ids, hasLength(3200));
      for (final ScanItemPhase phase in <ScanItemPhase>[
        ScanItemPhase.ready,
        ScanItemPhase.needsReview,
        ScanItemPhase.noIdentity,
        ScanItemPhase.lookupFailed,
      ]) {
        expect(
          session.items.where((ScanSessionItem item) => item.phase == phase),
          hasLength(800),
        );
      }
      final ScanSessionItem reviewed = session.items.firstWhere(
        (ScanSessionItem item) => item.phase == ScanItemPhase.ready,
      );
      reviewed.approval = ScanQueueApproval(
        operationId: reviewed.id,
        card: cardFromScryfall(printing, finish: Finish.nonfoil),
        quantity: 7,
      );
      reviewed.manuallyReviewed = true;
      await session.persist(<ScanSessionItem>[reviewed]);
      final String reviewedId = reviewed.id;
      session.removeListener(observe);
      session.dispose();
      session = ScanSession(
        recognizer: recognizer,
        resolver: resolver,
        store: drafts,
      );
      await session.load();
      await _settle(session);
      expect(session.items.map((ScanSessionItem item) => item.id).toSet(), ids);
      expect(
        session.items
            .singleWhere((ScanSessionItem item) => item.id == reviewedId)
            .approval!
            .quantity,
        7,
      );
      resolver.recovered = true;
      await session.retryUnresolved();
      await _settle(session);
      expect(session.items.map((ScanSessionItem item) => item.id).toSet(), ids);
      expect(
        session.items.where(
          (ScanSessionItem item) =>
              item.phase == ScanItemPhase.lookupFailed ||
              item.phase == ScanItemPhase.noIdentity,
        ),
        isEmpty,
      );
      expect(
        session.items.where(
          (ScanSessionItem item) => item.phase == ScanItemPhase.needsReview,
        ),
        hasLength(2400),
      );
      expect(
        session.items
            .singleWhere((ScanSessionItem item) => item.id == reviewedId)
            .approval!
            .quantity,
        7,
      );
      expect(
        recognizer.calls,
        1600,
        reason: 'Catalog retries do not photograph or create physical copies.',
      );
      await session.clearCaptures();
      await Future<void>.delayed(Duration.zero);
      expect(session.items, isEmpty);
      expect(session.pendingRecognitionCards, 0);
      expect(session.pendingPhotoCaptures, 0);
      expect(drafts.saved, isEmpty);
      expect(
        await session.addPhotos(<String>['mock-1600.jpg'], multipleCards: true),
        isTrue,
      );
      await _settle(session);
      expect(session.items, hasLength(2));
      expect(
        session.items.any((ScanSessionItem item) => ids.contains(item.id)),
        isFalse,
      );
    } finally {
      if (!resolver.initialCatalog.isCompleted) {
        resolver.initialCatalog.complete();
      }
      session.removeListener(observe);
      session.dispose();
    }
  });

  test('1000 multi-card photos keep duplicates and bound native and lookup staging', () async {
    final _Recognizer recognizer = _Recognizer();
    final _Resolver resolver = _Resolver(manyCandidates: true);
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: resolver,
    );
    addTearDown(session.dispose);
    final Stopwatch elapsed = Stopwatch()..start();
    await session.addPhotos(
      List<String>.generate(1000, (int index) => '$index.jpg'),
      multipleCards: true,
    );
    await _settle(session);
    elapsed.stop();
    expect(recognizer.calls, 1000);
    expect(recognizer.maximumActive, 1);
    expect(resolver.maximumBatch, lessThanOrEqualTo(75));
    expect(resolver.resolved, 2000);
    expect(session.items, hasLength(2000));
    expect(
      session.items.map((ScanSessionItem item) => item.id).toSet(),
      hasLength(2000),
    );
    expect(
      session.items.every(
        (ScanSessionItem item) => item.resolution!.candidates.length == 3,
      ),
      isTrue,
    );
    expect(
      session.items.every((ScanSessionItem item) => !item.selected),
      isTrue,
    );
    // This measures orchestration only; native OCR and network time are covered separately.
    debugPrint(
      '1000 synthetic photos / 2000 cards: ${elapsed.elapsedMilliseconds} ms; lookup batch <= ${resolver.maximumBatch}, native concurrency ${recognizer.maximumActive}',
    );
  });

  test('pause preserves pending photos and resume completes exact matches without selecting them', () async {
    final _Recognizer recognizer = _Recognizer();
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _Resolver(),
    );
    addTearDown(session.dispose);
    recognizer.afterCall = session.pause;
    await session.addPhotos(<String>[
      'one.jpg',
      'two.jpg',
    ], multipleCards: false);
    while (session.running) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(session.remainingPhotos, 1);
    expect(session.items, hasLength(1));
    recognizer.afterCall = null;
    session.resume();
    await _settle(session);
    expect(session.items, hasLength(2));
    expect(
      session.items.every((ScanSessionItem item) => item.exactMatch),
      isTrue,
    );
    expect(
      session.items.every(
        (ScanSessionItem item) => !item.selected && item.approval == null,
      ),
      isTrue,
    );
  });

  test('recognition failure retains original path for retry', () async {
    final _Recognizer recognizer = _Recognizer()..failNext = true;
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _Resolver(),
    );
    addTearDown(session.dispose);
    await session.addPhotos(<String>['recoverable.jpg'], multipleCards: false);
    await _settle(session);
    expect(session.failedPhotos, 1);
    await session.retryUnresolved();
    expect(recognizer.paths, <String>['recoverable.jpg', 'recoverable.jpg']);
    expect(session.failedPhotos, 0);
    expect(session.items, hasLength(1));
  });
  for (final String generation in <String>[
    '',
    '/ec186f14-cafc-443a-8827-deb8e915aac1',
  ]) {
    test(
      'failed crop persistence cleans native cache$generation and retains retry source',
      () async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'scanner_cache_failure_',
        );
        addTearDown(() => directory.delete(recursive: true));
        final File original = await File('${directory.path}/original.jpg')
            .writeAsBytes(<int>[1]);
        final Directory cache = await Directory(
          '${directory.path}/ScanCrops$generation',
        ).create(recursive: true);
        final File temporary = await File('${cache.path}/recognized.jpg')
            .writeAsBytes(<int>[2]);
        final _Recognizer recognizer = _Recognizer()
          ..resultCrop = ScanCrop(
            imagePath: temporary.path,
            width: _crop.width,
            height: _crop.height,
            rectified: true,
            sourceCorners: _crop.sourceCorners,
            lines: _crop.lines,
          );
        final _FailedDrafts drafts = _FailedDrafts();
        final ScanSession session = ScanSession(
          recognizer: recognizer,
          resolver: _Resolver(),
          store: drafts,
        );
        addTearDown(session.dispose);
        await session.addPhotos(<String>[original.path], multipleCards: false);
        await _settle(session);
        for (int retry = 0; retry < 100 && await temporary.exists(); retry++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(await temporary.exists(), isFalse);
        expect(await original.exists(), isTrue);
        expect(drafts.photos.values.single.imagePath, original.path);
        expect(session.failedPhotos, 1);
      },
    );
  }
  test(
    'partial crop persistence recovers both crops and load is idempotent',
    () async {
      final _Drafts drafts = _Drafts()..failPartial = true;
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(),
        resolver: _Resolver(),
        store: drafts,
      );
      addTearDown(session.dispose);
      await session.addPhotos(<String>['pair.jpg'], multipleCards: true);
      await _settle(session);
      expect(session.failedPhotos, 1);
      expect(drafts.saved.length, 1);
      await session.retryUnresolved();
      expect(session.items.length, 2);
      expect(
        session.items.every((ScanSessionItem item) => item.resolution != null),
        isTrue,
      );
      expect(drafts.photos, isEmpty);
      await session.load();
      await session.load();
      expect(session.items.length, 2);
    },
  );

  test('pending photo replay retains the reviewed printing, quantity and stable approval ID', () async {
    final _Drafts drafts = _Drafts();
    final ScanDraftPhoto photo = (await drafts.importPhotos(<String>[
      'pair.jpg',
    ], multipleCards: true)).single;
    final MTGCard card = MTGCard(
      name: 'Reviewed printing',
      setId: 'set',
      description: '',
      cmc: 1,
      typeLine: 'Instant',
      flavorText: '',
      setType: SetType.core,
      rarity: Rarity.common,
      manaCost: null,
      finish: Finish.foil,
    );
    final String id = '${photo.id}_0';
    drafts.saved[id] = ScanDraftItem(
      id: id,
      photoId: photo.id,
      crop: _crop,
      approval: ScanQueueApproval(
        operationId: id,
        card: card,
        quantity: 7,
        deckId: 'chosen-deck',
      ),
      selected: true,
    );
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: _Resolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    await session.load();
    await _settle(session);
    expect(drafts.saved[id]!.approval!.quantity, 7);
    expect(drafts.saved[id]!.approval!.operationId, id);
    expect(drafts.saved[id]!.approval!.deckId, 'chosen-deck');
    expect(drafts.saved[id]!.selected, isTrue);
    expect(session.items.length, 2);
  });

  test(
    'discard during lookup cannot recreate its draft after delayed removal',
    () async {
      final _Drafts drafts = _Drafts()..removing = Completer<void>();
      final _DelayedResolver resolver = _DelayedResolver();
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(),
        resolver: resolver,
        store: drafts,
      );
      addTearDown(session.dispose);
      await session.addPhotos(<String>['one.jpg'], multipleCards: false);
      while (session.items.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      final Future<void> removing = session.remove(session.items.single);
      resolver.pending.complete();
      while (session.running) {
        await Future<void>.delayed(Duration.zero);
      }
      drafts.removing!.complete();
      await removing;
      expect(drafts.saved, isEmpty);
      expect(session.items, isEmpty);
    },
  );
}
