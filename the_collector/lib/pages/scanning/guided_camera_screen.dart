import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:arcane/arcane.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../theme/collector_brand.dart';
import '../../utils/scanning/live_scan_detector.dart';
import '../../utils/scanning/scan_camera_lens_policy.dart';
import '../../utils/scanning/scan_capture_feedback.dart';
import '../../utils/scanning/scan_card_lighting.dart';
import '../../utils/scanning/scan_exposure_policy.dart';
import '../../utils/scanning/scan_focus_stack.dart';
import '../../utils/scanning/scan_recognition.dart';
import '../../utils/scanning/scan_session.dart';
import '../../utils/scanning/scan_resolver.dart';
import '../../utils/scanning/live_scan_tracker.dart';
import 'capture_preview_transform.dart';
import 'live_capture_overlay.dart';

class GuidedCameraScreen extends StatefulWidget {
  final Future<bool> Function(String, List<List<ScanPoint>>)? onCaptured;
  final Future<bool> Function(
    List<String>,
    List<List<ScanPoint>>,
    String,
    List<List<ScanPoint>>?,
  )?
  onFocusStackCaptured;
  final Future<bool> Function(
    List<String>,
    List<List<ScanPoint>>,
    String,
    List<List<ScanPoint>>,
  )?
  onUnidentifiedPhotoCaptured;
  final bool automaticCapture;
  final bool active;
  final bool stationaryFocusStack;
  final bool multipleCards;
  final bool continuous;
  final ScanSession? session;
  final String destinationLabel;
  final Future<void> Function()? onClearCaptures;
  final WidgetBuilder? captureDrawerBuilder;
  final VoidCallback? onDone;
  @visibleForTesting
  final DateTime Function()? feedbackClock;
  const GuidedCameraScreen({
    super.key,
    this.onCaptured,
    this.onFocusStackCaptured,
    this.onUnidentifiedPhotoCaptured,
    this.automaticCapture = true,
    this.active = true,
    this.stationaryFocusStack = false,
    this.multipleCards = false,
    this.continuous = true,
    this.session,
    this.destinationLabel = 'Collection',
    this.onClearCaptures,
    this.captureDrawerBuilder,
    this.onDone,
    this.feedbackClock,
  });

  @visibleForTesting
  static List<List<ScanPoint>>? freezeCaptureExclusions(
    Iterable<List<ScanPoint>> candidates,
  ) {
    final List<List<ScanPoint>> regions = <List<ScanPoint>>[];
    for (final List<ScanPoint> region in candidates) {
      if (regions.any(
        (List<ScanPoint> outside) => _regionContains(outside, region),
      )) {
        continue;
      }
      regions.removeWhere(
        (List<ScanPoint> inside) => _regionContains(region, inside),
      );
      regions.add(List<ScanPoint>.unmodifiable(region));
    }
    return regions.length > 8
        ? null
        : List<List<ScanPoint>>.unmodifiable(regions);
  }

  static bool _regionContains(List<ScanPoint> outside, List<ScanPoint> inside) {
    if (outside.length != 4 || inside.length != 4) return false;
    double? direction;
    for (int index = 0; index < 4; index++) {
      final ScanPoint a = outside[index];
      final ScanPoint b = outside[(index + 1) % 4];
      final ScanPoint c = outside[(index + 2) % 4];
      final double turn = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
      if (!turn.isFinite || turn.abs() < 1e-10) return false;
      if (direction != null && direction * turn < 0) return false;
      direction = turn;
    }
    for (final ScanPoint point in inside) {
      for (int index = 0; index < 4; index++) {
        final ScanPoint a = outside[index];
        final ScanPoint b = outside[(index + 1) % 4];
        final double side =
            (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x);
        if (!side.isFinite || side * direction! < -1e-10) return false;
      }
    }
    return true;
  }

  @visibleForTesting
  static bool isCapturedCardPanel(
    List<ScanPoint> candidate,
    List<ScanPoint> owner,
  ) {
    bool valid(List<ScanPoint> points) =>
        points.length == 4 &&
        points.every(
          (ScanPoint point) =>
              point.x.isFinite &&
              point.y.isFinite &&
              point.x >= 0 &&
              point.x <= 1 &&
              point.y >= 0 &&
              point.y <= 1,
        ) &&
        _regionContains(points, points);
    if (!valid(candidate) || !valid(owner)) return false;
    double area(List<ScanPoint> points) {
      double twice = 0;
      for (int index = 0; index < points.length; index++) {
        final ScanPoint first = points[index];
        final ScanPoint next = points[(index + 1) % points.length];
        twice += first.x * next.y - next.x * first.y;
      }
      return twice / 2;
    }

    final double candidateArea = area(candidate).abs();
    final double signedOwnerArea = area(owner);
    if (candidateArea <= 1e-10 || candidateArea > signedOwnerArea.abs() * .75) {
      return false;
    }
    final ScanPoint center = ScanPoint(
      candidate.fold<double>(0, (double value, ScanPoint p) => value + p.x) / 4,
      candidate.fold<double>(0, (double value, ScanPoint p) => value + p.y) / 4,
    );
    if (!_regionContains(owner, List<ScanPoint>.filled(4, center))) {
      return false;
    }
    List<ScanPoint> polygon = candidate;
    for (int index = 0; index < owner.length; index++) {
      if (polygon.isEmpty) return false;
      final ScanPoint start = owner[index];
      final ScanPoint end = owner[(index + 1) % owner.length];
      double side(ScanPoint point) =>
          ((end.x - start.x) * (point.y - start.y) -
              (end.y - start.y) * (point.x - start.x)) *
          signedOwnerArea.sign;
      final List<ScanPoint> clipped = <ScanPoint>[];
      ScanPoint previous = polygon.last;
      double previousSide = side(previous);
      for (final ScanPoint point in polygon) {
        final double currentSide = side(point);
        if ((currentSide >= 0) != (previousSide >= 0)) {
          final double fraction = previousSide / (previousSide - currentSide);
          clipped.add(
            ScanPoint(
              previous.x + fraction * (point.x - previous.x),
              previous.y + fraction * (point.y - previous.y),
            ),
          );
        }
        if (currentSide >= 0) clipped.add(point);
        previous = point;
        previousSide = currentSide;
      }
      polygon = clipped;
    }
    return area(polygon).abs() / candidateArea >= .90;
  }

  @override
  State<GuidedCameraScreen> createState() => _GuidedCameraScreenState();
}

typedef _UnidentifiedPhotoHandoff = Future<bool> Function(
  List<String>,
  List<List<ScanPoint>>,
  String,
  List<List<ScanPoint>>,
);

typedef _TrackedPhotoHandoff = Future<bool> Function(
  List<String>,
  List<List<ScanPoint>>,
  String,
  List<List<ScanPoint>>?,
);
typedef _SinglePhotoHandoff = Future<bool> Function(
  String,
  List<List<ScanPoint>>,
);

enum _CapturePhase { idle, focusing, takingPhoto, saving, discarding }

class _RawContour {
  _RawContour(
    this.corners, {
    this.receiptId,
    this.capture,
    this.paths,
    List<double>? captureAppearance,
  }) : frozenCorners = List<ScanPoint>.unmodifiable(corners),
       _captureBaseline = captureAppearance,
       _baseline = captureAppearance;
  final String? receiptId;
  final LiveCaptureSnapshot? capture;
  final List<String>? paths;
  final List<ScanPoint> frozenCorners;
  List<ScanPoint> corners;
  int stableFrames = 1;
  int lastObservedFrame = 0;
  int? _focusRequestGeneration;
  DateTime? lastObservedAt;
  bool visible = true;
  List<double>? _baseline;
  List<double>? _captureBaseline;
  List<double>? _currentAppearance;
  DateTime? _currentAppearanceAt;
  List<double>? _previewAppearance;
  DateTime? _previewAppearanceAt;
  List<ScanPoint>? _previewAppearanceCorners;
  List<double>? _settling;
  int _settlingFrames = 0;
  int _changedFrames = 0;
  DateTime? _changedSince;
  int _backgroundFrames = 0;
  DateTime? _backgroundSince;
  List<double>? _backgroundAppearance;
  bool _appearanceConflict = false;
  bool qualityFailed = false;
  bool hadSavedItem = false;

  bool get appearanceConflict => _appearanceConflict;
  bool get safeForCaptureFeedback =>
      visible &&
      !_appearanceConflict &&
      _captureBaseline != null &&
      _currentAppearance != null &&
      _currentAppearanceAt != null &&
      DateTime.now().difference(_currentAppearanceAt!) <=
          const Duration(milliseconds: 700) &&
      _difference(_captureBaseline!, _currentAppearance!) < .38;

  void clearCaptureFeedbackAppearance() {
    _currentAppearance = null;
    _currentAppearanceAt = null;
  }

  void observeSavedAppearance(SavedTargetAppearance sample) {
    if (_captureBaseline != null ||
        !sample.isValid ||
        !sameFootprint(sample.corners, frozenCorners)) {
      return;
    }
    final List<double>? appearance = _normalizeAppearance(sample.values);
    if (appearance == null) return;
    _captureBaseline = appearance;
    _baseline = appearance;
    _settling = null;
    _settlingFrames = 0;
    _changedFrames = 0;
    _changedSince = null;
    _appearanceConflict =
        _appearanceConflict ||
        (_currentAppearance != null &&
            _difference(appearance, _currentAppearance!) >= .38);
    if (const bool.fromEnvironment('PHYSICAL_CARD_QA')) {
      debugPrint(
        'CAPTURE_SOURCE_APPEARANCE id=$receiptId '
        'difference=${_currentAppearance == null ? null : _difference(appearance, _currentAppearance!)} '
        'corners=${frozenCorners.map((ScanPoint point) => '${point.x},${point.y}').join(';')}',
      );
    }
  }

  void observePreviewAppearance(LiveCardAppearanceSample sample, DateTime now) {
    if (!sample.present) {
      return;
    }
    final List<double>? appearance = _normalizeAppearance(sample.values);
    if (appearance == null) {
      return;
    }
    _previewAppearance = appearance;
    _previewAppearanceAt = now;
    _previewAppearanceCorners = List<ScanPoint>.unmodifiable(sample.corners);
  }

  List<double>? appearanceForCapture(DateTime now, List<ScanPoint> target) =>
      _previewAppearanceAt != null &&
          _previewAppearanceCorners != null &&
          sameFootprint(_previewAppearanceCorners!, target) &&
          now.difference(_previewAppearanceAt!) <=
              const Duration(milliseconds: 1400)
      ? _previewAppearance
      : null;

  static bool sameFootprint(List<ScanPoint> first, List<ScanPoint> second) {
    if (first.length != 4 || second.length != 4) return false;
    for (int index = 0; index < 4; index++) {
      if (!((first[index].x - second[index].x).abs() <= .0001 &&
          (first[index].y - second[index].y).abs() <= .0001)) {
        return false;
      }
    }
    return true;
  }

  void resetAppearanceEvidence() {
    clearCaptureFeedbackAppearance();
    _settling = null;
    _settlingFrames = 0;
    _changedFrames = 0;
    _changedSince = null;
    _backgroundFrames = 0;
    _backgroundSince = null;
    _backgroundAppearance = null;
  }

  bool retireFromAppearance(
    LiveCardAppearanceSample? sample, {
    required bool uniqueContour,
    required bool noContour,
    required DateTime now,
  }) {
    if (sample == null) {
      resetAppearanceEvidence();
      return false;
    }
    final List<double>? background =
        noContour && !sample.present && _captureBaseline != null
        ? _normalizeAppearance(sample.values)
        : null;
    final bool changedTexture =
        background != null && _difference(_captureBaseline!, background) >= .38;
    if (noContour &&
        !sample.present &&
        (_flatBackground(sample.values) || changedTexture)) {
      if (background != null &&
          _backgroundAppearance != null &&
          _difference(_backgroundAppearance!, background) > .15) {
        _backgroundSince = null;
        _backgroundFrames = 0;
      }
      _backgroundAppearance = background;
      _appearanceConflict = true;
      _changedFrames = 0;
      _changedSince = null;
      _settling = null;
      _settlingFrames = 0;
      _backgroundSince ??= now;
      _backgroundFrames++;
      return _backgroundFrames >= 3 &&
          now.difference(_backgroundSince!) >=
              const Duration(milliseconds: 1400);
    }
    _backgroundFrames = 0;
    _backgroundSince = null;
    _backgroundAppearance = null;
    final List<double>? appearance = uniqueContour && sample.present
        ? _normalizeAppearance(sample.values)
        : null;
    if (appearance == null) {
      resetAppearanceEvidence();
      return false;
    }
    _currentAppearance = appearance;
    _currentAppearanceAt = now;
    if (_baseline == null) {
      if (_settling != null && _difference(_settling!, appearance) <= .15) {
        _settlingFrames++;
      } else {
        _settling = appearance;
        _settlingFrames = 1;
      }
      if (_settlingFrames >= 3) _baseline = appearance;
      return false;
    }
    _appearanceConflict = _difference(_baseline!, appearance) >= .38;
    if (!_appearanceConflict) {
      _changedFrames = 0;
      _changedSince = null;
      return false;
    }
    _changedSince ??= now;
    _changedFrames++;
    return _changedFrames >= 3 &&
        now.difference(_changedSince!) >= const Duration(milliseconds: 500);
  }

  static List<double>? _luminance(List<double> rgb) {
    if (rgb.length != 288 ||
        rgb.any((double value) => !value.isFinite || value < 0 || value > 1)) {
      return null;
    }
    return <double>[
      for (int index = 0; index < rgb.length; index += 3)
        .2126 * rgb[index] + .7152 * rgb[index + 1] + .0722 * rgb[index + 2],
    ];
  }

  static double _mean(List<double> values) =>
      values.reduce((double a, double b) => a + b) / values.length;

  static double _deviation(List<double> values, double mean) => math.sqrt(
    values.fold<double>(
          0,
          (double sum, double value) => sum + (value - mean) * (value - mean),
        ) /
        values.length,
  );

  static bool _flatBackground(List<double> rgb) {
    final List<double>? values = _luminance(rgb);
    if (values == null) return false;
    final double mean = _mean(values);
    return mean >= .03 && mean <= .90 && _deviation(values, mean) < .012;
  }

  static List<double>? _normalizeAppearance(List<double> rgb) {
    final List<double>? values = _luminance(rgb);
    if (values == null) return null;
    final double mean = _mean(values);
    final double deviation = _deviation(values, mean);
    if (deviation < .025 ||
        values.where((double value) => value < .015 || value > .985).length >
            24) {
      return null;
    }
    return <double>[
      ...values.map(
        (double value) => ((value - mean) / deviation).clamp(-3, 3).toDouble(),
      ),
      for (int index = 0; index < rgb.length; index += 3) ...<double>[
        rgb[index] /
            math.max(.05, rgb[index] + rgb[index + 1] + rgb[index + 2]),
        rgb[index + 2] /
            math.max(.05, rgb[index] + rgb[index + 1] + rgb[index + 2]),
      ],
    ];
  }

  static double _difference(List<double> a, List<double> b) {
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
}

typedef _CaptureFeedbackContext = ({
  int generation,
  int feedbackGeneration,
  CameraController camera,
  ScanSession? session,
  String orientation,
  LiveCaptureSnapshot capture,
});

class _SavedCaptureQuality {
  _SavedCaptureQuality({
    required this.origin,
    required this.paths,
    required this.targets,
  });
  final _CaptureFeedbackContext origin;
  final List<String> paths;
  final List<({String receiptId, String? trackId, List<ScanPoint> corners})>
  targets;
  final Set<String> qualified = <String>{};
  final Set<String> accepting = <String>{};
  final Set<String> failed = <String>{};
}

class _GuidedCameraScreenState extends State<GuidedCameraScreen>
    with WidgetsBindingObserver {
  static EdgeInsets _actionPadding(EdgeInsets _) => const EdgeInsets.all(10);
  CameraController? _camera;
  List<CameraDescription> _rearCameras = <CameraDescription>[];
  String? _selectedCameraName;
  bool _lensChosenManually = false;
  bool _closerLensAttempted = false;
  Future<void> _lifecycle = Future<void>.value();
  String? _error;
  bool _capturing = false;
  bool _waitingRawFocus = false;
  bool _rawFocusReadinessRequired = false;
  bool _rawTargetFocusSupported = false;
  int _focusGeneration = 0;
  int _startedLiveFrames = 0;
  ({
    _RawContour contour,
    int focusGeneration,
    int afterFrame,
    double lensPosition,
  })?
  _rawSettledFocus;
  bool _sceneSaved = false;
  bool _torch = false;
  int _generation = 0;
  int _strongAppearanceOffset = 0;
  int _rawAppearanceOffset = 0;
  int _ownedVerificationOffset = 0;
  int _captured = 0;
  bool _controls = false;
  bool _clearingCaptures = false;
  final Set<Future<void>> _captureWork = <Future<void>>{};
  final ScanCaptureFeedback _captureFeedback = ScanCaptureFeedback();
  Timer? _captureFeedbackTimer;
  _CaptureFeedbackContext? _pendingCaptureFeedback;
  final Map<String, _CaptureFeedbackContext> _rawFeedbackOrigins =
      <String, _CaptureFeedbackContext>{};
  final Map<String, _SavedCaptureQuality> _savedCaptureQuality =
      <String, _SavedCaptureQuality>{};
  bool _focusLocked = false;
  bool _torchUnavailable = false;
  bool _startingStream = false;
  bool get _sweeping => widget.automaticCapture && !widget.stationaryFocusStack;
  bool get _streamDuringCapture =>
      (_sweeping || _adaptiveCapturing) &&
      defaultTargetPlatform == TargetPlatform.iOS;
  bool _adaptiveCapturing = false;
  final Set<String> _adaptiveTargetIds = <String>{};
  bool _rectanglesSupported = true;
  final NativeLiveCardDetector _liveDetector = NativeLiveCardDetector();
  late final LiveScanTracker _liveTracker = LiveScanTracker(
    resolver: widget.session?.resolver,
    retireIdentified: widget.automaticCapture,
  );
  final ScanFocusTargetMemory _focusMemory = ScanFocusTargetMemory();
  final ScanFocusDiscoveryBudget _focusDiscovery = ScanFocusDiscoveryBudget();
  String? _pendingPhoto;
  List<String>? _pendingStack;
  List<String>? _savedStack;
  LiveCaptureSnapshot? _savedCaptureSnapshot;
  final List<({List<String> paths, LiveCaptureSnapshot snapshot})>
  _savedCaptures = <({List<String> paths, LiveCaptureSnapshot snapshot})>[];
  List<List<ScanPoint>> _pendingExclusions = const <List<ScanPoint>>[];
  List<List<ScanPoint>>? _pendingUnidentifiedContours;
  bool _pendingRawOrientationChanged = false;
  int? _pendingRawGeneration;
  String? _pendingRawOrientationToken;
  _UnidentifiedPhotoHandoff? _pendingRawHandoff;
  _TrackedPhotoHandoff? _pendingTrackedHandoff;
  _SinglePhotoHandoff? _pendingSingleHandoff;
  List<List<ScanPoint>>? _pendingTrackedTargets;
  List<_RawContour> _pendingRawRecoveries = const <_RawContour>[];
  ScanSession? _pendingRawSession;
  CameraController? _pendingRawCamera;
  List<List<double>?>? _pendingRawAppearances;
  int _nextRawPreviewId = 0;
  final List<_RawContour> _rawObservations = <_RawContour>[];
  final List<_RawContour> _rawPhotoContours = <_RawContour>[];
  final Set<String> _boundSavedFocusItems = <String>{};
  List<List<ScanPoint>> _pendingSavedFocus = const <List<ScanPoint>>[];
  DateTime? _automaticReadyAt;
  DateTime? _automaticRetryAt;
  bool _automaticPaused = false;
  List<LiveCardDetection> _focusCandidates = <LiveCardDetection>[];
  int _captureStep = 0;
  int _captureSteps = 1;
  LiveCaptureSnapshot? _pendingCaptureSnapshot;
  _CapturePhase _capturePhase = _CapturePhase.idle;
  Size? _liveFrameSize;
  String? _liveOrientationToken;
  String? _trackingError;
  DateTime? _lastTextFrame;
  int _acceptedLiveFrames = 0;
  int _geometryPriorityRemaining = 2;
  bool _resumeOwnershipPending = false;
  final Set<String> _resumeAppearanceIds = <String>{};
  int _resumeObservedFrames = 0;
  DateTime? _resumeObservationStarted;
  Offset? _focusPoint;
  Timer? _focusTimer;
  Timer? _discoveryTimer;
  Future<void>? _discoveryFocus;
  DateTime? _manualFocusAt;
  int _discoveryIndex = 0;
  double _zoom = 1;
  double _appliedZoom = 1;
  double _minZoom = 1;
  double _maxZoom = 1;
  double _exposure = 0;
  double _appliedExposure = 0;
  double _minExposure = 0;
  double _maxExposure = 0;
  double _exposureStep = 0;
  final ScanExposurePolicy _exposurePolicy = ScanExposurePolicy();
  Future<void> _exposureWork = Future<void>.value();
  int _exposureEpoch = 0;
  int _manualExposureRevision = 0;
  bool _automaticExposureBusy = false;
  bool _automaticExposureUnavailable = false;
  bool _manualExposure = false;
  double _manualExposureValue = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _liveTracker.addListener(_tracksChanged);
    widget.session?.addListener(_recognitionChanged);
    _scheduleCamera(widget.active);
  }

