import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'live_scan_detector.dart';
import 'scan_recognition.dart';
import 'scan_resolver.dart';

class LiveScanTrack {
  static int _nextPhotoFeedbackIncarnation = 0;
  LiveScanTrack({
    required this.id,
    required LiveCardDetection detection,
    required this.lastSeen,
  }) : corners = detection.corners,
       confidence = detection.confidence,
       _lines = detection.lines,
       _warnings = detection.warnings {
    if (_readableCardText(crop)) _cardEvidenceAt = lastSeen;
    if (_strongCaptureProof(crop)) _captureProofAt = lastSeen;
  }

  final String id;
  int _photoFeedbackIncarnation = ++_nextPhotoFeedbackIncarnation;
  String get photoFeedbackId => 'photo-$_photoFeedbackIncarnation';
  void _invalidatePhotoFeedback() {
    _photoFeedbackIncarnation = ++_nextPhotoFeedbackIncarnation;
  }

  List<ScanPoint> corners;
  double confidence;
  DateTime lastSeen;
  int stableFrames = 1;
  ScanResolution? resolution;
  bool resolving = false;
  String? error;
  List<ScanTextLine> _lines;
  List<String> _warnings;
  String? _resolvedKey;
  DateTime? _lastAttempt;
  DateTime? _cardEvidenceAt;
  DateTime? _captureProofAt;
  DateTime? _capturedAt;
  bool _capturedIdentified = false;
  ScanCrop? _capturedCrop;
  ScanResolution? _identifiedSavedResolution;
  LiveCaptureObservation? _recoveryObservation;

  bool get captured => _capturedAt != null;
  bool get hasRetainedCapture => _recoveryObservation != null;
  bool get capturedIdentified => captured && _capturedIdentified;

  bool get hasCatalogMatch =>
      resolution?.candidates.any(
        (ScanCandidate candidate) =>
            !candidate.hasContradiction &&
            (candidate.evidence.any(
                  (ScanEvidence evidence) => const <ScanEvidence>{
                    ScanEvidence.nameMatch,
                    ScanEvidence.footerMatch,
                    ScanEvidence.rulesTextMatch,
                  }.contains(evidence),
                ) ||
                (candidate.evidence.contains(ScanEvidence.rulesKeywordMatch) &&
                    (candidate.evidence.contains(ScanEvidence.fuzzyName) ||
                        resolution!.candidates.length == 1))),
      ) ??
      false;

  bool get hasVerifiedLiveIdentity {
    final ScanResolution? result = resolution;
    if (hasConflictingScanTitle(crop) ||
        result == null ||
        result.status == ScanResolutionStatus.noMatch) {
      return false;
    }
    if (verifiedLiveHistoricalBodyIdentity(crop, result) != null) return true;
    final Set<String> names = result.candidates
        .where(
          (ScanCandidate candidate) =>
              !candidate.hasContradiction &&
              candidate.evidence.contains(ScanEvidence.nameMatch) &&
              candidate.evidence.any(
                (ScanEvidence evidence) => const <ScanEvidence>{
                  ScanEvidence.typeLineMatch,
                  ScanEvidence.rulesTextMatch,
                  ScanEvidence.footerMatch,
                }.contains(evidence),
              ),
        )
        .map(
          (ScanCandidate candidate) => candidate.card.name.trim().toLowerCase(),
        )
        .toSet();
    return names.length == 1 && names.single.isNotEmpty;
  }

  bool get hasCardEvidence => _cardEvidenceAt != null || hasCatalogMatch;

  ScanCrop get crop => ScanCrop(
    imagePath: '',
    width: 1000,
    height: 1400,
    rectified: !_warnings.contains('partial_card'),
    sourceCorners: corners,
    lines: _lines,
    warnings: _warnings,
  );
}

final class LiveCaptureObservation {
  const LiveCaptureObservation._(
    this.captureId,
    this.id,
    this.crop,
    this.photoCaptureId,
  );

  final String captureId;
  final String id;
  final ScanCrop crop;
  final String photoCaptureId;
  String get receiptId => 'live_${captureId}_$id';
  bool get isRefinement => photoCaptureId != captureId;
}

class LiveCaptureSnapshot {
  static final math.Random _ids = math.Random.secure();
  final String captureId = List<String>.generate(
    16,
    (int _) => _ids.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final LiveScanTracker _owner;
  final int _generation;
  final int _captureGeneration;
  final DateTime _created;
  final int _frameSequence;
  final List<_CaptureTarget> _targets;
  final List<_CaptureTarget> _recoveryTargets;
  final List<_CaptureGeometry> _physicalGeometry;
  final bool _geometryOnly;
  final List<ScanCrop> _rearmedMissing = <ScanCrop>[];
  DateTime? _acknowledgedAt;
  bool _sceneChanged = false;
  Future<int>? _liveIdentification;
  bool _liveIdentificationInFlight = false;
  Set<String>? _admittedLiveIds;
  Future<bool>? _observationRetention;
  bool _observationRetentionFailed = false;
  final List<LiveCaptureObservation> _retainedObservations =
      <LiveCaptureObservation>[];
  final Set<String> _failedLiveIds = <String>{};
  final Map<String, ({String id, ScanCrop crop, ScanResolution resolution})>
  _resolvedLiveCrops =
      <String, ({String id, ScanCrop crop, ScanResolution resolution})>{};
  final List<({String id, ScanCrop crop, ScanResolution resolution})>
  _retainedCrops = <({String id, ScanCrop crop, ScanResolution resolution})>[];
  final List<({String id, ScanCrop crop, ScanResolution resolution})>
  _identifiedCrops =
      <({String id, ScanCrop crop, ScanResolution resolution})>[];

  LiveCaptureSnapshot._(
    this._owner,
    this._generation,
    this._captureGeneration,
    this._created,
    this._frameSequence,
    this._targets,
    this._recoveryTargets,
    this._physicalGeometry,
    this._geometryOnly,
  );

  bool get liveRetentionFailed =>
      _failedLiveIds.isNotEmpty || _observationRetentionFailed;
  List<LiveCaptureObservation> get retainedObservations =>
      List<LiveCaptureObservation>.unmodifiable(_retainedObservations);
  List<({String id, ScanCrop crop, ScanResolution resolution})>
  get retainedCrops =>
      List<
        ({String id, ScanCrop crop, ScanResolution resolution})
      >.unmodifiable(_retainedCrops);

  bool get isEmpty => _targets.isEmpty;
  int get count => _targets.length;
  List<ScanCrop> get crops => List<ScanCrop>.unmodifiable(
    _targets.map((_CaptureTarget target) => target.crop),
  );

  List<({String receiptId, String trackId})> get photoReceipts =>
      List<({String receiptId, String trackId})>.unmodifiable(
        _targets.map(
          (_CaptureTarget target) => (
            receiptId:
                target.origin?.receiptId ?? 'live_${captureId}_${target.id}',
            trackId: target.photoFeedbackId,
          ),
        ),
      );

  List<({String receiptId, String trackId})> get retainedIdentityReceipts =>
      List<({String receiptId, String trackId})>.unmodifiable(
        _targets
            .where(
              (_CaptureTarget target) =>
                  _retainedCrops.any((receipt) => receipt.id == target.id),
            )
            .map(
              (_CaptureTarget target) => (
                receiptId:
                    target.origin?.receiptId ??
                    'live_${captureId}_${target.id}',
                trackId: target.photoFeedbackId,
              ),
            ),
      );

  List<({String id, ScanCrop crop, ScanResolution resolution})>
  get identifiedCrops =>
      List<
        ({String id, ScanCrop crop, ScanResolution resolution})
      >.unmodifiable(_identifiedCrops);
}

class _CaptureTarget {
  final String id;
  final String photoFeedbackId;
  final ScanCrop crop;
  final DateTime? proofAt;
  final bool geometryConfirmed;
  final ScanResolution? historicalResolution;
  final LiveCaptureObservation? origin;

  const _CaptureTarget(
    this.id,
    this.crop, {
    required this.photoFeedbackId,
    this.proofAt,
    this.geometryConfirmed = false,
    this.historicalResolution,
    this.origin,
  });
}

class _CaptureGeometry {
  final List<ScanPoint> corners;
  final List<ScanCrop> observations = <ScanCrop>[];
  DateTime? missingSince;
  bool removed = false;

  _CaptureGeometry(List<ScanPoint> corners)
    : corners = List<ScanPoint>.unmodifiable(corners);
}

class _RecentCaptureProof {
  final _CaptureTarget target;
  final DateTime observedAt;

  const _RecentCaptureProof(this.target, this.observedAt);
}

class _PendingCapturedTarget {
  final _CaptureTarget target;
  final DateTime savedAt;

  const _PendingCapturedTarget(this.target, this.savedAt);
}

class _MissingCaptureRetry {
  final ScanCrop crop;
  int attempts = 0;
  DateTime? missingSince;

  _MissingCaptureRetry(this.crop);
}

class _CaptureConflict {
  final ScanCrop crop;
  final int frameSequence;
  final DateTime observedAt;

  const _CaptureConflict(this.crop, this.frameSequence, this.observedAt);
}

class _CompletedFootprint {
  final String id;
  final LiveCaptureSnapshot? capture;
  ScanCrop savedCrop;
  DateTime? identifiedAt;
  final List<ScanPoint> corners;
  DateTime lastPresence;
  DateTime? missingSince;
  List<double>? baseline;
  List<double>? settling;
  int settledFrames = 0;
  int changedFrames = 0;
  int backgroundFrames = 0;
  DateTime? changeStarted;
  bool awaitingPresenceObservation = false;