  void _tracksChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void didUpdateWidget(GuidedCameraScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool changedSession = oldWidget.session != widget.session;
    if (changedSession) {
      _resetCaptureFeedback(forgetReceipts: true);
      oldWidget.session?.removeListener(_recognitionChanged);
      widget.session?.addListener(_recognitionChanged);
      _savedStack = null;
      _sceneSaved = false;
    }
    if (changedSession || oldWidget.active != widget.active) {
      _scheduleCamera(widget.active, preserveOwnership: !changedSession);
    }
  }

  void _recognitionChanged() {
    final ScanSession? session = widget.session;
    if (!mounted || session == null || _clearingCaptures) return;
    for (final _RawContour raw in _rawPhotoContours) {
      final LiveCaptureSnapshot? capture = raw.capture;
      final List<String>? paths = raw.paths;
      final _SavedCaptureQuality? quality =
          _savedCaptureQuality[capture?.captureId];
      if (capture == null ||
          paths == null ||
          quality == null ||
          !_validCaptureFeedback(quality.origin) ||
          !_liveTracker.ownsFrozenRegion(capture, raw.frozenCorners)) {
        continue;
      }
      final List<SavedTargetAppearance> samples = session
          .captureTargetAppearances(paths)
          .where(
            (SavedTargetAppearance sample) =>
                _RawContour.sameFootprint(sample.corners, raw.frozenCorners),
          )
          .toList();
      if (samples.length == 1) raw.observeSavedAppearance(samples.single);
    }
    _qualifySavedCaptures(session);
    final Set<_RawContour> identifiedRaw = <_RawContour>{};
    for (final _RawContour raw in _rawPhotoContours.toList()) {
      final LiveCaptureSnapshot? capture = raw.capture;
      final List<String>? paths = raw.paths;
      if (paths != null &&
          session
              .capturedItems(paths)
              .any(
                (ScanSessionItem item) => _rawRegionsOverlap(
                  raw.frozenCorners,
                  item.crop.sourceCorners,
                ),
              )) {
        raw.hadSavedItem = true;
      }
      if (capture == null || paths == null || raw.appearanceConflict) {
        continue;
      }
      final List<ScanSessionItem> owned = session
          .capturedItems(paths)
          .where(
            (ScanSessionItem item) =>
                item.liveCaptureReceiptId == null &&
                item.crop.imagePath.isNotEmpty &&
                _liveTracker.ownsFrozenRegion(
                  capture,
                  raw.frozenCorners,
                  currentCorners: item.crop.sourceCorners,
                ) &&
                _sameRawRegion(raw.corners, item.crop.sourceCorners),
          )
          .toList();
      if (owned.length != 1) {
        continue;
      }
      final ScanSessionItem item = owned.single;
      final ScanResolution? resolution = item.resolution;
      if (resolution == null || item.error != null) {
        continue;
      }
      if (!_liveTracker.corroboratesSavedIdentity(capture, item.crop)) {
        continue;
      }
      if (_rawPhotoContours
              .where(
                (_RawContour other) =>
                    identical(other.capture, capture) &&
                    _liveTracker.ownsFrozenRegion(
                      capture,
                      other.frozenCorners,
                      currentCorners: item.crop.sourceCorners,
                    ),
              )
              .length !=
          1) {
        continue;
      }
      if (_liveTracker.identifyCaptured(
            item.crop,
            resolution,
            capture: capture,
          ) >
          0) {
        final String? receiptId = raw.receiptId;
        final _CaptureFeedbackContext? origin = _rawFeedbackOrigins[receiptId];
        if (receiptId != null &&
            origin != null &&
            !raw.appearanceConflict &&
            _captureFeedback.containsReceipt(receiptId) &&
            _validCaptureFeedback(origin)) {
          final List<LiveScanTrack> identified = _liveTracker.tracks
              .where(
                (LiveScanTrack track) =>
                    track.capturedIdentified &&
                    _sameRawRegion(track.corners, raw.corners),
              )
              .toList();
          if (identified.length == 1) {
            _captureFeedback.acknowledge(
              generation: origin.feedbackGeneration,
              receipts: <({String receiptId, String? trackId})>[
                (
                  receiptId: receiptId,
                  trackId: identified.single.photoFeedbackId,
                ),
              ],
              now: DateTime.now(),
            );
          }
        }
        _rawFeedbackOrigins.remove(receiptId);
        identifiedRaw.add(raw);
      }
    }
    _rawPhotoContours.removeWhere(identifiedRaw.contains);
    final List<({List<String> paths, LiveCaptureSnapshot snapshot})> captures =
        widget.automaticCapture
        ? _savedCaptures
        : <({List<String> paths, LiveCaptureSnapshot snapshot})>[
            if (_savedStack != null && _savedCaptureSnapshot != null)
              (paths: _savedStack!, snapshot: _savedCaptureSnapshot!),
          ];
    final Set<String> retained = <String>{};
    final List<List<ScanPoint>> pendingFocus = <List<ScanPoint>>[];
    for (final ({List<String> paths, LiveCaptureSnapshot snapshot}) capture
        in captures) {
      final List<ScanSessionItem> photoReadItems = session
          .capturedItems(capture.paths)
          .where(
            (ScanSessionItem item) =>
                item.liveCaptureReceiptId == null ||
                item.crop.imagePath.isNotEmpty,
          )
          .toList();
      for (final ScanSessionItem item in session.capturedItems(capture.paths)) {
        retained.add(item.id);
        if (widget.automaticCapture &&
            photoReadItems.contains(item) &&
            _liveTracker.rememberSavedCrop(item.crop, capture.snapshot)) {
          _boundSavedFocusItems.add(item.id);
        }
        if (item.resolution != null && item.error == null) {
          final int identified = _liveTracker.identifyCaptured(
            item.crop,
            item.resolution!,
            capture: capture.snapshot,
          );
          if (identified > 0) _boundSavedFocusItems.add(item.id);
          if (widget.automaticCapture &&
              !_boundSavedFocusItems.contains(item.id) &&
              _liveTracker.canFocusSavedCapture(capture.snapshot) &&
              item.resolution!.candidates.any(
                (ScanCandidate candidate) =>
                    !candidate.hasContradiction &&
                    candidate.evidence.any(
                      (ScanEvidence evidence) => const <ScanEvidence>{
                        ScanEvidence.nameMatch,
                        ScanEvidence.footerMatch,
                        ScanEvidence.rulesTextMatch,
                      }.contains(evidence),
                    ),
              ) &&
              !_liveTracker.isSaved(item.crop.sourceCorners)) {
            pendingFocus.add(item.crop.sourceCorners);
          }
        }
      }
      if (widget.automaticCapture &&
          !_capturing &&
          _adaptiveTargetIds.isEmpty &&
          session.failedPhotos == 0 &&
          session.storageError == null &&
          session.captureReadComplete(capture.paths) &&
          !session.captureDetailsPending(capture.paths)) {
        final List<LiveScanTrack> missing = _liveTracker.rearmMissingCaptured(
          capture.snapshot,
          photoReadItems.map((ScanSessionItem item) => item.crop),
        );
        _adaptiveTargetIds.addAll(
          missing.map((LiveScanTrack track) => track.id),
        );
      }
      if (widget.automaticCapture &&
          session.failedPhotos == 0 &&
          session.storageError == null &&
          session.captureReadComplete(capture.paths) &&
          !session.captureDetailsPending(capture.paths) &&
          _liveTracker.canFocusSavedCapture(capture.snapshot)) {
        for (final List<ScanPoint> raw in session.capturedRawRegions(
          capture.paths,
        )) {
          if (photoReadItems.any(
                (ScanSessionItem item) => _liveTracker.ownsFrozenRegion(
                  capture.snapshot,
                  raw,
                  currentCorners: item.crop.sourceCorners,
                ),
              ) ||
              !_liveTracker.ownsFrozenRegion(capture.snapshot, raw)) {
            continue;
          }
          final List<LiveCardDetection> current = _focusCandidates
              .where(
                (LiveCardDetection card) => _liveTracker.ownsFrozenRegion(
                  capture.snapshot,
                  raw,
                  currentCorners: card.corners,
                ),
              )
              .toList();
          if (current.length != 1 ||
              _liveTracker.isSaved(current.single.corners) ||
              _awaitsFrozenRead(current.single.corners)) {
            continue;
          }
          final ScanPoint? point = _focusCenter(current.single.corners);
          if (point != null) {
            _focusDiscovery.grantUnreadRecovery(point);
          }
        }
      }
    }
    _adaptiveTargetIds.retainAll(
      _liveTracker.uncapturedTracks.map((LiveScanTrack track) => track.id),
    );
    _boundSavedFocusItems.retainAll(retained);
    _pendingSavedFocus = List<List<ScanPoint>>.unmodifiable(pendingFocus);
    if (widget.automaticCapture &&
        _liveTracker.savedFootprints.isNotEmpty &&
        _liveTracker.uncapturedTracks.isEmpty &&
        _pendingSavedFocus.isEmpty) {
      _focusMemory.clear();
      _focusPoint = null;
    }
    setState(() {});
  }

  DeviceOrientation _orientation(CameraController controller) =>
      controller.value.previewPauseOrientation ??
      controller.value.lockedCaptureOrientation ??
      controller.value.deviceOrientation;

  void _cameraChanged() {
    final CameraController? controller = _camera;
    if (controller == null) return;
    final String token = NativeLiveCardDetector.orientationTokenFor(
      camera: controller.description,
      orientation: _orientation(controller),
    );
    if (_liveOrientationToken != null && token != _liveOrientationToken) {
      if (const bool.fromEnvironment('PHYSICAL_CARD_QA')) {
        debugPrint(
          'CAPTURE_DIAGNOSTIC orientation $_liveOrientationToken -> $token phase=$_capturePhase',
        );
      }
      _clearTracking();
      if (mounted) setState(() {});
    }
  }

  void _clearTracking() {
    _resumeOwnershipPending = false;
    _resumeAppearanceIds.clear();
    _resumeObservedFrames = 0;
    _resumeObservationStarted = null;
    _resetCaptureFeedback();
    _invalidateExposure();
    _rawFocusReadinessRequired = false;
    _rawTargetFocusSupported = false;
    _rawSettledFocus = null;
    _focusGeneration++;
    _savedCaptureSnapshot = null;
    _savedCaptures.clear();
    _adaptiveTargetIds.clear();
    _boundSavedFocusItems.clear();
    _pendingSavedFocus = const <List<ScanPoint>>[];
    _automaticReadyAt = null;
    if (const bool.fromEnvironment('PHYSICAL_CARD_QA')) {
      debugPrint(
        'CAPTURE_DIAGNOSTIC clear phase=$_capturePhase ids=${_liveTracker.tracks.map((LiveScanTrack track) => track.id).join(',')}',
      );
    }
    _liveDetector.reset();
    _rawObservations.clear();
    _rawPhotoContours.clear();
    _liveTracker.clear();
    _focusMemory.clear();
    _focusDiscovery.clear();
    _focusCandidates = <LiveCardDetection>[];
    _liveFrameSize = null;
    _liveOrientationToken = null;
    _lastTextFrame = null;
    _acceptedLiveFrames = 0;
    _geometryPriorityRemaining = 2;
  }

  void _suspendTracking() {
    _captureFeedbackTimer?.cancel();
    _captureFeedbackTimer = null;
    _captureFeedback.dismissCue();
    _invalidateExposure();
    _rawFocusReadinessRequired = false;
    _rawTargetFocusSupported = false;
    _rawSettledFocus = null;
    _focusGeneration++;
    _automaticReadyAt = null;
    _liveDetector.reset();
    _liveTracker.suspendObservations();
    _rawObservations.clear();
    for (final _RawContour contour in _rawPhotoContours) {
      contour.resetAppearanceEvidence();
      contour.visible = false;
    }
    _focusMemory.clear();
    _focusDiscovery.clear();
    _focusCandidates = <LiveCardDetection>[];
    _pendingSavedFocus = const <List<ScanPoint>>[];
    _focusPoint = null;
    _focusTimer?.cancel();
    _liveFrameSize = null;
    _lastTextFrame = null;
    _acceptedLiveFrames = 0;
    _geometryPriorityRemaining = 2;
    _resumeOwnershipPending = true;
    _resumeAppearanceIds
      ..clear()
      ..addAll(
        _liveTracker.savedFootprints.map(
          (LiveScanExcludedRegion region) => region.id,
        ),
      )
      ..addAll(
        _rawPhotoContours
            .map((_RawContour contour) => contour.receiptId)
            .whereType<String>(),
      );
    _resumeObservedFrames = 0;
    _resumeObservationStarted = null;
  }

  void _observeResumedOwnership(
    CameraController controller,
    LiveScanFrame frame,
  ) {
    if (!_resumeOwnershipPending) return;
    final DateTime now = DateTime.now();
    _resumeObservationStarted ??= now;
    _resumeObservedFrames++;
    final Map<String, List<ScanPoint>> footprints = <String, List<ScanPoint>>{
      for (final LiveScanExcludedRegion region in _liveTracker.savedFootprints)
        region.id: region.corners,
      for (final _RawContour contour in _rawPhotoContours)
        if (contour.receiptId != null) contour.receiptId!: contour.corners,
    };
    _resumeAppearanceIds.retainAll(footprints.keys);
    if (frame.appearanceSamplingSupported) {
      _resumeAppearanceIds.removeWhere((String id) {
        final List<LiveCardAppearanceSample> samples = frame.appearanceSamples
            .where((LiveCardAppearanceSample sample) => sample.id == id)
            .toList();
        if (samples.length != 1) return false;
        final LiveCardAppearanceSample sample = samples.single;
        return _sameRawRegion(sample.corners, footprints[id]!) &&
            sample.values.length == 288 &&
            sample.values.every(
              (double value) => value.isFinite && value >= 0 && value <= 1,
            );
      });
    } else if (frame.cards.isNotEmpty || frame.focusCandidates.isNotEmpty) {
      _resumeAppearanceIds.clear();
    }
    if (_resumeObservedFrames < 3 ||
        now.difference(_resumeObservationStarted!) <
            const Duration(milliseconds: 500) ||
        _resumeAppearanceIds.isNotEmpty) {
      return;
    }
    _resumeOwnershipPending = false;
    _CaptureFeedbackContext refreshed(_CaptureFeedbackContext previous) => (
      generation: _generation,
      feedbackGeneration: _captureFeedback.generation,
      camera: controller,
      session: widget.session,
      orientation: frame.orientationToken,
      capture: previous.capture,
    );
    for (final String id in _rawFeedbackOrigins.keys.toList()) {
      _rawFeedbackOrigins[id] = refreshed(_rawFeedbackOrigins[id]!);
    }
    for (final MapEntry<String, _SavedCaptureQuality> entry
        in _savedCaptureQuality.entries.toList()) {
      final _SavedCaptureQuality previous = entry.value;
      _savedCaptureQuality[entry.key] =
          _SavedCaptureQuality(
              origin: refreshed(previous.origin),
              paths: previous.paths,
              targets: previous.targets,
            )
            ..qualified.addAll(previous.qualified)
            ..failed.addAll(previous.failed);
    }
  }

  Future<T> _trackCaptureWork<T>(Future<T> Function() operation) {
    final Future<T> result = Future<T>.sync(operation);
    late final Future<void> finished;
    finished = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _captureWork.remove(finished));
    _captureWork.add(finished);
    return result;
  }

  Future<void> _clearCaptures() async {
    final Future<void> Function()? clear = widget.onClearCaptures;
    if (clear == null || _clearingCaptures) return;
    final bool wasPaused = _automaticPaused;
    bool cleared = false;
    final CameraController? controller = _camera;
    setState(() {
      _resetCaptureFeedback();
      _invalidateExposure();
      _clearingCaptures = true;
      _automaticPaused = true;
      _automaticReadyAt = null;
    });
    try {
      while (_captureWork.isNotEmpty) {
        await Future.wait<void>(List<Future<void>>.of(_captureWork));
      }
      await _discoveryFocus;
      if (controller != null &&
          _usesCamera(controller) &&
          controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      await clear();
      for (final String path in _pendingStack ?? <String>[?_pendingPhoto]) {
        try {
          final File photo = File(path);
          if (await photo.exists()) await photo.delete();
        } on FileSystemException {
          // The batch is cleared even if a temporary photo cannot be removed.
        }
      }
      if (!mounted) return;
      _generation++;
      _automaticExposureBusy = false;
      _resetCaptureFeedback(forgetReceipts: true);
      _clearTracking();
      setState(() {
        _savedStack = null;
        _sceneSaved = false;
        _captured = 0;
        _pendingPhoto = null;
        _pendingStack = null;
        _pendingCaptureSnapshot = null;
        _pendingCaptureFeedback = null;
        _pendingUnidentifiedContours = null;
        _pendingRawOrientationChanged = false;
        _pendingRawGeneration = null;
        _pendingRawOrientationToken = null;
        _pendingRawHandoff = null;
        _pendingTrackedHandoff = null;
        _pendingSingleHandoff = null;
        _pendingTrackedTargets = null;
        _pendingRawRecoveries = const <_RawContour>[];
        _pendingRawSession = null;
        _pendingRawCamera = null;
        _pendingRawAppearances = null;
        _pendingExclusions = const <List<ScanPoint>>[];
        _automaticRetryAt = null;
        _focusPoint = null;
        _manualFocusAt = null;
        _focusTimer?.cancel();
        _discoveryIndex = 0;
        _controls = false;
        if (_camera != null) _error = null;
      });
      cleared = true;
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Clear failed');
      }
    } finally {
      if (mounted) {
        setState(() {
          _clearingCaptures = false;
          _automaticPaused = cleared && widget.automaticCapture
              ? true
              : wasPaused;
        });
        final CameraController? current = _camera;
        if (current != null && _usesCamera(current)) await _startLive(current);
      }
    }
  }

  void _newScene() {
    if (_clearingCaptures || _capturing || _pendingPhoto != null) return;
    _sceneSaved = false;
    _savedStack = null;
    _clearTracking();
    if (mounted) setState(() {});
  }

  Future<void> _disposeCamera(CameraController? controller) async {
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {
      // A disconnected camera can reject stopping its stream; still release it.
    } finally {
      await controller.dispose();
    }
  }

  Future<void> _startLive(CameraController controller) async {
    if (_clearingCaptures ||
        !_usesCamera(controller) ||
        controller.value.isStreamingImages) {
      return;
    }
    setState(() => _startingStream = true);
    try {
      await controller.startImageStream((CameraImage image) {
        unawaited(_analyzeFrame(controller, image));
      });
      if (_usesCamera(controller)) {
        setState(() => _trackingError = null);
        _discoveryTimer?.cancel();
        if (widget.multipleCards || widget.automaticCapture) {
          _discoveryTimer = Timer.periodic(const Duration(seconds: 4), (_) {
            _discoveryFocus ??= _discoverFocus(controller)
                .whenComplete(() => _discoveryFocus = null);
          });
        }
      }
    } catch (error, stack) {
      if (const bool.fromEnvironment('PHYSICAL_CARD_QA')) {
        debugPrint('LIVE_STREAM_FAILURE:$error\n$stack');
      }
      if (_usesCamera(controller)) {
        setState(() => _trackingError = 'Tracking unavailable');
      }
    } finally {
      if (_usesCamera(controller)) setState(() => _startingStream = false);
    }
  }

  Future<void> _analyzeFrame(
    CameraController controller,
    CameraImage image,
  ) async {
    if (_clearingCaptures ||
        !_usesCamera(controller) ||
        (_capturing && !_streamDuringCapture)) {
      return;
    }
    final DateTime now = DateTime.now();
    final int frameSequence = ++_startedLiveFrames;
    final bool textDue =
        _lastTextFrame == null ||
        now.difference(_lastTextFrame!) >= const Duration(seconds: 1);
    final bool geometryPriority =
        widget.automaticCapture &&
        widget.session != null &&
        widget.onUnidentifiedPhotoCaptured != null &&
        (_acceptedLiveFrames < 2 ||
            (textDue &&
                _geometryPriorityRemaining > 0 &&
                _rawObservations.any(
                  (_RawContour contour) => contour.stableFrames < 2,
                )));
    final bool includeText = textDue && !geometryPriority;
    final int generation = _generation;
    final int analysis = _liveTracker.beginFrameAnalysis();
    try {
      final ({
        List<LiveScanExcludedRegion> regions,
        int strongCount,
        int rawCount,
      })
      appearanceSelection = _nextAppearanceRegions();
      final List<LiveScanExcludedRegion> appearanceRegions =
          appearanceSelection.regions;
      final Set<String> sampledIds = appearanceRegions
          .map((LiveScanExcludedRegion region) => region.id)
          .toSet();
      final List<LiveScanExcludedRegion> completed =
          _liveTracker.completedFootprints;
      final List<LiveScanExcludedRegion> masked = completed
          .where(
            (LiveScanExcludedRegion region) => sampledIds.contains(region.id),
          )
          .toList();
      final String? verificationId =
          includeText &&
              completed.isNotEmpty &&
              masked.length == completed.length
          ? completed[_ownedVerificationOffset % completed.length].id
          : null;
      final LiveScanFrame? frame = await _liveDetector.analyze(
        image,
        camera: controller.description,
        orientation: _orientation(controller),
        includeText: includeText,
        excludedRegions: masked
            .where(
              (LiveScanExcludedRegion region) => region.id != verificationId,
            )
            .toList(),
        appearanceRegions: appearanceRegions,
      );
      if (frame == null ||
          _clearingCaptures ||
          !_usesCamera(controller) ||
          generation != _generation ||
          (_capturing && !_streamDuringCapture)) {
        return;
      }
      final String current = NativeLiveCardDetector.orientationTokenFor(
        camera: controller.description,
        orientation: _orientation(controller),
      );
      if (frame.orientationToken != current) return;
      if (_liveOrientationToken != null && _liveOrientationToken != current) {
        _clearTracking();
      }
      _acceptedLiveFrames++;
      if (geometryPriority && _geometryPriorityRemaining > 0) {
        _geometryPriorityRemaining--;
      }
      if (includeText && !frame.geometryOnly) {
        _geometryPriorityRemaining = 2;
      }
      _strongAppearanceOffset += appearanceSelection.strongCount;
      _rawAppearanceOffset += appearanceSelection.rawCount;
      if (verificationId != null && !frame.geometryOnly) {
        _ownedVerificationOffset++;
      }
      if (includeText && !frame.geometryOnly) _lastTextFrame = DateTime.now();
      _liveFrameSize = Size(frame.width.toDouble(), frame.height.toDouble());
      _liveOrientationToken = frame.orientationToken;
      _rectanglesSupported = frame.rectanglesSupported;
      _trackingError = null;
      _focusCandidates = frame.focusCandidates;
      _updateRawContours(frame, sampledIds, frameSequence);
      _focusDiscovery.observe(
        frame.focusCandidates.map((LiveCardDetection card) => card.corners),
      );
      _liveTracker.update(
        frame.cards,
        frameAnalysis: analysis,
        currentGeometry: frame.focusCandidates.map(
          (LiveCardDetection card) => card.corners,
        ),
        appearanceSamples: frame.appearanceSamples,
        appearanceSamplingSupported: frame.appearanceSamplingSupported,
      );
      _observeResumedOwnership(controller, frame);
      _recognitionChanged();
      _focusMemory.update(
        _liveTracker.uncapturedTracks.map(
          (LiveScanTrack track) => track.crop.sourceCorners,
        ),
      );
      if (mounted) setState(() {});
      _considerAutomaticExposure(controller, frame);
      _considerAutomaticCapture(controller);
      _considerDiscoveryFocus(controller);
    } catch (error, stack) {
      if (const bool.fromEnvironment('PHYSICAL_CARD_QA')) {
        debugPrint('LIVE_ANALYSIS_FAILURE:$error\n$stack');
      }
      if (_usesCamera(controller) && generation == _generation) {
        setState(
          () => _trackingError = widget.automaticCapture
              ? 'Tracking unavailable'
              : 'Tracking unavailable',
        );
      }
    } finally {
      _liveTracker.endFrameAnalysis(analysis);
    }
  }

  void _resetCaptureFeedback({bool forgetReceipts = false}) {
    _captureFeedbackTimer?.cancel();
    _captureFeedbackTimer = null;
    _captureFeedback.invalidate(forgetReceipts: forgetReceipts);
    _rawFeedbackOrigins.clear();
    _savedCaptureQuality.clear();
  }

  static bool _savedCardQuality(ScanCrop crop) =>
      hasVerifiedSavedCardCapturePresence(crop);

  void _qualifySavedCaptures(ScanSession session) {
    for (final _SavedCaptureQuality quality
        in _savedCaptureQuality.values.toList()) {
      if (!_validCaptureFeedback(quality.origin)) continue;
      final List<ScanSessionItem> owned = session
          .capturedItems(quality.paths)
          .where(
            (ScanSessionItem item) =>
                item.liveCaptureReceiptId == null &&
                _savedCardQuality(item.crop),
          )
          .toList();
      final List<({String receiptId, String? trackId, ScanSessionItem item})>
      receipts =
          <({String receiptId, String? trackId, ScanSessionItem item})>[];
      for (final ({String receiptId, String? trackId, List<ScanPoint> corners})
          target
          in quality.targets) {
        if (quality.qualified.contains(target.receiptId) ||
            quality.accepting.contains(target.receiptId)) {
          continue;
        }
        final List<ScanSessionItem> matches = owned
            .where(
              (ScanSessionItem item) =>
                  _sameRawRegion(target.corners, item.crop.sourceCorners) &&
                  _liveTracker.ownsFrozenRegion(
                    quality.origin.capture,
                    target.corners,
                    currentCorners: item.crop.sourceCorners,
                  ),
            )
            .toList();
        if (matches.length == 1 &&
            quality.targets
                    .where(
                      (
                        ({
                          String receiptId,
                          String? trackId,
                          List<ScanPoint> corners,
                        })
                        other,
                      ) => _sameRawRegion(
                        other.corners,
                        matches.single.crop.sourceCorners,
                      ),
                    )
                    .length ==
                1) {
          if (target.trackId == null) {
            final List<_RawContour> raw = _rawPhotoContours
                .where(
                  (_RawContour contour) =>
                      contour.receiptId == target.receiptId,
                )
                .toList();
            if (raw.length == 1 &&
                raw.single.visible &&
                !raw.single.appearanceConflict &&
                !_captureReceiptStillVisible(quality.origin, (
                  receiptId: target.receiptId,
                  trackId: null,
                ), DateTime.now())) {
              continue;
            }
          }
          quality.accepting.add(target.receiptId);
          receipts.add((
            receiptId: target.receiptId,
            trackId: target.trackId,
            item: matches.single,
          ));
        } else if (session.captureReadComplete(quality.paths) &&
            !session.captureDetailsPending(quality.paths) &&
            session
                .capturedItems(quality.paths)
                .every(
                  (ScanSessionItem item) =>
                      item.phase != ScanItemPhase.processing &&
                      item.phase != ScanItemPhase.retrying,
                )) {
          quality.failed.add(target.receiptId);
          for (final _RawContour raw in _rawPhotoContours.where(
            (_RawContour raw) => raw.receiptId == target.receiptId,
          )) {
            raw.qualityFailed = true;
          }
        }
      }
      if (receipts.isNotEmpty) {
        unawaited(_acceptSavedCaptures(session, quality, receipts));
      }
      if (quality.qualified.length == quality.targets.length ||
          (session.captureReadComplete(quality.paths) &&
              !session.captureDetailsPending(quality.paths) &&
              quality.targets.every(
                (
                  ({String receiptId, String? trackId, List<ScanPoint> corners})
                  target,
                ) => target.trackId == null
                    ? !_rawPhotoContours.any(
                        (_RawContour raw) => raw.receiptId == target.receiptId,
                      )
                    : !_liveTracker.tracks.any(
                        (LiveScanTrack track) =>
                            track.photoFeedbackId == target.trackId,
                      ),
              ))) {
        _savedCaptureQuality.remove(quality.origin.capture.captureId);
      }
    }
  }

  Future<void> _acceptSavedCaptures(
    ScanSession session,
    _SavedCaptureQuality quality,
    List<({String receiptId, String? trackId, ScanSessionItem item})> receipts,
  ) async {
    try {
      final bool accepted = await session.acceptCaptures(
        receipts
            .map(
              (
                ({String receiptId, String? trackId, ScanSessionItem item})
                receipt,
              ) => receipt.item,
            )
            .toList(),
        isCurrent: () =>
            _validCaptureFeedback(quality.origin) &&
            identical(
              _savedCaptureQuality[quality.origin.capture.captureId],
              quality,
            ),
      );
      if (!accepted ||
          !_validCaptureFeedback(quality.origin) ||
          !identical(
            _savedCaptureQuality[quality.origin.capture.captureId],
            quality,
          )) {
        return;
      }
      final List<({String receiptId, String? trackId})> confirmed =
          <({String receiptId, String? trackId})>[];
      for (final ({String receiptId, String? trackId, ScanSessionItem item})
          receipt
          in receipts) {
        final List<ScanPoint> corners = quality.targets
            .singleWhere(
              (
                ({String receiptId, String? trackId, List<ScanPoint> corners})
                target,
              ) => target.receiptId == receipt.receiptId,
            )
            .corners;
        if (!session.capturedItems(quality.paths).contains(receipt.item) ||
            !_savedCardQuality(receipt.item.crop) ||
            !_sameRawRegion(corners, receipt.item.crop.sourceCorners) ||
            !_liveTracker.ownsFrozenRegion(
              quality.origin.capture,
              corners,
              currentCorners: receipt.item.crop.sourceCorners,
            )) {
          continue;
        }
        quality.qualified.add(receipt.receiptId);
        quality.failed.remove(receipt.receiptId);
        for (final _RawContour raw in _rawPhotoContours.where(
          (_RawContour raw) => raw.receiptId == receipt.receiptId,
        )) {
          raw.qualityFailed = false;
        }
        confirmed.add((receiptId: receipt.receiptId, trackId: receipt.trackId));
      }
      if (confirmed.isNotEmpty) {
        _acknowledgeCaptureFeedback(quality.origin, confirmed);
      }
      if (quality.qualified.length == quality.targets.length) {
        _savedCaptureQuality.remove(quality.origin.capture.captureId);
      }
    } finally {
      quality.accepting.removeAll(
        receipts.map(
          (
            ({String receiptId, String? trackId, ScanSessionItem item}) receipt,
          ) => receipt.receiptId,
        ),
      );
    }
  }

  _CaptureFeedbackContext _captureFeedbackContext(
    CameraController camera,
    LiveCaptureSnapshot capture,
  ) => (
    generation: _generation,
    feedbackGeneration: _captureFeedback.generation,
    camera: camera,
    session: widget.session,
    orientation: NativeLiveCardDetector.orientationTokenFor(
      camera: camera.description,
      orientation: _orientation(camera),
    ),
    capture: capture,
  );

  bool _validCaptureFeedback(_CaptureFeedbackContext origin) =>
      mounted &&
      !_resumeOwnershipPending &&
      !_clearingCaptures &&
      !_automaticPaused &&
      origin.generation == _generation &&
      origin.feedbackGeneration == _captureFeedback.generation &&
      _usesCamera(origin.camera) &&
      identical(origin.session, widget.session) &&
      widget.session?.clearingCaptures != true &&
      widget.session?.paused != true &&
      widget.session?.storageError == null &&
      origin.orientation ==
          NativeLiveCardDetector.orientationTokenFor(
            camera: origin.camera.description,
            orientation: _orientation(origin.camera),
          );

  void _acknowledgeCaptureFeedback(
    _CaptureFeedbackContext origin,
    Iterable<({String receiptId, String? trackId})> receipts,
  ) {
    if (!_validCaptureFeedback(origin)) return;
    final List<({String receiptId, String? trackId})> acknowledged = receipts
        .toList();
    final DateTime now = DateTime.now();
    final DateTime feedbackNow = widget.feedbackClock?.call() ?? now;
    final bool currentReceipt = acknowledged.any(
      (({String receiptId, String? trackId}) receipt) =>
          !_captureFeedback.containsReceipt(receipt.receiptId) &&
          _captureReceiptStillVisible(origin, receipt, now),
    );
    final bool added = _captureFeedback.acknowledge(
      generation: origin.feedbackGeneration,
      receipts: acknowledged,
      now: feedbackNow,
    );
    for (final ({String receiptId, String? trackId}) receipt in acknowledged) {
      if (receipt.trackId == null) {
        _rawFeedbackOrigins[receipt.receiptId] = origin;
      }
    }
    if (added && !currentReceipt) {
      _captureFeedback.dismissCue();
    }
    final bool signal = added && _captureFeedback.takeSignal(feedbackNow);
    setState(() {});
    if (!added || !currentReceipt) return;
    _captureFeedbackTimer?.cancel();
    final int generation = _captureFeedback.generation;
    _captureFeedbackTimer = Timer(ScanCaptureFeedback.cueDuration, () {
      if (mounted && generation == _captureFeedback.generation) setState(() {});
    });
    if (signal) {
      unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        unawaited(
          NativeCardRecognizer.channel
              .invokeMethod<bool>('captureConfirmed')
              .then<void>((bool? _) {})
              .catchError((Object _) {}),
        );
      }
    }
  }

  bool _captureReceiptStillVisible(
    _CaptureFeedbackContext origin,
    ({String receiptId, String? trackId}) receipt,
    DateTime now,
  ) {
    final String? trackId = receipt.trackId;
    if (trackId != null) {
      return _liveTracker.tracks.any(
        (LiveScanTrack track) => track.photoFeedbackId == trackId,
      );
    }
    final String prefix = 'raw_${origin.capture.captureId}_';
    if (!receipt.receiptId.startsWith(prefix)) {
      return false;
    }
    final List<_RawContour> retained = _rawPhotoContours
        .where((_RawContour raw) => raw.receiptId == receipt.receiptId)
        .toList();
    if (retained.length == 1) {
      final _RawContour raw = retained.single;
      final List<String>? paths = raw.paths;
      if (!raw.visible ||
          raw.appearanceConflict ||
          paths == null ||
          _focusCandidates
                  .where(
                    (LiveCardDetection card) =>
                        _sameRawRegion(raw.corners, card.corners),
                  )
                  .length !=
              1) {
        return false;
      }
      if (raw.safeForCaptureFeedback) return true;
      return origin.session
              ?.capturedItems(paths)
              .any(
                (ScanSessionItem item) =>
                    _savedCardQuality(item.crop) &&
                    _sameRawRegion(raw.corners, item.crop.sourceCorners) &&
                    _liveTracker.corroboratesSavedIdentity(
                      origin.capture,
                      item.crop,
                    ),
              ) ??
          false;
    }
    final int? index = int.tryParse(receipt.receiptId.substring(prefix.length));
    final List<List<ScanPoint>>? targets = _pendingUnidentifiedContours;
    if (index == null ||
        targets == null ||
        index < 0 ||
        index >= targets.length) {
      return false;
    }
    final List<ScanPoint> target = targets[index];
    if (_focusCandidates
            .where(
              (LiveCardDetection card) => _sameRawRegion(card.corners, target),
            )
            .length !=
        1) {
      return false;
    }
    final List<_RawContour> current = _rawObservations
        .where((_RawContour contour) => _sameRawRegion(contour.corners, target))
        .toList();
    final List<double>? shutter = _pendingRawAppearances?[index];
    final List<double>? appearance = current.length == 1
        ? current.single.appearanceForCapture(now, target)
        : null;
    return shutter == null ||
        appearance == null ||
        _RawContour._difference(shutter, appearance) < .38;
  }

  void _invalidateExposure() {
    _exposureEpoch++;
    _exposurePolicy.reset();
  }

  bool _canAdjustAutomaticExposure(CameraController controller) {
    final ScanSession? session = widget.session;
    return widget.automaticCapture &&
        _usesCamera(controller) &&
        !_resumeOwnershipPending &&
        !_manualExposure &&
        !_automaticExposureUnavailable &&
        !_clearingCaptures &&
        !_automaticPaused &&
        !_controls &&
        !_capturing &&
        !_waitingRawFocus &&
        !_startingStream &&
        !_focusLocked &&
        _discoveryFocus == null &&
        _pendingPhoto == null &&
        session?.paused != true &&
        session?.clearingCaptures != true &&
        session?.storageError == null &&
        !_photoCaptureBacklog &&
        (_manualFocusAt == null ||
            DateTime.now().difference(_manualFocusAt!) >=
                const Duration(seconds: 12));
  }

  void _considerAutomaticExposure(
    CameraController controller,
    LiveScanFrame frame,
  ) {
    if (_automaticExposureBusy) return;
    if (!_canAdjustAutomaticExposure(controller) ||
        !frame.rectanglesSupported) {
      _exposurePolicy.reset();
      return;
    }
    final List<ScanCardLighting> lighting = <ScanCardLighting>[];
    bool readable = false;
    for (final LiveCardDetection card in frame.focusCandidates) {
      if (card.confidence < .9 ||
          card.corners.length != 4 ||
          !card.warnings.contains('geometry_only') ||
          card.warnings.contains('tracked_partial') ||
          card.corners.any(
            (ScanPoint p) =>
                !p.x.isFinite ||
                !p.y.isFinite ||
                p.x < 0 ||
                p.x > 1 ||
                p.y < 0 ||
                p.y > 1,
          ) ||
          !GuidedCameraScreen._regionContains(card.corners, card.corners) ||
          frame.focusCandidates
                  .where(
                    (LiveCardDetection other) =>
                        _sameRawRegion(other.corners, card.corners),
                  )
                  .length !=
              1 ||
          _hasRawPhoto(card.corners) ||
          _liveTracker.isSaved(card.corners) ||
          _awaitsFrozenRead(card.corners)) {
        continue;
      }
      final ScanCardLighting? stats = card.lighting;
      if (stats == null || !stats.isValid) continue;
      lighting.add(stats);
      readable =
          readable ||
          _availableCaptureTracks.any(
            (LiveScanTrack track) =>
                _sameRawRegion(track.corners, card.corners),
          ) ||
          _liveTracker.tracks.any(
            (LiveScanTrack track) =>
                track.hasVerifiedLiveIdentity &&
                _sameRawRegion(track.corners, card.corners),
          );
    }
    if (lighting.isEmpty && frame.focusCandidates.isNotEmpty) {
      _exposurePolicy.reset();
      return;
    }
    if (lighting.isEmpty &&
        (frame.cards.isNotEmpty ||
            _rawObservations.isNotEmpty ||
            _rawPhotoContours.any((_RawContour raw) => raw.visible) ||
            frame.appearanceSamples.any(
              (LiveCardAppearanceSample sample) => sample.present,
            ) ||
            _liveTracker.tracks.any(
              (LiveScanTrack track) =>
                  DateTime.now().difference(track.lastSeen) <=
                  const Duration(milliseconds: 500),
            ))) {
      _exposurePolicy.reset();
      return;
    }
    final double? next = _exposurePolicy.observe(
      now: DateTime.now(),
      lighting: lighting,
      readable: readable,
      currentExposure: _exposure,
      minExposure: _minExposure,
      maxExposure: _maxExposure,
      exposureStep: _exposureStep,
    );
    if (next == null) return;
    setState(() => _automaticExposureBusy = true);
    unawaited(_applyAutomaticExposure(controller, next));
  }

  Future<void> _queueExposure(
    CameraController controller,
    double value, {
    required bool automatic,
  }) {
    final int generation = _generation;
    final int epoch = _exposureEpoch;
    final int manualRevision = _manualExposureRevision;
    bool current() =>
        _usesCamera(controller) &&
        generation == _generation &&
        (automatic
            ? epoch == _exposureEpoch
            : manualRevision == _manualExposureRevision);
    final Future<void> operation = _exposureWork.then((_) async {
      if (!current() ||
          _clearingCaptures ||
          _capturing ||
          (automatic && !_canAdjustAutomaticExposure(controller))) {
        return;
      }
      final double actual = await controller.setExposureOffset(value);
      if (!actual.isFinite || actual < _minExposure || actual > _maxExposure) {
        throw StateError('Invalid exposure offset');
      }
      if (current()) {
        if (!automatic) _manualExposureValue = actual;
        _appliedExposure = actual;
        setState(() => _exposure = actual);
      }
    });
    _exposureWork = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _applyAutomaticExposure(
    CameraController controller,
    double value,
  ) async {
    final int generation = _generation;
    final int epoch = _exposureEpoch;
    try {
      await _queueExposure(
        controller,
        value,
        automatic: true,
      ).timeout(const Duration(milliseconds: 400));
    } catch (_) {
      if (_usesCamera(controller) && generation == _generation) {
        _automaticExposureUnavailable = true;
        if (epoch == _exposureEpoch) _invalidateExposure();
      }
    } finally {
      if (_usesCamera(controller) && generation == _generation) {
        setState(() => _automaticExposureBusy = false);
      }
    }
  }

  void _manualExposurePreview(double value) {
    _invalidateExposure();
    _manualExposureRevision++;
    _manualExposure = true;
    _manualExposureValue = value;
    setState(() => _exposure = value);
  }

  void _considerAutomaticCapture(CameraController controller) {
    if (!widget.automaticCapture ||
        _resumeOwnershipPending ||
        _clearingCaptures ||
        _waitingRawFocus ||
        _automaticExposureBusy) {
      return;
    }
    if (_availableCaptureTracks.isEmpty) {
      _considerRawCapture(controller);
      return;
    }
    final ScanSession? session = widget.session;
    final bool waitingForRead =
        session != null &&
        (session.paused ||
            session.storageError != null ||
            _photoCaptureBacklog);
    if (!_usesCamera(controller) ||
        _capturing ||
        _pendingPhoto != null ||
        _startingStream ||
        _automaticPaused ||
        _controls ||
        (session == null && _savedCaptures.length >= 8) ||
        waitingForRead ||
        _availableCaptureTracks.isEmpty ||
        !_liveTracker.completionCapacityAvailable) {
      _automaticReadyAt = null;
      return;
    }
    final DateTime now = DateTime.now();
    if (_automaticRetryAt != null && now.isBefore(_automaticRetryAt!)) return;
    if (!_sweeping) {
      _automaticReadyAt ??= now;
      if (now.difference(_automaticReadyAt!) <
          const Duration(milliseconds: 1200)) {
        return;
      }
    }
    _automaticReadyAt = null;
    unawaited(_capture());
  }

  bool get _photoCaptureBacklog {
    final ScanSession? session = widget.session;
    return session != null &&
        (session.pendingPhotoCaptures >= 8 ||
            session.detailBackpressure ||
            _savedCaptures
                    .where(
                      (
                        ({List<String> paths, LiveCaptureSnapshot snapshot})
                        receipt,
                      ) => !session.captureReadComplete(receipt.paths),
                    )
                    .length >=
                8);
  }

  bool _awaitsFrozenRead(List<ScanPoint> corners) {
    final ScanSession? session = widget.session;
    return widget.automaticCapture &&
        session != null &&
        _savedCaptures.any(
          (({List<String> paths, LiveCaptureSnapshot snapshot}) capture) =>
              (!session.captureReadComplete(capture.paths) ||
                  session.captureDetailsPending(capture.paths)) &&
              _liveTracker.ownsFrozenRegion(capture.snapshot, corners),
        );
  }

  bool _rawOwnsRegion(_RawContour raw, List<ScanPoint> corners) =>
      _sameRawRegion(raw.corners, corners) ||
      _sameRawRegion(raw.frozenCorners, corners);

  bool _hasRawPhoto(List<ScanPoint> corners) =>
      _rawPhotoContours.any((_RawContour raw) => _rawOwnsRegion(raw, corners));

  bool _isSavedCardPanel(List<ScanPoint> corners) {
    final List<List<ScanPoint>> owners = <List<ScanPoint>>[
      ..._rawPhotoContours.map((_RawContour raw) => raw.frozenCorners),
      ..._liveTracker.savedFootprints.map(
        (LiveScanExcludedRegion saved) => saved.corners,
      ),
    ];
    if (owners.any(
      (List<ScanPoint> owner) =>
          GuidedCameraScreen.isCapturedCardPanel(corners, owner),
    )) {
      return true;
    }
    final ScanSession? session = widget.session;
    if (session == null || owners.isEmpty) return false;
    final Iterable<List<String>> sources = <List<String>>[
      ..._savedCaptures.map(
        (({List<String> paths, LiveCaptureSnapshot snapshot}) capture) =>
            capture.paths,
      ),
      ..._rawPhotoContours
          .map((_RawContour raw) => raw.paths)
          .whereType<List<String>>(),
    ];
    for (final List<String> paths in sources) {
      for (final ScanSessionItem item in session.capturedItems(paths)) {
        final ScanCrop crop = item.crop;
        if (crop.imagePath.isNotEmpty &&
            crop.rectified &&
            owners.any(
              (List<ScanPoint> owner) =>
                  _sameRawRegion(owner, crop.sourceCorners),
            ) &&
            GuidedCameraScreen.isCapturedCardPanel(
              corners,
              crop.sourceCorners,
            )) {
          return true;
        }
      }
    }
    return false;
  }

  _RawContour? _recoverableRawOwner(List<ScanPoint> corners) {
    final ScanSession? session = widget.session;
    if (session == null) return null;
    final List<_RawContour> owners = _rawPhotoContours
        .where((_RawContour raw) => _rawOwnsRegion(raw, corners))
        .toList();
    if (owners.length != 1) return null;
    final _RawContour raw = owners.single;
    final LiveCaptureSnapshot? capture = raw.capture;
    final List<String>? paths = raw.paths;
    if (capture == null ||
        paths == null ||
        raw.appearanceConflict ||
        !raw.qualityFailed ||
        raw.hadSavedItem ||
        !session.captureReadComplete(paths) ||
        session.captureDetailsPending(paths) ||
        session.captureDetailsFailed(paths) ||
        !_liveTracker.ownsFrozenRegion(
          capture,
          raw.frozenCorners,
          currentCorners: corners,
        ) ||
        session
            .capturedItems(paths)
            .any(
              (ScanSessionItem item) =>
                  _rawRegionsOverlap(
                    raw.frozenCorners,
                    item.crop.sourceCorners,
                  ) ||
                  _rawRegionsOverlap(corners, item.crop.sourceCorners),
            )) {
      return null;
    }
    return raw;
  }

  List<LiveScanTrack> get _availableCaptureTracks => _liveTracker.eligibleTracks
      .where(
        (LiveScanTrack track) =>
            !_awaitsFrozenRead(track.corners) &&
            (!_hasRawPhoto(track.corners) ||
                _recoverableRawOwner(track.corners) != null),
      )
      .toList();

  List<List<ScanPoint>>? _protectedCaptureRegions({
    Set<_RawContour> recoveringRaw = const <_RawContour>{},
  }) => GuidedCameraScreen.freezeCaptureExclusions(<List<ScanPoint>>[
    ..._rawPhotoContours
        .where((_RawContour raw) => !recoveringRaw.contains(raw))
        .expand(
          (_RawContour raw) => <List<ScanPoint>>[
            raw.frozenCorners,
            raw.corners,
          ],
        ),
    ..._liveTracker.savedFootprints.map(
      (LiveScanExcludedRegion saved) => saved.corners,
    ),
    ...<List<ScanPoint>>[
      ..._liveTracker.tracks.map((LiveScanTrack track) => track.corners),
      ..._focusCandidates.map((LiveCardDetection card) => card.corners),
    ].where(_awaitsFrozenRead),
  ]);

  static bool _sameRawRegion(List<ScanPoint> a, List<ScanPoint> b) {
    if (a.length != 4 || b.length != 4) return false;
    ScanBounds bounds(List<ScanPoint> points) {
      final double left = points
          .map((ScanPoint p) => p.x)
          .reduce((double x, double y) => x < y ? x : y);
      final double top = points
          .map((ScanPoint p) => p.y)
          .reduce((double x, double y) => x < y ? x : y);
      final double right = points
          .map((ScanPoint p) => p.x)
          .reduce((double x, double y) => x > y ? x : y);
      final double bottom = points
          .map((ScanPoint p) => p.y)
          .reduce((double x, double y) => x > y ? x : y);
      return ScanBounds(left, top, right - left, bottom - top);
    }

    final ScanBounds x = bounds(a);
    final ScanBounds y = bounds(b);
    final double left = x.x > y.x ? x.x : y.x;
    final double top = x.y > y.y ? x.y : y.y;
    final double right = x.x + x.width < y.x + y.width
        ? x.x + x.width
        : y.x + y.width;
    final double bottom = x.y + x.height < y.y + y.height
        ? x.y + x.height
        : y.y + y.height;
    if (right <= left || bottom <= top) return false;
    final double intersection = (right - left) * (bottom - top);
    final double union = x.width * x.height + y.width * y.height - intersection;
    return union > 0 && intersection / union >= .6;
  }

  static bool _rawRegionsOverlap(List<ScanPoint> a, List<ScanPoint> b) {
    if (a.length != 4 ||
        b.length != 4 ||
        <ScanPoint>[
          ...a,
          ...b,
        ].any((ScanPoint point) => !point.x.isFinite || !point.y.isFinite)) {
      return true;
    }
    double minimum(Iterable<double> values) =>
        values.reduce((double x, double y) => math.min(x, y));
    double maximum(Iterable<double> values) =>
        values.reduce((double x, double y) => math.max(x, y));
    return minimum(a.map((ScanPoint p) => p.x)) <
            maximum(b.map((ScanPoint p) => p.x)) &&
        minimum(b.map((ScanPoint p) => p.x)) <
            maximum(a.map((ScanPoint p) => p.x)) &&
        minimum(a.map((ScanPoint p) => p.y)) <
            maximum(b.map((ScanPoint p) => p.y)) &&
        minimum(b.map((ScanPoint p) => p.y)) <
            maximum(a.map((ScanPoint p) => p.y));
  }

  ({List<LiveScanExcludedRegion> regions, int strongCount, int rawCount})
  _nextAppearanceRegions() {
    final List<LiveScanExcludedRegion> strong = _liveTracker.savedFootprints;
    final List<LiveScanExcludedRegion> raw =
        <_RawContour>[
              ..._rawPhotoContours,
              ..._rawObservations.where(
                (_RawContour contour) =>
                    !_hasRawPhoto(contour.corners) &&
                    !_liveTracker.isSaved(contour.corners) &&
                    !_awaitsFrozenRead(contour.corners),
              ),
            ]
            .where((_RawContour contour) => contour.receiptId != null)
            .map(
              (_RawContour contour) => LiveScanExcludedRegion(
                id: contour.receiptId!,
                corners: contour.paths == null
                    ? contour.corners
                    : contour.frozenCorners,
              ),
            )
            .toList();
    if (raw.isEmpty) {
      return (regions: strong, strongCount: strong.length, rawCount: 0);
    }
    final int strongCount = math.min(
      strong.length,
      8 - math.min(2, raw.length),
    );
    final int rawCount = math.min(raw.length, 8 - strongCount);
    final List<LiveScanExcludedRegion> selected = <LiveScanExcludedRegion>[
      for (int index = 0; index < strongCount; index++)
        strong[(_strongAppearanceOffset + index) % strong.length],
      for (int index = 0; index < rawCount; index++)
        raw[(_rawAppearanceOffset + index) % raw.length],
    ];
    return (
      regions: List<LiveScanExcludedRegion>.unmodifiable(selected),
      strongCount: strongCount,
      rawCount: rawCount,
    );
  }

  void _updateRawContours(
    LiveScanFrame frame,
    Set<String> sampledIds,
    int frameSequence,
  ) {
    if (!frame.rectanglesSupported) {
      _rawObservations.clear();
      for (final _RawContour retained in _rawPhotoContours) {
        retained.clearCaptureFeedbackAppearance();
        retained.visible = false;
      }
      return;
    }
    final List<LiveCardDetection> present = frame.focusCandidates
        .where(
          (LiveCardDetection card) =>
              card.corners.length == 4 &&
              card.corners.every(
                (ScanPoint point) =>
                    point.x.isFinite &&
                    point.y.isFinite &&
                    point.x >= 0 &&
                    point.x <= 1 &&
                    point.y >= 0 &&
                    point.y <= 1,
              ) &&
              GuidedCameraScreen._regionContains(card.corners, card.corners),
        )
        .take(40)
        .toList();
    final List<LiveCardDetection> current = present
        .where(
          (LiveCardDetection card) =>
              card.confidence >= .9 &&
              card.warnings.contains('geometry_only') &&
              !card.warnings.contains('tracked_partial'),
        )
        .toList();
    final Set<_RawContour> retired = <_RawContour>{};
    final DateTime now = DateTime.now();
    for (final _RawContour retained in _rawPhotoContours) {
      final List<LiveCardDetection> matches = present
          .where(
            (LiveCardDetection card) => _rawOwnsRegion(retained, card.corners),
          )
          .toList();
      retained.visible = matches.length == 1;
      if (!retained.visible || !frame.appearanceSamplingSupported) {
        retained.clearCaptureFeedbackAppearance();
      }
      if (sampledIds.contains(retained.receiptId)) {
        final List<LiveCardAppearanceSample> samples = frame.appearanceSamples
            .where(
              (LiveCardAppearanceSample sample) =>
                  sample.id == retained.receiptId &&
                  _RawContour.sameFootprint(
                    sample.corners,
                    retained.frozenCorners,
                  ),
            )
            .toList();
        if (!frame.appearanceSamplingSupported ||
            _capturing ||
            _discoveryFocus != null) {
          retained.resetAppearanceEvidence();
        } else if (retained.retireFromAppearance(
          samples.length == 1 ? samples.single : null,
          uniqueContour: matches.length == 1,
          noContour:
              matches.isEmpty &&
              <LiveCardDetection>[
                ...frame.focusCandidates,
                ...frame.cards,
              ].every(
                (LiveCardDetection card) =>
                    !_rawRegionsOverlap(retained.corners, card.corners),
              ),
          now: now,
        )) {
          if (const bool.fromEnvironment('PHYSICAL_CARD_QA')) {
            debugPrint(
              'RAW_RETIRE_DIAGNOSTIC id=${retained.receiptId} '
              'matches=${matches.length} present=${samples.singleOrNull?.present} '
              'changed=${retained._changedFrames} '
              'background=${retained._backgroundFrames} '
              'frozen=${retained.frozenCorners.map((ScanPoint point) => '${point.x},${point.y}').join(';')} '
              'current=${retained.corners.map((ScanPoint point) => '${point.x},${point.y}').join(';')}',
            );
          }
          if (retained.capture != null) {
            _liveTracker.invalidateFrozenRegion(
              retained.capture!,
              retained.frozenCorners,
            );
          }
          retired.add(retained);
        }
      }
      if (matches.length == 1) {
        retained.corners = List<ScanPoint>.unmodifiable(matches.single.corners);
      }
    }
    _rawPhotoContours.removeWhere(retired.contains);
    for (final _RawContour retiredContour in retired) {
      _rawFeedbackOrigins.remove(retiredContour.receiptId);
    }
    final List<_RawContour> next = <_RawContour>[];
    for (final LiveCardDetection card in current) {
      if (_hasRawPhoto(card.corners) ||
          _isSavedCardPanel(card.corners) ||
          _liveTracker.savedFootprints.any(
            (LiveScanExcludedRegion saved) =>
                _sameRawRegion(saved.corners, card.corners),
          )) {
        continue;
      }
      final List<_RawContour> prior = _rawObservations
          .where(
            (_RawContour contour) =>
                _sameRawRegion(contour.corners, card.corners),
          )
          .toList();
      if (current
              .where(
                (LiveCardDetection other) =>
                    _sameRawRegion(other.corners, card.corners),
              )
              .length !=
          1) {
        continue;
      }
      final _RawContour contour =
          prior.length == 1 &&
              prior.single.lastObservedAt != null &&
              now.difference(prior.single.lastObservedAt!) <=
                  const Duration(milliseconds: 1400)
          ? prior.single
          : _RawContour(
              card.corners,
              receiptId: 'preview_${_generation}_${++_nextRawPreviewId}',
            );
      if (prior.length == 1 && identical(contour, prior.single)) {
        contour.stableFrames++;
      }
      contour.lastObservedAt = now;
      contour.lastObservedFrame = frameSequence;
      if (frame.appearanceSamplingSupported &&
          sampledIds.contains(contour.receiptId)) {
        final List<LiveCardAppearanceSample> samples = frame.appearanceSamples
            .where(
              (LiveCardAppearanceSample sample) =>
                  sample.id == contour.receiptId &&
                  _sameRawRegion(sample.corners, card.corners),
            )
            .toList();
        if (samples.length == 1) {
          contour.observePreviewAppearance(samples.single, now);
        }
      }
      contour.corners = List<ScanPoint>.unmodifiable(card.corners);
      next.add(contour);
    }
    _rawObservations
      ..clear()
      ..addAll(next.take(8));
  }

  List<List<ScanPoint>> get _rawCaptureTargets => _rawObservations
      .where(
        (_RawContour contour) =>
            contour.stableFrames >= 2 &&
            contour.lastObservedAt != null &&
            DateTime.now().difference(contour.lastObservedAt!) <=
                const Duration(milliseconds: 500) &&
            !_rawPhotoContours.any(
              (_RawContour saved) => _rawOwnsRegion(saved, contour.corners),
            ) &&
            !_awaitsFrozenRead(contour.corners) &&
            !_isSavedCardPanel(contour.corners) &&
            !_liveTracker.savedFootprints.any(
              (saved) => _sameRawRegion(saved.corners, contour.corners),
            ),
      )
      .take(8 - _rawPhotoContours.length)
      .map((_RawContour contour) => contour.corners)
      .toList();

  void _considerRawCapture(CameraController controller) {
    final ScanSession? session = widget.session;
    if (session == null ||
        _resumeOwnershipPending ||
        widget.onUnidentifiedPhotoCaptured == null ||
        !_usesCamera(controller) ||
        _capturing ||
        _waitingRawFocus ||
        _automaticExposureBusy ||
        _pendingPhoto != null ||
        _startingStream ||
        _automaticPaused ||
        _controls ||
        session.paused ||
        session.storageError != null ||
        _photoCaptureBacklog ||
        _rawPhotoContours.length >= 8 ||
        (_automaticRetryAt != null &&
            DateTime.now().isBefore(_automaticRetryAt!))) {
      return;
    }
    final List<List<ScanPoint>> targets = _rawCaptureTargets;
    if (targets.isEmpty) return;
    unawaited(_captureUnidentified(controller, targets));
  }

  Future<void> _captureUnidentified(
    CameraController controller,
    List<List<ScanPoint>> targets,
  ) => _trackCaptureWork(() => _captureUnidentifiedPhoto(controller, targets));

  Future<void> _captureUnidentifiedPhoto(
    CameraController controller,
    List<List<ScanPoint>> targets,
  ) async {
    final _UnidentifiedPhotoHandoff handoff =
        widget.onUnidentifiedPhotoCaptured!;
    if (_clearingCaptures || _waitingRawFocus || _capturing) {
      return;
    }
    setState(() => _waitingRawFocus = true);
    try {
      targets = await _readyRawTargets(controller, targets);
    } finally {
      if (mounted) setState(() => _waitingRawFocus = false);
    }
    if (targets.isEmpty ||
        _clearingCaptures ||
        _automaticPaused ||
        _controls ||
        !_usesCamera(controller)) {
      return;
    }
    final List<List<ScanPoint>>? protected = _protectedCaptureRegions();
    if (protected == null) return;
    setState(() {
      _capturing = true;
      _capturePhase = _CapturePhase.takingPhoto;
    });
    final ScanSession? owner = widget.session;
    final int capture = _liveTracker.beginCapture();
    final String? orientation = _liveOrientationToken;
    final int generation = _generation;
    final bool streaming = _streamDuringCapture;
    final DateTime shutterAt = DateTime.now();
    final List<List<double>?> appearances = targets.map((
      List<ScanPoint> target,
    ) {
      final List<_RawContour> matching = _rawObservations
          .where(
            (_RawContour contour) => _sameRawRegion(contour.corners, target),
          )
          .toList();
      return matching.length == 1
          ? matching.single.appearanceForCapture(shutterAt, target)
          : null;
    }).toList();
    try {
      final LiveCaptureSnapshot snapshot = _liveTracker.snapshotCapture(
        geometryOnly: true,
        currentGeometry: targets,
        blockedRegions: protected,
      );
      final _CaptureFeedbackContext feedback = _captureFeedbackContext(
        controller,
        snapshot,
      );
      if (!streaming && controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      if (!_usesCamera(controller)) return;
      final XFile file = await controller.takePicture();
      _pendingCaptureFeedback = feedback;
      _pendingPhoto = file.path;
      _pendingStack = <String>[file.path];
      _pendingCaptureSnapshot = snapshot;
      _pendingExclusions = protected;
      _pendingUnidentifiedContours = List<List<ScanPoint>>.unmodifiable(
        targets,
      );
      _pendingRawGeneration = generation;
      _pendingRawOrientationToken = orientation;
      _pendingRawHandoff = handoff;
      _pendingRawSession = owner;
      _pendingRawCamera = controller;
      _pendingRawAppearances = appearances;
      _pendingRawOrientationChanged =
          orientation !=
          NativeLiveCardDetector.orientationTokenFor(
            camera: controller.description,
            orientation: _orientation(controller),
          );
      if (!mounted) return;
      await _savePending();
    } catch (_) {
      _automaticRetryAt = DateTime.now().add(const Duration(seconds: 4));
      if (mounted && _pendingPhoto == null) {
        setState(() => _error = 'Capture failed');
      }
    } finally {
      if (mounted) {
        setState(() {
          _capturing = false;
          _capturePhase = _CapturePhase.idle;
        });
      }
      try {
        if (_usesCamera(controller)) await _startLive(controller);
      } finally {
        _liveTracker.endCapture(
          capture,
          resumeTracking:
              !streaming &&
              _usesCamera(controller) &&
              controller.value.isStreamingImages,
        );
      }
    }
  }

  Future<List<List<ScanPoint>>> _readyRawTargets(
    CameraController controller,
    List<List<ScanPoint>> targets,
  ) async {
    final int generation = _generation;
    final ScanSession? session = widget.session;
    final String? orientation = _liveOrientationToken;
    final List<_RawContour> contours = <_RawContour>[];
    for (final List<ScanPoint> target in targets) {
      final List<_RawContour> matches = _rawObservations
          .where(
            (_RawContour contour) => _sameRawRegion(contour.corners, target),
          )
          .toList();
      if (matches.length != 1) return const <List<ScanPoint>>[];
      contours.add(matches.single);
    }
    bool current() =>
        mounted &&
        widget.automaticCapture &&
        widget.onUnidentifiedPhotoCaptured != null &&
        session != null &&
        !session.paused &&
        !session.clearingCaptures &&
        session.storageError == null &&
        !_photoCaptureBacklog &&
        _rawPhotoContours.length < 8 &&
        !_clearingCaptures &&
        !_automaticExposureBusy &&
        !_automaticPaused &&
        !_controls &&
        _usesCamera(controller) &&
        generation == _generation &&
        identical(session, widget.session) &&
        orientation != null &&
        orientation == _liveOrientationToken &&
        orientation ==
            NativeLiveCardDetector.orientationTokenFor(
              camera: controller.description,
              orientation: _orientation(controller),
            );
    final Future<void>? focusing = _discoveryFocus;
    if (focusing != null) {
      try {
        await focusing.timeout(const Duration(seconds: 1));
      } catch (_) {
        return const <List<ScanPoint>>[];
      }
    }
    if (!current()) return const <List<ScanPoint>>[];
    final bool requiresSettledFocus = _rawFocusReadinessRequired;
    final bool canFocusTarget =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        controller.value.focusPointSupported &&
        !_focusLocked &&
        (_manualFocusAt == null ||
            DateTime.now().difference(_manualFocusAt!) >=
                const Duration(seconds: 12));
    if (requiresSettledFocus ||
        canFocusTarget ||
        _rawCloserLensCandidate(controller, contours) != null) {
      try {
        Map<Object?, Object?>? status = await NativeCardRecognizer.channel
            .invokeMethod<Map<Object?, Object?>>(
              'cameraFocusStatus',
              <String, String>{'cameraName': controller.description.name},
            )
            .timeout(const Duration(milliseconds: 400));
        if (!current()) return const <List<ScanPoint>>[];
        final ScanPoint? focus = _nativeFocusPoint(controller, status);
        if (canFocusTarget && (focus != null || _rawTargetFocusSupported)) {
          _rawTargetFocusSupported = true;
          final List<_RawContour> focused = contours
              .where((_RawContour contour) => _rawFocusContains(contour, focus))
              .toList();
          final _RawContour target = focused.length == 1
              ? focused.single
              : contours.first;
          status = await _readyRawTargetFocus(
            controller,
            target,
            status,
            current,
          );
          if (status == null || !current()) {
            return const <List<ScanPoint>>[];
          }
          contours
            ..clear()
            ..add(target);
        }
        final Object? position = status?['lensPosition'];
        final bool settled =
            status?['isAdjustingFocus'] == false &&
            (status?['focusMode'] == 0 || status?['focusMode'] == 2) &&
            position is num &&
            position.toDouble().isFinite &&
            position >= 0 &&
            position <= 1;
        if (!settled) {
          if (requiresSettledFocus) return const <List<ScanPoint>>[];
        } else {
          _rawFocusReadinessRequired = false;
          final LiveCardDetection? candidate = _rawCloserLensCandidate(
            controller,
            contours,
          );
          if (candidate != null) {
            final CameraDescription? closer = closerScanLens(
              current: controller.description,
              cameras: _rearCameras,
              userSelectedLens: _lensChosenManually,
              hasCardEvidence: true,
              sharpness: candidate.sharpness,
              lensPosition: position.toDouble(),
            );
            if (closer != null) {
              _selectLens(closer.name, automatic: true);
              if (generation != _generation) {
                _closerLensAttempted = true;
                return const <List<ScanPoint>>[];
              }
            }
          }
        }
      } catch (_) {
        if (requiresSettledFocus ||
            (_rawTargetFocusSupported && canFocusTarget)) {
          return const <List<ScanPoint>>[];
        }
      }
    }
    if (!current()) return const <List<ScanPoint>>[];
    final List<List<ScanPoint>> available = _rawCaptureTargets;
    return List<List<ScanPoint>>.unmodifiable(
      contours
          .where(
            (_RawContour contour) =>
                _rawObservations.contains(contour) &&
                available
                        .where(
                          (List<ScanPoint> region) =>
                              _sameRawRegion(region, contour.corners),
                        )
                        .length ==
                    1,
          )
          .map(
            (_RawContour contour) =>
                List<ScanPoint>.unmodifiable(contour.corners),
          ),
    );
  }

  ScanPoint? _nativeFocusPoint(
    CameraController controller,
    Map<Object?, Object?>? status,
  ) {
    final Object? x = status?['focusPointX'];
    final Object? y = status?['focusPointY'];
    if (x is! num ||
        y is! num ||
        !x.isFinite ||
        !y.isFinite ||
        x < 0 ||
        x > 1 ||
        y < 0 ||
        y > 1) {
      return null;
    }
    final double nativeX = x.toDouble();
    final double nativeY = y.toDouble();
    return switch (_orientation(controller)) {
      DeviceOrientation.portraitUp => ScanPoint(1 - nativeY, nativeX),
      DeviceOrientation.portraitDown => ScanPoint(nativeY, 1 - nativeX),
      DeviceOrientation.landscapeRight => ScanPoint(1 - nativeX, 1 - nativeY),
      DeviceOrientation.landscapeLeft => ScanPoint(nativeX, nativeY),
    };
  }

  bool _rawFocusContains(_RawContour contour, ScanPoint? point) =>
      point != null &&
      GuidedCameraScreen._regionContains(
        contour.corners,
        List<ScanPoint>.filled(4, point),
      );

  Future<Map<Object?, Object?>?> _readyRawTargetFocus(
    CameraController controller,
    _RawContour target,
    Map<Object?, Object?>? initialStatus,
    bool Function() current,
  ) async {
    final DateTime deadline = DateTime.now().add(
      const Duration(milliseconds: 900),
    );
    int focusGeneration = _focusGeneration;
    bool targetCurrent() =>
        current() &&
        focusGeneration == _focusGeneration &&
        _rawObservations.contains(target) &&
        _rawCaptureTargets
                .where(
                  (List<ScanPoint> corners) =>
                      _sameRawRegion(corners, target.corners),
                )
                .length ==
            1;
    Map<Object?, Object?>? status = initialStatus;
    double? previous;
    int stable = 0;
    bool requested = false;
    while (targetCurrent() && DateTime.now().isBefore(deadline)) {
      final bool matches = _rawFocusContains(
        target,
        _nativeFocusPoint(controller, status),
      );
      // A new card can occupy the same focus point at a different depth.
      final bool hasTargetRequest =
          target._focusRequestGeneration == focusGeneration;
      if ((!matches || !hasTargetRequest) && !requested) {
        final ScanPoint? point = _focusCenter(target.corners);
        if (point == null) return null;
        requested = true;
        final int requestedGeneration = _focusGeneration + 1;
        await _setFocusPoint(
          controller,
          Offset(point.x, point.y),
          singleShot: !_sweeping,
          expose: false,
        ).timeout(const Duration(milliseconds: 400));
        focusGeneration = requestedGeneration;
        if (!targetCurrent()) return null;
        target._focusRequestGeneration = focusGeneration;
        status = null;
        previous = null;
        stable = 0;
      } else {
        final Object? rawPosition = status?['lensPosition'];
        final double? position =
            rawPosition is num &&
                rawPosition.isFinite &&
                rawPosition >= 0 &&
                rawPosition <= 1
            ? rawPosition.toDouble()
            : null;
        final bool settled =
            matches &&
            position != null &&
            status?['isAdjustingFocus'] == false &&
            (status?['focusMode'] == 0 || status?['focusMode'] == 2);
        if (!settled) {
          _rawSettledFocus = null;
          stable = 0;
        } else {
          final double settledPosition = position;
          final ({
            _RawContour contour,
            int focusGeneration,
            int afterFrame,
            double lensPosition,
          })?
          ready = _rawSettledFocus;
          if (ready != null &&
              identical(ready.contour, target) &&
              ready.focusGeneration == focusGeneration &&
              (settledPosition - ready.lensPosition).abs() < .003) {
            if (target.lastObservedFrame > ready.afterFrame) return status;
          } else {
            _rawSettledFocus = null;
            stable =
                previous != null && (settledPosition - previous).abs() < .003
                ? stable + 1
                : 0;
            if (stable >= 3) {
              // A frame already being analyzed can still contain pre-focus pixels.
              _rawSettledFocus = (
                contour: target,
                focusGeneration: focusGeneration,
                afterFrame: _startedLiveFrames,
                lensPosition: settledPosition,
              );
            }
          }
        }
        previous = settled ? position : null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!targetCurrent()) return null;
      status = await NativeCardRecognizer.channel
          .invokeMethod<Map<Object?, Object?>>(
            'cameraFocusStatus',
            <String, String>{'cameraName': controller.description.name},
          )
          .timeout(const Duration(milliseconds: 400));
    }
    return null;
  }

  LiveCardDetection? _rawCloserLensCandidate(
    CameraController controller,
    List<_RawContour> contours,
  ) {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.iOS ||
        controller.description.lensType != CameraLensType.wide ||
        _focusLocked ||
        _lensChosenManually ||
        _closerLensAttempted ||
        _hasCaptureOwnership ||
        _rawPhotoContours.isNotEmpty ||
        (_manualFocusAt != null &&
            DateTime.now().difference(_manualFocusAt!) <
                const Duration(seconds: 12)) ||
        !_rearCameras.any(
          (CameraDescription camera) =>
              camera.lensType == CameraLensType.ultraWide,
        )) {
      return null;
    }
    final List<List<ScanPoint>> available = _rawCaptureTargets;
    for (final _RawContour contour in contours) {
      if (!_rawObservations.contains(contour) ||
          !available.any(
            (List<ScanPoint> corners) =>
                _sameRawRegion(corners, contour.corners),
          )) {
        continue;
      }
      final List<LiveCardDetection> matches = _focusCandidates
          .where(
            (LiveCardDetection card) =>
                _sameRawRegion(card.corners, contour.corners),
          )
          .toList();
      if (matches.length != 1) continue;
      final LiveCardDetection card = matches.single;
      final double? sharpness = card.sharpness;
      if (card.confidence >= .9 &&
          card.warnings.contains('geometry_only') &&
          !card.warnings.contains('tracked_partial') &&
          sharpness != null &&
          sharpness.isFinite &&
          sharpness >= 0 &&
          sharpness < .12) {
        return card;
      }
    }
    return null;
  }

  void _considerDiscoveryFocus(CameraController controller) {
    if (!widget.automaticCapture ||
        !_usesCamera(controller) ||
        _capturing ||
        _waitingRawFocus ||
        _automaticExposureBusy ||
        _startingStream ||
        _automaticPaused ||
        _controls ||
        _focusLocked ||
        _pendingPhoto != null ||
        _adaptiveTargetIds.isNotEmpty ||
        _pendingSavedFocus.isNotEmpty ||
        _automaticReadyAt != null ||
        _availableCaptureTracks.isNotEmpty ||
        _discoveryFocus != null ||
        (_manualFocusAt != null &&
            DateTime.now().difference(_manualFocusAt!) <
                const Duration(seconds: 12))) {
      return;
    }
    final ScanPoint? point = planDetectedScanFocusPoints(
      regions: _focusCandidates
          .where(
            (LiveCardDetection card) =>
                !_liveTracker.isSaved(card.corners) &&
                !_hasRawPhoto(card.corners) &&
                !_awaitsFrozenRead(card.corners),
          )
          .map((LiveCardDetection card) => card.corners),
    ).where(_focusDiscovery.allowsImmediate).firstOrNull;
    if (point == null) {
      return;
    }
    _discoveryFocus = _discoverFocus(
      controller,
      preferredPoint: point,
    ).whenComplete(() => _discoveryFocus = null);
  }

  Future<void> _discoverFocus(
    CameraController controller, {
    ScanPoint? preferredPoint,
  }) async {
    final int generation = _generation;
    if (!_usesCamera(controller) ||
        _resumeOwnershipPending ||
        _waitingRawFocus ||
        _automaticExposureBusy ||
        _capturing ||
        _startingStream ||
        _pendingPhoto != null ||
        (widget.automaticCapture && _automaticPaused) ||
        _adaptiveTargetIds.isNotEmpty ||
        _controls ||
        _focusLocked ||
        (_pendingSavedFocus.isEmpty &&
            _focusCandidates
                .where(
                  (LiveCardDetection card) =>
                      !_liveTracker.isSaved(card.corners) &&
                      !_hasRawPhoto(card.corners),
                )
                .isEmpty) ||
        !controller.value.focusPointSupported ||
        (_manualFocusAt != null &&
            DateTime.now().difference(_manualFocusAt!) <
                const Duration(seconds: 12))) {
      return;
    }
    if (preferredPoint != null &&
        !_focusDiscovery.allowsImmediate(preferredPoint)) {
      return;
    }
    List<ScanPoint> points = widget.automaticCapture
        ? planDetectedScanFocusPoints(
            regions:
                (_pendingSavedFocus.isNotEmpty
                        ? _pendingSavedFocus
                        : <List<ScanPoint>>[
                            ..._focusMemory.targets,
                            ..._focusCandidates.map(
                              (LiveCardDetection card) => card.corners,
                            ),
                          ])
                    .where(
                      (List<ScanPoint> corners) =>
                          !_liveTracker.isSaved(corners) &&
                          !_hasRawPhoto(corners),
                    ),
          )
        : planScanFocusPoints(
            candidates: _focusCandidates
                .where(
                  (LiveCardDetection card) =>
                      !_liveTracker.isSaved(card.corners) &&
                      !_hasRawPhoto(card.corners),
                )
                .toList(),
            trackedCorners: _focusMemory.targets.where(
              (List<ScanPoint> corners) =>
                  !_liveTracker.isSaved(corners) && !_hasRawPhoto(corners),
            ),
          );
    final bool exploring =
        widget.automaticCapture &&
        _liveTracker.savedFootprints.isNotEmpty &&
        _liveTracker.uncapturedTracks.isEmpty &&
        _pendingSavedFocus.isEmpty;
    if (exploring) {
      points = points.where(_focusDiscovery.allows).toList(growable: false);
    }
    if (points.isEmpty && preferredPoint == null) {
      return;
    }
    final ScanPoint point =
        preferredPoint ?? points[_discoveryIndex++ % points.length];
    if (exploring || preferredPoint != null) {
      _focusDiscovery.record(point);
    }
    final _RawContour? rawTarget = _rawObservations
        .where((_RawContour contour) => _rawFocusContains(contour, point))
        .singleOrNull;
    final int requestedGeneration = _focusGeneration + 1;
    try {
      await _setFocusPoint(
        controller,
        Offset(point.x, point.y),
        singleShot: !_sweeping,
        expose: false,
      );
      if (_clearingCaptures ||
          !_usesCamera(controller) ||
          _capturing ||
          generation != _generation) {
        return;
      }
      if (rawTarget != null &&
          requestedGeneration == _focusGeneration &&
          identical(
            rawTarget,
            _rawObservations
                .where(
                  (_RawContour contour) => _rawFocusContains(contour, point),
                )
                .singleOrNull,
          )) {
        rawTarget._focusRequestGeneration = requestedGeneration;
      }
      _rawFocusReadinessRequired =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
      await _waitForFocus(controller, sweep: _sweeping);
      if (!_usesCamera(controller) || _capturing || generation != _generation) {
        return;
      }
      await _considerCloserLens(controller, point);
    } catch (_) {
      // Automatic probes must leave manual focus and capture available.
    }
  }

  Future<void> _considerCloserLens(
    CameraController controller,
    ScanPoint focus,
  ) async {
    if (_clearingCaptures ||
        _waitingRawFocus ||
        _lensChosenManually ||
        _closerLensAttempted ||
        _hasCaptureOwnership) {
      return;
    }
    final bool hasEvidence = _liveTracker.tracks.any((LiveScanTrack track) {
      final List<ScanPoint> corners = track.crop.sourceCorners;
      if (!track.hasCardEvidence || corners.length != 4) return false;
      final double x =
          corners.fold<double>(0, (double sum, ScanPoint p) => sum + p.x) / 4;
      final double y =
          corners.fold<double>(0, (double sum, ScanPoint p) => sum + p.y) / 4;
      return (x - focus.x).abs() < .15 && (y - focus.y).abs() < .15;
    });
    if (!hasEvidence) return;
    double? sharpness;
    for (final LiveCardDetection candidate in _focusCandidates) {
      if (candidate.corners.length != 4) continue;
      final double x =
          candidate.corners.fold<double>(
            0,
            (double sum, ScanPoint p) => sum + p.x,
          ) /
          4;
      final double y =
          candidate.corners.fold<double>(
            0,
            (double sum, ScanPoint p) => sum + p.y,
          ) /
          4;
      if ((x - focus.x).abs() < .15 && (y - focus.y).abs() < .15) {
        final double? score = candidate.sharpness;
        if (score != null && (sharpness == null || score > sharpness)) {
          sharpness = score;
        }
      }
    }
    try {
      final Map<Object?, Object?>? status = await NativeCardRecognizer.channel
          .invokeMethod<Map<Object?, Object?>>(
            'cameraFocusStatus',
            <String, String>{'cameraName': controller.description.name},
          )
          .timeout(const Duration(milliseconds: 400));
      if (_clearingCaptures || !_usesCamera(controller) || _capturing) return;
      final CameraDescription? closer = closerScanLens(
        current: controller.description,
        cameras: _rearCameras,
        userSelectedLens: _lensChosenManually,
        hasCardEvidence: hasEvidence,
        sharpness: sharpness,
        lensPosition: (status?['lensPosition'] as num?)?.toDouble(),
      );
      if (closer != null) {
        _closerLensAttempted = true;
        _selectLens(closer.name, automatic: true);
      }
    } catch (_) {
      // A camera without focus telemetry keeps its current physical lens.
    }
  }

  void _scheduleCamera(bool open, {bool preserveOwnership = false}) {
    _discoveryTimer?.cancel();
    final int generation = ++_generation;
    _invalidateExposure();
    _automaticExposureBusy = false;
    _automaticExposureUnavailable = false;
    _exposureWork = Future<void>.value();
    final CameraController? previous = _camera;
    final bool retained =
        preserveOwnership &&
        (_resumeOwnershipPending ||
            _hasCaptureOwnership ||
            _rawPhotoContours.isNotEmpty);
    final String? retainedCamera = _selectedCameraName;
    final double retainedZoom = _appliedZoom;
    previous?.removeListener(_cameraChanged);
    _camera = null;
    _torch = false;
    _startingStream = false;
    _trackingError = null;
    if (retained) {
      _suspendTracking();
    } else {
      _clearTracking();
    }
    if (mounted) setState(() {});
    _lifecycle = _lifecycle.catchError((Object _) {}).then((_) async {
      await _disposeCamera(previous);
      if (!open || !mounted || generation != _generation) return;
      setState(() => _error = null);
      CameraController? controller;
      try {
        final List<CameraDescription> cameras = await availableCameras();
        if (!mounted || generation != _generation) return;
        if (cameras.isEmpty) throw StateError('No camera is available.');
        _rearCameras = cameras
            .where(
              (CameraDescription camera) =>
                  camera.lensDirection == CameraLensDirection.back,
            )
            .toList();
        final CameraDescription camera =
            _rearCameras
                .where(
                  (CameraDescription item) => item.name == _selectedCameraName,
                )
                .firstOrNull ??
            _rearCameras
                .where(
                  (CameraDescription item) =>
                      item.lensType == CameraLensType.wide,
                )
                .firstOrNull ??
            _rearCameras.firstOrNull ??
            cameras.first;
        final bool restoreOwnership = retained && camera.name == retainedCamera;
        if (retained && !restoreOwnership) _clearTracking();
        _selectedCameraName = camera.name;
        controller = CameraController(
          camera,
          ResolutionPreset.max,
          enableAudio: false,
          imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
              ? ImageFormatGroup.bgra8888
              : ImageFormatGroup.yuv420,
        );
        await controller.initialize();
        if (!mounted || generation != _generation) {
          await controller.dispose();
          return;
        }
        try {
          await controller.setJpegImageQuality(95);
        } catch (_) {}
        try {
          await controller.setFlashMode(FlashMode.off);
        } catch (_) {}
        try {
          _minZoom = await controller.getMinZoomLevel();
          _maxZoom = (await controller.getMaxZoomLevel()).clamp(
            _minZoom,
            8.0 > _minZoom ? 8.0 : _minZoom,
          );
          _zoom = (restoreOwnership ? retainedZoom : 1.0).clamp(
            _minZoom,
            _maxZoom,
          );
          await controller.setZoomLevel(_zoom);
          if (restoreOwnership && _zoom != retainedZoom) _clearTracking();
        } catch (_) {
          if (restoreOwnership) _clearTracking();
          _minZoom = _maxZoom = _zoom = 1;
        }
        try {
          _minExposure = await controller.getMinExposureOffset();
          _maxExposure = await controller.getMaxExposureOffset();
          _exposureStep = await controller.getExposureOffsetStepSize();
          _exposure = (_manualExposure ? _manualExposureValue : 0.0).clamp(
            _minExposure,
            _maxExposure,
          );
          if (_manualExposure) {
            _exposure = await controller
                .setExposureOffset(_exposure)
                .timeout(const Duration(milliseconds: 400));
            if (!_exposure.isFinite ||
                _exposure < _minExposure ||
                _exposure > _maxExposure) {
              throw StateError('Invalid exposure offset');
            }
            _manualExposureValue = _exposure;
          }
          _appliedExposure = _exposure;
        } catch (_) {
          _minExposure = _maxExposure = _exposure = _appliedExposure = 0;
          if (_manualExposure) _manualExposureValue = 0;
        }
        _focusLocked = false;
        _appliedZoom = _zoom;
        _torchUnavailable = false;
        if (!mounted || generation != _generation) {
          await controller.dispose();
          return;
        }
        setState(() => _camera = controller);
        controller.addListener(_cameraChanged);
        await _startLive(controller);
      } catch (error) {
        await controller?.dispose();
        if (mounted && generation == _generation) {
          setState(
            () => _error =
                error is CameraException &&
                    (error.code.contains('Denied') ||
                        error.code.contains('Restricted'))
                ? 'Camera access denied. Enable Camera in Settings.'
                : 'Camera unavailable',
          );
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleCamera(widget.active, preserveOwnership: true);
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _scheduleCamera(false, preserveOwnership: true);
    }
  }

  Future<void> _capture() => _trackCaptureWork(_capturePhoto);

  Future<void> _capturePhoto() async {
    final CameraController? controller = _camera;
    final _TrackedPhotoHandoff? trackedHandoff = widget.onFocusStackCaptured;
    final _SinglePhotoHandoff? singleHandoff = widget.onCaptured;
    if (_clearingCaptures ||
        _resumeOwnershipPending ||
        _waitingRawFocus ||
        _automaticExposureBusy ||
        _capturing ||
        (widget.automaticCapture && _photoCaptureBacklog) ||
        (!widget.automaticCapture && widget.multipleCards && _sceneSaved) ||
        _pendingPhoto != null ||
        _startingStream ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }
    final List<LiveScanTrack> available = _availableCaptureTracks;
    final List<LiveScanTrack> newTracks = available
        .where((LiveScanTrack track) => !track.hasRetainedCapture)
        .toList();
    final LiveScanTrack? recoveryTarget =
        (newTracks.isEmpty ? available : newTracks)
            .where(
              (LiveScanTrack track) => _adaptiveTargetIds.contains(track.id),
            )
            .firstOrNull ??
        (_sweeping &&
                !_photoCaptureBacklog &&
                !_focusLocked &&
                (_manualFocusAt == null ||
                    DateTime.now().difference(_manualFocusAt!) >=
                        const Duration(seconds: 12))
            ? (newTracks.isEmpty ? available : newTracks)
                  .where(
                    (LiveScanTrack track) =>
                        track.hasRetainedCapture &&
                        !track.hasVerifiedLiveIdentity,
                  )
                  .firstOrNull
            : null);
    setState(() {
      _capturing = true;
      _adaptiveCapturing = recoveryTarget != null;
      _capturePhase = _CapturePhase.focusing;
      _captureStep = 0;
      if (!widget.multipleCards && !widget.automaticCapture) {
        _sceneSaved = false;
        _savedStack = null;
        _savedCaptureSnapshot = null;
      }
    });
    if (!widget.multipleCards && !widget.automaticCapture) {
      _liveTracker.rearmCaptured();
    }
    final int capture = _liveTracker.beginCapture();
    final bool streamDuringCapture = _streamDuringCapture;
    final Stopwatch? timer = const bool.fromEnvironment('PHYSICAL_CARD_QA')
        ? (Stopwatch()..start())
        : null;
    bool completed = false;
    try {
      await _discoveryFocus;
      if (timer != null) {
        debugPrint('CAPTURE_TIMING discoveryMs=${timer.elapsedMilliseconds}');
      }
      if (!_usesCamera(controller)) return;
      if (recoveryTarget != null) {
        final LiveScanTrack? current = _availableCaptureTracks
            .where((LiveScanTrack track) => track.id == recoveryTarget.id)
            .firstOrNull;
        final ScanPoint? point = current == null
            ? null
            : _focusCenter(current.corners);
        if (point == null) return;
        if (controller.value.focusPointSupported) {
          final Offset focus = Offset(point.x, point.y);
          await _setFocusPoint(
            controller,
            focus,
            singleShot: !_sweeping,
            expose: false,
          );
          if (!_usesCamera(controller)) return;
          setState(() {
            _focusLocked = false;
          });
          await _waitForFocus(controller, capture: true, sweep: true);
        }
        if (!_usesCamera(controller) ||
            !_availableCaptureTracks.any(
              (LiveScanTrack track) => track.id == recoveryTarget.id,
            )) {
          return;
        }
      }
      final Set<_RawContour> recoveringRaw = <_RawContour>{
        for (final LiveScanTrack track in _availableCaptureTracks)
          if (_recoverableRawOwner(track.corners) case final _RawContour raw)
            raw,
      };
      final List<List<ScanPoint>>? protected = _protectedCaptureRegions(
        recoveringRaw: recoveringRaw,
      );
      if (protected == null) return;
      _pendingExclusions = protected;
      final LiveCaptureSnapshot snapshot = _liveTracker.snapshotCapture(
        targetIds:
            newTracks.isNotEmpty &&
                !_photoCaptureBacklog &&
                _liveTracker.uncapturedTracks.any(
                  (LiveScanTrack track) => track.hasRetainedCapture,
                )
            ? <String>{
                ...newTracks.map((LiveScanTrack track) => track.id),
                ..._liveTracker.uncapturedTracks
                    .where((LiveScanTrack track) => !track.hasRetainedCapture)
                    .map((LiveScanTrack track) => track.id),
              }
            : recoveryTarget != null &&
                  _adaptiveTargetIds.contains(recoveryTarget.id)
            ? <String>{recoveryTarget.id}
            : null,
        currentGeometry: <List<ScanPoint>>[
          ..._focusCandidates.map((LiveCardDetection card) => card.corners),
          ..._liveTracker.tracks.map((LiveScanTrack track) => track.corners),
        ],
        blockedRegions: protected,
      );
      if (const bool.fromEnvironment('PHYSICAL_CARD_QA')) {
        debugPrint(
          'CAPTURE_DIAGNOSTIC snapshot=${snapshot.count} token=$_liveOrientationToken ids=${_liveTracker.tracks.map((LiveScanTrack track) => track.id).join(',')}',
        );
      }
      if (widget.automaticCapture && snapshot.isEmpty) return;
      final _CaptureFeedbackContext feedback = _captureFeedbackContext(
        controller,
        snapshot,
      );
      final List<List<ScanPoint>>? trackedTargets = widget.automaticCapture
          ? List<List<ScanPoint>>.unmodifiable(
              snapshot.crops.map(
                (ScanCrop crop) =>
                    List<ScanPoint>.unmodifiable(crop.sourceCorners),
              ),
            )
          : null;
      final bool stackCallback =
          (widget.multipleCards || widget.automaticCapture) &&
          trackedHandoff != null;
      final bool stack = stackCallback && !_sweeping && recoveryTarget == null;
      final List<ScanPoint> points = stack
          ? _captureFocusPoints(snapshot)
          : <ScanPoint>[];
      if (!streamDuringCapture) _liveDetector.reset();
      if (!streamDuringCapture && controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      final List<String> paths = <String>[];
      _captureSteps = stack ? points.length : 1;
      for (int index = 0; index < _captureSteps; index++) {
        final int started = timer?.elapsedMilliseconds ?? 0;
        if (!_usesCamera(controller)) break;
        if (mounted) {
          setState(() {
            _captureStep = index + 1;
            _capturePhase = _CapturePhase.focusing;
          });
        }
        if (stack && controller.value.focusPointSupported) {
          final ScanPoint point = points[index];
          final Offset focus = Offset(point.x, point.y);
          await _setFocusPoint(
            controller,
            focus,
            singleShot: true,
            expose: false,
          );
          if (!_usesCamera(controller)) break;
          setState(() {
            _focusLocked = false;
          });
          await _waitForFocus(controller, capture: true);
        }
        if (!_usesCamera(controller)) break;
        final int focused = timer?.elapsedMilliseconds ?? 0;
        if (mounted) setState(() => _capturePhase = _CapturePhase.takingPhoto);
        final XFile file = await controller.takePicture();
        if (timer != null) {
          debugPrint(
            'CAPTURE_TIMING step=${index + 1} focusMs=${focused - started} photoMs=${timer.elapsedMilliseconds - focused} focus=${stack ? '${points[index].x},${points[index].y}' : 'current'}',
          );
        }
        paths.add(file.path);
        if (recoveryTarget != null) {
          _adaptiveTargetIds.remove(recoveryTarget.id);
        }
        _pendingCaptureFeedback = feedback;
        _pendingTrackedHandoff = stackCallback ? trackedHandoff : null;
        _pendingSingleHandoff = singleHandoff;
        _pendingTrackedTargets = trackedTargets;
        _pendingRawRecoveries = recoveringRaw
            .where(
              (_RawContour raw) => snapshot.crops.any(
                (ScanCrop crop) => _rawOwnsRegion(raw, crop.sourceCorners),
              ),
            )
            .toList();
        _pendingPhoto = paths.first;
        _pendingStack = stackCallback ? List<String>.of(paths) : null;
        _pendingCaptureSnapshot = snapshot;
      }
      completed = paths.isNotEmpty;
      if (mounted && completed) {
        if (singleHandoff == null && !stackCallback) {
          Navigator.of(context).pop(paths.first);
        } else {
          if (widget.continuous && _usesCamera(controller)) {
            await _startLive(controller);
          }
          await _savePending();
        }
      }
    } catch (error) {
      _automaticRetryAt = DateTime.now().add(const Duration(seconds: 4));
      if (widget.automaticCapture &&
          _pendingPhoto != null &&
          (_pendingSingleHandoff != null || _pendingTrackedHandoff != null)) {
        if (widget.continuous && _usesCamera(controller)) {
          await _startLive(controller);
        }
        await _savePending();
        completed = _pendingPhoto == null;
      }
      if (mounted) {
        setState(() {
          if (!completed && _pendingPhoto == null) {
            _error = 'Capture failed';
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _capturing = false;
          _adaptiveCapturing = false;
          _capturePhase = _CapturePhase.idle;
        });
      }
      try {
        if (_usesCamera(controller) &&
            (!completed ||
                (widget.onCaptured != null ||
                        widget.onFocusStackCaptured != null) &&
                    (widget.continuous || _pendingPhoto != null))) {
          await _startLive(controller);
        }
      } finally {
        _liveTracker.endCapture(
          capture,
          resumeTracking:
              !streamDuringCapture &&
              _usesCamera(controller) &&
              controller.value.isStreamingImages,
        );
      }
    }
  }

  String get _captureStatus => switch (_capturePhase) {
    _CapturePhase.idle => 'Capture photo',
    _CapturePhase.focusing =>
      _captureStep == 0 ? 'Preparing…' : 'Focus $_captureStep/$_captureSteps',
    _CapturePhase.takingPhoto => 'Photo $_captureStep/$_captureSteps',
    _CapturePhase.saving => 'Saving…',
    _CapturePhase.discarding => 'Discarding…',
  };

  ScanPoint? _focusCenter(List<ScanPoint> corners) {
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
      return null;
    }
    return ScanPoint(
      corners.fold<double>(0, (double sum, ScanPoint point) => sum + point.x) /
          4,
      corners.fold<double>(0, (double sum, ScanPoint point) => sum + point.y) /
          4,
    );
  }

  double _focusDistanceSquared(ScanPoint a, ScanPoint b) =>
      (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y);

  List<ScanPoint> _captureFocusPoints(LiveCaptureSnapshot snapshot) {
    if (widget.automaticCapture) {
      return planDetectedScanFocusPoints(
        regions: <List<ScanPoint>>[
          ...snapshot.crops.map((ScanCrop crop) => crop.sourceCorners),
          ..._liveTracker.recentFocusCrops.map(
            (ScanCrop crop) => crop.sourceCorners,
          ),
          ..._focusMemory.targets,
          ..._focusCandidates.map((LiveCardDetection card) => card.corners),
        ].where((List<ScanPoint> corners) => !_liveTracker.isSaved(corners)),
      );
    }
    final List<ScanPoint> fallback = planScanFocusPoints(
      candidates: _focusCandidates
          .where(
            (LiveCardDetection card) => !_liveTracker.isSaved(card.corners),
          )
          .toList(),
      trackedCorners: _focusMemory.targets.where(
        (List<ScanPoint> corners) => !_liveTracker.isSaved(corners),
      ),
    );
    final List<ScanPoint> proven = <ScanPoint>[
      ...snapshot.crops
          .map((ScanCrop crop) => _focusCenter(crop.sourceCorners))
          .whereType<ScanPoint>(),
    ];
    final List<ScanPoint> points = <ScanPoint>[];
    for (final ScanPoint center in proven) {
      if (points.every(
        (ScanPoint point) => _focusDistanceSquared(point, center) >= .0036,
      )) {
        points.add(center);
      }
      if (points.length == 5) break;
    }
    if (points.length >= 3) return List<ScanPoint>.unmodifiable(points);
    for (final ScanPoint center
        in _liveTracker.recentFocusCrops
            .map((ScanCrop crop) => _focusCenter(crop.sourceCorners))
            .whereType<ScanPoint>()) {
      if (points.every(
        (ScanPoint point) => _focusDistanceSquared(point, center) >= .0036,
      )) {
        points.add(center);
      }
      if (points.length == 5) break;
    }
    if (points.length >= 3) return List<ScanPoint>.unmodifiable(points);
    for (final ScanPoint center in fallback) {
      if (points.every(
        (ScanPoint point) => _focusDistanceSquared(point, center) >= .0036,
      )) {
        points.add(center);
      }
      if (points.length == 5) break;
    }
    return List<ScanPoint>.unmodifiable(points);
  }

  Future<void> _waitForFocus(
    CameraController controller, {
    bool capture = false,
    bool sweep = false,
  }) async {
    final bool nativeFocus =
        (capture || sweep) && defaultTargetPlatform == TargetPlatform.iOS;
    await Future<void>.delayed(Duration(milliseconds: nativeFocus ? 100 : 500));
    final DateTime deadline = DateTime.now().add(
      Duration(milliseconds: sweep ? 650 : 3000),
    );
    double? previous;
    int stable = 0;
    while (_usesCamera(controller) && DateTime.now().isBefore(deadline)) {
      try {
        final Map<Object?, Object?>? status = await NativeCardRecognizer.channel
            .invokeMethod<Map<Object?, Object?>>(
              'cameraFocusStatus',
              <String, String>{'cameraName': controller.description.name},
            )
            .timeout(const Duration(milliseconds: 400));
        if (status == null) break;
        final double? position = (status['lensPosition'] as num?)?.toDouble();
        final bool settled =
            status['isAdjustingFocus'] == false &&
            status['focusMode'] != 1 &&
            (sweep || status['isAdjustingExposure'] == false) &&
            position != null &&
            previous != null &&
            (position - previous).abs() < .003;
        stable = settled ? stable + 1 : 0;
        previous = position;
        if (stable >= 3) return;
      } catch (_) {
        break;
      }
      await Future<void>.delayed(
        Duration(milliseconds: nativeFocus ? 100 : 200),
      );
    }
    if (!sweep && _usesCamera(controller)) {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
    }
  }

  Future<void> _setFocusPoint(
    CameraController controller,
    Offset point, {
    bool singleShot = false,
    bool expose = true,
  }) async {
    _focusGeneration++;
    _rawSettledFocus = null;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final bool? applied = await NativeCardRecognizer.channel
          .invokeMethod<bool>('cameraFocusAtPoint', <String, Object>{
            'cameraName': controller.description.name,
            'previewOrientation': _orientation(controller).name,
            'x': point.dx,
            'y': point.dy,
            'singleShot': singleShot,
            'adjustExposure': expose && controller.value.exposurePointSupported,
          });
      if (applied != true) {
        throw CameraException('focus_unavailable', 'Focus could not change.');
      }
      return;
    }
    await controller.setFocusMode(
      singleShot ? FocusMode.locked : FocusMode.auto,
    );
    await controller.setFocusPoint(point);
    if (expose && controller.value.exposurePointSupported) {
      await controller.setExposurePoint(point);
    }
  }

  Future<void> _savePending() async {
    final String? path = _pendingPhoto;
    if (path == null) return;
    if (mounted) setState(() => _capturePhase = _CapturePhase.saving);
    bool saved = false;
    final List<List<ScanPoint>>? rawTargets = _pendingUnidentifiedContours;
    final _CaptureFeedbackContext? feedback = _pendingCaptureFeedback;
    if (rawTargets != null &&
        _camera != null &&
        _pendingRawOrientationToken ==
            NativeLiveCardDetector.orientationTokenFor(
              camera: _camera!.description,
              orientation: _orientation(_camera!),
            )) {
      _pendingRawOrientationChanged = false;
    }
    try {
      saved = _pendingRawOrientationChanged
          ? false
          : rawTargets != null
          ? await _pendingRawHandoff!(
              _pendingStack!,
              _pendingExclusions,
              _pendingCaptureSnapshot!.captureId,
              rawTargets,
            )
          : _pendingStack != null
          ? await _pendingTrackedHandoff!(
              _pendingStack!,
              _pendingExclusions,
              _pendingCaptureSnapshot!.captureId,
              _pendingTrackedTargets,
            )
          : await _pendingSingleHandoff!(path, _pendingExclusions);
    } catch (_) {
      saved = false;
    }
    if (!mounted) return;
    final bool ownsTrackedCapture =
        saved &&
        rawTargets == null &&
        feedback != null &&
        feedback.generation == _generation &&
        identical(feedback.session, widget.session) &&
        identical(feedback.camera, _camera) &&
        _usesCamera(feedback.camera) &&
        feedback.orientation ==
            NativeLiveCardDetector.orientationTokenFor(
              camera: feedback.camera.description,
              orientation: _orientation(feedback.camera),
            );
    if (ownsTrackedCapture && _pendingCaptureSnapshot != null) {
      final int marked = _liveTracker.markCaptured(_pendingCaptureSnapshot!);
      if (const bool.fromEnvironment('PHYSICAL_CARD_QA')) {
        debugPrint(
          'CAPTURE_DIAGNOSTIC ack=${_pendingCaptureSnapshot!.count} marked=$marked token=$_liveOrientationToken ids=${_liveTracker.tracks.map((LiveScanTrack track) => '${track.id}:${track.captured}').join(',')}',
        );
      }
      for (final _RawContour raw in _pendingRawRecoveries) {
        _rawPhotoContours.remove(raw);
        _rawFeedbackOrigins.remove(raw.receiptId);
      }
      _focusMemory.clear();
    }
    final bool ownsRawCapture =
        saved &&
        rawTargets != null &&
        _pendingRawGeneration == _generation &&
        identical(_pendingRawSession, widget.session) &&
        identical(_pendingRawCamera, _camera) &&
        _camera != null &&
        _pendingRawOrientationToken ==
            NativeLiveCardDetector.orientationTokenFor(
              camera: _camera!.description,
              orientation: _orientation(_camera!),
            );
    if (ownsRawCapture && _pendingCaptureSnapshot != null) {
      _liveTracker.markCaptured(_pendingCaptureSnapshot!);
    }
    if (saved &&
        feedback != null &&
        (ownsTrackedCapture || ownsRawCapture) &&
        _validCaptureFeedback(feedback)) {
      final List<ScanCrop> capturedCrops = feedback.capture.crops;
      final List<({String receiptId, String trackId})> trackedReceipts =
          feedback.capture.photoReceipts;
      _savedCaptureQuality[feedback.capture.captureId] = _SavedCaptureQuality(
        origin: feedback,
        paths: List<String>.unmodifiable(_pendingStack ?? <String>[path]),
        targets:
            <({String receiptId, String? trackId, List<ScanPoint> corners})>[
              if (rawTargets != null)
                for (int index = 0; index < rawTargets.length; index++)
                  (
                    receiptId: 'raw_${feedback.capture.captureId}_$index',
                    trackId: null,
                    corners: rawTargets[index],
                  )
              else
                for (int index = 0; index < trackedReceipts.length; index++)
                  (
                    receiptId: trackedReceipts[index].receiptId,
                    trackId: trackedReceipts[index].trackId,
                    corners: capturedCrops[index].sourceCorners,
                  ),
            ],
      );
    }
    setState(() {
      if (saved) {
        if (ownsTrackedCapture || ownsRawCapture) {
          _captured++;
          _sceneSaved = true;
          _savedStack = _pendingStack ?? <String>[path];
          _savedCaptureSnapshot = ownsTrackedCapture
              ? _pendingCaptureSnapshot
              : null;
        }
        if (ownsRawCapture) {
          final List<List<ScanPoint>> savedRawTargets = rawTargets;
          _rawPhotoContours.addAll(<_RawContour>[
            for (int index = 0; index < savedRawTargets.length; index++)
              _RawContour(
                savedRawTargets[index],
                receiptId: 'raw_${_pendingCaptureSnapshot!.captureId}_$index',
                capture: _pendingCaptureSnapshot,
                paths: List<String>.unmodifiable(_savedStack!),
                captureAppearance: _pendingRawAppearances?[index],
              ),
          ]);
        }
        if (widget.automaticCapture &&
            ownsTrackedCapture &&
            _pendingCaptureSnapshot != null) {
          if (_savedCaptures.length == 8) {
            final ScanSession? session = widget.session;
            final int completed = _savedCaptures.indexWhere(
              (({List<String> paths, LiveCaptureSnapshot snapshot}) receipt) =>
                  (session?.captureReadComplete(receipt.paths) ?? false) ||
                  receipt.snapshot.identifiedCrops.length ==
                      receipt.snapshot.count,
            );
            if (completed >= 0) _savedCaptures.removeAt(completed);
          }
          _savedCaptures.add((
            paths: List<String>.unmodifiable(_savedStack!),
            snapshot: _pendingCaptureSnapshot!,
          ));
        }
        _pendingPhoto = null;
        _pendingStack = null;
        _pendingCaptureSnapshot = null;
        _pendingCaptureFeedback = null;
        _pendingUnidentifiedContours = null;
        _pendingRawOrientationChanged = false;
        _pendingRawGeneration = null;
        _pendingRawOrientationToken = null;
        _pendingRawHandoff = null;
        _pendingTrackedHandoff = null;
        _pendingSingleHandoff = null;
        _pendingTrackedTargets = null;
        _pendingRawRecoveries = const <_RawContour>[];
        _pendingRawSession = null;
        _pendingRawCamera = null;
        _pendingRawAppearances = null;
        _pendingExclusions = const <List<ScanPoint>>[];
        _error = null;
      } else {
        _error = _pendingRawOrientationChanged
            ? 'Orientation changed. Restore to save, or discard.'
            : 'Save failed. Free storage, retry or discard.';
      }
    });
    if (saved) _recognitionChanged();
    if (saved && !widget.continuous) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _retrySaving() => _trackCaptureWork(_retryPendingSave);

  Future<void> _retryPendingSave() async {
    if (_clearingCaptures || _capturing || _pendingPhoto == null) return;
    setState(() => _capturing = true);
    final int capture = _liveTracker.beginCapture(resume: true);
    try {
      await _savePending();
    } finally {
      if (mounted) {
        setState(() {
          _capturing = false;
          _capturePhase = _CapturePhase.idle;
        });
      }
      _liveTracker.endCapture(capture, resumeTracking: false);
    }
  }

  Future<void> _discardPending() async {
    final String? path = _pendingPhoto;
    if (_clearingCaptures || _capturing || path == null) return;
    final bool? discard = await DialogConfirm(
      title: 'Discard unsaved photo?',
      description: 'Deletes this unsaved photo. Saved batch photos stay.',
      confirmText: 'Discard photo',
      destructive: true,
      onConfirm: () {},
    ).open<bool>(context);
    if (discard != true ||
        !mounted ||
        _clearingCaptures ||
        _pendingPhoto != path) {
      return;
    }
    setState(() {
      _capturing = true;
      _capturePhase = _CapturePhase.discarding;
    });
    try {
      for (final String pending in _pendingStack ?? <String>[path]) {
        final File original = File(pending);
        if (await original.exists()) await original.delete();
      }
      if (mounted) {
        setState(() {
          _pendingPhoto = null;
          _pendingStack = null;
          _pendingCaptureSnapshot = null;
          _pendingCaptureFeedback = null;
          _pendingUnidentifiedContours = null;
          _pendingRawOrientationChanged = false;
          _pendingRawGeneration = null;
          _pendingRawOrientationToken = null;
          _pendingRawHandoff = null;
          _pendingTrackedHandoff = null;
          _pendingSingleHandoff = null;
          _pendingTrackedTargets = null;
          _pendingRawRecoveries = const <_RawContour>[];
          _pendingRawSession = null;
          _pendingRawCamera = null;
          _pendingRawAppearances = null;
          _pendingExclusions = const <List<ScanPoint>>[];
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Discard failed');
      }
    } finally {
      if (mounted) {
        setState(() {
          _capturing = false;
          _capturePhase = _CapturePhase.idle;
        });
      }
    }
  }

  Future<void> _toggleTorch() async {
    final CameraController? controller = _camera;
    if (_clearingCaptures ||
        _waitingRawFocus ||
        controller == null ||
        _capturing) {
      return;
    }
    final bool torch = !_torch;
    try {
      await controller.setFlashMode(torch ? FlashMode.torch : FlashMode.off);
      if (_usesCamera(controller)) setState(() => _torch = torch);
    } catch (_) {
      if (_usesCamera(controller)) {
        setState(() {
          _torchUnavailable = true;
          _error = 'Torch unavailable';
        });
      }
    }
  }

  Future<void> _focus(
    TapDownDetails details,
    CapturePreviewTransform transform,
  ) async {
    final CameraController? controller = _camera;
    if (_clearingCaptures ||
        _waitingRawFocus ||
        controller == null ||
        _capturing) {
      return;
    }
    final Offset point = transform.normalizedTap(details.localPosition);
    _manualFocusAt = DateTime.now();
    await _discoveryFocus;
    if (_clearingCaptures ||
        _waitingRawFocus ||
        !_usesCamera(controller) ||
        _capturing) {
      return;
    }
    try {
      await _setFocusPoint(controller, point);
      if (!_usesCamera(controller)) return;
      setState(() {
        _focusPoint = point;
        _focusLocked = false;
      });
      _focusTimer?.cancel();
      _focusTimer = Timer(const Duration(seconds: 2), () {
        if (_usesCamera(controller)) setState(() => _focusPoint = null);
      });
    } catch (_) {
      if (_usesCamera(controller)) {
        setState(() => _error = 'Tap focus unavailable');
      }
    }
  }

  Future<void> _setZoom(double value) async {
    final CameraController? controller = _camera;
    if (_clearingCaptures ||
        _waitingRawFocus ||
        controller == null ||
        _capturing ||
        _startingStream) {
      return;
    }
    try {
      await controller.setZoomLevel(value);
      if (_usesCamera(controller) && value != _appliedZoom) {
        _appliedZoom = value;
        _clearTracking();
        setState(() {});
      }
    } catch (_) {
      if (_usesCamera(controller)) {
        setState(() => _error = 'Zoom failed');
      }
    }
  }

  Future<void> _setExposure(double value) async {
    final CameraController? controller = _camera;
    if (_clearingCaptures ||
        _waitingRawFocus ||
        controller == null ||
        _capturing ||
        _startingStream) {
      return;
    }
    _manualExposurePreview(value);
    final int revision = _manualExposureRevision;
    try {
      await _queueExposure(
        controller,
        value,
        automatic: false,
      ).timeout(const Duration(milliseconds: 400));
    } catch (_) {
      if (_usesCamera(controller) && revision == _manualExposureRevision) {
        setState(() {
          _exposure = _appliedExposure;
          _manualExposureValue = _appliedExposure;
          _error = 'Exposure failed';
        });
      }
    }
  }

  void _adjustZoom(double value) {
    if (_clearingCaptures ||
        _waitingRawFocus ||
        _camera == null ||
        _capturing ||
        _startingStream) {
      return;
    }
    final double next = value.clamp(_minZoom, _maxZoom);
    if (next == _zoom) {
      return;
    }
    setState(() => _zoom = next);
    unawaited(_setZoom(next));
  }

  void _adjustExposure(double value) {
    if (_clearingCaptures ||
        _waitingRawFocus ||
        _camera == null ||
        _capturing ||
        _startingStream) {
      return;
    }
    final double next = value.clamp(_minExposure, _maxExposure);
    if (next == _exposure) {
      return;
    }
    _manualExposurePreview(next);
    unawaited(_setExposure(next));
  }

  Future<void> _toggleFocusLock() async {
    final CameraController? controller = _camera;
    if (_clearingCaptures ||
        _waitingRawFocus ||
        controller == null ||
        _capturing) {
      return;
    }
    final bool locked = !_focusLocked;
    try {
      await controller.setFocusMode(locked ? FocusMode.locked : FocusMode.auto);
      if (_usesCamera(controller)) {
        setState(() => _focusLocked = locked);
        _rawFocusReadinessRequired = false;
        _rawSettledFocus = null;
        _focusGeneration++;
      }
    } catch (_) {
      if (_usesCamera(controller)) {
        setState(() => _error = 'Focus lock unavailable');
      }
    }
  }

  bool _usesCamera(CameraController controller) =>
      mounted && identical(_camera, controller);

  String _lensLabel(CameraDescription camera) {
    final String label = switch (camera.lensType) {
      CameraLensType.wide => 'Wide',
      CameraLensType.ultraWide => 'Ultra-wide',
      CameraLensType.telephoto => 'Telephoto',
      CameraLensType.unknown => 'Camera',
    };
    final int matching = _rearCameras
        .where((CameraDescription item) => item.lensType == camera.lensType)
        .length;
    return matching > 1 || camera.lensType == CameraLensType.unknown
        ? '$label ${_rearCameras.indexOf(camera) + 1}'
        : label;
  }

  bool get _hasCaptureOwnership =>
      _pendingPhoto != null ||
      _savedCaptures.isNotEmpty ||
      _savedCaptureSnapshot != null ||
      _liveTracker.savedFootprints.isNotEmpty;

  void _selectLens(String? name, {bool automatic = false}) {
    if (_clearingCaptures ||
        (_waitingRawFocus && !automatic) ||
        name == null ||
        name == _selectedCameraName ||
        _capturing) {
      return;
    }
    if (automatic && _hasCaptureOwnership) return;
    if (!automatic) _lensChosenManually = true;
    _selectedCameraName = name;
    _focusPoint = null;
    _focusTimer?.cancel();
    _scheduleCamera(true);
  }

  Widget _lensControls(bool ready) => Semantics(
    label: 'Camera lens',
    child: Select<String>(
      key: const ValueKey<String>('camera-lens-selector'),
      value: _selectedCameraName,
      enabled: ready,
      onChanged: ready ? _selectLens : null,
      constraints: const BoxConstraints(minHeight: 44),
      popupWidthConstraint: PopoverConstraint.flexible,
      popupConstraints: BoxConstraints(
        minWidth: 200,
        maxWidth: MediaQuery.sizeOf(context).width - 24,
        maxHeight: 240,
      ),
      itemBuilder: (BuildContext context, String name) => Text(
        _lensLabel(
          _rearCameras.firstWhere(
            (CameraDescription camera) => camera.name == name,
          ),
        ),
      ),
      popup: SelectPopup<String>(
        items: SelectItemList(
          children: <Widget>[
            for (final CameraDescription camera in _rearCameras)
              SelectItemButton<String>(
                value: camera.name,
                child: Text(_lensLabel(camera)),
              ),
          ],
        ),
      ).call,
    ),
  );

  Widget _controlIcon({
    required String key,
    required String label,
    required IconData icon,
    required bool active,
    required VoidCallback? onPressed,
  }) => Semantics(
    container: true,
    label: label,
    button: true,
    toggled: active,
    enabled: onPressed != null,
    child: Tooltip(
      tooltip: (BuildContext context) => TooltipContainer(child: Text(label)),
      child: SizedBox(
        width: 44,
        height: 44,
        child: IconButton(
          key: ValueKey<String>(key),
          icon: Icon(icon),
          variance: active ? ButtonVariance.primary : ButtonVariance.outline,
          disableTransition: MediaQuery.disableAnimationsOf(context),
          onPressed: onPressed,
        ),
      ),
    ),
  );

  Widget _cameraControls(bool ready) => ComponentTheme<SliderTheme>(
    data: SliderTheme(thumbBorderColor: Theme.of(context).colorScheme.primary),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 190),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_maxZoom > _minZoom) ...<Widget>[
                Text('Zoom ${_zoom.toStringAsFixed(1)}×'),
                Semantics(
                  label: 'Zoom',
                  slider: true,
                  enabled: ready,
                  excludeSemantics: true,
                  value: '${_zoom.toStringAsFixed(1)}×',
                  increasedValue:
                      '${(_zoom + .1).clamp(_minZoom, _maxZoom).toStringAsFixed(1)}×',
                  decreasedValue:
                      '${(_zoom - .1).clamp(_minZoom, _maxZoom).toStringAsFixed(1)}×',
                  onIncrease: ready && _zoom < _maxZoom
                      ? () => _adjustZoom(_zoom + .1)
                      : null,
                  onDecrease: ready && _zoom > _minZoom
                      ? () => _adjustZoom(_zoom - .1)
                      : null,
                  child: Slider(
                    enabled: ready,
                    value: SliderValue.single(_zoom),
                    min: _minZoom,
                    max: _maxZoom,
                    onChanged: ready
                        ? (SliderValue value) =>
                              setState(() => _zoom = value.value)
                        : null,
                    onChangeEnd: ready
                        ? (SliderValue value) => _setZoom(value.value)
                        : null,
                  ),
                ),
              ],
              if (_maxExposure > _minExposure) ...<Widget>[
                Text('Exposure ${_exposure.toStringAsFixed(1)} EV'),
                Semantics(
                  label: 'Exposure',
                  slider: true,
                  enabled: ready,
                  excludeSemantics: true,
                  value: '${_exposure.toStringAsFixed(1)} EV',
                  increasedValue:
                      '${(_exposure + (_exposureStep > 0 ? _exposureStep : .1)).clamp(_minExposure, _maxExposure).toStringAsFixed(1)} EV',
                  decreasedValue:
                      '${(_exposure - (_exposureStep > 0 ? _exposureStep : .1)).clamp(_minExposure, _maxExposure).toStringAsFixed(1)} EV',
                  onIncrease: ready && _exposure < _maxExposure
                      ? () => _adjustExposure(
                          _exposure + (_exposureStep > 0 ? _exposureStep : .1),
                        )
                      : null,
                  onDecrease: ready && _exposure > _minExposure
                      ? () => _adjustExposure(
                          _exposure - (_exposureStep > 0 ? _exposureStep : .1),
                        )
                      : null,
                  child: Slider(
                    enabled: ready,
                    value: SliderValue.single(_exposure),
                    min: _minExposure,
                    max: _maxExposure,
                    divisions: _exposureStep > 0
                        ? ((_maxExposure - _minExposure) / _exposureStep)
                              .round()
                              .clamp(1, 1000)
                        : null,
                    onChanged: ready
                        ? (SliderValue value) =>
                              _manualExposurePreview(value.value)
                        : null,
                    onChangeEnd: ready
                        ? (SliderValue value) => _setExposure(value.value)
                        : null,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Size _previewSize(CameraController controller) {
    final Size size = controller.value.previewSize!;
    final DeviceOrientation orientation = _orientation(controller);
    final bool landscape =
        orientation == DeviceOrientation.landscapeLeft ||
        orientation == DeviceOrientation.landscapeRight;
    return landscape ? size : Size(size.height, size.width);
  }

  Widget _preview(CameraController? controller) {
    if (!widget.active) {
      return const Center(child: Text('Paused'));
    }
    if (controller == null) {
      return Center(
        child: _error == null
            ? const CollectorLoading(label: 'Opening camera…')
            : SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    SecondaryButton(
                      onPressed: _clearingCaptures
                          ? null
                          : () => _scheduleCamera(true),
                      child: const Text('Retry camera'),
                    ),
                  ],
                ),
              ),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size source = _liveFrameSize ?? _previewSize(controller);
        final CapturePreviewTransform transform = CapturePreviewTransform(
          sourceSize: source,
          viewportSize: constraints.biggest,
          fit: BoxFit.contain,
        );
        final Offset? focus = _focusPoint == null
            ? null
            : transform.project(_focusPoint!);
        final String? tracking =
            _trackingError ??
            (!_rectanglesSupported
                ? (widget.automaticCapture
                      ? 'Outlines unavailable'
                      : 'Outlines unavailable')
                : _liveTracker.tracks.isEmpty
                ? (widget.automaticCapture
                      ? (_pendingSavedFocus.isNotEmpty ? 'Focusing…' : null)
                      : '')
                : null);
        return ClipRect(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: _clearingCaptures
                ? null
                : (TapDownDetails tap) => _focus(tap, transform),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ColoredBox(
                  color: Colors.black,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: source.width,
                      height: source.height,
                      child: CameraPreview(controller),
                    ),
                  ),
                ),
                LiveCaptureOverlay(
                  savingTrackIds: _pendingPhoto == null
                      ? <String>{
                          for (final _SavedCaptureQuality quality
                              in _savedCaptureQuality.values)
                            for (final ({
                                  String receiptId,
                                  String? trackId,
                                  List<ScanPoint> corners,
                                })
                                target
                                in quality.targets)
                              if (target.trackId != null &&
                                  !quality.qualified.contains(target.receiptId))
                                target.trackId!,
                        }
                      : _pendingCaptureSnapshot?.photoReceipts
                                .map(
                                  (
                                    ({String receiptId, String trackId})
                                    receipt,
                                  ) => receipt.trackId,
                                )
                                .toSet() ??
                            const <String>{},
                  safeToMoveTrackIds: _resumeOwnershipPending
                      ? const <String>{}
                      : _captureFeedback.safeTrackIds,
                  safeToMovePhotoRegions: _rawPhotoContours
                      .where(
                        (_RawContour raw) =>
                            raw.safeForCaptureFeedback &&
                            raw.receiptId != null &&
                            _captureFeedback.containsReceipt(raw.receiptId!) &&
                            _rawFeedbackOrigins[raw.receiptId] != null &&
                            _validCaptureFeedback(
                              _rawFeedbackOrigins[raw.receiptId]!,
                            ),
                      )
                      .map((_RawContour raw) => raw.corners)
                      .toList(),
                  tracks: _liveTracker.tracks
                      .where(
                        (LiveScanTrack track) => !_rawPhotoContours.any(
                          (_RawContour contour) =>
                              _sameRawRegion(contour.corners, track.corners),
                        ),
                      )
                      .toList(),
                  observedPhotoRegions: _rawObservations
                      .where(
                        (_RawContour contour) =>
                            !_rawPhotoContours.any(
                              (_RawContour retained) => _sameRawRegion(
                                retained.corners,
                                contour.corners,
                              ),
                            ) &&
                            !_liveTracker.tracks.any(
                              (LiveScanTrack track) =>
                                  track.hasCardEvidence &&
                                  _sameRawRegion(
                                    track.corners,
                                    contour.corners,
                                  ),
                            ),
                      )
                      .map((_RawContour contour) => contour.corners)
                      .toList(),
                  retainedPhotoRegions: <List<ScanPoint>>[
                    ..._rawPhotoContours
                        .where((_RawContour contour) => contour.visible)
                        .map((_RawContour contour) => contour.corners),
                    ...?_pendingUnidentifiedContours,
                  ],
                  transform: transform,
                ),
                if (focus != null)
                  Positioned(
                    left: (focus.dx - 24).clamp(
                      0,
                      (constraints.maxWidth - 48).clamp(0, double.infinity),
                    ),
                    top: (focus.dy - 24).clamp(
                      0,
                      (constraints.maxHeight - 48).clamp(0, double.infinity),
                    ),
                    child: IgnorePointer(
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 4),
                          borderRadius: BorderRadius.zero,
                        ),
                        foregroundDecoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 2),
                          borderRadius: BorderRadius.zero,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: IgnorePointer(
                    child: AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 220),
                      child: tracking == null
                          ? const SizedBox.shrink()
                          : DecoratedBox(
                              key: ValueKey<String>(tracking),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: .92),
                                borderRadius: BorderRadius.zero,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                child: Text(
                                  tracking,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _captureControls(CameraController? controller) {
    final bool ready =
        controller != null &&
        !_capturing &&
        !_waitingRawFocus &&
        !_startingStream &&
        !_clearingCaptures;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (!widget.automaticCapture || _controls)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                if (_rearCameras.length > 1) _lensControls(ready),
                _controlIcon(
                  key: 'camera-torch',
                  label: _torch ? 'Turn torch off' : 'Turn torch on',
                  icon: _torch ? Icons.lightning : Icons.lightning_slash,
                  active: _torch,
                  onPressed: ready && !_torchUnavailable ? _toggleTorch : null,
                ),
                _controlIcon(
                  key: 'camera-focus-lock',
                  label: _focusLocked ? 'Unlock focus' : 'Lock focus',
                  icon: _focusLocked ? Icons.lock : Icons.crosshair,
                  active: _focusLocked,
                  onPressed: ready ? _toggleFocusLock : null,
                ),
                if (!widget.automaticCapture)
                  _controlIcon(
                    key: 'camera-adjustments',
                    label: _controls
                        ? 'Close adjustments'
                        : 'Adjust zoom and exposure',
                    icon: Icons.sliders,
                    active: _controls,
                    onPressed: ready
                        ? () => setState(() => _controls = !_controls)
                        : null,
                  ),
              ],
            ),
          ),
        if (_controls && controller != null) _cameraControls(ready),
        if (!widget.automaticCapture &&
            _controls &&
            widget.onClearCaptures != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: SizedBox(
              width: double.infinity,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: SecondaryButton(
                  key: const ValueKey<String>('camera-clear-captures'),
                  onPressed: _clearingCaptures ? null : _clearCaptures,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 24),
                    child: Center(
                      child: Text(
                        _clearingCaptures ? 'Discarding' : 'Discard remaining',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (_error != null && controller != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Semantics(liveRegion: true, child: Text(_error!)),
          ),
        if (_pendingPhoto != null && (!widget.automaticCapture || !_capturing))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Button(
              style: const ButtonStyle.destructive()
                  .withBackgroundColor(
                    color: Theme.of(context).colorScheme.destructive,
                    hoverColor: Theme.of(context).colorScheme.destructive,
                    disabledColor: Theme.of(context)
                        .colorScheme
                        .primaryForeground,
                  )
                  .withForegroundColor(
                    color: Theme.of(context).colorScheme.primaryForeground,
                    hoverColor: Theme.of(context).colorScheme.primaryForeground,
                    disabledColor: Theme.of(context)
                        .colorScheme
                        .mutedForeground,
                  ),
              onPressed: _clearingCaptures || _capturing
                  ? null
                  : _discardPending,
              child: const Text('Discard unsaved photo'),
            ),
          ),
      ],
    );
  }

  void _openReview() {
    final int count = widget.session?.items.length ?? _captured;
    final int photos =
        (widget.session?.pendingPhotoCaptures ?? 0) +
        (widget.session?.pendingDetailSources ?? 0);
    if (_clearingCaptures ||
        (widget.automaticCapture && count == 0 && photos == 0) ||
        _capturing ||
        _waitingRawFocus ||
        _pendingPhoto != null) {
      return;
    }
    _resetCaptureFeedback();
    unawaited(Navigator.of(context).maybePop<bool>(true));
  }

  Widget _captureActions(CameraController? controller) {
    if (widget.automaticCapture) return _automaticActions(controller);
    final bool capturedScene = widget.multipleCards && _sceneSaved;
    final bool ready =
        controller != null && !_capturing && !_startingStream && !capturedScene;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool stacked =
              constraints.maxWidth < 320 ||
              MediaQuery.textScalerOf(context).scale(14) > 22;
          final List<Widget> actions = <Widget>[
            if ((widget.onCaptured != null ||
                widget.onFocusStackCaptured != null))
              SecondaryButton(
                density: const ButtonDensity(_actionPadding),
                onPressed: _capturing || _pendingPhoto != null
                    ? null
                    : _openReview,
                child: const Text('Review batch', textAlign: TextAlign.center),
              ),
            PrimaryButton(
              density: const ButtonDensity(_actionPadding),
              onPressed: ready
                  ? (_pendingPhoto == null ? _capture : _retrySaving)
                  : null,
              child: Text(
                _capturing
                    ? _captureStatus
                    : _pendingPhoto == null
                    ? (capturedScene ? 'Captured' : 'Capture photo')
                    : 'Retry save',
                textAlign: TextAlign.center,
              ),
            ),
            if (capturedScene)
              Semantics(
                label: 'Clear markers',
                child: SecondaryButton(
                  density: const ButtonDensity(_actionPadding),
                  onPressed: _newScene,
                  child: const Text(
                    'Clear markers',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ];
          if (stacked) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_captured > 0)
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      '$_captured ${widget.multipleCards ? 'scenes' : 'photos'}',
                      key: const ValueKey<String>('camera-capture-count'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                for (
                  int index = 0;
                  index < actions.length;
                  index++
                ) ...<Widget>[
                  if (index > 0) const SizedBox(height: 8),
                  actions[index],
                ],
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child:
                    widget.onCaptured != null ||
                        widget.onFocusStackCaptured != null
                    ? GhostButton(
                        onPressed: _capturing || _pendingPhoto != null
                            ? null
                            : _openReview,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const Icon(Icons.stack, size: 24),
                            const SizedBox(height: 4),
                            const Text(
                              'Review batch',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )
                    : const SizedBox(),
              ),
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.foreground,
                    width: 2,
                  ),
                ),
                child: SizedBox(
                  width: 94,
                  height: 94,
                  child: PrimaryButton(
                    key: const ValueKey<String>('camera-shutter'),
                    shape: ButtonShape.circle,
                    density: const ButtonDensity(_actionPadding),
                    onPressed: ready
                        ? (_pendingPhoto == null ? _capture : _retrySaving)
                        : null,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          _capturePhase == _CapturePhase.focusing
                              ? Icons.crosshair
                              : Icons.camera,
                          size: 28,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _capturing
                              ? _captureStatus
                              : _pendingPhoto == null
                              ? (capturedScene ? 'Captured' : 'Capture photo')
                              : 'Retry save',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        '$_captured',
                        key: const ValueKey<String>('camera-capture-count'),
                        style: Theme.of(context).typography.h3,
                      ),
                      Text(widget.multipleCards ? 'scenes' : 'photos'),
                      if (capturedScene)
                        Semantics(
                          label: 'Clear markers',
                          child: TextButton(
                            onPressed: _newScene,
                            child: const Text(
                              'Clear markers',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _automaticActions(CameraController? controller) {
    final bool busy =
        _clearingCaptures ||
        _waitingRawFocus ||
        _capturing ||
        _startingStream ||
        _automaticExposureBusy;
    final ScanSession? session = widget.session;
    final int count = session?.items.length ?? _captured;
    final int photos =
        (session?.pendingPhotoCaptures ?? 0) +
        (session?.pendingDetailSources ?? 0);
    final bool captured =
        !_clearingCaptures &&
        !_resumeOwnershipPending &&
        !_automaticPaused &&
        !_controls &&
        widget.active &&
        _error == null &&
        session?.storageError == null &&
        _captureFeedback.cueVisible(
          widget.feedbackClock?.call() ?? DateTime.now(),
        );
    final String? status = _clearingCaptures
        ? 'Discarding'
        : captured
        ? 'Next card'
        : _pendingPhoto != null && !_capturing
        ? 'Save failed'
        : session?.storageError != null
        ? 'Storage unavailable'
        : _error != null && controller != null
        ? 'Capture failed'
        : _automaticPaused || _controls || !widget.active
        ? 'Paused'
        : _photoCaptureBacklog
        ? 'Queue full'
        : _rawPhotoContours.any((_RawContour raw) => raw.qualityFailed) ||
              _savedCaptureQuality.values.any(
                (_SavedCaptureQuality quality) => quality.failed.isNotEmpty,
              )
        ? 'Hold steady'
        : _automaticExposureBusy
        ? 'Adjusting light…'
        : _waitingRawFocus
        ? 'Focusing…'
        : _capturing
        ? _captureStatus
        : widget.captureDrawerBuilder == null
        ? null
        : 'Scanning';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Semantics(
            liveRegion: status != null,
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 140),
              width: double.infinity,
              height:
                  MediaQuery.textScalerOf(context).scale(18) *
                      (MediaQuery.textScalerOf(context).scale(13) > 20
                          ? 2
                          : 1) +
                  12,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: captured ? const Color(0xff73e59a) : Colors.transparent,
                borderRadius: BorderRadius.zero,
              ),
              child: Center(
                child: Text(
                  status ?? '',
                  key: const ValueKey<String>('camera-auto-status'),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.3,
                    color: captured ? Colors.black : null,
                    fontWeight: captured ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ),
          if (_pendingPhoto != null && !_capturing)
            SecondaryButton(
              onPressed: busy ? null : _retrySaving,
              child: const Text('Retry save'),
            ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (widget.captureDrawerBuilder == null)
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Semantics(
                      label: 'Review captures for ${widget.destinationLabel}',
                      value: '$count captures',
                      child: PrimaryButton(
                        key: const ValueKey<String>('camera-review'),
                        onPressed:
                            busy ||
                                (count == 0 && photos == 0) ||
                                _pendingPhoto != null
                            ? null
                            : _openReview,
                        child: MediaQuery.textScalerOf(context).scale(13) > 20
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  const Icon(Icons.stack, size: 18),
                                  Visibility(
                                    visible: count > 0,
                                    maintainSize: true,
                                    maintainAnimation: true,
                                    maintainState: true,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        const SizedBox(width: 6),
                                        Text(
                                          '$count',
                                          style: const TextStyle(fontSize: 14),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              )
                            : Text(
                                count > 0 ? 'Review $count' : 'Review',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 14),
                              ),
                      ),
                    ),
                  ),
                ),
              if (widget.captureDrawerBuilder == null) const SizedBox(width: 8),
              _controlIcon(
                key: 'camera-auto-pause',
                label: _automaticPaused
                    ? 'Resume automatic capture'
                    : 'Pause automatic capture',
                icon: _automaticPaused ? Icons.play : Icons.pause,
                active: _automaticPaused,
                onPressed: controller == null || _clearingCaptures
                    ? null
                    : () => setState(() {
                        _resetCaptureFeedback();
                        _invalidateExposure();
                        _automaticPaused = !_automaticPaused;
                        _automaticReadyAt = null;
                      }),
              ),
              if (widget.onClearCaptures != null) ...<Widget>[
                const SizedBox(width: 8),
                _controlIcon(
                  key: 'camera-clear-captures',
                  label: 'Discard remaining',
                  icon: Icons.trash,
                  active: false,
                  onPressed: _clearingCaptures ? null : _clearCaptures,
                ),
              ],
              const SizedBox(width: 8),
              if (widget.onDone != null) ...<Widget>[
                _controlIcon(
                  key: 'camera-done',
                  label: 'Done scanning',
                  icon: Icons.x,
                  active: false,
                  onPressed: busy || _pendingPhoto != null
                      ? null
                      : widget.onDone,
                ),
                const SizedBox(width: 8),
              ],
              _controlIcon(
                key: 'camera-adjustments',
                label: _controls ? 'Close camera controls' : 'Camera controls',
                icon: Icons.sliders,
                active: _controls,
                onPressed:
                    _clearingCaptures ||
                        (controller == null && widget.onClearCaptures == null)
                    ? null
                    : () => setState(() {
                        _invalidateExposure();
                        _controls = !_controls;
                      }),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _resetCaptureFeedback();
    widget.session?.removeListener(_recognitionChanged);
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _focusTimer?.cancel();
    _discoveryTimer?.cancel();
    _liveDetector.reset();
    _liveTracker.removeListener(_tracksChanged);
    _liveTracker.dispose();
    final CameraController? controller = _camera;
    _camera = null;
    controller?.removeListener(_cameraChanged);
    unawaited(
      _lifecycle
          .catchError((Object _) {})
          .then((_) => _disposeCamera(controller)),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CameraController? controller = _camera;
    return PopScope(
      canPop:
          !_clearingCaptures &&
          !_waitingRawFocus &&
          !_capturing &&
          _pendingPhoto == null,
      child: Scaffold(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints viewport) {
              if (widget.automaticCapture) {
                return Column(
                  children: <Widget>[
                    Expanded(
                      child: LayoutBuilder(
                        builder:
                            (BuildContext context, BoxConstraints preview) =>
                                Stack(
                                  fit: StackFit.expand,
                                  children: <Widget>[
                                    _preview(controller),
                                    if (_controls ||
                                        (_error != null &&
                                            controller != null) ||
                                        (_pendingPhoto != null && !_capturing))
                                      Positioned(
                                        left: 8,
                                        right: 8,
                                        bottom: 8,
                                        child: Container(
                                          key: const ValueKey<String>(
                                            'camera-controls-panel',
                                          ),
                                          constraints: BoxConstraints(
                                            maxHeight: preview.maxHeight * .7,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .background,
                                            border: Border.all(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .border,
                                            ),
                                            borderRadius: BorderRadius.zero,
                                          ),
                                          child: SingleChildScrollView(
                                            child: _captureControls(controller),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                      ),
                    ),
                    if (widget.captureDrawerBuilder != null)
                      Visibility(
                        visible: !_controls && _pendingPhoto == null,
                        maintainState: true,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: viewport.maxHeight * .5,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Builder(
                              builder: widget.captureDrawerBuilder!,
                            ),
                          ),
                        ),
                      ),
                    _automaticActions(controller),
                  ],
                );
              }
              if (!widget.automaticCapture &&
                  viewport.maxWidth > viewport.maxHeight &&
                  viewport.maxWidth >= 600) {
                return Row(
                  children: <Widget>[
                    Expanded(child: _preview(controller)),
                    SizedBox(
                      width: 270,
                      child: Column(
                        children: <Widget>[
                          Expanded(
                            child: SingleChildScrollView(
                              child: _captureControls(controller),
                            ),
                          ),
                          _captureActions(controller),
                        ],
                      ),
                    ),
                  ],
                );
              }
              return Column(
                children: <Widget>[
                  Expanded(child: _preview(controller)),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: viewport.maxHeight * .45,
                    ),
                    child: SingleChildScrollView(
                      child: _captureControls(controller),
                    ),
                  ),
                  _captureActions(controller),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