  _CompletedFootprint(
    LiveScanTrack track,
    this.savedCrop,
    DateTime now, {
    bool identified = true,
    this.capture,
  }) : id = track.id,
       identifiedAt = identified ? now : null,
       corners = List<ScanPoint>.unmodifiable(track.corners),
       lastPresence = now;
}

class LiveScanTracker extends ChangeNotifier {
  LiveScanTracker({
    ScanResolver? resolver,
    DateTime Function()? clock,
    this.expiry = const Duration(milliseconds: 1400),
    this.retireIdentified = false,
  }) : _resolver = resolver ?? ScanResolver(),
       _ownsResolver = resolver == null,
       _clock = clock ?? DateTime.now {
    _expiryTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_prune()) notifyListeners();
    });
  }

  final ScanResolver _resolver;
  final bool _ownsResolver;
  final DateTime Function() _clock;
  final Duration expiry;
  final bool retireIdentified;
  final List<_CompletedFootprint> _completed = <_CompletedFootprint>[];
  final LinkedHashSet<LiveCaptureSnapshot> _acknowledgedCaptures =
      LinkedHashSet<LiveCaptureSnapshot>();
  final LinkedHashMap<String, DateTime> _releasedCompletions =
      LinkedHashMap<String, DateTime>();
  final Map<String, ScanCrop> _releasedSaved = <String, ScanCrop>{};
  bool _appearanceSamplingSupported = false;
  final List<LiveScanTrack> _tracks = <LiveScanTrack>[];
  final List<_PendingCapturedTarget> _pendingCaptured =
      <_PendingCapturedTarget>[];
  final List<_MissingCaptureRetry> _missingCaptureRetries =
      <_MissingCaptureRetry>[];
  final List<_RecentCaptureProof> _recentProofs = <_RecentCaptureProof>[];
  final List<_CaptureConflict> _captureConflicts = <_CaptureConflict>[];
  List<List<ScanPoint>> _currentGeometry = <List<ScanPoint>>[];
  List<LiveCardDetection> _currentDetections = <LiveCardDetection>[];
  DateTime? _geometryAt;
  DateTime? _currentFrameStartedAt;
  DateTime? _emptySceneStarted;
  int _lastRemovalSequence = 0;
  final LinkedHashMap<String, ScanResolution> _cache =
      LinkedHashMap<String, ScanResolution>();
  final Map<int, DateTime> _frameAnalyses = <int, DateTime>{};
  static const Duration _maximumAnalysisGrace = Duration(seconds: 8);
  static const Duration _maximumCaptureGrace = Duration(seconds: 30);
  static const Duration _maximumRestartGrace = Duration(seconds: 8);
  static const Duration _maximumTextGap = Duration(seconds: 6);
  static const Duration _maximumCapturedTextGap = Duration(seconds: 30);
  static const Duration _maximumFocusProofAge = Duration(seconds: 12);
  DateTime? _captureStarted;
  DateTime? _restartStarted;
  int _captureGeneration = 0;
  late final Timer _expiryTimer;
  bool _disposed = false;
  bool _observationsSuspended = false;
  int? _drainingGeneration;
  int _lookupGeneration = 0;
  int _nextId = 0;
  int _nextAnalysis = 0;
  int _generation = 0;
  int _frameSequence = 0;
  final Map<String, String> _recoveryDiagnostics = <String, String>{};
  final Map<String, String> _identificationDiagnostics = <String, String>{};

  List<LiveScanTrack> get tracks => List<LiveScanTrack>.unmodifiable(
    _tracks.where((LiveScanTrack track) => track.hasCardEvidence),
  );

  List<LiveScanTrack> get uncapturedTracks => List<LiveScanTrack>.unmodifiable(
    tracks.where((LiveScanTrack track) => !track.captured),
  );

  List<LiveScanExcludedRegion> get completedFootprints =>
      !_appearanceSamplingSupported
      ? const <LiveScanExcludedRegion>[]
      : List<LiveScanExcludedRegion>.unmodifiable(
          _completed
              .where(
                (_CompletedFootprint completed) =>
                    completed.identifiedAt != null,
              )
              .map(
                (_CompletedFootprint completed) => LiveScanExcludedRegion(
                  id: completed.id,
                  corners: List<ScanPoint>.unmodifiable(completed.corners),
                ),
              ),
        );

  List<LiveScanExcludedRegion> get savedFootprints =>
      List<LiveScanExcludedRegion>.unmodifiable(
        _completed.map(
          (_CompletedFootprint completed) => LiveScanExcludedRegion(
            id: completed.id,
            corners: List<ScanPoint>.unmodifiable(completed.corners),
          ),
        ),
      );

  bool get completionCapacityAvailable =>
      !retireIdentified ||
      (_completed.length < 8 && _acknowledgedCaptures.length < 8);

  bool isCompleted(List<ScanPoint> corners) => _completed.any(
    (_CompletedFootprint completed) =>
        completed.identifiedAt != null &&
        (_captureGeometryMatches(completed.corners, corners) ||
            _recoveryGeometryMatches(completed.corners, corners)),
  );

  bool isSaved(List<ScanPoint> corners) => _completed.any(
    (_CompletedFootprint completed) =>
        _captureGeometryMatches(completed.corners, corners) ||
        _recoveryGeometryMatches(completed.corners, corners),
  );

  List<LiveScanTrack> get eligibleTracks => List<LiveScanTrack>.unmodifiable(
    uncapturedTracks.where(
      (LiveScanTrack track) =>
          completionCapacityAvailable &&
          track.stableFrames >= 2 &&
          _trackCaptureProof(track) &&
          _clock().difference(track.lastSeen) <= expiry &&
          !isSaved(track.corners),
    ),
  );

  List<ScanCrop> get recentFocusCrops {
    final DateTime now = _clock();
    final List<ScanCrop> crops = <ScanCrop>[];
    for (final _RecentCaptureProof proof in _recentProofs.reversed) {
      if (isSaved(proof.target.crop.sourceCorners) ||
          proof.target.proofAt == null ||
          now.difference(proof.target.proofAt!) > _maximumFocusProofAge ||
          !_targetCaptureProof(proof.target) ||
          _captureConflicts.any(
            (_CaptureConflict conflict) =>
                conflict.observedAt.isAfter(proof.observedAt) &&
                _recoveryGeometryMatches(
                  proof.target.crop.sourceCorners,
                  conflict.crop.sourceCorners,
                ) &&
                _captureContradiction(proof.target.crop, conflict.crop),
          ) ||
          crops.any(
            (ScanCrop crop) => _captureGeometryMatches(
              crop.sourceCorners,
              proof.target.crop.sourceCorners,
            ),
          )) {
        continue;
      }
      crops.add(proof.target.crop);
      if (crops.length == 5) {
        break;
      }
    }
    return List<ScanCrop>.unmodifiable(crops);
  }

  _CaptureTarget _freezeTarget(
    LiveScanTrack track, {
    bool geometryConfirmed = false,
  }) {
    final ScanCrop crop = track.crop;
    return _CaptureTarget(
      track.id,
      ScanCrop(
        imagePath: crop.imagePath,
        width: crop.width,
        height: crop.height,
        rectified: crop.rectified,
        sourceCorners: List<ScanPoint>.unmodifiable(crop.sourceCorners),
        lines: List<ScanTextLine>.unmodifiable(crop.lines),
        warnings: List<String>.unmodifiable(crop.warnings),
        sharpness: crop.sharpness,
      ),
      origin: track._recoveryObservation,
      photoFeedbackId: track.photoFeedbackId,
      proofAt: track._captureProofAt,
      geometryConfirmed: geometryConfirmed,
      historicalResolution:
          track.resolution != null &&
              verifiedLiveHistoricalBodyIdentity(crop, track.resolution!) !=
                  null
          ? track.resolution
          : null,
    );
  }

  LiveCaptureSnapshot snapshotCapture({
    Set<String>? targetIds,
    Iterable<List<ScanPoint>> currentGeometry = const <List<ScanPoint>>[],
    Iterable<List<ScanPoint>> blockedRegions = const <List<ScanPoint>>[],
    bool geometryOnly = false,
  }) {
    _prune();
    final Set<String>? selectedIds = geometryOnly
        ? const <String>{}
        : targetIds;
    final List<List<ScanPoint>> blocked = blockedRegions.toList();
    bool isBlocked(List<ScanPoint> corners) => blocked.any(
      (List<ScanPoint> region) =>
          _acknowledgedFootprintMatches(region, corners),
    );
    final List<_CaptureTarget> targets = uncapturedTracks
        .where(
          (LiveScanTrack track) =>
              completionCapacityAvailable &&
              (selectedIds == null || selectedIds.contains(track.id)) &&
              !isSaved(track.corners) &&
              !isBlocked(track.corners),
        )
        .map((LiveScanTrack track) {
          final _RecentCaptureProof? proof = _recentProofs
              .where(
                (_RecentCaptureProof proof) =>
                    proof.target.id == track.id &&
                    _targetCaptureProof(proof.target) &&
                    !_captureContradiction(proof.target.crop, track.crop),
              )
              .firstOrNull;
          final bool confirmed = currentGeometry.any(
            (List<ScanPoint> corners) =>
                _captureGeometryMatches(track.corners, corners),
          );
          if (proof == null) {
            return _freezeTarget(track, geometryConfirmed: confirmed);
          }
          final ScanCrop crop = proof.target.crop;
          return _CaptureTarget(
            track.id,
            ScanCrop(
              imagePath: crop.imagePath,
              width: crop.width,
              height: crop.height,
              rectified: crop.rectified,
              sourceCorners: List<ScanPoint>.unmodifiable(track.corners),
              lines: crop.lines,
              warnings: crop.warnings,
              sharpness: crop.sharpness,
            ),
            origin: track._recoveryObservation,
            photoFeedbackId: track.photoFeedbackId,
            proofAt: proof.target.proofAt,
            geometryConfirmed: confirmed,
            historicalResolution: proof.target.historicalResolution,
          );
        })
        .toList();
    for (final _RecentCaptureProof proof in _recentProofs) {
      if (targets.length >= 8) break;
      if (!completionCapacityAvailable ||
          (selectedIds != null && !selectedIds.contains(proof.target.id)) ||
          isBlocked(proof.target.crop.sourceCorners) ||
          isSaved(proof.target.crop.sourceCorners) ||
          proof.target.proofAt == null ||
          !_targetCaptureProof(proof.target) ||
          _clock().difference(proof.target.proofAt!) >
              _maximumCapturedTextGap ||
          _pendingCaptured.any(
            (_PendingCapturedTarget pending) =>
                pending.target.id == proof.target.id,
          ) ||
          _tracks.any(
            (LiveScanTrack track) =>
                track.captured &&
                _captureGeometryMatches(
                  proof.target.crop.sourceCorners,
                  track.corners,
                ),
          ) ||
          targets.any(
            (_CaptureTarget target) => _captureGeometryMatches(
              proof.target.crop.sourceCorners,
              target.crop.sourceCorners,
            ),
          ) ||
          !currentGeometry.any(
            (List<ScanPoint> corners) => _captureGeometryMatches(
              proof.target.crop.sourceCorners,
              corners,
            ),
          )) {
        continue;
      }
      targets.add(
        _CaptureTarget(
          proof.target.id,
          proof.target.crop,
          photoFeedbackId: proof.target.photoFeedbackId,
          proofAt: proof.target.proofAt,
          geometryConfirmed: true,
          historicalResolution: proof.target.historicalResolution,
        ),
      );
      if (targets.length == 8) break;
    }
    final List<_CaptureTarget> strongTargets = targets
        .where(
          (_CaptureTarget target) =>
              target.proofAt != null && _targetCaptureProof(target),
        )
        .toList();
    targets.removeWhere((_CaptureTarget target) {
      if (_targetCaptureProof(target)) {
        return false;
      }
      final List<_CaptureTarget> owners = strongTargets
          .where(
            (_CaptureTarget other) =>
                !identical(other, target) &&
                _weakAdmittedInset(other.crop, target.crop),
          )
          .toList();
      return owners.length == 1;
    });
    if (const bool.fromEnvironment('PHYSICAL_CARD_QA')) {
      final DateTime now = _clock();
      Map<String, double> bounds(List<ScanPoint> corners) {
        final _CardBounds value = _bounds(corners);
        return <String, double>{
          'left': value.left,
          'top': value.top,
          'right': value.right,
          'bottom': value.bottom,
        };
      }

      debugPrint(
        'CAPTURE_DIAGNOSTIC:${jsonEncode(<String, Object?>{
          'targets': targets.map((_CaptureTarget target) => target.id).toList(),
          'proofs': _recentProofs.map((_RecentCaptureProof proof) => <String, Object?>{'id': proof.target.id, 'proofAgeMs': proof.target.proofAt == null ? null : now.difference(proof.target.proofAt!).inMilliseconds, 'strong': _targetCaptureProof(proof.target), 'geometryConfirmed': currentGeometry.any((List<ScanPoint> corners) => _captureGeometryMatches(proof.target.crop.sourceCorners, corners)), 'bounds': bounds(proof.target.crop.sourceCorners)}).toList(),
          'tracks': _tracks.map((LiveScanTrack track) => <String, Object?>{'id': track.id, 'proofAgeMs': track._captureProofAt == null ? null : now.difference(track._captureProofAt!).inMilliseconds, 'strong': _trackCaptureProof(track), 'geometryConfirmed': currentGeometry.any((List<ScanPoint> corners) => _captureGeometryMatches(track.corners, corners)), 'bounds': bounds(track.corners)}).toList(),
          'geometry': currentGeometry.where((List<ScanPoint> corners) => corners.length == 4).take(16).map(bounds).toList(),
        })}',
      );
    }
    final List<_CaptureGeometry> physical = <_CaptureGeometry>[];
    if (_geometryAt != null && _clock().difference(_geometryAt!) <= expiry) {
      final List<List<ScanPoint>> observed =
          <List<ScanPoint>>[
                ...currentGeometry,
                if (!geometryOnly) ..._currentGeometry,
              ]
              .where(
                (List<ScanPoint> corners) =>
                    corners.length == 4 &&
                    corners.every(
                      (ScanPoint point) =>
                          point.x.isFinite &&
                          point.y.isFinite &&
                          point.x >= 0 &&
                          point.x <= 1 &&
                          point.y >= 0 &&
                          point.y <= 1,
                    ),
              )
              .toList()
            ..sort(
              (List<ScanPoint> a, List<ScanPoint> b) =>
                  _bounds(b).area.compareTo(_bounds(a).area),
            );
      for (final List<ScanPoint> corners in observed) {
        if (corners.length != 4 ||
            corners.any(
              (ScanPoint point) =>
                  !point.x.isFinite ||
                  !point.y.isFinite ||
                  point.x < 0 ||
                  point.x > 1 ||
                  point.y < 0 ||
                  point.y > 1,
            ) ||
            _bounds(corners).area <= 0 ||
            isSaved(corners) ||
            (geometryOnly && isBlocked(corners)) ||
            (!geometryOnly &&
                selectedIds != null &&
                !targets.any(
                  (_CaptureTarget target) => _acknowledgedFootprintMatches(
                    target.crop.sourceCorners,
                    corners,
                  ),
                )) ||
            physical.any(
              (_CaptureGeometry previous) =>
                  _captureGeometryMatches(previous.corners, corners),
            )) {
          continue;
        }
        final _CaptureGeometry region = _CaptureGeometry(corners);
        for (final LiveCardDetection detection in _currentDetections) {
          if (detection.lines.isNotEmpty &&
              _acknowledgedFootprintMatches(corners, detection.corners)) {
            region.observations.add(_detectionCrop(detection));
          }
        }
        physical.add(region);
        if (physical.length == 8) {
          break;
        }
      }
    }
    return LiveCaptureSnapshot._(
      this,
      _generation,
      _captureGeneration,
      _clock(),
      _frameSequence,
      List<_CaptureTarget>.unmodifiable(targets),
      List<_CaptureTarget>.unmodifiable(
        _recentProofs
            .where(
              (_RecentCaptureProof proof) =>
                  !isSaved(proof.target.crop.sourceCorners) &&
                  (selectedIds == null ||
                      selectedIds.contains(proof.target.id)) &&
                  !isBlocked(proof.target.crop.sourceCorners) &&
                  proof.target.proofAt != null &&
                  _clock().difference(proof.target.proofAt!) <=
                      _maximumFocusProofAge &&
                  _targetCaptureProof(proof.target),
            )
            .map((_RecentCaptureProof proof) => proof.target),
      ),
      List<_CaptureGeometry>.unmodifiable(physical),
      geometryOnly,
    );
  }

  void _rememberProof(LiveScanTrack track, DateTime now) {
    final _RecentCaptureProof? previous = _recentProofs
        .where((_RecentCaptureProof proof) => proof.target.id == track.id)
        .firstOrNull;
    if (previous != null &&
        _targetCaptureProof(previous.target) &&
        (!_trackCaptureProof(track) ||
            track._captureProofAt == null ||
            (previous.target.proofAt != null &&
                !track._captureProofAt!.isAfter(previous.target.proofAt!))) &&
        !_captureContradiction(previous.target.crop, track.crop)) {
      return;
    }
    _recentProofs.removeWhere(
      (_RecentCaptureProof proof) =>
          proof.target.id == track.id ||
          (_captureGeometryMatches(
                proof.target.crop.sourceCorners,
                track.corners,
              ) &&
              (_captureIdentityMatches(proof.target.crop, track.crop) ||
                  _captureContradiction(proof.target.crop, track.crop))),
    );
    if (track.captured) return;
    if (_recentProofs.length == 8) _recentProofs.removeAt(0);
    _recentProofs.add(_RecentCaptureProof(_freezeTarget(track), now));
  }

  int markCaptured(LiveCaptureSnapshot snapshot) {
    final DateTime now = _clock();
    if (_disposed ||
        _observationsSuspended ||
        snapshot._owner != this ||
        snapshot._generation != _generation ||
        !_validCapture(snapshot) ||
        now.difference(snapshot._created) > _maximumCaptureGrace) {
      return 0;
    }
    _prune();
    if (retireIdentified &&
        !_acknowledgedCaptures.contains(snapshot) &&
        _acknowledgedCaptures.length == 8) {
      return 0;
    }
    snapshot._acknowledgedAt ??= now;
    if (retireIdentified) _acknowledgedCaptures.add(snapshot);
    int marked = 0;
    for (final _CaptureTarget target in snapshot._targets) {
      if (_missingWasRearmed(snapshot, target.crop)) {
        continue;
      }
      final LiveScanTrack? track = _tracks
          .where((LiveScanTrack track) => track.id == target.id)
          .firstOrNull;
      if (track == null) {
        final DateTime? proofAt = target.proofAt;
        final bool admittedCapture =
            _captureStarted != null &&
            now.difference(_captureStarted!) <= _maximumCaptureGrace &&
            proofAt != null &&
            snapshot._created.difference(proofAt) <= _maximumCapturedTextGap;
        final bool restoreKnown =
            target.geometryConfirmed &&
            snapshot._frameSequence == _frameSequence &&
            proofAt != null &&
            (now.difference(proofAt) <= _maximumCapturedTextGap ||
                admittedCapture) &&
            _targetCaptureProof(target) &&
            (admittedCapture ||
                _recentProofs.any(
                  (_RecentCaptureProof proof) =>
                      proof.target.id == target.id &&
                      !_captureContradiction(proof.target.crop, target.crop),
                )) &&
            !_tracks.any(
              (LiveScanTrack other) => _captureGeometryMatches(
                target.crop.sourceCorners,
                other.corners,
              ),
            );
        if (restoreKnown && _makeTrackRoom()) {
          final LiveScanTrack restored = LiveScanTrack(
            id: target.id,
            detection: LiveCardDetection(
              confidence: .85,
              corners: target.crop.sourceCorners,
              lines: target.crop.lines,
              warnings: target.crop.warnings,
            ),
            lastSeen: now,
          );
          restored._cardEvidenceAt = now;
          restored._captureProofAt = proofAt;
          restored._capturedAt = now;
          restored._capturedCrop = target.crop;
          _tracks.add(restored);
          _pendingCaptured.removeWhere(
            (_PendingCapturedTarget pending) => pending.target.id == target.id,
          );
          marked++;
          continue;
        }
        if ((proofAt != null &&
                now.difference(proofAt) > _maximumCapturedTextGap) ||
            (target.geometryConfirmed &&
                snapshot._frameSequence != _frameSequence)) {
          continue;
        }
        if (_pendingCaptured.any(
          (_PendingCapturedTarget pending) => pending.target.id == target.id,
        )) {
          continue;
        }
        if (_pendingCaptured.length == 8) _pendingCaptured.removeAt(0);
        _pendingCaptured.add(_PendingCapturedTarget(target, now));
      } else if (!track.captured &&
          _captureGeometryMatches(target.crop.sourceCorners, track.corners) &&
          !_captureContradiction(target.crop, track.crop)) {
        track._capturedAt = now;
        track._capturedCrop = target.crop;
        track._capturedIdentified = false;
        track._identifiedSavedResolution = null;
        track._cardEvidenceAt = now;
        marked++;
      }
    }
    if (retireIdentified) {
      for (final LiveScanTrack track in _tracks) {
        final ScanCrop? receipt = track._capturedCrop;
        if (_completed.length >= 8) {
          break;
        }
        if (track._capturedAt != snapshot._acknowledgedAt ||
            receipt == null ||
            !(_strongCaptureProof(receipt) ||
                snapshot._targets.any(
                  (_CaptureTarget target) =>
                      target.id == track.id &&
                      target.historicalResolution != null &&
                      verifiedLiveHistoricalBodyIdentity(
                            receipt,
                            target.historicalResolution!,
                          ) !=
                          null,
                )) ||
            !snapshot._targets.any(
              (_CaptureTarget target) =>
                  target.id == track.id &&
                  _targetCaptureProof(target) &&
                  _captureIdentityMatches(target.crop, receipt),
            ) ||
            _completed.any(
              (_CompletedFootprint completed) => completed.id == track.id,
            )) {
          continue;
        }
        _completed.add(
          _CompletedFootprint(
            track,
            receipt,
            now,
            identified: false,
            capture: snapshot,
          ),
        );
      }
    }
    if (marked > 0) notifyListeners();
    return marked;
  }

  bool _admitCapturedLive(LiveCaptureSnapshot capture) {
    if (capture._owner != this) return false;
    if (capture._admittedLiveIds != null) return true;
    if (!canFocusSavedCapture(capture)) return false;
    capture._admittedLiveIds = capture._targets
        .where(
          (_CaptureTarget target) =>
              _targetCaptureProof(target) &&
              _tracks
                      .where(
                        (LiveScanTrack track) =>
                            track.id == target.id &&
                            track.captured &&
                            !_captureContradiction(target.crop, track.crop) &&
                            ownsFrozenRegion(
                              capture,
                              target.crop.sourceCorners,
                              currentCorners: track.corners,
                            ),
                      )
                      .length ==
                  1,
        )
        .map((_CaptureTarget target) => target.id)
        .toSet();
    return true;
  }

  Future<bool> retainCapturedObservations(
    LiveCaptureSnapshot capture, {
    required Future<bool> Function(List<LiveCaptureObservation>) retain,
  }) {
    if (!_admitCapturedLive(capture)) return Future<bool>.value(false);
    final Future<bool>? pending = capture._observationRetention;
    if (pending != null) return pending;
    final List<LiveCaptureObservation> observations =
        List<LiveCaptureObservation>.unmodifiable(
          capture._targets
              .where(
                (_CaptureTarget target) =>
                    capture._admittedLiveIds!.contains(target.id) &&
                    _targetCaptureProof(target),
              )
              .map(
                (_CaptureTarget target) => LiveCaptureObservation._(
                  target.origin?.captureId ?? capture.captureId,
                  target.origin?.id ?? target.id,
                  target.crop,
                  capture.captureId,
                ),
              ),
        );
    final Future<bool> job =
        (() async {
          bool saved = observations.isEmpty;
          try {
            if (observations.isNotEmpty) saved = await retain(observations);
          } catch (_) {
            saved = false;
          }
          return saved;
        })().then<bool>((bool saved) {
          capture._observationRetentionFailed = !saved;
          if (saved) {
            capture._retainedObservations
              ..clear()
              ..addAll(observations);
          } else {
            capture._observationRetention = null;
          }
          return saved;
        });
    capture._observationRetention = job;
    return job;
  }

  Future<int> identifyCapturedLive(
    LiveCaptureSnapshot capture, {
    Future<bool> Function(
      ({String id, ScanCrop crop, ScanResolution resolution}),
    )?
    retain,
    bool retryFailed = false,
  }) {
    if (!_admitCapturedLive(capture)) return Future<int>.value(0);
    final Future<int>? previous = capture._liveIdentification;
    if (previous != null &&
        (capture._liveIdentificationInFlight ||
            !retryFailed ||
            !capture.liveRetentionFailed)) {
      return previous;
    }
    capture._liveIdentificationInFlight = true;
    final Future<int> job = _identifyCapturedLive(capture, retain).whenComplete(
      () {
        capture._liveIdentificationInFlight = false;
      },
    );
    capture._liveIdentification = job;
    return job;
  }

  Future<int> _identifyCapturedLive(
    LiveCaptureSnapshot capture,
    Future<bool> Function(
      ({String id, ScanCrop crop, ScanResolution resolution}),
    )?
    retain,
  ) async {
    int identified = 0;
    for (final _CaptureTarget target in capture._targets) {
      if (!capture._admittedLiveIds!.contains(target.id) ||
          capture._retainedCrops.any((receipt) => receipt.id == target.id) ||
          hasConflictingScanTitle(target.crop) ||
          !_targetCaptureProof(target)) {
        continue;
      }
      try {
        final String key = _evidenceKey(target.crop);
        final ScanResolution resolution =
            capture._resolvedLiveCrops[target.id]?.resolution ??
            target.historicalResolution ??
            _cache[key] ??
            await _resolver.resolve(target.crop);
        if (resolution.status == ScanResolutionStatus.noMatch) {
          continue;
        }
        final String? historicalIdentity = verifiedLiveHistoricalBodyIdentity(
          target.crop,
          resolution,
        );
        final List<ScanCandidate> supported = resolution.candidates
            .where(
              (ScanCandidate candidate) =>
                  !candidate.hasContradiction &&
                  (historicalIdentity != null
                      ? candidate.card.name == historicalIdentity
                      : candidate.evidence.contains(ScanEvidence.nameMatch) &&
                            candidate.evidence.any(
                              (ScanEvidence evidence) => const <ScanEvidence>{
                                ScanEvidence.typeLineMatch,
                                ScanEvidence.rulesTextMatch,
                                ScanEvidence.footerMatch,
                              }.contains(evidence),
                            )),
            )
            .toList();
        if (supported.isEmpty ||
            supported
                    .map((ScanCandidate candidate) => candidate.card.name)
                    .toSet()
                    .length !=
                1) {
          continue;
        }
        final ScanResolution identity = ScanResolution(
          candidates: supported,
          hints: resolution.hints,
          status: ScanResolutionStatus.needsReview,
          hasMore: resolution.hasMore,
          page: resolution.page,
          historicalBodyIdentityProof: resolution.historicalBodyIdentityProof,
        );
        final ({String id, ScanCrop crop, ScanResolution resolution}) receipt =
            (id: target.id, crop: target.crop, resolution: identity);
        capture._resolvedLiveCrops[target.id] = receipt;
        if (retain != null && !await retain(receipt)) {
          capture._failedLiveIds.add(target.id);
          continue;
        }
        capture._failedLiveIds.remove(target.id);
        capture._retainedCrops.add(receipt);
        if (!canFocusSavedCapture(capture)) continue;
        if (identifyCaptured(target.crop, identity, capture: capture) > 0) {
          capture._identifiedCrops.add(receipt);
          identified++;
        }
      } catch (_) {
        capture._failedLiveIds.add(target.id);
      }
    }
    return identified;
  }

  int identifyCaptured(
    ScanCrop savedCrop,
    ScanResolution savedResolution, {
    LiveCaptureSnapshot? capture,
  }) {
    if (_disposed ||
        _observationsSuspended ||
        hasConflictingScanTitle(savedCrop) ||
        _tracks.any(
          (LiveScanTrack track) =>
              hasConflictingScanTitle(track.crop) &&
              _recoveryGeometryMatches(savedCrop.sourceCorners, track.corners),
        ) ||
        _currentDetections.any(
          (LiveCardDetection detection) =>
              hasConflictingScanTitle(_detectionCrop(detection)) &&
              _recoveryGeometryMatches(
                savedCrop.sourceCorners,
                detection.corners,
              ),
        ) ||
        (retireIdentified && capture == null) ||
        savedResolution.status == ScanResolutionStatus.noMatch ||
        (capture != null &&
            (capture._owner != this ||
                capture._generation != _generation ||
                !_validCapture(capture) ||
                capture._acknowledgedAt == null ||
                (capture._geometryOnly &&
                    (!_savedCaptureGeometryProof(savedCrop) ||
                        !corroboratesSavedIdentity(capture, savedCrop))) ||
                _missingWasRearmed(capture, savedCrop)))) {
      return 0;
    }
    final String? savedSelfReference = ScanHints.observedSavedBodySelfReference(
      savedCrop,
    );
    if (savedSelfReference != null &&
        verifiedSavedSelfReferenceIdentity(savedCrop, savedResolution) ==
            null) {
      return 0;
    }
    final String? historicalIdentity =
        verifiedHistoricalBodyIdentity(savedCrop, savedResolution) ??
        verifiedLiveHistoricalBodyIdentity(savedCrop, savedResolution);
    final List<ScanCandidate> supported = savedResolution.candidates
        .where(
          (ScanCandidate candidate) =>
              !candidate.hasContradiction &&
              (historicalIdentity != null
                  ? candidate.card.name == historicalIdentity
                  : candidate.evidence.any(
                      (ScanEvidence evidence) => const <ScanEvidence>{
                        ScanEvidence.nameMatch,
                        ScanEvidence.footerMatch,
                        ScanEvidence.rulesTextMatch,
                      }.contains(evidence),
                    )),
        )
        .toList();
    if (supported.isEmpty) return 0;
    final ScanCandidate first = supported.first;
    if (!first.evidence.contains(ScanEvidence.nameMatch) &&
        !first.evidence.contains(ScanEvidence.footerMatch) &&
        historicalIdentity == null &&
        (savedResolution.hasMore ||
            supported.any(
              (ScanCandidate candidate) =>
                  candidate.card.name != first.card.name,
            ))) {
      return 0;
    }
    _prune();
    if (savedSelfReference != null) {
      if (capture == null) return 0;
      final ScanHints savedHints = ScanHints.fromCrop(savedCrop);
      // Current owned geometry supplies presence when retained text does not
      // qualify for the generic geometry refresh.
      final List<LiveScanTrack> currentOwners = _tracks
          .where(
            (LiveScanTrack track) =>
                track._capturedAt == capture._acknowledgedAt &&
                _savedCaptureGeometryMatches(savedCrop, track.crop) &&
                !_captureContradiction(savedCrop, track.crop) &&
                _corroboratedBodySelfReference(
                  savedCrop,
                  track.crop,
                  savedHints,
                  ScanHints.fromCrop(track.crop),
                ) &&
                ownsFrozenRegion(
                  capture,
                  savedCrop.sourceCorners,
                  currentCorners: track.corners,
                ),
          )
          .toList();
      if (currentOwners.length != 1) return 0;
    }
    if (historicalIdentity != null &&
        <ScanCrop>[
          ..._currentDetections.map(_detectionCrop),
          ..._tracks.map((LiveScanTrack track) => track.crop),
        ].any(
          (ScanCrop observed) =>
              (_recoveryGeometryMatches(
                    savedCrop.sourceCorners,
                    observed.sourceCorners,
                  ) ||
                  _historicalOwnedInsetMatches(
                    savedCrop,
                    observed.sourceCorners,
                  )) &&
              _historicalObservedTitleConflict(
                historicalIdentity,
                savedCrop,
                observed,
              ),
        )) {
      return 0;
    }
    final List<_CompletedFootprint> completedMatches = _completed
        .where(
          (_CompletedFootprint completed) =>
              completed.identifiedAt != null &&
              _captureGeometryMatches(
                savedCrop.sourceCorners,
                completed.corners,
              ) &&
              _captureIdentityMatches(savedCrop, completed.savedCrop),
        )
        .toList();
    if (completedMatches.length == 1) return 1;
    final List<LiveScanTrack> bodyMatches = capture == null
        ? <LiveScanTrack>[]
        : _tracks
              .where(
                (LiveScanTrack track) =>
                    _acknowledgedBodyIdentity(savedCrop, track, capture),
              )
              .toList();
    final List<LiveScanTrack> matching = _tracks
        .where(
          (LiveScanTrack track) =>
              track.captured &&
              !_releasedCompletions.containsKey(track.id) &&
              track._capturedCrop != null &&
              _savedCaptureGeometryMatches(savedCrop, track._capturedCrop!) &&
              (_captureIdentityMatches(savedCrop, track._capturedCrop!) ||
                  bodyMatches.contains(track)) &&
              !_captureContradiction(savedCrop, track.crop),
        )
        .toList();
    _reportIdentification(savedCrop, matching.length);
    if (matching.length > 1) return 0;
    final LiveScanTrack? track =
        matching.firstOrNull ??
        (capture == null
            ? null
            : _recoverCaptured(savedCrop, capture) ??
                  (retireIdentified
                      ? _bindSavedCurrent(
                          savedCrop,
                          capture,
                          verifiedHistoricalIdentity: historicalIdentity,
                        )
                      : null));
    if (track == null) return 0;
    if (bodyMatches.contains(track)) {
      track._capturedCrop = savedCrop;
    }
    if (track.capturedIdentified &&
        identical(track._identifiedSavedResolution, savedResolution)) {
      return 1;
    }
    track.resolution = ScanResolution(
      candidates: supported,
      hints: savedResolution.hints,
      status: savedResolution.status,
      hasMore: savedResolution.hasMore,
      page: savedResolution.page,
      historicalBodyIdentityProof: savedResolution.historicalBodyIdentityProof,
    );
    track._capturedIdentified = true;
    track._identifiedSavedResolution = savedResolution;
    track.error = null;
    if (retireIdentified) {
      final _CompletedFootprint? pending = _completed
          .where((_CompletedFootprint completed) => completed.id == track.id)
          .firstOrNull;
      if (pending == null) {
        if (_completed.length >= 8) {
          track._capturedIdentified = false;
          return 0;
        }
        _completed.add(
          _CompletedFootprint(track, savedCrop, _clock(), capture: capture),
        );
      } else {
        pending.savedCrop = savedCrop;
        pending.identifiedAt ??= _clock();
      }
    }
    notifyListeners();
    return 1;
  }

  bool canFocusSavedCapture(LiveCaptureSnapshot capture) {
    final DateTime? acknowledged = capture._acknowledgedAt;
    if (_disposed ||
        _observationsSuspended ||
        capture._owner != this ||
        capture._generation != _generation ||
        !_validCapture(capture) ||
        capture._sceneChanged ||
        acknowledged == null ||
        _lastRemovalSequence > capture._frameSequence) {
      return false;
    }
    final DateTime now = _clock();
    return now.difference(acknowledged) <= _maximumCapturedTextGap ||
        _ownedCapturePresent(capture, now);
  }

  bool ownsFrozenRegion(
    LiveCaptureSnapshot capture,
    List<ScanPoint> corners, {
    List<ScanPoint>? currentCorners,
  }) {
    if (!canFocusSavedCapture(capture) ||
        _geometryAt == null ||
        _clock().difference(_geometryAt!) > expiry) {
      return false;
    }
    final Iterable<_CaptureGeometry> matches = capture._physicalGeometry.where(
      (_CaptureGeometry region) =>
          !region.removed &&
          region.missingSince == null &&
          _acknowledgedFootprintMatches(region.corners, corners) &&
          (currentCorners == null ||
              (_acknowledgedFootprintMatches(region.corners, currentCorners) &&
                  _acknowledgedFootprintMatches(corners, currentCorners))) &&
          _currentGeometry.any(
            (List<ScanPoint> current) =>
                _acknowledgedFootprintMatches(region.corners, current) &&
                _acknowledgedFootprintMatches(corners, current) &&
                (currentCorners == null ||
                    _acknowledgedFootprintMatches(currentCorners, current)),
          ),
    );
    return currentCorners == null ? matches.isNotEmpty : matches.length == 1;
  }

  void invalidateFrozenRegion(
    LiveCaptureSnapshot capture,
    List<ScanPoint> corners,
  ) {
    if (capture._owner != this || capture._generation != _generation) {
      return;
    }
    for (final _CaptureGeometry region in capture._physicalGeometry) {
      if (_acknowledgedFootprintMatches(region.corners, corners)) {
        region.removed = true;
      }
    }
  }

  bool corroboratesSavedIdentity(LiveCaptureSnapshot capture, ScanCrop saved) {
    if (hasConflictingScanTitle(saved) ||
        !ownsFrozenRegion(capture, saved.sourceCorners) ||
        capture._acknowledgedAt == null ||
        _geometryAt == null ||
        _currentFrameStartedAt == null ||
        !_currentFrameStartedAt!.isAfter(capture._acknowledgedAt!) ||
        !_geometryAt!.isAfter(capture._acknowledgedAt!) ||
        _frameSequence <= capture._frameSequence) {
      return false;
    }
    final List<ScanCrop> current = _currentDetections
        .map(_detectionCrop)
        .where(
          (ScanCrop observed) =>
              !hasConflictingScanTitle(observed) &&
              _strongCaptureProof(observed) &&
              ownsFrozenRegion(
                capture,
                saved.sourceCorners,
                currentCorners: observed.sourceCorners,
              ) &&
              _captureIdentityMatches(saved, observed) &&
              !_captureContradiction(saved, observed),
        )
        .toList();
    return current.length == 1;
  }

  List<LiveScanTrack> rearmMissingCaptured(
    LiveCaptureSnapshot capture,
    Iterable<ScanCrop> savedCrops,
  ) {
    final DateTime now = _clock();
    final List<ScanCrop> saved = savedCrops.toList();
    if (!retireIdentified ||
        !canFocusSavedCapture(capture) ||
        _geometryAt == null ||
        now.difference(_geometryAt!) > expiry ||
        saved.any((ScanCrop crop) => crop.sourceCorners.length != 4)) {
      return const <LiveScanTrack>[];
    }
    final List<LiveScanTrack> rearmed = <LiveScanTrack>[];
    _pruneMissingCaptureRetries(now);
    for (final _CaptureTarget target in capture._targets) {
      if (_missingWasRearmed(capture, target.crop) ||
          saved.any(
            (ScanCrop crop) => _recoveryGeometryMatches(
              target.crop.sourceCorners,
              crop.sourceCorners,
            ),
          )) {
        continue;
      }
      final LiveScanTrack? track = _tracks
          .where((LiveScanTrack track) => track.id == target.id)
          .firstOrNull;
      final _CompletedFootprint? receipt = _completed
          .where(
            (_CompletedFootprint receipt) =>
                receipt.id == target.id && identical(receipt.capture, capture),
          )
          .firstOrNull;
      if (track == null ||
          receipt == null ||
          receipt.identifiedAt != null ||
          !track.captured ||
          track.capturedIdentified ||
          track._capturedAt != capture._acknowledgedAt ||
          now.difference(track.lastSeen) > expiry ||
          track.stableFrames < 2 ||
          !_targetCaptureProof(target) ||
          !_trackCaptureProof(track) ||
          !_acknowledgedFootprintMatches(
            target.crop.sourceCorners,
            track.corners,
          ) ||
          !_captureIdentityMatches(target.crop, track.crop) ||
          _captureContradiction(target.crop, track.crop) ||
          !_currentGeometry.any(
            (List<ScanPoint> corners) => _acknowledgedFootprintMatches(
              target.crop.sourceCorners,
              corners,
            ),
          ) ||
          _tracks.any(
            (LiveScanTrack other) =>
                !identical(track, other) &&
                (other.captured || _strongCaptureProof(other.crop)) &&
                _recoveryGeometryMatches(
                  target.crop.sourceCorners,
                  other.corners,
                ),
          )) {
        continue;
      }
      _MissingCaptureRetry? retry = _missingCaptureRetries
          .where(
            (_MissingCaptureRetry retry) =>
                _acknowledgedFootprintMatches(
                  retry.crop.sourceCorners,
                  target.crop.sourceCorners,
                ) &&
                _captureIdentityMatches(retry.crop, target.crop) &&
                !_captureContradiction(retry.crop, target.crop),
          )
          .firstOrNull;
      if (retry == null) {
        if (_missingCaptureRetries.length == 64) {
          continue;
        }
        retry = _MissingCaptureRetry(target.crop);
        _missingCaptureRetries.add(retry);
      }
      if (retry.attempts >= 2) {
        continue;
      }
      retry.attempts++;
      capture._rearmedMissing.add(target.crop);
      for (final _CaptureGeometry region in capture._physicalGeometry) {
        if (_recoveryGeometryMatches(
          target.crop.sourceCorners,
          region.corners,
        )) {
          region.removed = true;
        }
      }
      _completed.remove(receipt);
      _pendingCaptured.removeWhere(
        (_PendingCapturedTarget pending) => pending.target.id == target.id,
      );
      track._recoveryObservation = capture._retainedObservations
          .where((LiveCaptureObservation value) => value.id == target.id)
          .firstOrNull;
      track._invalidatePhotoFeedback();
      track._capturedAt = null;
      track._capturedCrop = null;
      track._capturedIdentified = false;
      track._identifiedSavedResolution = null;
      rearmed.add(track);
      break;
    }
    if (rearmed.isNotEmpty) {
      notifyListeners();
    }
    return List<LiveScanTrack>.unmodifiable(rearmed);
  }

  bool _missingWasRearmed(LiveCaptureSnapshot capture, ScanCrop crop) =>
      capture._rearmedMissing.any(
        (ScanCrop missing) =>
            _recoveryGeometryMatches(missing.sourceCorners, crop.sourceCorners),
      );

  void _pruneMissingCaptureRetries(DateTime now) {
    final bool freshGeometry =
        _geometryAt != null && now.difference(_geometryAt!) <= expiry;
    _missingCaptureRetries.removeWhere((_MissingCaptureRetry retry) {
      final bool present =
          freshGeometry &&
          _currentGeometry.any(
            (List<ScanPoint> corners) => _acknowledgedFootprintMatches(
              retry.crop.sourceCorners,
              corners,
            ),
          );
      final bool replacement =
          freshGeometry &&
          _currentDetections.any(
            (LiveCardDetection detection) =>
                _acknowledgedFootprintMatches(
                  retry.crop.sourceCorners,
                  detection.corners,
                ) &&
                _strongCaptureProof(_detectionCrop(detection)) &&
                _captureContradiction(retry.crop, _detectionCrop(detection)),
          );
      if (replacement) {
        return true;
      }
      if (present) {
        retry.missingSince = null;
        return false;
      }
      retry.missingSince ??= now;
      return now.difference(retry.missingSince!) > _maximumCapturedTextGap;
    });
  }

  bool _pendingReceiptPresent(LiveScanTrack track, DateTime now) =>
      retireIdentified &&
      _geometryAt != null &&
      now.difference(_geometryAt!) <= expiry &&
      _completed.any(
        (_CompletedFootprint completed) =>
            completed.id == track.id &&
            completed.identifiedAt == null &&
            completed.capture != null &&
            completed.capture!._acknowledgedAt == track._capturedAt &&
            _acknowledgedCaptures.contains(completed.capture) &&
            now.difference(completed.lastPresence) <= expiry &&
            completed.missingSince == null &&
            _savedCaptureGeometryProof(completed.savedCrop) &&
            !_captureContradiction(completed.savedCrop, track.crop) &&
            (_currentGeometry.any(
                  (List<ScanPoint> corners) =>
                      _captureGeometryMatches(completed.corners, corners) ||
                      _recoveryGeometryMatches(completed.corners, corners),
                ) ||
                (_appearanceSamplingSupported && completed.baseline != null)),
      );

  bool _ownedCapturePresent(LiveCaptureSnapshot capture, DateTime now) =>
      retireIdentified &&
      capture._owner == this &&
      capture._generation == _generation &&
      !capture._sceneChanged &&
      _acknowledgedCaptures.contains(capture) &&
      _lastRemovalSequence <= capture._frameSequence &&
      _geometryAt != null &&
      now.difference(_geometryAt!) <= expiry &&
      _completed.any(
        (_CompletedFootprint completed) =>
            identical(completed.capture, capture) &&
            completed.missingSince == null &&
            now.difference(completed.lastPresence) <= expiry &&
            _savedCaptureGeometryProof(completed.savedCrop) &&
            (_currentGeometry.any(
                  (List<ScanPoint> corners) =>
                      _captureGeometryMatches(completed.corners, corners) ||
                      _recoveryGeometryMatches(completed.corners, corners),
                ) ||
                (_appearanceSamplingSupported && completed.baseline != null)),
      );

  LiveScanTrack? _bindSavedCurrent(
    ScanCrop saved,
    LiveCaptureSnapshot capture, {
    String? verifiedHistoricalIdentity,
  }) {
    final DateTime now = _clock();
    final DateTime? acknowledged = capture._acknowledgedAt;
    if (!retireIdentified ||
        capture._owner != this ||
        capture._generation != _generation ||
        !_validCapture(capture) ||
        capture._sceneChanged ||
        acknowledged == null ||
        (now.difference(acknowledged) > _maximumCapturedTextGap &&
            !_ownedCapturePresent(capture, now)) ||
        _geometryAt == null ||
        now.difference(_geometryAt!) > expiry ||
        _lastRemovalSequence > capture._frameSequence ||
        !_savedCaptureGeometryProof(saved)) {
      return null;
    }
    final List<LiveScanTrack> matches = _tracks
        .where(
          (LiveScanTrack track) =>
              !_releasedCompletions.containsKey(track.id) &&
              now.difference(track.lastSeen) <= expiry &&
              _trackCaptureProof(track) &&
              (!track.captured || track._capturedAt == acknowledged) &&
              _savedCaptureGeometryMatches(saved, track.crop) &&
              _captureIdentityMatches(saved, track.crop) &&
              !_captureContradiction(saved, track.crop) &&
              (verifiedHistoricalIdentity == null ||
                  !_historicalObservedTitleConflict(
                    verifiedHistoricalIdentity,
                    saved,
                    track.crop,
                  )) &&
              _currentGeometry.any(
                (List<ScanPoint> corners) =>
                    _captureGeometryMatches(track.corners, corners),
              ) &&
              !_captureConflicts.any(
                (_CaptureConflict conflict) =>
                    conflict.frameSequence > capture._frameSequence &&
                    _recoveryGeometryMatches(
                      saved.sourceCorners,
                      conflict.crop.sourceCorners,
                    ) &&
                    (_captureContradiction(saved, conflict.crop) ||
                        (verifiedHistoricalIdentity != null &&
                            _historicalObservedTitleConflict(
                              verifiedHistoricalIdentity,
                              saved,
                              conflict.crop,
                            ))),
              ),
        )
        .toList();
    if (_releasedCompletions.entries.any(
      (MapEntry<String, DateTime> released) =>
          released.value.isAfter(capture._created) &&
          _releasedSaved[released.key] != null &&
          _recoveryGeometryMatches(
            _releasedSaved[released.key]!.sourceCorners,
            saved.sourceCorners,
          ),
    )) {
      return null;
    }
    if (matches.isEmpty) {
      return _bindFrozenSavedGeometry(
        saved,
        capture,
        acknowledged,
        now,
        verifiedHistoricalIdentity: verifiedHistoricalIdentity,
      );
    }
    if (matches.length != 1) return null;
    final LiveScanTrack track = matches.single;
    if (_completed.any(
          (_CompletedFootprint completed) =>
              completed.id != track.id &&
              _recoveryGeometryMatches(completed.corners, saved.sourceCorners),
        ) ||
        _tracks.any(
          (LiveScanTrack other) =>
              !identical(other, track) &&
              (other.captured || _strongCaptureProof(other.crop)) &&
              _recoveryGeometryMatches(saved.sourceCorners, other.corners),
        )) {
      return null;
    }
    track._capturedAt = acknowledged;
    track._capturedCrop = saved;
    track._cardEvidenceAt = acknowledged;
    return track;
  }

  LiveScanTrack? _bindFrozenSavedGeometry(
    ScanCrop saved,
    LiveCaptureSnapshot capture,
    DateTime acknowledged,
    DateTime now, {
    String? verifiedHistoricalIdentity,
  }) {
    LiveScanTrack? reject(String reason) {
      if (const bool.fromEnvironment('PHYSICAL_CARD_QA')) {
        final List<String> names = ScanHints.fromCrop(saved).names;
        final String key =
            'frozen:${capture._captureGeneration}:${names.join('|')}';
        if (_recoveryDiagnostics[key] != reason) {
          if (_recoveryDiagnostics.length >= 8) {
            _recoveryDiagnostics.clear();
          }
          _recoveryDiagnostics[key] = reason;
          debugPrint(
            'CAPTURE_FROZEN_GEOMETRY_DIAGNOSTIC:${jsonEncode(<String, Object?>{'names': names, 'reason': reason, 'frozenRegions': capture._physicalGeometry.length, 'removedRegions': capture._physicalGeometry.where((_CaptureGeometry region) => region.removed).length, 'currentGeometry': _currentGeometry.length})}',
          );
        }
      }
      return null;
    }

    final List<_CaptureGeometry> frozen = capture._physicalGeometry
        .where(
          (_CaptureGeometry region) =>
              !region.removed &&
              region.missingSince == null &&
              (_acknowledgedFootprintMatches(
                    saved.sourceCorners,
                    region.corners,
                  ) ||
                  (verifiedHistoricalIdentity != null &&
                      _historicalOwnedInsetMatches(saved, region.corners))),
        )
        .toList();
    if (frozen.length != 1 || _completed.length >= 8) {
      return reject('missing_unique_frozen_region_or_capacity');
    }
    final _CaptureGeometry region = frozen.single;
    final bool useObservedParent =
        verifiedHistoricalIdentity != null &&
        !_acknowledgedFootprintMatches(saved.sourceCorners, region.corners);
    final List<ScanPoint> ownershipCorners = useObservedParent
        ? region.corners
        : saved.sourceCorners;
    if (region.observations.any(
          (ScanCrop observed) =>
              _captureContradiction(saved, observed) ||
              (verifiedHistoricalIdentity != null &&
                  _historicalObservedTitleConflict(
                    verifiedHistoricalIdentity,
                    saved,
                    observed,
                  )),
        ) ||
        _currentDetections.any(
          (LiveCardDetection detection) =>
              _acknowledgedFootprintMatches(
                ownershipCorners,
                detection.corners,
              ) &&
              (_captureContradiction(saved, _detectionCrop(detection)) ||
                  (verifiedHistoricalIdentity != null &&
                      _historicalObservedTitleConflict(
                        verifiedHistoricalIdentity,
                        saved,
                        _detectionCrop(detection),
                      ))),
        ) ||
        _captureConflicts.any(
          (_CaptureConflict conflict) =>
              conflict.frameSequence > capture._frameSequence &&
              _recoveryGeometryMatches(
                ownershipCorners,
                conflict.crop.sourceCorners,
              ) &&
              (_captureContradiction(saved, conflict.crop) ||
                  (verifiedHistoricalIdentity != null &&
                      _historicalObservedTitleConflict(
                        verifiedHistoricalIdentity,
                        saved,
                        conflict.crop,
                      ))),
        ) ||
        _completed.any(
          (_CompletedFootprint completed) =>
              _recoveryGeometryMatches(ownershipCorners, completed.corners),
        )) {
      return reject('observed_conflict_or_existing_receipt');
    }
    final List<List<ScanPoint>> current = <List<ScanPoint>>[];
    for (final List<ScanPoint> corners in _currentGeometry) {
      if (_acknowledgedFootprintMatches(ownershipCorners, corners) &&
          _acknowledgedFootprintMatches(region.corners, corners) &&
          !current.any(
            (List<ScanPoint> previous) =>
                _captureGeometryMatches(previous, corners),
          )) {
        current.add(corners);
      }
    }
    if (current.length != 1) {
      return reject('missing_unique_current_region');
    }
    final List<LiveScanTrack> physical = _tracks
        .where(
          (LiveScanTrack track) =>
              _acknowledgedFootprintMatches(ownershipCorners, track.corners),
        )
        .toList();
    if (physical.length > 1 ||
        physical.any(
          (LiveScanTrack track) =>
              (track.captured && track._capturedAt != acknowledged) ||
              _releasedCompletions.containsKey(track.id) ||
              _captureContradiction(saved, track.crop) ||
              (verifiedHistoricalIdentity != null &&
                  _historicalObservedTitleConflict(
                    verifiedHistoricalIdentity,
                    saved,
                    track.crop,
                  )),
        ) ||
        _tracks.any(
          (LiveScanTrack track) =>
              !physical.contains(track) &&
              (track.captured || track.hasCardEvidence) &&
              _recoveryGeometryMatches(ownershipCorners, track.corners),
        )) {
      return reject('competing_or_conflicting_current_track');
    }
    final LiveScanTrack track;
    if (physical.isEmpty) {
      if (!_makeTrackRoom()) {
        return reject('track_capacity');
      }
      track = LiveScanTrack(
        id: 'card-${++_nextId}',
        detection: LiveCardDetection(
          confidence: .85,
          corners: useObservedParent ? current.single : saved.sourceCorners,
          lines: saved.lines,
          warnings: saved.warnings,
        ),
        lastSeen: _geometryAt!,
      );
      _tracks.add(track);
    } else {
      track = physical.single;
    }
    track.corners = List<ScanPoint>.unmodifiable(
      useObservedParent ? current.single : saved.sourceCorners,
    );
    track._lines = saved.lines;
    track._warnings = saved.warnings;
    track._capturedAt = acknowledged;
    track._capturedCrop = saved;
    track._cardEvidenceAt = now;
    return track;
  }

  bool rememberSavedCrop(ScanCrop saved, LiveCaptureSnapshot capture) {
    if (_disposed ||
        !retireIdentified ||
        !_savedCaptureGeometryProof(saved) ||
        capture._owner != this ||
        capture._generation != _generation ||
        !_validCapture(capture) ||
        capture._acknowledgedAt == null ||
        _missingWasRearmed(capture, saved)) {
      return false;
    }
    final _CompletedFootprint? prior = _completed
        .where(
          (_CompletedFootprint completed) =>
              _captureGeometryMatches(completed.corners, saved.sourceCorners) &&
              _captureIdentityMatches(completed.savedCrop, saved),
        )
        .firstOrNull;
    if (prior != null) {
      if (!identical(prior.capture, capture)) return false;
      if (prior.identifiedAt == null) prior.savedCrop = saved;
      return true;
    }
    if (_clock().difference(capture._acknowledgedAt!) >
            _maximumCapturedTextGap &&
        !_ownedCapturePresent(capture, _clock())) {
      return false;
    }
    final LiveScanTrack? track = _bindSavedCurrent(saved, capture);
    if (track == null) return false;
    final _CompletedFootprint? owned = _completed
        .where((_CompletedFootprint completed) => completed.id == track.id)
        .firstOrNull;
    if (owned != null) {
      if (!identical(owned.capture, capture) ||
          !_captureIdentityMatches(owned.savedCrop, saved)) {
        return false;
      }
      if (owned.identifiedAt == null) {
        owned.savedCrop = saved;
      }
      return true;
    }
    if (_completed.length >= 8) return false;
    _completed.add(
      _CompletedFootprint(
        track,
        saved,
        _clock(),
        identified: false,
        capture: capture,
      ),
    );
    notifyListeners();
    return true;
  }

  bool _acknowledgedBodyIdentity(
    ScanCrop saved,
    LiveScanTrack track,
    LiveCaptureSnapshot capture,
  ) {
    final DateTime now = _clock();
    final DateTime? acknowledged = capture._acknowledgedAt;
    final ScanCrop? receipt = track._capturedCrop;
    if (acknowledged == null ||
        (now.difference(acknowledged) > _maximumCapturedTextGap &&
            !_pendingReceiptPresent(track, now)) ||
        track._capturedAt != acknowledged ||
        receipt == null ||
        _title(receipt.lines) != null ||
        _geometryAt == null ||
        now.difference(_geometryAt!) > expiry ||
        _lastRemovalSequence > capture._frameSequence ||
        !capture._targets.any(
          (_CaptureTarget target) =>
              target.id == track.id &&
              _title(target.crop.lines) == null &&
              _captureGeometryMatches(
                target.crop.sourceCorners,
                receipt.sourceCorners,
              ),
        ) ||
        !_tightBodyFootprintMatches(
          saved.sourceCorners,
          receipt.sourceCorners,
        ) ||
        !_currentGeometry.any(
          (List<ScanPoint> corners) =>
              _captureGeometryMatches(track.corners, corners),
        ) ||
        _tracks.any(
          (LiveScanTrack other) =>
              !identical(other, track) &&
              (other.captured ||
                  (other.hasCardEvidence && _strongCaptureProof(other.crop))) &&
              _captureGeometryMatches(receipt.sourceCorners, other.corners),
        )) {
      return false;
    }
    final ScanHints rawSaved = ScanHints.fromCrop(saved);
    final ScanHints rawReceipt = ScanHints.fromCrop(receipt);
    if (_captureMetadataContradiction(rawSaved, rawReceipt) ||
        _captureMetadataContradiction(
          rawSaved,
          ScanHints.fromCrop(track.crop),
        ) ||
        _captureContradiction(saved, track.crop)) {
      return false;
    }
    ScanHints reliable(ScanCrop crop) => ScanHints.fromCrop(
      crop,
      minimumConfidence: .85,
    );
    final ScanHints a = reliable(saved);
    final ScanHints b = reliable(receipt);
    if (a.typeLine == null ||
        a.typeLine != b.typeLine ||
        ScanResolver.rulesSearchPhrase(a.rulesText) == null ||
        ScanResolver.rulesSearchPhrase(b.rulesText) == null) {
      return false;
    }
    const Set<String> colors = <String>{
      'white',
      'blue',
      'black',
      'red',
      'green',
      'colorless',
    };
    Set<String> observedColors(ScanHints hints) =>
        <String>[...hints.names, ...hints.rulesText]
            .expand(
              (String text) =>
                  RegExp(r'[a-z]+')
                      .allMatches(text.toLowerCase())
                      .map((RegExpMatch match) => match.group(0)!),
            )
            .toSet()
            .intersection(colors);
    final Set<String> firstColors = observedColors(a);
    if (firstColors.isEmpty || !setEquals(firstColors, observedColors(b))) {
      return false;
    }
    Set<String> rules(ScanHints hints) => hints.rulesText
        .map(
          (String text) =>
              text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''),
        )
        .where((String text) => text.length >= 24)
        .toSet();
    final Set<String> firstRules = rules(a);
    final Set<String> secondRules = rules(b);
    final Set<String> exact = firstRules.intersection(secondRules);
    if (exact.isEmpty) {
      return false;
    }
    final Set<String> remaining = secondRules.difference(exact);
    int matched = exact.length;
    for (final String rule in firstRules.difference(exact)) {
      final String? near = remaining
          .where((String other) => _singleRuleCharacterDifference(rule, other))
          .firstOrNull;
      if (near != null) {
        remaining.remove(near);
        matched++;
      }
    }
    return matched >= 2;
  }

  LiveScanTrack? _recoverCaptured(
    ScanCrop savedCrop,
    LiveCaptureSnapshot capture,
  ) {
    final DateTime now = _clock();
    final DateTime? acknowledged = capture._acknowledgedAt;
    LiveScanTrack? reject(String reason) {
      if (const bool.fromEnvironment('PHYSICAL_CARD_QA')) {
        final List<String> names = ScanHints.fromCrop(savedCrop).names;
        final String key = names.join('|');
        if (_recoveryDiagnostics[key] != reason) {
          if (_recoveryDiagnostics.length >= 8) {
            _recoveryDiagnostics.clear();
          }
          _recoveryDiagnostics[key] = reason;
          debugPrint(
            'CAPTURE_RECOVERY_DIAGNOSTIC:${jsonEncode(<String, Object?>{'names': names, 'reason': reason, 'frozenProofs': capture._recoveryTargets.length, 'currentGeometry': _currentGeometry.length, 'currentTextDetections': _currentDetections.where((LiveCardDetection detection) => detection.lines.isNotEmpty).length, 'acknowledged': acknowledged != null})}',
          );
        }
      }
      return null;
    }

    if (capture._owner != this ||
        capture._generation != _generation ||
        !_validCapture(capture)) {
      return reject('different_capture_generation');
    }
    if (acknowledged == null ||
        (now.difference(acknowledged) > _maximumCapturedTextGap &&
            !_ownedCapturePresent(capture, now))) {
      return reject('missing_or_expired_ack');
    }
    if (_geometryAt == null || now.difference(_geometryAt!) > expiry) {
      return reject('stale_current_geometry');
    }
    if (_lastRemovalSequence > capture._frameSequence) {
      return reject('observed_scene_removed');
    }
    final List<_CaptureTarget> proofs = capture._recoveryTargets
        .where(
          (_CaptureTarget target) =>
              !_releasedCompletions.containsKey(target.id) &&
              (now.difference(acknowledged) <= _maximumCapturedTextGap ||
                  _tracks.any(
                    (LiveScanTrack track) =>
                        track.id == target.id &&
                        _pendingReceiptPresent(track, now),
                  )) &&
              _captureGeometryMatches(
                savedCrop.sourceCorners,
                target.crop.sourceCorners,
              ) &&
              _captureIdentityMatches(savedCrop, target.crop) &&
              !_captureConflicts.any(
                (_CaptureConflict conflict) =>
                    conflict.frameSequence > capture._frameSequence &&
                    _recoveryGeometryMatches(
                      target.crop.sourceCorners,
                      conflict.crop.sourceCorners,
                    ) &&
                    _captureContradiction(target.crop, conflict.crop),
              ),
        )
        .toList();
    if (proofs.length != 1) {
      return reject('nonunique_or_contradicted_frozen_proof');
    }
    final _CaptureTarget proof = proofs.single;
    final LiveScanTrack? corrected = _correctAcknowledgedFootprint(
      savedCrop,
      capture,
      proof,
      acknowledged,
    );
    if (corrected != null) {
      return corrected;
    }
    final List<List<ScanPoint>> matches = _currentGeometry.where((
      List<ScanPoint> corners,
    ) {
      if (_captureGeometryMatches(proof.crop.sourceCorners, corners)) {
        return true;
      }
      if (!_recoveryGeometryMatches(proof.crop.sourceCorners, corners)) {
        return false;
      }
      return _currentDetections.any((LiveCardDetection detection) {
        if (!_captureGeometryMatches(corners, detection.corners)) {
          return false;
        }
        final ScanCrop observed = _detectionCrop(detection);
        final ScanHints hints = ScanHints.fromCrop(observed);
        return hints.typeLine != null &&
            ScanResolver.rulesSearchPhrase(hints.rulesText) != null &&
            _captureIdentityMatches(savedCrop, observed);
      });
    }).toList();
    final List<List<ScanPoint>> unique = <List<ScanPoint>>[];
    for (final List<ScanPoint> corners in matches) {
      if (!unique.any(
        (List<ScanPoint> other) => _captureGeometryMatches(corners, other),
      )) {
        unique.add(corners);
      }
    }
    if (unique.length != 1) {
      return reject('missing_unique_current_geometry_or_inset_ocr');
    }
    final List<ScanPoint> geometry = unique.single;
    if (_currentDetections.any(
      (LiveCardDetection detection) =>
          _recoveryGeometryMatches(
            proof.crop.sourceCorners,
            detection.corners,
          ) &&
          _captureContradiction(savedCrop, _detectionCrop(detection)),
    )) {
      return reject('current_card_contradiction');
    }
    final List<LiveScanTrack> physical = _tracks
        .where(
          (LiveScanTrack track) =>
              _recoveryGeometryMatches(proof.crop.sourceCorners, track.corners),
        )
        .toList();
    final List<LiveScanTrack> admittedInsets = physical
        .where(
          (LiveScanTrack track) =>
              track._capturedAt == acknowledged &&
              track._capturedCrop != null &&
              capture._targets.any(
                (_CaptureTarget target) =>
                    target.id == track.id &&
                    _captureGeometryMatches(
                      target.crop.sourceCorners,
                      track._capturedCrop!.sourceCorners,
                    ),
              ) &&
              _weakAdmittedInset(proof.crop, track._capturedCrop!),
        )
        .toList();
    final List<LiveScanTrack> remaining = physical
        .where((LiveScanTrack track) => !admittedInsets.contains(track))
        .toList();
    final LiveCardDetection? fullDetection = _currentDetections
        .where(
          (LiveCardDetection detection) =>
              _captureGeometryMatches(geometry, detection.corners) &&
              _strongCaptureProof(_detectionCrop(detection)) &&
              _captureIdentityMatches(savedCrop, _detectionCrop(detection)),
        )
        .firstOrNull;
    final bool upgradeInset =
        admittedInsets.length == 1 &&
        fullDetection != null &&
        _captureGeometryMatches(proof.crop.sourceCorners, geometry) &&
        remaining.length <= 1 &&
        remaining.every(
          (LiveScanTrack track) =>
              !track.captured &&
              _captureGeometryMatches(geometry, track.corners) &&
              _trackCaptureProof(track) &&
              _captureIdentityMatches(savedCrop, track.crop),
        );
    if (!upgradeInset &&
        (physical.length > 1 ||
            physical.any(
              (LiveScanTrack track) =>
                  track.captured ||
                  _captureContradiction(savedCrop, track.crop),
            ))) {
      return reject('ambiguous_or_conflicting_current_track');
    }
    final LiveScanTrack track;
    if (upgradeInset) {
      track = admittedInsets.single;
      _tracks.removeWhere((LiveScanTrack other) => remaining.contains(other));
      final LiveCardDetection observed = fullDetection;
      track._lines = observed.lines;
      track._warnings = observed.warnings;
    } else if (physical.isEmpty) {
      if (!_makeTrackRoom()) {
        return reject('track_limit');
      }
      track = LiveScanTrack(
        id: proof.id,
        detection: LiveCardDetection(
          confidence: .85,
          corners: proof.crop.sourceCorners,
          lines: proof.crop.lines,
          warnings: proof.crop.warnings,
        ),
        lastSeen: _geometryAt!,
      );
      _tracks.add(track);
    } else {
      track = physical.single;
    }
    track.corners = _captureGeometryMatches(proof.crop.sourceCorners, geometry)
        ? geometry
        : proof.crop.sourceCorners;
    track._captureProofAt = proof.proofAt;
    track._cardEvidenceAt = acknowledged;
    track._capturedAt = acknowledged;
    track._capturedCrop = savedCrop;
    track._capturedIdentified = false;
    track._identifiedSavedResolution = null;
    _pendingCaptured.removeWhere(
      (_PendingCapturedTarget target) => target.target.id == proof.id,
    );
    return track;
  }

  LiveScanTrack? _correctAcknowledgedFootprint(
    ScanCrop saved,
    LiveCaptureSnapshot capture,
    _CaptureTarget proof,
    DateTime acknowledged,
  ) {
    final List<LiveScanTrack> receipts = _tracks
        .where(
          (LiveScanTrack track) =>
              track.id == proof.id &&
              track._capturedAt == acknowledged &&
              track._capturedCrop != null &&
              _strongCaptureProof(track._capturedCrop!) &&
              _captureIdentityMatches(saved, track._capturedCrop!) &&
              !_captureContradiction(saved, track.crop) &&
              _acknowledgedFootprintMatches(
                proof.crop.sourceCorners,
                track.corners,
              ) &&
              capture._targets.any(
                (_CaptureTarget target) =>
                    target.id == track.id &&
                    target.proofAt != null &&
                    _targetCaptureProof(target) &&
                    _captureGeometryMatches(
                      target.crop.sourceCorners,
                      track._capturedCrop!.sourceCorners,
                    ) &&
                    _captureIdentityMatches(saved, target.crop),
              ),
        )
        .toList();
    if (receipts.length != 1) {
      return null;
    }
    final LiveScanTrack receipt = receipts.single;
    if (_tracks.any(
          (LiveScanTrack other) =>
              !identical(other, receipt) &&
              (other.captured ||
                  (other.hasCardEvidence && _strongCaptureProof(other.crop))) &&
              _acknowledgedFootprintMatches(
                proof.crop.sourceCorners,
                other.corners,
              ),
        ) ||
        _captureConflicts.any(
          (_CaptureConflict conflict) =>
              conflict.frameSequence > capture._frameSequence &&
              _acknowledgedFootprintMatches(
                proof.crop.sourceCorners,
                conflict.crop.sourceCorners,
              ) &&
              _captureContradiction(saved, conflict.crop),
        ) ||
        _currentDetections.any(
          (LiveCardDetection detection) =>
              _acknowledgedFootprintMatches(
                proof.crop.sourceCorners,
                detection.corners,
              ) &&
              _captureContradiction(saved, _detectionCrop(detection)),
        )) {
      return null;
    }
    final List<List<ScanPoint>> geometry = <List<ScanPoint>>[];
    for (final List<ScanPoint> corners in _currentGeometry) {
      if (!_captureGeometryMatches(receipt.corners, corners) ||
          !_acknowledgedFootprintMatches(proof.crop.sourceCorners, corners)) {
        continue;
      }
      if (!geometry.any(
        (List<ScanPoint> other) => _captureGeometryMatches(other, corners),
      )) {
        geometry.add(corners);
      }
    }
    if (geometry.length != 1) {
      return null;
    }
    receipt.corners = List<ScanPoint>.unmodifiable(saved.sourceCorners);
    receipt._capturedCrop = saved;
    return receipt;
  }

  bool _makeTrackRoom() {
    if (_tracks.length < 8) return true;
    final List<LiveScanTrack> unproved =
        _tracks
            .where(
              (LiveScanTrack track) =>
                  !track.captured &&
                  !track.hasCardEvidence &&
                  !_recentStrongProof(track),
            )
            .toList()
          ..sort(
            (LiveScanTrack a, LiveScanTrack b) =>
                a.lastSeen.compareTo(b.lastSeen),
          );
    if (unproved.isEmpty) return false;
    _tracks.remove(unproved.first);
    return true;
  }

  void _reportIdentification(ScanCrop saved, int matched) {
    if (!const bool.fromEnvironment('PHYSICAL_CARD_QA')) {
      return;
    }
    final List<String> names = ScanHints.fromCrop(saved).names;
    final List<Map<String, Object?>> receipts = _tracks
        .where(
          (LiveScanTrack track) =>
              track.captured && track._capturedCrop != null,
        )
        .map(
          (LiveScanTrack track) => <String, Object?>{
            'id': track.id,
            'geometry': _savedCaptureGeometryMatches(
              saved,
              track._capturedCrop!,
            ),
            'identity': _captureIdentityMatches(saved, track._capturedCrop!),
            'currentContradiction': _captureContradiction(saved, track.crop),
            'identified': track.capturedIdentified,
          },
        )
        .toList();
    final String state = jsonEncode(<String, Object?>{
      'names': names,
      'matched': matched,
      'receipts': receipts,
    });
    final String key = names.join('|');
    if (_identificationDiagnostics[key] == state) {
      return;
    }
    if (_identificationDiagnostics.length >= 8) {
      _identificationDiagnostics.clear();
    }
    _identificationDiagnostics[key] = state;
    debugPrint('CAPTURE_IDENTIFICATION_DIAGNOSTIC:$state');
  }

  void _releaseCompleted(
    _CompletedFootprint completed,
    DateTime now, {
    required String reason,
    Map<String, Object?> evidence = const <String, Object?>{},
  }) {
    if (const bool.fromEnvironment('PHYSICAL_CARD_QA')) {
      debugPrint(
        'CAPTURE_RELEASE_DIAGNOSTIC:${jsonEncode(<String, Object?>{
          'id': completed.id,
          'reason': reason,
          'identified': completed.identifiedAt != null,
          'names': ScanHints.fromCrop(completed.savedCrop).names,
          'lastPresenceAgeMs': now.difference(completed.lastPresence).inMilliseconds,
          'missingAgeMs': completed.missingSince == null ? null : now.difference(completed.missingSince!).inMilliseconds,
          'samplingSupported': _appearanceSamplingSupported,
          'appearanceSettled': completed.baseline != null,
          'corners': completed.corners.map((ScanPoint point) => <String, double>{'x': point.x, 'y': point.y}).toList(),
          ...evidence,
        })}',
      );
    }
    _completed.remove(completed);
    _releasedCompletions[completed.id] = now;
    _releasedSaved[completed.id] = completed.savedCrop;
    if (_releasedCompletions.length > 64) {
      final String oldest = _releasedCompletions.keys.first;
      _releasedCompletions.remove(oldest);
      _releasedSaved.remove(oldest);
    }
    _tracks.removeWhere((LiveScanTrack track) => track.id == completed.id);
    _recentProofs.removeWhere(
      (_RecentCaptureProof proof) => proof.target.id == completed.id,
    );
    _pendingCaptured.removeWhere(
      (_PendingCapturedTarget pending) => pending.target.id == completed.id,
    );
    final LiveCaptureSnapshot? capture = completed.capture;
    if (capture != null) {
      capture._sceneChanged = true;
    }
    if (capture != null &&
        !_completed.any(
          (_CompletedFootprint other) => identical(other.capture, capture),
        ) &&
        !_tracks.any(
          (LiveScanTrack track) => track._capturedAt == capture._acknowledgedAt,
        ) &&
        !_pendingCaptured.any(
          (_PendingCapturedTarget pending) =>
              pending.savedAt == capture._acknowledgedAt,
        )) {
      _acknowledgedCaptures.remove(capture);
    }
  }

  void _updateCompleted(
    List<LiveCardDetection> cards,
    List<List<ScanPoint>> geometry,
    Iterable<LiveCardAppearanceSample> samples,
    DateTime now,
  ) {
    if (!retireIdentified || _completed.isEmpty) return;
    final Map<String, LiveCardAppearanceSample> byId =
        <String, LiveCardAppearanceSample>{
          for (final LiveCardAppearanceSample sample in samples.take(8))
            sample.id: sample,
        };
    for (final _CompletedFootprint completed in List<_CompletedFootprint>.of(
      _completed,
    )) {
      completed.awaitingPresenceObservation = false;
      final List<LiveCardDetection> associated = cards
          .where(
            (LiveCardDetection card) =>
                _captureGeometryMatches(completed.corners, card.corners) ||
                _recoveryGeometryMatches(completed.corners, card.corners),
          )
          .toList();
      final LiveCardAppearanceSample? sample = byId[completed.id];
      final bool sampleGeometry =
          sample != null &&
          (_captureGeometryMatches(completed.corners, sample.corners) ||
              _recoveryGeometryMatches(completed.corners, sample.corners));
      final List<double>? appearance = sample == null || !sampleGeometry
          ? null
          : _normalizedAppearance(sample.values);
      bool unchanged =
          appearance != null &&
          completed.baseline != null &&
          _appearanceDifference(completed.baseline!, appearance) <= .18;
      final LiveCardDetection? contradicted = associated
          .where(
            (LiveCardDetection card) =>
                card.lines.isNotEmpty &&
                _captureContradiction(
                  completed.savedCrop,
                  _detectionCrop(card),
                ),
          )
          .firstOrNull;
      if (contradicted != null && !unchanged) {
        _releaseCompleted(
          completed,
          now,
          reason: 'observed_text_contradiction',
          evidence: <String, Object?>{
            'observedLines': contradicted.lines
                .take(10)
                .map(
                  (ScanTextLine line) => <String, Object?>{
                    'text': line.text,
                    'confidence': line.confidence,
                    'bounds': <String, double>{
                      'x': line.bounds.x,
                      'y': line.bounds.y,
                      'width': line.bounds.width,
                      'height': line.bounds.height,
                    },
                  },
                )
                .toList(),
            'observedWarnings': contradicted.warnings,
          },
        );
        continue;
      }
      final bool geometryPresent =
          associated.isNotEmpty ||
          geometry.any(
            (List<ScanPoint> corners) =>
                _captureGeometryMatches(completed.corners, corners) ||
                _recoveryGeometryMatches(completed.corners, corners),
          );
      final bool nativePresent =
          sample != null && sampleGeometry && sample.present;
      if (appearance != null) {
        final List<double>? baseline = completed.baseline;
        if (baseline == null) {
          final DateTime? acknowledged = completed.capture?._acknowledgedAt;
          final bool freshPendingPhoto =
              completed.identifiedAt == null &&
              acknowledged != null &&
              now.difference(acknowledged) <= expiry &&
              !completed.capture!._sceneChanged &&
              _savedCaptureGeometryProof(completed.savedCrop);
          if (nativePresent ||
              geometryPresent ||
              freshPendingPhoto ||
              (completed.identifiedAt != null &&
                  now.difference(completed.identifiedAt!) <= expiry)) {
            if (completed.settling == null ||
                _appearanceDifference(completed.settling!, appearance) <= .15) {
              completed.settling = appearance;
              completed.settledFrames++;
              if (completed.settledFrames >= 3) {
                completed.baseline = appearance;
                unchanged = true;
              }
            } else {
              completed.settling = appearance;
              completed.settledFrames = 1;
            }
          }
        } else {
          final double difference = _appearanceDifference(baseline, appearance);
          unchanged = difference <= .18;
          if (difference >= .38) {
            completed.changeStarted ??= now;
            completed.changedFrames++;
            if (completed.changedFrames >= 3 &&
                now.difference(completed.changeStarted!) >=
                    const Duration(milliseconds: 500)) {
              _releaseCompleted(
                completed,
                now,
                reason: 'repeated_appearance_change',
                evidence: <String, Object?>{
                  'difference': difference,
                  'changedFrames': completed.changedFrames,
                  'changeAgeMs': now
                      .difference(completed.changeStarted!)
                      .inMilliseconds,
                  'nativePresent': nativePresent,
                  'geometryPresent': geometryPresent,
                },
              );
              continue;
            }
          } else {
            completed.changedFrames = 0;
            completed.changeStarted = null;
          }
        }
      } else {
        completed.changedFrames = 0;
        completed.changeStarted = null;
      }
      if (geometryPresent || nativePresent || unchanged) {
        completed.lastPresence = now;
        completed.missingSince = null;
        completed.backgroundFrames = 0;
      } else if ((_appearanceSamplingSupported || completed.baseline != null) &&
          (!sampleGeometry || sample.values.length != 288)) {
        // Missing or unscheduled samples cannot establish physical removal.
        completed.awaitingPresenceObservation = true;
        completed.missingSince = null;
        completed.backgroundFrames = 0;
      } else {
        completed.missingSince ??= now;
        completed.backgroundFrames =
            sample != null &&
                !sample.present &&
                _flatBackgroundAppearance(sample.values)
            ? completed.backgroundFrames + 1
            : 0;
        if (now.difference(completed.missingSince!) >= expiry &&
            (!_appearanceSamplingSupported ||
                completed.baseline == null ||
                completed.backgroundFrames >= 3)) {
          _releaseCompleted(
            completed,
            now,
            reason: 'physical_absence',
            evidence: <String, Object?>{
              'sampleReceived': sample != null,
              'backgroundFrames': completed.backgroundFrames,
              'geometryCount': geometry.length,
            },
          );
        }
      }
    }
  }

  bool _validCapture(LiveCaptureSnapshot capture) =>
      capture._captureGeneration == _captureGeneration ||
      (retireIdentified && _acknowledgedCaptures.contains(capture));

  int beginCapture({bool resume = false}) {
    if (_disposed) return -1;
    _captureStarted = _clock();
    _restartStarted = null;
    if (!resume) _captureGeneration++;
    return _captureGeneration;
  }

  void rearmCaptured() {
    if (_disposed) return;
    _captureGeneration++;
    _acknowledgedCaptures.clear();
    _completed.clear();
    _releasedCompletions.clear();
    _releasedSaved.clear();
    bool changed = _pendingCaptured.isNotEmpty;
    _pendingCaptured.clear();
    _missingCaptureRetries.clear();
    for (final LiveScanTrack track in _tracks) {
      track._recoveryObservation = null;
      track._invalidatePhotoFeedback();
      if (!track.captured) {
        continue;
      }
      track._capturedAt = null;
      track._capturedCrop = null;
      track._capturedIdentified = false;
      track._identifiedSavedResolution = null;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void endCapture(int token, {required bool resumeTracking}) {
    if (_disposed || token != _captureGeneration || _captureStarted == null) {
      return;
    }
    bool changed = _prune();
    _captureStarted = null;
    _restartStarted = resumeTracking && _tracks.isNotEmpty ? _clock() : null;
    changed = _prune() || changed;
    if (changed) notifyListeners();
  }

  int beginFrameAnalysis() {
    if (_disposed) return -1;
    final int token = ++_nextAnalysis;
    _frameAnalyses[token] = _clock();
    return token;
  }

  void endFrameAnalysis(int token) {
    if (_disposed || _frameAnalyses.remove(token) == null) return;
    if (_prune()) notifyListeners();
  }

  void update(
    List<LiveCardDetection> cards, {
    int? frameAnalysis,
    Iterable<List<ScanPoint>> currentGeometry = const <List<ScanPoint>>[],
    Iterable<LiveCardAppearanceSample> appearanceSamples =
        const <LiveCardAppearanceSample>[],
    bool appearanceSamplingSupported = false,
  }) {
    if (_disposed ||
        (frameAnalysis != null && !_frameAnalyses.containsKey(frameAnalysis))) {
      return;
    }
    _observationsSuspended = false;
    _frameSequence++;
    final DateTime now = _clock();
    _currentFrameStartedAt = frameAnalysis == null
        ? now
        : _frameAnalyses[frameAnalysis];
    final List<List<ScanPoint>> geometry = currentGeometry
        .where(
          (List<ScanPoint> corners) =>
              corners.length == 4 &&
              corners.every(
                (ScanPoint point) =>
                    point.x.isFinite &&
                    point.y.isFinite &&
                    point.x >= 0 &&
                    point.x <= 1 &&
                    point.y >= 0 &&
                    point.y <= 1,
              ),
        )
        .take(8)
        .toList();
    final List<LiveCardDetection> current = cards
        .where(_validDetection)
        .take(8)
        .toList();
    _appearanceSamplingSupported = appearanceSamplingSupported;
    _updateCompleted(current, geometry, appearanceSamples, now);
    for (final LiveCaptureSnapshot capture in _acknowledgedCaptures) {
      for (final _CaptureGeometry region in capture._physicalGeometry) {
        if (region.removed) {
          continue;
        }
        final bool present =
            <List<ScanPoint>>[
              ...geometry,
              ...current.map((LiveCardDetection card) => card.corners),
            ].any(
              (List<ScanPoint> corners) =>
                  _acknowledgedFootprintMatches(region.corners, corners) ||
                  _recoveryGeometryMatches(region.corners, corners),
            ) ||
            _completed.any(
              (_CompletedFootprint completed) =>
                  identical(completed.capture, capture) &&
                  completed.missingSince == null &&
                  completed.lastPresence == now &&
                  _acknowledgedFootprintMatches(
                    region.corners,
                    completed.corners,
                  ),
            );
        final bool awaitingObservation = _completed.any(
          (_CompletedFootprint completed) =>
              identical(completed.capture, capture) &&
              completed.awaitingPresenceObservation &&
              _acknowledgedFootprintMatches(region.corners, completed.corners),
        );
        if (present || awaitingObservation) {
          region.missingSince = null;
        } else {
          region.missingSince ??= now;
          if (now.difference(region.missingSince!) >= expiry) {
            region.removed = true;
          }
        }
        for (final LiveCardDetection detection in current) {
          if (detection.lines.isEmpty ||
              !_acknowledgedFootprintMatches(
                region.corners,
                detection.corners,
              )) {
            continue;
          }
          final ScanCrop observed = _detectionCrop(detection);
          if (region.observations.length == 8) {
            region.observations.removeAt(0);
          }
          region.observations.add(observed);
        }
      }
    }
    current.removeWhere(
      (LiveCardDetection detection) => isCompleted(detection.corners),
    );
    _currentDetections = current;
    _currentGeometry = <List<ScanPoint>>[
      ...geometry,
      ...current.map((LiveCardDetection detection) => detection.corners),
    ];
    _geometryAt = now;
    if (_currentGeometry.isEmpty &&
        !_completed.any(
          (_CompletedFootprint completed) =>
              completed.awaitingPresenceObservation ||
              (completed.missingSince == null && completed.lastPresence == now),
        )) {
      _emptySceneStarted ??= now;
      if (now.difference(_emptySceneStarted!) >= expiry) {
        _lastRemovalSequence = _frameSequence;
        _recentProofs.clear();
      }
    } else {
      _emptySceneStarted = null;
    }
    for (final LiveCardDetection detection in current) {
      if (detection.lines.isEmpty) continue;
      final ScanCrop observed = _detectionCrop(detection);
      final bool conflicts =
          _recentProofs.any(
            (_RecentCaptureProof proof) =>
                _recoveryGeometryMatches(
                  proof.target.crop.sourceCorners,
                  detection.corners,
                ) &&
                _captureContradiction(proof.target.crop, observed),
          ) ||
          _tracks.any(
            (LiveScanTrack track) =>
                track._capturedCrop != null &&
                _recoveryGeometryMatches(
                  track._capturedCrop!.sourceCorners,
                  detection.corners,
                ) &&
                _captureContradiction(track._capturedCrop!, observed),
          );
      if (!conflicts) {
        continue;
      }
      if (_captureConflicts.length == 16) {
        _captureConflicts.removeAt(0);
      }
      _captureConflicts.add(_CaptureConflict(observed, _frameSequence, now));
    }
    // Fresh geometry must be associated before the previous frame can expire.
    final Set<int> refreshedGeometry = <int>{};
    for (final LiveScanTrack track in _tracks) {
      if (now.difference(track.lastSeen) <= expiry ||
          !_geometryProofSupported(track, now)) {
        continue;
      }
      for (int index = 0; index < geometry.length; index++) {
        if (refreshedGeometry.contains(index) ||
            !_rawGeometryMatches(track, geometry[index], now)) {
          continue;
        }
        _refresh(
          track,
          LiveCardDetection(
            confidence: track.confidence,
            corners: _captureGeometryMatches(track.corners, geometry[index])
                ? geometry[index]
                : track.corners,
            lines: const <ScanTextLine>[],
            warnings: const <String>['geometry_only'],
          ),
          now,
        );
        refreshedGeometry.add(index);
        break;
      }
    }
    _prune();
    final List<LiveCardDetection> detections = current;
    final List<_Association> associations = <_Association>[];
    for (final LiveScanTrack track in _tracks) {
      for (int index = 0; index < detections.length; index++) {
        final LiveCardDetection detection = detections[index];
        final List<ScanPoint>? whole = detection.lines.isEmpty
            ? _panelFootprint(track, detection.corners, now)
            : null;
        final double score = whole != null
            ? 1.5
            : detection.lines.isEmpty &&
                  _trackCaptureProof(track) &&
                  _recoveryGeometryMatches(track.corners, detection.corners) &&
                  !_captureGeometryMatches(track.corners, detection.corners)
            ? 0
            : _associationScore(track, detection);
        if (score > 0) associations.add(_Association(track, index, score));
      }
    }
    associations.sort(
      (_Association a, _Association b) => b.score.compareTo(a.score),
    );
    final Set<String> assignedTracks = <String>{};
    final Set<int> assignedCards = <int>{};
    for (final _Association association in associations) {
      if (assignedTracks.contains(association.track.id) ||
          assignedCards.contains(association.cardIndex)) {
        continue;
      }
      assignedTracks.add(association.track.id);
      assignedCards.add(association.cardIndex);
      _refresh(association.track, detections[association.cardIndex], now);
    }
    final Set<int> assignedGeometry = <int>{};
    for (final LiveScanTrack track in _tracks) {
      if (assignedTracks.contains(track.id) ||
          !_geometryProofSupported(track, now)) {
        continue;
      }
      int? selected;
      double score = 0;
      for (int index = 0; index < geometry.length; index++) {
        if (assignedGeometry.contains(index) ||
            !_rawGeometryMatches(track, geometry[index], now)) {
          continue;
        }
        final LiveCardDetection detection = LiveCardDetection(
          confidence: track.confidence,
          corners: geometry[index],
          lines: const <ScanTextLine>[],
          warnings: const <String>['geometry_only'],
        );
        final double candidateScore = _associationScore(track, detection);
        if (candidateScore > score) {
          score = candidateScore;
          selected = index;
        }
      }
      if (selected == null) continue;
      assignedGeometry.add(selected);
      assignedTracks.add(track.id);
      _refresh(
        track,
        LiveCardDetection(
          confidence: track.confidence,
          corners: _captureGeometryMatches(track.corners, geometry[selected])
              ? geometry[selected]
              : track.corners,
          lines: const <ScanTextLine>[],
          warnings: const <String>['geometry_only'],
        ),
        now,
      );
    }
    for (int index = 0; index < detections.length; index++) {
      if (assignedCards.contains(index)) continue;
      if (!_makeTrackRoom()) continue;
      final LiveScanTrack track = LiveScanTrack(
        id: 'card-${++_nextId}',
        detection: detections[index],
        lastSeen: now,
      );
      _tracks.add(track);
      _restoreCaptured(track, now);
      if (_readableCardText(track.crop)) _rememberProof(track, now);
      assignedTracks.add(track.id);
    }
    if (_restartStarted != null) {
      // Associate the first resumed frame before dropping its bounded restart grace.
      _restartStarted = null;
      _prune();
    }
    notifyListeners();
    unawaited(_drain());
  }

  void _refresh(
    LiveScanTrack track,
    LiveCardDetection detection,
    DateTime now,
  ) {
    final List<ScanPoint>? panelFootprint = detection.lines.isEmpty
        ? _panelFootprint(track, detection.corners, now)
        : null;
    final ScanHints oldHints = ScanHints.fromCrop(track.crop);
    final ScanHints newHints = ScanHints.fromCrop(
      ScanCrop(
        imagePath: '',
        width: 1000,
        height: 1400,
        rectified: !detection.warnings.contains('partial_card'),
        sourceCorners: detection.corners,
        lines: detection.lines
            .where((ScanTextLine line) => line.confidence >= .8)
            .toList(),
        warnings: detection.warnings,
      ),
    );
    final ScanCrop observed = ScanCrop(
      imagePath: '',
      width: 1000,
      height: 1400,
      rectified: !detection.warnings.contains('partial_card'),
      sourceCorners: detection.corners,
      lines: detection.lines,
      warnings: detection.warnings,
    );
    if (_readableCardText(observed) ||
        (!track.captured &&
            _restartStarted != null &&
            now.difference(_restartStarted!) < _maximumRestartGrace &&
            track._cardEvidenceAt != null)) {
      track._cardEvidenceAt = now;
    }
    final bool printingChanged =
        (oldHints.setCode != null &&
            newHints.setCode != null &&
            oldHints.setCode != newHints.setCode) ||
        (oldHints.collectorNumber != null &&
            newHints.collectorNumber != null &&
            oldHints.collectorNumber != newHints.collectorNumber) ||
        (oldHints.language != null &&
            newHints.language != null &&
            oldHints.language != newHints.language);
    final bool preservedCapturedPrefix =
        track._capturedCrop != null &&
        track._capturedAt != null &&
        now.difference(track._capturedAt!) <= _maximumCapturedTextGap &&
        _preserveCapturedPrefix(track._capturedCrop!, observed);
    final bool capturedContradiction =
        track._capturedCrop != null &&
        _captureContradiction(track._capturedCrop!, observed);
    final bool capturedMetadataChanged =
        track._capturedCrop != null &&
        _captureMetadataContradiction(
          ScanHints.fromCrop(track._capturedCrop!),
          ScanHints.fromCrop(observed),
        );
    if (printingChanged ||
        capturedMetadataChanged ||
        ((capturedContradiction ||
                _captureContradiction(track.crop, observed)) &&
            !preservedCapturedPrefix)) {
      track._invalidatePhotoFeedback();
      track._recoveryObservation = null;
      track._captureProofAt = null;
      track._capturedAt = null;
      track._capturedIdentified = false;
      track._identifiedSavedResolution = null;
      track._capturedCrop = null;
      track.resolution = null;
      track.error = null;
      track._resolvedKey = null;
      track._lastAttempt = null;
      track.stableFrames = 0;
    }
    if (_strongCaptureProof(observed)) track._captureProofAt = now;
    if (detection.lines.isNotEmpty &&
        detection.warnings.contains('incomplete_card') &&
        !detection.warnings.contains('partial_card') &&
        !track.capturedIdentified &&
        (track.resolution == null ||
            verifiedLiveHistoricalBodyIdentity(observed, track.resolution!) ==
                null)) {
      track.resolution = null;
      track._resolvedKey = null;
    }
    track.corners = List<ScanPoint>.unmodifiable(<ScanPoint>[
      for (int index = 0; index < 4; index++)
        ScanPoint(
          panelFootprint?[index].x ??
              track.corners[index].x * .35 + detection.corners[index].x * .65,
          panelFootprint?[index].y ??
              track.corners[index].y * .35 + detection.corners[index].y * .65,
        ),
    ]);
    track.confidence = detection.confidence;
    track.lastSeen = now;
    track.stableFrames++;
    // A geometry frame cannot reinterpret retained partial OCR as a full crop.
    if (detection.lines.isNotEmpty) {
      track._warnings = detection.warnings;
      if (detection.lines.isNotEmpty) track._lines = detection.lines;
    }
    if (detection.lines.isNotEmpty && _readableCardText(observed)) {
      _restoreCaptured(track, now);
      _rememberProof(track, now);
    }
  }

  void _restoreCaptured(LiveScanTrack track, DateTime now) {
    if (track.captured || !_readableCardText(track.crop)) return;
    _pendingCaptured.removeWhere(
      (_PendingCapturedTarget pending) =>
          _captureGeometryMatches(
            pending.target.crop.sourceCorners,
            track.corners,
          ) &&
          _captureContradiction(pending.target.crop, track.crop),
    );
    final _PendingCapturedTarget? pending = _pendingCaptured
        .where(
          (_PendingCapturedTarget pending) =>
              _captureGeometryMatches(
                pending.target.crop.sourceCorners,
                track.corners,
              ) &&
              _captureIdentityMatches(pending.target.crop, track.crop),
        )
        .firstOrNull;
    if (pending == null) return;
    _pendingCaptured.remove(pending);
    track._capturedAt = pending.savedAt;
    track._capturedCrop = pending.target.crop;
    track._capturedIdentified = false;
    track._identifiedSavedResolution = null;
    track._cardEvidenceAt = now;
  }

  Future<void> _drain() async {
    if (_drainingGeneration == _lookupGeneration ||
        _disposed ||
        _observationsSuspended) {
      return;
    }
    final int generation = _lookupGeneration;
    _drainingGeneration = generation;
    try {
      while (!_disposed && generation == _lookupGeneration) {
        LiveScanTrack? next;
        String? key;
        final DateTime now = _clock();
        for (final LiveScanTrack track in _tracks) {
          if (!track.hasCardEvidence ||
              track.capturedIdentified ||
              track.stableFrames < 2 ||
              now.difference(track.lastSeen) > expiry) {
            continue;
          }
          final String textKey = _evidenceKey(track.crop);
          if (textKey.isEmpty || track._resolvedKey == textKey) continue;
          if (track._lastAttempt != null &&
              now.difference(track._lastAttempt!) <
                  const Duration(seconds: 3)) {
            continue;
          }
          if (next == null ||
              (next._lastAttempt != null &&
                  (track._lastAttempt == null ||
                      track._lastAttempt!.isBefore(next._lastAttempt!)))) {
            next = track;
            key = textKey;
          }
        }
        if (next == null || key == null) break;
        final LiveScanTrack track = next;
        final ScanCrop crop = track.crop;
        track._lastAttempt = now;
        track.resolving = true;
        track.error = null;
        notifyListeners();
        try {
          final ScanResolution resolution;
          final ScanResolution? cached = _cache.remove(key);
          if (cached != null) {
            _cache[key] = cached;
            resolution = cached;
          } else {
            resolution = await _resolver.resolve(crop);
            if (_disposed || generation != _lookupGeneration) continue;
            _cache[key] = resolution;
            if (_cache.length > 128) _cache.remove(_cache.keys.first);
          }
          if (_current(track, generation) &&
              !track.capturedIdentified &&
              _evidenceKey(track.crop) == key) {
            track.resolution = resolution;
            track._resolvedKey = key;
            if (verifiedLiveHistoricalBodyIdentity(track.crop, resolution) !=
                null) {
              track._captureProofAt = _clock();
            }
            if (track.hasCatalogMatch || _trackCaptureProof(track)) {
              _rememberProof(track, _clock());
            }
          }
        } catch (_) {
          if (_current(track, generation)) {
            track.error = 'Identification unavailable';
          }
        } finally {
          if (_current(track, generation)) {
            track.resolving = false;
            notifyListeners();
          }
        }
      }
    } finally {
      if (_drainingGeneration == generation) _drainingGeneration = null;
    }
  }

  bool _current(LiveScanTrack track, int generation) =>
      !_disposed &&
      !_observationsSuspended &&
      generation == _lookupGeneration &&
      _tracks.contains(track);

  bool _recentStrongProof(LiveScanTrack track) => _recentProofs.any(
    (_RecentCaptureProof proof) =>
        proof.target.id == track.id &&
        _clock().difference(proof.observedAt) <= _maximumCapturedTextGap &&
        _targetCaptureProof(proof.target) &&
        !_captureContradiction(proof.target.crop, track.crop),
  );

  bool _geometryProofSupported(LiveScanTrack track, DateTime now) =>
      _pendingReceiptPresent(track, now) ||
      _recentStrongProof(track) ||
      (track.captured &&
          track._cardEvidenceAt != null &&
          now.difference(track._cardEvidenceAt!) <= _maximumCapturedTextGap &&
          _trackCaptureProof(track));

  List<ScanPoint>? _panelFootprint(
    LiveScanTrack track,
    List<ScanPoint> corners,
    DateTime now,
  ) {
    if (!_geometryProofSupported(track, now) ||
        (!_trackCaptureProof(track) && !_pendingReceiptPresent(track, now))) {
      return null;
    }
    final bool admitted =
        _captureStarted != null &&
        now.difference(_captureStarted!) <= _maximumCaptureGrace;
    final bool captured =
        _pendingReceiptPresent(track, now) ||
        (track._capturedAt != null &&
            now.difference(track._capturedAt!) <= _maximumCapturedTextGap);
    if (!captured &&
        (track._captureProofAt == null ||
            now.difference(track._captureProofAt!) >
                (admitted ? _maximumCapturedTextGap : _maximumTextGap))) {
      return null;
    }
    List<ScanPoint> whole = track.corners;
    final _RecentCaptureProof? proof = _recentProofs
        .where(
          (_RecentCaptureProof proof) =>
              proof.target.id == track.id &&
              _targetCaptureProof(proof.target) &&
              !_captureContradiction(proof.target.crop, track.crop),
        )
        .firstOrNull;
    if (proof != null &&
        !_captureGeometryMatches(proof.target.crop.sourceCorners, whole) &&
        _recoveryGeometryMatches(proof.target.crop.sourceCorners, whole)) {
      whole = proof.target.crop.sourceCorners;
    }
    if (_captureGeometryMatches(whole, corners) ||
        !_recoveryGeometryMatches(whole, corners) ||
        _tracks.any(
          (LiveScanTrack other) =>
              !identical(other, track) &&
              _geometryProofSupported(other, now) &&
              _strongCaptureProof(other.crop) &&
              _recoveryGeometryMatches(other.corners, corners),
        )) {
      return null;
    }
    return whole;
  }

  bool _rawGeometryMatches(
    LiveScanTrack track,
    List<ScanPoint> corners,
    DateTime now,
  ) {
    if (_captureGeometryMatches(track.corners, corners)) return true;
    if (_panelFootprint(track, corners, now) != null) return true;
    final bool recentSavedFootprint =
        _pendingReceiptPresent(track, now) ||
        (track._capturedAt != null &&
            now.difference(track._capturedAt!) <= _maximumCapturedTextGap &&
            _trackCaptureProof(track));
    if (!track.crop.warnings.contains('partial_card') ||
        (!recentSavedFootprint &&
            (track._captureProofAt == null ||
                now.difference(track._captureProofAt!) > _maximumTextGap)) ||
        !_geometryProofSupported(track, now)) {
      return false;
    }
    final _CardBounds proof = _bounds(track.corners);
    final _CardBounds proposal = _bounds(corners);
    if (proof.area <= 0 || proposal.area <= 0) return false;
    final double fraction = proposal.area / proof.area;
    final double intersection =
        math.max(
          0,
          math.min(proof.right, proposal.right) -
              math.max(proof.left, proposal.left),
        ) *
        math.max(
          0,
          math.min(proof.bottom, proposal.bottom) -
              math.max(proof.top, proposal.top),
        );
    final double dx =
        (proof.left + proof.right - proposal.left - proposal.right) / 2;
    final double dy =
        (proof.top + proof.bottom - proposal.top - proposal.bottom) / 2;
    return fraction >= .35 &&
        fraction <= .70 &&
        intersection / proposal.area >= .90 &&
        math.sqrt(dx * dx + dy * dy) <= .09;
  }

  bool _prune() {
    final int previous = _tracks.length;
    final DateTime now = _clock();
    _pruneMissingCaptureRetries(now);
    _acknowledgedCaptures.removeWhere(
      (LiveCaptureSnapshot capture) =>
          capture._acknowledgedAt == null ||
          (now.difference(capture._acknowledgedAt!) > _maximumCapturedTextGap &&
              !_completed.any(
                (_CompletedFootprint completed) =>
                    identical(completed.capture, capture),
              )),
    );
    _releasedCompletions.removeWhere(
      (String id, DateTime released) =>
          now.difference(released) > _maximumCapturedTextGap,
    );
    _releasedSaved.removeWhere(
      (String id, ScanCrop crop) => !_releasedCompletions.containsKey(id),
    );
    _tracks.removeWhere(
      (LiveScanTrack track) => _completed.any(
        (_CompletedFootprint completed) =>
            completed.id == track.id &&
            completed.identifiedAt != null &&
            now.difference(completed.identifiedAt!) >=
                const Duration(seconds: 3),
      ),
    );
    _pendingCaptured.removeWhere(
      (_PendingCapturedTarget pending) =>
          now.difference(pending.savedAt) > _maximumCapturedTextGap,
    );
    _recentProofs.removeWhere(
      (_RecentCaptureProof proof) =>
          now.difference(proof.observedAt) > _maximumCapturedTextGap,
    );
    _captureConflicts.removeWhere(
      (_CaptureConflict conflict) =>
          now.difference(conflict.observedAt) > _maximumCapturedTextGap,
    );
    if ((_captureStarted != null &&
            now.difference(_captureStarted!) < _maximumCaptureGrace) ||
        (_restartStarted != null &&
            now.difference(_restartStarted!) < _maximumRestartGrace)) {
      return false;
    }
    // Slow OCR must not expire its tracks, but stalled requests get a bounded grace.
    if (_frameAnalyses.values.any(
      (DateTime started) => now.difference(started) < _maximumAnalysisGrace,
    )) {
      return false;
    }
    _tracks.removeWhere((LiveScanTrack track) {
      if (_completed.any(
        (_CompletedFootprint completed) =>
            completed.id == track.id &&
            completed.identifiedAt != null &&
            now.difference(completed.identifiedAt!) <
                const Duration(seconds: 3),
      )) {
        return false;
      }
      if (_pendingReceiptPresent(track, now)) {
        return false;
      }
      if (track._capturedAt != null &&
          now.difference(track._capturedAt!) <= _maximumCapturedTextGap) {
        return false;
      }
      final bool recentIdentity = _recentStrongProof(track);
      return now.difference(track.lastSeen) > expiry ||
          (track._cardEvidenceAt != null &&
              now.difference(track._cardEvidenceAt!) >
                  (track.captured || recentIdentity
                      ? _maximumCapturedTextGap
                      : _maximumTextGap));
    });
    return previous != _tracks.length;
  }

  void suspendObservations() {
    if (_disposed) return;
    _observationsSuspended = true;
    _lookupGeneration++;
    _captureGeneration++;
    _captureStarted = null;
    _restartStarted = null;
    _frameAnalyses.clear();
    _currentGeometry = <List<ScanPoint>>[];
    _currentDetections = <LiveCardDetection>[];
    _geometryAt = null;
    _currentFrameStartedAt = null;
    _emptySceneStarted = null;
    _recentProofs.clear();
    _tracks.removeWhere((LiveScanTrack track) => !track.captured);
    for (final LiveScanTrack track in _tracks) {
      track.stableFrames = 0;
      track.resolving = false;
      track._lastAttempt = null;
      track._captureProofAt = null;
    }
    for (final _CompletedFootprint completed in _completed) {
      completed.missingSince = null;
      completed.settling = null;
      completed.settledFrames = 0;
      completed.changedFrames = 0;
      completed.backgroundFrames = 0;
      completed.changeStarted = null;
      completed.awaitingPresenceObservation = true;
    }
    for (final LiveCaptureSnapshot capture in _acknowledgedCaptures) {
      for (final _CaptureGeometry region in capture._physicalGeometry) {
        region.missingSince = null;
      }
    }
    for (final _MissingCaptureRetry retry in _missingCaptureRetries) {
      retry.missingSince = null;
    }
    notifyListeners();
  }

  void clear() {
    if (_disposed) return;
    _generation++;
    _lookupGeneration++;
    _observationsSuspended = false;
    _captureGeneration++;
    _captureStarted = null;
    _restartStarted = null;
    _tracks.clear();
    _completed.clear();
    _acknowledgedCaptures.clear();
    _releasedCompletions.clear();
    _releasedSaved.clear();
    _appearanceSamplingSupported = false;
    _pendingCaptured.clear();
    _missingCaptureRetries.clear();
    _recentProofs.clear();
    _captureConflicts.clear();
    _currentGeometry = <List<ScanPoint>>[];
    _currentDetections = <LiveCardDetection>[];
    _geometryAt = null;
    _currentFrameStartedAt = null;
    _emptySceneStarted = null;
    _lastRemovalSequence = 0;
    _recoveryDiagnostics.clear();
    _identificationDiagnostics.clear();
    _frameAnalyses.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _lookupGeneration++;
    _captureGeneration++;
    _captureStarted = null;
    _restartStarted = null;
    _expiryTimer.cancel();
    _tracks.clear();
    _completed.clear();
    _acknowledgedCaptures.clear();
    _releasedCompletions.clear();
    _releasedSaved.clear();
    _appearanceSamplingSupported = false;
    _pendingCaptured.clear();
    _missingCaptureRetries.clear();
    _recentProofs.clear();
    _captureConflicts.clear();
    _currentGeometry = <List<ScanPoint>>[];
    _currentDetections = <LiveCardDetection>[];
    _cache.clear();
    _frameAnalyses.clear();
    final ScanCatalog source = _resolver.catalog;
    if (_ownsResolver && source is ScryfallScanCatalog) source.close();
    super.dispose();
  }
}

class _Association {
  const _Association(this.track, this.cardIndex, this.score);
  final LiveScanTrack track;
  final int cardIndex;
  final double score;
}

ScanCrop _detectionCrop(LiveCardDetection detection) => ScanCrop(
  imagePath: '',
  width: 1000,
  height: 1400,
  rectified: !detection.warnings.contains('partial_card'),
  sourceCorners: detection.corners,
  lines: detection.lines,
  warnings: detection.warnings,
);

bool _recoveryGeometryMatches(List<ScanPoint> whole, List<ScanPoint> current) {
  if (_captureGeometryMatches(whole, current)) return true;
  if (whole.length != 4 || current.length != 4) return false;
  final _CardBounds proof = _bounds(whole);
  final _CardBounds proposal = _bounds(current);
  if (proof.area <= 0 || proposal.area <= 0) return false;
  final double fraction = proposal.area / proof.area;
  final double intersection =
      math.max(
        0,
        math.min(proof.right, proposal.right) -
            math.max(proof.left, proposal.left),
      ) *
      math.max(
        0,
        math.min(proof.bottom, proposal.bottom) -
            math.max(proof.top, proposal.top),
      );
  final double dx =
      (proof.left + proof.right - proposal.left - proposal.right) / 2;
  final double dy =
      (proof.top + proof.bottom - proposal.top - proposal.bottom) / 2;
  return fraction >= .16 &&
      fraction <= .70 &&
      intersection / proposal.area >= .90 &&
      math.sqrt(dx * dx + dy * dy) <= .11;
}

bool _flatBackgroundAppearance(List<double> rgb) {
  if (rgb.length != 288 ||
      rgb.any((double value) => !value.isFinite || value < 0 || value > 1)) {
    return false;
  }
  final List<double> luminance = <double>[
    for (int index = 0; index < rgb.length; index += 3)
      .2126 * rgb[index] + .7152 * rgb[index + 1] + .0722 * rgb[index + 2],
  ];
  final double mean =
      luminance.reduce((double a, double b) => a + b) / luminance.length;
  return mean >= .03 &&
      mean <= .90 &&
      math.sqrt(
            luminance.fold<double>(
                  0,
                  (double sum, double value) =>
                      sum + (value - mean) * (value - mean),
                ) /
                luminance.length,
          ) <
          .012;
}

List<double>? _normalizedAppearance(List<double> rgb) {
  if (rgb.length != 288 ||
      rgb.any((double value) => !value.isFinite || value < 0 || value > 1)) {
    return null;
  }
  final List<double> luminance = <double>[];
  final List<double> chroma = <double>[];
  int clipped = 0;
  for (int index = 0; index < rgb.length; index += 3) {
    final double r = rgb[index];
    final double g = rgb[index + 1];
    final double b = rgb[index + 2];
    final double light = .2126 * r + .7152 * g + .0722 * b;
    luminance.add(light);
    if (light < .015 || light > .985) clipped++;
    final double sum = math.max(.05, r + g + b);
    chroma.addAll(<double>[r / sum, b / sum]);
  }
  final double mean =
      luminance.reduce((double a, double b) => a + b) / luminance.length;
  final double deviation = math.sqrt(
    luminance.fold<double>(
          0,
          (double sum, double value) => sum + (value - mean) * (value - mean),
        ) /
        luminance.length,
  );
  if (deviation < .025 || clipped > 24) return null;
  return <double>[
    ...luminance.map(
      (double value) => ((value - mean) / deviation).clamp(-3, 3).toDouble(),
    ),
    ...chroma,
  ];
}

double _appearanceDifference(List<double> a, List<double> b) {
  double luminance = 0;
  double chroma = 0;
  for (int index = 0; index < 96; index++) {
    luminance += (a[index] - b[index]).abs();
  }
  for (int index = 96; index < a.length; index++) {
    chroma += (a[index] - b[index]).abs();
  }
  return .55 * luminance / 96 + 1.35 * chroma / 192;
}

bool _acknowledgedFootprintMatches(
  List<ScanPoint> frozen,
  List<ScanPoint> current,
) {
  if (frozen.length != 4 || current.length != 4) {
    return false;
  }
  final _CardBounds a = _bounds(frozen);
  final _CardBounds b = _bounds(current);
  if (a.area <= 0 || b.area <= 0) {
    return false;
  }
  final double ratio = b.area / a.area;
  final double intersection =
      math.max(0, math.min(a.right, b.right) - math.max(a.left, b.left)) *
      math.max(0, math.min(a.bottom, b.bottom) - math.max(a.top, b.top));
  final double dx = (a.left + a.right - b.left - b.right) / 2;
  final double dy = (a.top + a.bottom - b.top - b.bottom) / 2;
  return ratio >= .65 &&
      ratio <= 1.5 &&
      intersection / (a.area + b.area - intersection) >= .65 &&
      intersection / math.min(a.area, b.area) >= .9 &&
      math.sqrt(dx * dx + dy * dy) <= .06;
}

bool _historicalObservedTitleConflict(
  String identity,
  ScanCrop saved,
  ScanCrop observed,
) {
  final ScanCrop reliable = ScanCrop(
    imagePath: observed.imagePath,
    width: observed.width,
    height: observed.height,
    rectified: observed.rectified,
    sourceCorners: observed.sourceCorners,
    warnings: observed.warnings,
    lines: observed.lines
        .where((ScanTextLine line) => line.confidence >= .85)
        .toList(),
  );
  final ScanHints actual = ScanHints.fromCrop(
    observed,
    minimumConfidence: .85,
  );
  String normalized(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    '',
  );
  final List<ScanTextLine> titles = _titleLines(reliable.lines);
  if (titles.isEmpty) return false;
  final ScanTextLine anchor = titles.first;
  final List<String> observedNames = titles
      .where((ScanTextLine line) {
        final double ratio = line.bounds.width / anchor.bounds.width;
        final double overlap = math.max(
          0,
          math.min(
                line.bounds.x + line.bounds.width,
                anchor.bounds.x + anchor.bounds.width,
              ) -
              math.max(line.bounds.x, anchor.bounds.x),
        );
        return ratio >= .8 &&
            ratio <= 1.25 &&
            (line.bounds.y - anchor.bounds.y).abs() <= .035 &&
            (line.bounds.x - anchor.bounds.x).abs() <= .06 &&
            overlap / math.min(line.bounds.width, anchor.bounds.width) >= .85 &&
            normalized(line.text).length >= 3;
      })
      .map((ScanTextLine line) => line.text)
      .toList();
  const Set<String> colors = <String>{
    'white',
    'blue',
    'black',
    'red',
    'green',
    'colorless',
  };
  Set<String> titleColors(Iterable<String> names) => names
      .expand(
        (String name) =>
            RegExp(r'[a-z]+')
                .allMatches(name.toLowerCase())
                .map((RegExpMatch match) => match.group(0)!),
      )
      .toSet()
      .intersection(colors);
  final Set<String> expectedColors = titleColors(<String>[identity]);
  final Set<String> actualColors = titleColors(observedNames);
  if (expectedColors.isNotEmpty &&
      actualColors.isNotEmpty &&
      !setEquals(expectedColors, actualColors)) {
    return true;
  }
  final String expected = normalized(identity);
  final ScanHints savedHints = ScanHints.fromCrop(saved);
  return observedNames.any(
    (String title) =>
        normalized(title) != expected &&
        !(_compatibleNameplateStem(identity, title) &&
            _corroboratedTitleDrift(
              expected,
              normalized(title),
              savedHints,
              actual,
            )),
  );
}

// This contour belongs to the acknowledged photo; it never supplies identity or image coordinates.
bool _historicalOwnedInsetMatches(ScanCrop saved, List<ScanPoint> observed) {
  if (!hasVerifiedSavedBodyLayout(saved) ||
      !_ownershipQuad(saved.sourceCorners) ||
      !_ownershipQuad(observed)) {
    return false;
  }
  final double sourceArea = _ownershipPolygonArea(saved.sourceCorners);
  final double parentArea = _ownershipPolygonArea(observed);
  final double ratio = sourceArea / parentArea;
  final double overlap = _ownershipPolygonIntersection(
    saved.sourceCorners,
    observed,
  );
  final double dx =
      saved.sourceCorners.fold<double>(
            0,
            (double sum, ScanPoint point) => sum + point.x,
          ) /
          4 -
      observed.fold<double>(0, (double sum, ScanPoint point) => sum + point.x) /
          4;
  final double dy =
      saved.sourceCorners.fold<double>(
            0,
            (double sum, ScanPoint point) => sum + point.y,
          ) /
          4 -
      observed.fold<double>(0, (double sum, ScanPoint point) => sum + point.y) /
          4;
  return ratio >= .60 &&
      ratio <= .90 &&
      overlap / sourceArea >= .98 &&
      dx * dx + dy * dy <= .0036;
}

bool _ownershipQuad(List<ScanPoint> corners) {
  if (corners.length != 4 ||
      corners.any(
        (ScanPoint point) =>
            !point.x.isFinite ||
            !point.y.isFinite ||
            point.x < 0 ||
            point.x > 1 ||
            point.y < 0 ||
            point.y > 1,
      )) {
    return false;
  }
  double? direction;
  for (int index = 0; index < 4; index++) {
    final ScanPoint a = corners[index];
    final ScanPoint b = corners[(index + 1) % 4];
    final ScanPoint c = corners[(index + 2) % 4];
    final double cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
    if (cross.abs() < .000001 ||
        (direction != null && cross * direction <= 0)) {
      return false;
    }
    direction = cross;
  }
  return _ownershipPolygonArea(corners) >= .0001;
}

double _ownershipPolygonArea(List<ScanPoint> corners) {
  double area = 0;
  for (int index = 0; index < corners.length; index++) {
    final ScanPoint point = corners[index];
    final ScanPoint next = corners[(index + 1) % corners.length];
    area += point.x * next.y - next.x * point.y;
  }
  return area.abs() / 2;
}

double _ownershipPolygonIntersection(
  List<ScanPoint> subject,
  List<ScanPoint> clip,
) {
  double signed = 0;
  for (int index = 0; index < clip.length; index++) {
    final ScanPoint next = clip[(index + 1) % clip.length];
    signed += clip[index].x * next.y - next.x * clip[index].y;
  }
  final double direction = signed >= 0 ? 1 : -1;
  List<ScanPoint> polygon = subject;
  for (int index = 0; index < clip.length; index++) {
    if (polygon.isEmpty) {
      return 0;
    }
    final ScanPoint a = clip[index];
    final ScanPoint b = clip[(index + 1) % clip.length];
    double distance(ScanPoint point) =>
        direction *
        ((b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x));
    final List<ScanPoint> output = <ScanPoint>[];
    ScanPoint previous = polygon.last;
    double previousDistance = distance(previous);
    for (final ScanPoint point in polygon) {
      final double currentDistance = distance(point);
      if ((currentDistance >= 0) != (previousDistance >= 0)) {
        final double fraction =
            previousDistance / (previousDistance - currentDistance);
        output.add(
          ScanPoint(
            previous.x + fraction * (point.x - previous.x),
            previous.y + fraction * (point.y - previous.y),
          ),
        );
      }
      if (currentDistance >= 0) {
        output.add(point);
      }
      previous = point;
      previousDistance = currentDistance;
    }
    polygon = output;
  }
  return _ownershipPolygonArea(polygon);
}

bool _tightBodyFootprintMatches(
  List<ScanPoint> saved,
  List<ScanPoint> receipt,
) {
  if (saved.length != 4 || receipt.length != 4) {
    return false;
  }
  final _CardBounds a = _bounds(saved);
  final _CardBounds b = _bounds(receipt);
  if (a.area <= 0 || b.area <= 0) {
    return false;
  }
  final double intersection =
      math.max(0, math.min(a.right, b.right) - math.max(a.left, b.left)) *
      math.max(0, math.min(a.bottom, b.bottom) - math.max(a.top, b.top));
  final double dx = (a.left + a.right - b.left - b.right) / 2;
  final double dy = (a.top + a.bottom - b.top - b.bottom) / 2;
  return intersection / (a.area + b.area - intersection) >= .85 &&
      math.sqrt(dx * dx + dy * dy) <= .02;
}

bool _weakAdmittedInset(ScanCrop proof, ScanCrop receipt) {
  if (_strongCaptureProof(receipt) ||
      (!receipt.warnings.contains('small_image') &&
          !receipt.warnings.contains('incomplete_card')) ||
      _captureGeometryMatches(proof.sourceCorners, receipt.sourceCorners) ||
      !_recoveryGeometryMatches(proof.sourceCorners, receipt.sourceCorners) ||
      _titleLines(receipt.lines)
          .any((ScanTextLine line) => line.bounds.height < .07)) {
    return false;
  }
  final ScanHints a = ScanHints.fromCrop(proof);
  final ScanHints b = ScanHints.fromCrop(receipt);
  return !(a.setCode != null && b.setCode != null && a.setCode != b.setCode) &&
      !(a.collectorNumber != null &&
          b.collectorNumber != null &&
          a.collectorNumber != b.collectorNumber) &&
      !(a.language != null && b.language != null && a.language != b.language) &&
      !(a.typeLine != null && b.typeLine != null && a.typeLine != b.typeLine);
}

bool _validDetection(LiveCardDetection detection) =>
    detection.corners.length == 4 &&
    detection.confidence.isFinite &&
    detection.confidence >= .35 &&
    detection.corners.every(
      (ScanPoint point) =>
          point.x.isFinite &&
          point.y.isFinite &&
          point.x >= 0 &&
          point.x <= 1 &&
          point.y >= 0 &&
          point.y <= 1,
    ) &&
    _bounds(detection.corners).area > .001;

typedef _CardBounds = ({
  double left,
  double top,
  double right,
  double bottom,
  double area,
});

_CardBounds _bounds(List<ScanPoint> points) {
  final double left = points.map((ScanPoint p) => p.x).reduce(math.min);
  final double right = points.map((ScanPoint p) => p.x).reduce(math.max);
  final double top = points.map((ScanPoint p) => p.y).reduce(math.min);
  final double bottom = points.map((ScanPoint p) => p.y).reduce(math.max);
  return (
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    area: (right - left) * (bottom - top),
  );
}

double _associationScore(LiveScanTrack track, LiveCardDetection detection) {
  final _CardBounds a = _bounds(track.corners);
  final _CardBounds b = _bounds(detection.corners);
  final double ratio = a.area / b.area;
  if (ratio < .4 || ratio > 2.5) return 0;
  final double intersection =
      math.max(0, math.min(a.right, b.right) - math.max(a.left, b.left)) *
      math.max(0, math.min(a.bottom, b.bottom) - math.max(a.top, b.top));
  final double overlap = intersection / (a.area + b.area - intersection);
  final double dx = (a.left + a.right - b.left - b.right) / 2;
  final double dy = (a.top + a.bottom - b.top - b.bottom) / 2;
  final double distance = math.sqrt(dx * dx + dy * dy);
  if (overlap < .05 && distance > .13) return 0;
  return overlap + math.max(0, .13 - distance);
}

List<ScanTextLine> _titleLines(List<ScanTextLine> lines) =>
    lines
        .where(
          (ScanTextLine line) =>
              line.bounds.y < .13 &&
              line.bounds.x < .6 &&
              line.bounds.width > 0 &&
              line.bounds.width > line.bounds.height &&
              line.bounds.height < .20 &&
              line.textHeight > 0 &&
              line.textHeight < .07 &&
              line.confidence >= .8 &&
              !RegExp(r'^["“«]').hasMatch(line.text.trim()),
        )
        .toList()
      ..sort((ScanTextLine a, ScanTextLine b) {
        final int horizontal = a.bounds.x.compareTo(b.bounds.x);
        return horizontal == 0
            ? b.bounds.width.compareTo(a.bounds.width)
            : horizontal;
      });

String? _title(List<ScanTextLine> lines) => _titleLines(lines)
    .map(
      (ScanTextLine line) => line.text.toLowerCase().replaceAll(
        RegExp(r'[^\p{L}\p{N}]', unicode: true),
        '',
      ),
    )
    .where((String text) => text.length >= 3)
    .firstOrNull;

ScanHints _partialGeometryHints(ScanCrop crop) => ScanHints.fromCrop(
  ScanCrop(
    imagePath: '',
    width: crop.width,
    height: crop.height,
    rectified: false,
    sourceCorners: crop.sourceCorners,
    warnings: const <String>['partial_card'],
    lines: crop.lines,
  ),
  minimumConfidence: .85,
);

bool _preserveCapturedPrefix(ScanCrop captured, ScanCrop observed) {
  final ScanHints oldHints = ScanHints.fromCrop(captured);
  final ScanHints newHints = _partialGeometryHints(observed);
  if (oldHints.typeLine == null ||
      (newHints.typeLine != null && newHints.typeLine != oldHints.typeLine) ||
      (oldHints.setCode != null &&
          newHints.setCode != null &&
          oldHints.setCode != newHints.setCode) ||
      (oldHints.collectorNumber != null &&
          newHints.collectorNumber != null &&
          oldHints.collectorNumber != newHints.collectorNumber) ||
      (oldHints.language != null &&
          newHints.language != null &&
          oldHints.language != newHints.language) ||
      ScanResolver.rulesSearchPhrase(oldHints.rulesText) == null) {
    return false;
  }
  String normalized(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final String? oldTitle = _title(captured.lines);
  if (oldTitle == null || oldTitle.length < 12) return false;
  final bool clippedTitle = _titleLines(observed.lines)
      .any((ScanTextLine line) {
        final String title = normalized(line.text);
        return line.confidence >= .85 &&
            title.length >= 8 &&
            title.length <= oldTitle.length * .85 &&
            _singleRuleCharacterDifference(
              oldTitle.substring(0, 8),
              title.substring(0, 8),
            );
      });
  if (!clippedTitle) return false;
  final List<ScanTextLine> visibleBody = observed.lines
      .where(
        (ScanTextLine line) =>
            line.confidence >= .80 &&
            line.bounds.y >= .25 &&
            line.bounds.y < .85 &&
            line.bounds.x < .75 &&
            line.bounds.width >= .20 &&
            line.textHeight > 0 &&
            line.textHeight < .07,
      )
      .toList();
  final double quoteY = visibleBody
      .where(
        (ScanTextLine line) =>
            RegExp(r'^["“«]').hasMatch(line.text.trim()),
      )
      .fold<double>(
        1,
        (double earliest, ScanTextLine line) =>
            math.min(earliest, line.bounds.y),
      );
  final List<ScanTextLine> visibleRules = visibleBody
      .where(
        (ScanTextLine line) =>
            line.confidence >= .85 && line.bounds.y < quoteY,
      )
      .toList();
  const Set<String> colors = <String>{
    'white',
    'blue',
    'black',
    'red',
    'green',
    'colorless',
  };
  Set<String> observedColors(Iterable<String> text) => text
      .expand(
        (String line) =>
            RegExp(r'[a-z]+')
                .allMatches(line.toLowerCase())
                .map((RegExpMatch match) => match.group(0)!),
      )
      .toSet()
      .intersection(colors);
  final Set<String> oldColors = observedColors(<String>[
    ...oldHints.names,
    ...oldHints.rulesText,
  ]);
  final Set<String> newColors = observedColors(<String>[
    ..._titleLines(observed.lines).map((ScanTextLine line) => line.text),
    ...visibleRules.map((ScanTextLine line) => line.text),
  ]);
  if (oldColors.isNotEmpty &&
      newColors.isNotEmpty &&
      !setEquals(oldColors, newColors)) {
    return false;
  }
  final Set<String> knownRules = oldHints.rulesText
      .map(normalized)
      .where((String rule) => rule.length >= 24)
      .toSet();
  int matched = 0;
  for (final ScanTextLine line in visibleRules) {
    final String prefix = normalized(line.text);
    if (prefix.length < 18) continue;
    final String? matching = knownRules
        .where((String rule) => rule.startsWith(prefix))
        .firstOrNull;
    if (matching != null) {
      knownRules.remove(matching);
      matched++;
    }
  }
  return matched >= 2;
}

bool _captureContradiction(ScanCrop saved, ScanCrop current) {
  final String? oldName = _title(saved.lines);
  final String? newName = _title(current.lines);
  final ScanHints oldHints = ScanHints.fromCrop(saved);
  final ScanHints newHints = ScanHints.fromCrop(current);
  if (_captureMetadataContradiction(oldHints, newHints)) {
    return true;
  }
  if (oldName == null &&
      newName != null &&
      ScanHints.observedSavedBodySelfReference(saved) != null &&
      !_corroboratedBodySelfReference(saved, current, oldHints, newHints)) {
    return true;
  }
  const Set<String> colors = <String>{
    'white',
    'blue',
    'black',
    'red',
    'green',
    'colorless',
  };
  Set<String> titleColors(ScanCrop crop) =>
      _titleLines(crop.lines)
          .where((ScanTextLine line) => line.confidence >= .85)
          .expand(
            (ScanTextLine line) =>
                RegExp(r'[a-z]+')
                    .allMatches(line.text.toLowerCase())
                    .map((RegExpMatch match) => match.group(0)!),
          )
          .toSet()
          .intersection(colors);
  final Set<String> oldColors = titleColors(saved);
  final Set<String> newColors = titleColors(current);
  if (oldColors.isNotEmpty &&
      newColors.isNotEmpty &&
      !setEquals(oldColors, newColors)) {
    return true;
  }
  if (oldName != null &&
      newName != null &&
      oldName.length >= 12 &&
      oldName.length == newName.length &&
      _singleRuleCharacterDifference(oldName, newName) &&
      newHints.typeLine == null &&
      newHints.rulesText.isEmpty &&
      newHints.setCode == null &&
      newHints.collectorNumber == null) {
    return false;
  }
  return oldName != null &&
      newName != null &&
      oldName != newName &&
      !_corroboratedBodySelfReference(saved, current, oldHints, newHints) &&
      !_corroboratedTitleDrift(oldName, newName, oldHints, newHints) &&
      !_corroboratedWordTitleDrift(saved, current, oldHints, newHints) &&
      !_corroboratedTitlePasses(saved, current, oldHints, newHints);
}

bool _corroboratedBodySelfReference(
  ScanCrop first,
  ScanCrop second,
  ScanHints a,
  ScanHints b,
) {
  if (a.typeLine == null || a.typeLine != b.typeLine) return false;
  String normalized(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    '',
  );
  final String? firstSelf =
      ScanHints.observedBodySelfReference(first) ??
      ScanHints.observedSavedBodySelfReference(first);
  final String? secondSelf =
      ScanHints.observedBodySelfReference(second) ??
      ScanHints.observedSavedBodySelfReference(second);
  final bool sameObservedName =
      (firstSelf != null &&
          b.names.any(
            (String name) => normalized(name) == normalized(firstSelf),
          )) ||
      (secondSelf != null &&
          a.names.any(
            (String name) => normalized(name) == normalized(secondSelf),
          ));
  if (!sameObservedName) return false;
  Set<String> literalBody(ScanCrop crop, ScanHints hints) {
    final List<ScanTextLine> body =
        crop.lines
            .where(
              (ScanTextLine line) =>
                  line.confidence >= .90 &&
                  line.bounds.y >= .50 &&
                  line.bounds.y < .86,
            )
            .toList()
          ..sort(
            (ScanTextLine left, ScanTextLine right) =>
                left.bounds.y.compareTo(right.bounds.y),
          );
    final Set<String> result = <String>{};
    for (final ScanTextLine line in body) {
      if (RegExp(r'^["“«]').hasMatch(line.text.trim())) break;
      final String text = normalized(line.text);
      if (text.length >= 16 && hints.rulesText.contains(line.text.trim())) {
        result.add(text);
      }
    }
    return result;
  }

  final Set<String> firstRules = literalBody(first, a);
  final Set<String> secondRules = literalBody(second, b);
  return firstRules.intersection(secondRules).length >= 3;
}

bool _corroboratedTitlePasses(
  ScanCrop first,
  ScanCrop second,
  ScanHints a,
  ScanHints b,
) {
  List<ScanTextLine> passes(ScanCrop crop) {
    final List<ScanTextLine> titles = _titleLines(crop.lines);
    if (titles.isEmpty) {
      return titles;
    }
    final ScanTextLine anchor = titles.first;
    return titles.where((ScanTextLine line) {
      final double ratio = line.bounds.width / anchor.bounds.width;
      final double overlap = math.max(
        0,
        math.min(
              line.bounds.x + line.bounds.width,
              anchor.bounds.x + anchor.bounds.width,
            ) -
            math.max(line.bounds.x, anchor.bounds.x),
      );
      return line.confidence >= .85 &&
          ratio >= .8 &&
          ratio <= 1.25 &&
          (line.bounds.y - anchor.bounds.y).abs() <= .035 &&
          (line.bounds.x - anchor.bounds.x).abs() <= .06 &&
          overlap / math.min(line.bounds.width, anchor.bounds.width) >= .85;
    }).toList();
  }

  final List<ScanTextLine> firstPasses = passes(first);
  final List<ScanTextLine> secondPasses = passes(second);
  if (firstPasses.length < 2 && secondPasses.length < 2) {
    return false;
  }
  String normalized(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    '',
  );
  return firstPasses.any(
    (ScanTextLine left) => secondPasses.any(
      (ScanTextLine right) =>
          _compatibleNameplateStem(left.text, right.text) &&
          _corroboratedTitleDrift(
            normalized(left.text),
            normalized(right.text),
            a,
            b,
          ),
    ),
  );
}

bool _compatibleNameplateStem(String first, String second) {
  String? stem(String text) =>
      RegExp(r'\p{L}+', unicode: true).firstMatch(text.toLowerCase())?.group(0);
  final String? left = stem(first);
  final String? right = stem(second);
  if (left == null || right == null) {
    return false;
  }
  if (left == right) {
    return true;
  }
  if (math.min(left.length, right.length) < 4) {
    return false;
  }
  List<int> previous = List<int>.generate(right.length + 1, (int i) => i);
  for (int row = 0; row < left.length; row++) {
    final List<int> current = <int>[row + 1];
    for (int column = 0; column < right.length; column++) {
      current.add(
        math.min(
          math.min(current[column] + 1, previous[column + 1] + 1),
          previous[column] +
              (left.codeUnitAt(row) == right.codeUnitAt(column) ? 0 : 1),
        ),
      );
    }
    previous = current;
  }
  return previous.last <= 2;
}

bool _captureMetadataContradiction(ScanHints oldHints, ScanHints newHints) =>
    (oldHints.setCode != null &&
        newHints.setCode != null &&
        oldHints.setCode != newHints.setCode) ||
    (oldHints.collectorNumber != null &&
        newHints.collectorNumber != null &&
        oldHints.collectorNumber != newHints.collectorNumber) ||
    (oldHints.language != null &&
        newHints.language != null &&
        oldHints.language != newHints.language) ||
    (oldHints.typeLine != null &&
        newHints.typeLine != null &&
        oldHints.typeLine != newHints.typeLine);

bool _corroboratedWordTitleDrift(
  ScanCrop first,
  ScanCrop second,
  ScanHints a,
  ScanHints b,
) {
  if (first.sourceCorners.length != 4 ||
      second.sourceCorners.length != 4 ||
      a.typeLine == null ||
      a.typeLine != b.typeLine ||
      ScanResolver.rulesSearchPhrase(a.rulesText) == null ||
      ScanResolver.rulesSearchPhrase(b.rulesText) == null) {
    return false;
  }
  final _CardBounds firstBounds = _bounds(first.sourceCorners);
  final _CardBounds secondBounds = _bounds(second.sourceCorners);
  final double intersection =
      math.max(
        0,
        math.min(firstBounds.right, secondBounds.right) -
            math.max(firstBounds.left, secondBounds.left),
      ) *
      math.max(
        0,
        math.min(firstBounds.bottom, secondBounds.bottom) -
            math.max(firstBounds.top, secondBounds.top),
      );
  final double ratio = firstBounds.area / secondBounds.area;
  final double overlap =
      intersection / (firstBounds.area + secondBounds.area - intersection);
  final double dx =
      (firstBounds.left +
          firstBounds.right -
          secondBounds.left -
          secondBounds.right) /
      2;
  final double dy =
      (firstBounds.top +
          firstBounds.bottom -
          secondBounds.top -
          secondBounds.bottom) /
      2;
  if (ratio < .85 ||
      ratio > 1.18 ||
      overlap < .9 ||
      math.sqrt(dx * dx + dy * dy) > .02) {
    return false;
  }
  String normalized(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final Set<String> firstRules = a.rulesText
      .map(normalized)
      .where((String text) => text.length >= 24)
      .toSet();
  final Set<String> secondRules = b.rulesText
      .map(normalized)
      .where((String text) => text.length >= 24)
      .toSet();
  if (firstRules.intersection(secondRules).length < 2) {
    return false;
  }
  final ScanTextLine? firstTitle = _titleLines(first.lines).firstOrNull;
  final ScanTextLine? secondTitle = _titleLines(second.lines).firstOrNull;
  if (firstTitle == null ||
      secondTitle == null ||
      firstTitle.confidence < .85 ||
      secondTitle.confidence < .85) {
    return false;
  }
  List<String> words(String text) =>
      RegExp(r'[a-z]+')
          .allMatches(text.toLowerCase())
          .map((RegExpMatch match) => match.group(0)!)
          .toList();
  const Set<String> colors = <String>{
    'white',
    'blue',
    'black',
    'red',
    'green',
    'colorless',
  };
  final Set<String> firstColors = <String>[
    firstTitle.text,
    ...a.rulesText,
  ].expand(words).toSet().intersection(colors);
  final Set<String> secondColors = <String>[
    secondTitle.text,
    ...b.rulesText,
  ].expand(words).toSet().intersection(colors);
  if (firstColors.isEmpty || !setEquals(firstColors, secondColors)) {
    return false;
  }
  final List<String> firstWords = words(firstTitle.text);
  final List<String> secondWords = words(secondTitle.text);
  if (firstWords.length < 3 ||
      firstWords.length > 8 ||
      firstWords.length != secondWords.length ||
      firstWords.last != secondWords.last) {
    return false;
  }
  int changedWords = 0;
  int totalEdits = 0;
  for (int index = 0; index < firstWords.length; index++) {
    final String left = firstWords[index];
    final String right = secondWords[index];
    if (left == right) continue;
    if (math.min(left.length, right.length) < 4) {
      return false;
    }
    List<int> previous = List<int>.generate(right.length + 1, (int i) => i);
    for (int row = 0; row < left.length; row++) {
      final List<int> current = <int>[row + 1];
      for (int column = 0; column < right.length; column++) {
        current.add(
          math.min(
            math.min(current[column] + 1, previous[column + 1] + 1),
            previous[column] +
                (left.codeUnitAt(row) == right.codeUnitAt(column) ? 0 : 1),
          ),
        );
      }
      previous = current;
    }
    if (previous.last > (math.max(left.length, right.length) / 2).floor()) {
      return false;
    }
    changedWords++;
    totalEdits += previous.last;
  }
  return changedWords <= 2 && totalEdits <= 6;
}

bool _savedCaptureGeometryProof(ScanCrop crop) =>
    _strongCaptureProof(crop) || hasVerifiedSavedBodyLayout(crop);

bool _targetCaptureProof(_CaptureTarget target) =>
    _strongCaptureProof(target.crop) ||
    (target.historicalResolution != null &&
        verifiedLiveHistoricalBodyIdentity(
              target.crop,
              target.historicalResolution!,
            ) !=
            null);

bool _trackCaptureProof(LiveScanTrack track) =>
    _strongCaptureProof(track.crop) ||
    (track.resolution != null &&
        verifiedLiveHistoricalBodyIdentity(track.crop, track.resolution!) !=
            null);

bool _strongCaptureProof(ScanCrop crop) {
  final List<ScanTextLine> reliable = crop.lines
      .where((ScanTextLine line) => line.confidence >= .85)
      .toList();
  final ScanHints hints = ScanHints.fromCrop(
    crop,
    minimumConfidence: .85,
  );
  return (hints.setCode != null && hints.collectorNumber != null) ||
      (reliable.any(
            (ScanTextLine line) =>
                line.bounds.y < .13 &&
                line.bounds.x < .6 &&
                line.bounds.width >= .1 &&
                line.textHeight > 0 &&
                line.textHeight < .07 &&
                line.text.trim().length >= 3,
          ) &&
          hints.typeLine != null &&
          ScanResolver.rulesSearchPhrase(hints.rulesText) != null);
}

bool _corroboratedTitleDrift(
  String first,
  String second,
  ScanHints a,
  ScanHints b,
) {
  if (math.min(first.length, second.length) < 12 ||
      (a.typeLine == null && b.typeLine == null) ||
      ScanResolver.rulesSearchPhrase(a.rulesText) == null ||
      ScanResolver.rulesSearchPhrase(b.rulesText) == null) {
    return false;
  }
  Set<String> words(Iterable<String> lines) => lines
      .expand(
        (String text) =>
            RegExp(r'[a-z0-9]+')
                .allMatches(text.toLowerCase())
                .map((RegExpMatch match) => match.group(0)!),
      )
      .toSet();
  const Set<String> colors = <String>{
    'white',
    'blue',
    'black',
    'red',
    'green',
    'colorless',
  };
  final Set<String> firstColors = words(<String>[...a.names, ...a.rulesText])
      .intersection(colors);
  final Set<String> secondColors = words(<String>[...b.names, ...b.rulesText])
      .intersection(colors);
  if (firstColors.isNotEmpty &&
      secondColors.isNotEmpty &&
      !setEquals(firstColors, secondColors)) {
    return false;
  }
  String normalized(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final Set<String> firstRules = a.rulesText
      .map(normalized)
      .where((String line) => line.length >= 24)
      .toSet();
  final Set<String> secondRules = b.rulesText
      .map(normalized)
      .where((String line) => line.length >= 24)
      .toSet();
  if (firstRules.intersection(secondRules).length < 2) return false;
  final int limit = math.min(
    5,
    (math.max(first.length, second.length) * .25).floor(),
  );
  List<int> previous = List<int>.generate(
    second.length + 1,
    (int index) => index,
  );
  for (int row = 0; row < first.length; row++) {
    final List<int> current = <int>[row + 1];
    for (int column = 0; column < second.length; column++) {
      current.add(
        math.min(
          math.min(current[column] + 1, previous[column + 1] + 1),
          previous[column] +
              (first.codeUnitAt(row) == second.codeUnitAt(column) ? 0 : 1),
        ),
      );
    }
    previous = current;
  }
  return previous.last <= limit;
}

bool _captureIdentityMatches(ScanCrop saved, ScanCrop current) {
  if (_captureContradiction(saved, current)) return false;
  final ScanHints a = ScanHints.fromCrop(saved);
  final ScanHints b = ScanHints.fromCrop(current);
  if (_corroboratedBodySelfReference(saved, current, a, b)) return true;
  if (a.names.any(
    (String name) => b.names.any(
      (String other) => name.toLowerCase() == other.toLowerCase(),
    ),
  )) {
    return true;
  }
  if (a.setCode != null &&
      a.collectorNumber != null &&
      a.setCode == b.setCode &&
      a.collectorNumber == b.collectorNumber) {
    return true;
  }
  String normalized(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final Set<String> first = a.rulesText
      .map(normalized)
      .where((String text) => text.length >= 24)
      .toSet();
  final Set<String> second = b.rulesText
      .map(normalized)
      .where((String text) => text.length >= 24)
      .toSet();
  return ScanResolver.rulesSearchPhrase(a.rulesText) != null &&
      ScanResolver.rulesSearchPhrase(b.rulesText) != null &&
      first.intersection(second).length >= 2;
}

bool _savedCaptureGeometryMatches(ScanCrop saved, ScanCrop captured) {
  if (_captureGeometryMatches(saved.sourceCorners, captured.sourceCorners)) {
    return true;
  }
  if (saved.sourceCorners.length != 4 ||
      captured.sourceCorners.length != 4 ||
      _captureContradiction(saved, captured)) {
    return false;
  }
  ScanHints reliableHints(ScanCrop crop) => ScanHints.fromCrop(
    crop,
    minimumConfidence: .85,
  );
  final ScanHints a = reliableHints(saved);
  final ScanHints b = reliableHints(captured);
  final String? firstType =
      a.typeLine ??
      (saved.warnings.contains('geometry_adjusted')
          ? _partialGeometryHints(saved).typeLine
          : null);
  final String? secondType =
      b.typeLine ??
      (captured.warnings.contains('geometry_adjusted')
          ? _partialGeometryHints(captured).typeLine
          : null);
  if (firstType == null ||
      firstType != secondType ||
      ScanResolver.rulesSearchPhrase(a.rulesText) == null ||
      ScanResolver.rulesSearchPhrase(b.rulesText) == null) {
    return false;
  }
  Set<String> rules(ScanHints hints) => hints.rulesText
      .map(
        (String text) =>
            text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''),
      )
      .where((String text) => text.length >= 24)
      .toSet();
  final bool sameTitle = a.names.any(
    (String name) => b.names.any(
      (String other) => name.toLowerCase() == other.toLowerCase(),
    ),
  );
  final Set<String> firstRules = rules(a);
  final Set<String> secondRules = rules(b);
  final Set<String> remainingRules = Set<String>.of(secondRules);
  int matchedRules = 0;
  for (final String rule in firstRules) {
    if (remainingRules.remove(rule)) matchedRules++;
  }
  if (sameTitle) {
    for (final String rule in firstRules.where(
      (String rule) => !secondRules.contains(rule),
    )) {
      final String? matching = remainingRules
          .where((String other) => _singleRuleCharacterDifference(rule, other))
          .firstOrNull;
      if (matching != null) {
        remainingRules.remove(matching);
        matchedRules++;
      }
    }
  }
  if (matchedRules < 2) {
    return false;
  }
  const Set<String> colors = <String>{
    'white',
    'blue',
    'black',
    'red',
    'green',
    'colorless',
  };
  Set<String> observedColors(ScanHints hints) =>
      <String>[...hints.names, ...hints.rulesText]
          .expand(
            (String text) =>
                RegExp(r'[a-z]+')
                    .allMatches(text.toLowerCase())
                    .map((RegExpMatch match) => match.group(0)!),
          )
          .toSet()
          .intersection(colors);
  final Set<String> firstColors = observedColors(a);
  final Set<String> secondColors = observedColors(b);
  if (firstColors.isNotEmpty &&
      secondColors.isNotEmpty &&
      !setEquals(firstColors, secondColors)) {
    return false;
  }
  final _CardBounds first = _bounds(saved.sourceCorners);
  final _CardBounds second = _bounds(captured.sourceCorners);
  if (first.area <= 0 || second.area <= 0) return false;
  final double ratio = first.area / second.area;
  final double intersection =
      math.max(
        0,
        math.min(first.right, second.right) - math.max(first.left, second.left),
      ) *
      math.max(
        0,
        math.min(first.bottom, second.bottom) - math.max(first.top, second.top),
      );
  final double overlap =
      intersection / (first.area + second.area - intersection);
  final double dx = (first.left + first.right - second.left - second.right) / 2;
  final double dy = (first.top + first.bottom - second.top - second.bottom) / 2;
  return ratio >= .55 &&
      ratio <= 1.8 &&
      overlap >= (sameTitle ? .58 : .60) &&
      intersection / math.min(first.area, second.area) >= .90 &&
      math.sqrt(dx * dx + dy * dy) <= .04;
}

bool _singleRuleCharacterDifference(String first, String second) {
  if ((first.length - second.length).abs() > 1) return false;
  int firstIndex = 0;
  int secondIndex = 0;
  int differences = 0;
  while (firstIndex < first.length && secondIndex < second.length) {
    if (first.codeUnitAt(firstIndex) == second.codeUnitAt(secondIndex)) {
      firstIndex++;
      secondIndex++;
      continue;
    }
    if (++differences > 1) return false;
    if (first.length >= second.length) firstIndex++;
    if (second.length >= first.length) secondIndex++;
  }
  return differences +
          (first.length - firstIndex) +
          (second.length - secondIndex) <=
      1;
}

bool _captureGeometryMatches(List<ScanPoint> saved, List<ScanPoint> current) {
  if (saved.length != 4 || current.length != 4) return false;
  final _CardBounds a = _bounds(saved);
  final _CardBounds b = _bounds(current);
  if (a.area <= 0 || b.area <= 0) return false;
  final double ratio = a.area / b.area;
  if (ratio < .75 || ratio > 1.33) return false;
  final double intersection =
      math.max(0, math.min(a.right, b.right) - math.max(a.left, b.left)) *
      math.max(0, math.min(a.bottom, b.bottom) - math.max(a.top, b.top));
  final double overlap = intersection / (a.area + b.area - intersection);
  final double dx = (a.left + a.right - b.left - b.right) / 2;
  final double dy = (a.top + a.bottom - b.top - b.bottom) / 2;
  return overlap >= .60 && math.sqrt(dx * dx + dy * dy) <= .06;
}

bool _readableCardText(ScanCrop crop) {
  final List<ScanTextLine> reliable = crop.lines
      .where((ScanTextLine line) => line.confidence >= .65)
      .toList();
  final ScanHints hints = ScanHints.fromCrop(
    ScanCrop(
      imagePath: '',
      width: crop.width,
      height: crop.height,
      rectified: crop.rectified,
      sourceCorners: crop.sourceCorners,
      lines: reliable,
      warnings: crop.warnings,
    ),
  );
  if (hints.names.isNotEmpty ||
      hints.typeLine != null ||
      (hints.setCode != null && hints.collectorNumber != null)) {
    return true;
  }
  final RegExp cardRules = RegExp(
    r'\b(?:target|creature|battlefield|mana|draw|discard|counter|spell|damage|exile|sacrifice|token|library|graveyard)\b',
    caseSensitive: false,
  );
  return reliable.any(
    (ScanTextLine line) =>
        line.bounds.y >= .45 &&
        line.bounds.y < .86 &&
        line.bounds.width >= .2 &&
        line.text.trim().length >= 8 &&
        cardRules.hasMatch(line.text),
  );
}

String _evidenceKey(ScanCrop crop) {
  final ScanHints hints = ScanHints.fromCrop(crop);
  final List<ScanTextLine> reliable = crop.lines
      .where((ScanTextLine line) => line.confidence >= .65)
      .where((ScanTextLine line) => line.text.trim().length >= 3)
      .take(64)
      .toList();
  if (reliable.isEmpty) return '';
  return jsonEncode(<String, Object?>{
    'warnings': crop.warnings,
    'names': hints.names,
    'rules': hints.rulesText,
    'type': hints.typeLine,
    'set': hints.setCode,
    'number': hints.collectorNumber,
    'language': hints.language,
    'lines': <List<Object>>[
      for (final ScanTextLine line in reliable)
        <Object>[
          line.text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' '),
          line.bounds.y < .13
              ? 'title'
              : line.bounds.y > .70
              ? 'footer'
              : 'body',
          line.confidence >= .85
              ? 85
              : line.confidence >= .80
              ? 80
              : line.confidence >= .75
              ? 75
              : 65,
        ],
    ],
  });
}
