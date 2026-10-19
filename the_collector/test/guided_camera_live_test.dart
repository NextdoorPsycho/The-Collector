import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Point;

import 'package:arcane/arcane.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart' show SemanticsAction, SemanticsNode;
import 'package:hive/hive.dart';
import 'package:scryfall_api/scryfall_api.dart'
    show MtgCard, CardFace, Game, Language, PaginableList;
import 'package:the_collector/pages/scanning/guided_camera_screen.dart';
import 'package:the_collector/pages/scanning/live_capture_overlay.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/live_scan_tracker.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_capture_defaults.dart';
import 'package:the_collector/utils/scanning/scan_capture_feedback.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_session.dart';
import 'package:the_collector/theme/theme.dart';

import 'helpers/load_collector_fonts.dart';

class _SavedCard extends Fake implements MtgCard {
  _SavedCard(this.id, this.name);

  @override
  final String id;
  @override
  final String name;
}

// https://api.scryfall.com/cards/e768c957-3a1f-42f5-853a-96942f645df5
class _AutomaticPrinting extends Fake implements MtgCard {
  @override
  List<Game> get games => const <Game>[Game.paper];
  @override
  String get id => 'e768c957-3a1f-42f5-853a-96942f645df5';
  @override
  String get name => 'Lightning Bolt';
  @override
  String get set => 'm11';
  @override
  String get collectorNumber => '149';
  @override
  Language get lang => Language.english;
  @override
  String get typeLine => 'Instant';
  @override
  String? get illustrationId => null;
  @override
  String? get printedName => null;
  @override
  String? get printedText => null;
  @override
  String? get flavorText => null;
  @override
  String? get artist => 'Christopher Moeller';
  @override
  List<CardFace>? get cardFaces => null;
  @override
  String? get oracleText => 'Lightning Bolt deals 3 damage to any target.';
}

class _CirclePrinting extends _AutomaticPrinting {
  @override
  String get id => 'e0d377ec-c43c-43b9-934a-91b4d11650ab';
  @override
  String get name => 'Circle of Protection: Blue';
  @override
  String get set => 'ice';
  @override
  String get collectorNumber => '13';
  @override
  String get typeLine => 'Enchantment';
  @override
  String? get oracleText => null;
  @override
  String? get printedText =>
      'Prevent all damage against you from one blue source.';
  @override
  String? get artist => 'Pete Venters';
}

class _AutomaticCatalog extends Fake implements ScanCatalog {
  _AutomaticCatalog({MtgCard? card}) : card = card ?? _AutomaticPrinting();

  final MtgCard card;

  @override
  Future<MtgCard?> exactPrinting(
    String setCode,
    String collectorNumber, {
    String? language,
  }) async => setCode == 'm11' && collectorNumber == '149' ? card : null;

  @override
  Future<PaginableList<MtgCard>> printings(
    String name, {
    String? setCode,
    String? language,
    int page = 1,
  }) async => PaginableList<MtgCard>(
    data: name == card.name ? <MtgCard>[card] : <MtgCard>[],
    hasMore: false,
  );

  @override
  Future<MtgCard?> fuzzyName(String name) async => null;

  @override
  Future<PaginableList<MtgCard>> rulesTextPrintings(
    String phrase, {
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
    int page = 1,
  }) async => PaginableList<MtgCard>(data: <MtgCard>[card], hasMore: false);

  @override
  Future<PaginableList<MtgCard>> rulesKeywordCards(
    List<String> keywords, {
    String? phrase,
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
  }) async => PaginableList<MtgCard>(data: <MtgCard>[card], hasMore: false);
}

class _UnusedRecognizer extends Fake implements CardRecognizer {}

class _SavedSourceRecognizer implements CardRecognizer {
  _SavedSourceRecognizer(this.crop);
  final ScanCrop crop;
  final List<String> paths = <String>[];
  final Completer<void> gate = Completer<void>();

  @override
  Future<ScanRecognition> recognize(
    String path, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    paths.add(path);
    await gate.future;
    return ScanRecognition(
      imagePath: path,
      width: 2000,
      height: 1400,
      crops: <ScanCrop>[
        ScanCrop(
          imagePath: path,
          width: crop.width,
          height: crop.height,
          rectified: true,
          sourceCorners: crop.sourceCorners,
          lines: crop.lines,
          sharpness: crop.sharpness,
        ),
      ],
    );
  }
}

class _DeferredPhotoCatalog extends _AutomaticCatalog {
  _DeferredPhotoCatalog({required super.card});
  final Completer<void> gate = Completer<void>();

  @override
  Future<PaginableList<MtgCard>> printings(
    String name, {
    String? setCode,
    String? language,
    int page = 1,
  }) async {
    await gate.future;
    return super.printings(
      name,
      setCode: setCode,
      language: language,
      page: page,
    );
  }
}

class _NoLiveIdentityResolver extends ScanResolver {
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

class _RawPhotoRecognizer implements CardRecognizer {
  _RawPhotoRecognizer(this.crop);
  ScanCrop crop;
  int calls = 0;
  Completer<void>? gate;

  @override
  Future<ScanRecognition> recognize(
    String path, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    calls++;
    await gate?.future;
    return ScanRecognition(
      imagePath: path,
      width: 2000,
      height: 1400,
      crops: <ScanCrop>[
        ScanCrop(
          imagePath: '/tmp/crop-raw-photo-$calls.jpg',
          width: crop.width,
          height: crop.height,
          rectified: crop.rectified,
          sourceCorners: crop.sourceCorners,
          lines: crop.lines,
          warnings: <String>[
            ...crop.warnings,
            if (crop.lines.isEmpty) 'incomplete_card',
            if (crop.lines.isEmpty) 'no_text',
          ],
          sharpness: crop.sharpness,
        ),
      ],
    );
  }
}

class _PresencePhotoRecognizer
    implements CardRecognizer, CapturePresenceRecognizer {
  _PresencePhotoRecognizer(ScanCrop crop) : reader = _RawPhotoRecognizer(crop);
  final _RawPhotoRecognizer reader;
  final Completer<void> deep = Completer<void>();
  int deepCalls = 0;
  bool emptyPresence = false;
  int get calls => reader.calls;
  Completer<void>? get gate => reader.gate;
  set gate(Completer<void>? value) => reader.gate = value;
  @override
  bool get supportsCapturePresence => true;
  @override
  Future<ScanRecognition> recognizePresence(
    String path, {
    bool multipleCards = true,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    final ScanRecognition result = await reader.recognize(
      path,
      multipleCards: multipleCards,
    );
    return ScanRecognition(
      imagePath: result.imagePath,
      width: result.width,
      height: result.height,
      crops: emptyPresence
          ? const <ScanCrop>[]
          : result.crops
                .map(
                  (ScanCrop crop) => ScanCrop(
                    imagePath: crop.imagePath,
                    width: crop.width,
                    height: crop.height,
                    rectified: crop.rectified,
                    sourceCorners: crop.sourceCorners,
                    lines: crop.lines,
                    warnings: <String>[...crop.warnings, 'details_pending'],
                  ),
                )
                .toList(),
    );
  }

  @override
  Future<ScanRecognition> recognize(
    String path, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    deepCalls++;
    await deep.future;
    return reader.recognize(path, multipleCards: multipleCards);
  }
}

mixin _SavedCaptureAcknowledgement on ScanSession {
  final Map<String, ScanCrop> savedEvidence = <String, ScanCrop>{};
  final Set<String> acceptedEvidence = <String>{};

  // Camera fixtures model the store acknowledgment; disk and journal failures
  // are exercised by scan_capture_acceptance_test.dart.
  @override
  Future<bool> acceptCaptures(
    List<ScanSessionItem> captures, {
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() == false ||
        captures.isEmpty ||
        captures.any(
          (ScanSessionItem item) =>
              !items.contains(item) ||
              item.rescanPending ||
              !hasVerifiedSavedCardCapturePresence(item.crop) ||
              !identical(savedEvidence[item.id], item.crop),
        )) {
      return false;
    }
    acceptedEvidence.addAll(captures.map((ScanSessionItem item) => item.id));
    return true;
  }
}

class _RecognitionSession extends ScanSession
    with _SavedCaptureAcknowledgement {
  _RecognitionSession({required super.recognizer, required super.resolver});
}

class _ControlledSession extends ScanSession with _SavedCaptureAcknowledgement {
  _ControlledSession({required super.recognizer, required super.resolver});

  bool get hasObservers => hasListeners;

  final Set<String> rawCompletedGroups = <String>{};
  final Set<String> failedDetailGroups = <String>{};
  final Map<String, List<List<ScanPoint>>> rawRegions =
      <String, List<List<ScanPoint>>>{};
  int failedPhotoCount = 0;
  final Map<String, String> captureGroups = <String, String>{};
  final Map<String, List<SavedTargetAppearance>> sourceAppearances =
      <String, List<SavedTargetAppearance>>{};
  final Map<String, Set<String>> refinementReceipts = <String, Set<String>>{};

  @override
  Future<bool> adoptLiveObservations(
    List<LiveCaptureObservation> values, {
    ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
  }) async {
    final bool saved = await super.adoptLiveObservations(
      values,
      defaults: defaults,
    );
    if (saved) {
      for (final LiveCaptureObservation value in values.where(
        (LiveCaptureObservation value) => value.isRefinement,
      )) {
        (refinementReceipts['${value.photoCaptureId}_0'] ??= <String>{}).add(
          value.receiptId,
        );
      }
    }
    return saved;
  }

  String captureGroup(List<String> paths) =>
      captureGroups[ScanDraftStore.focusStackCaptureId(paths)] ??
      ScanDraftStore.focusStackCaptureId(paths);

  void rememberCapture(List<String> paths, String captureId) {
    captureGroups[ScanDraftStore.focusStackCaptureId(paths)] = captureId;
  }

  @override
  List<SavedTargetAppearance> captureTargetAppearances(List<String> paths) =>
      sourceAppearances[captureGroup(paths)] ??
      super.captureTargetAppearances(paths);

  @override
  Future<bool> addFocusStack(
    List<String> paths, {
    bool ownedCameraSource = false,
    String? captureId,
    bool diagnosticOnly = false,
    bool preferFastPresence = false,
    List<List<ScanPoint>>? targetRegions,
    List<List<ScanPoint>> excludedRegions = const <List<ScanPoint>>[],
    ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
  }) {
    if (captureId != null) rememberCapture(paths, captureId);
    return super.addFocusStack(
      paths,
      ownedCameraSource: ownedCameraSource,
      captureId: captureId,
      diagnosticOnly: diagnosticOnly,
      preferFastPresence: preferFastPresence,
      targetRegions: targetRegions,
      excludedRegions: excludedRegions,
      defaults: defaults,
    );
  }

  @override
  Iterable<ScanSessionItem> capturedItems(List<String> paths) {
    final Set<String> photoIds = <String>{
      for (int index = 0; index < paths.length; index++)
        '${captureGroup(paths)}_$index',
    };
    final Set<String> existing = super
        .capturedItems(paths)
        .map((ScanSessionItem item) => item.id)
        .toSet();
    return items.where(
      (ScanSessionItem item) =>
          photoIds.contains(item.photoId) ||
          existing.contains(item.id) ||
          photoIds.any(
            (String photoId) =>
                refinementReceipts[photoId]?.contains(
                  item.liveCaptureReceiptId,
                ) ??
                false,
          ),
    );
  }

  @override
  int get failedPhotos => failedPhotoCount;

  @override
  bool captureReadComplete(List<String> paths) =>
      rawCompletedGroups.contains(captureGroup(paths)) ||
      capturedItems(paths)
          .any((ScanSessionItem item) => item.crop.imagePath.isNotEmpty);

  @override
  bool captureDetailsFailed(List<String> paths) =>
      failedDetailGroups.contains(captureGroup(paths)) ||
      super.captureDetailsFailed(paths);

  @override
  List<List<ScanPoint>> capturedRawRegions(List<String> paths) =>
      rawRegions[captureGroup(paths)] ?? const <List<ScanPoint>>[];
}

class _ProcessingSession extends _ControlledSession {
  _ProcessingSession({required super.recognizer, required super.resolver});

  bool processing = true;
  int queuedPhotos = 0;

  @override
  bool get running => processing || super.running;

  @override
  int get remainingPhotos => queuedPhotos;

  @override
  int get pendingPhotoCaptures => queuedPhotos;
}

class _CaptureHaptics {
  int lightImpacts = 0;
  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'HapticFeedback.vibrate' &&
              call.arguments == 'HapticFeedbackType.lightImpact') {
            lightImpacts++;
          }
          return null;
        });
  }

  void restore() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null);
}

class _Camera extends CameraPlatform {
  _Camera() {
    frames = StreamController<CameraImageData>.broadcast(
      onListen: () => actions.add('stream start'),
      onCancel: () => actions.add('stream stop'),
    );
  }

  final List<String> actions = <String>[];
  final List<int> quality = <int>[];
  final List<ResolutionPreset?> resolution = <ResolutionPreset?>[];
  late final StreamController<CameraImageData> frames;
  final StreamController<DeviceOrientationChangedEvent> orientations =
      StreamController<DeviceOrientationChangedEvent>.broadcast();
  Point<double>? focus;
  final List<Point<double>> focusPoints = <Point<double>>[];
  final List<double> zoomLevels = <double>[];
  final List<double> exposureOffsets = <double>[];
  Completer<double>? exposureGate;
  bool failExposure = false;
  Point<double>? exposure;
  bool failCapture = false;
  bool focusPointSupported = true;
  bool ultraWideAvailable = true;
  bool streamingCapture = false;
  Completer<XFile>? pendingPicture;
  void Function()? beforePicture;
  String picturePath = '/tmp/synthetic-live-camera.jpg';

  @override
  Future<List<CameraDescription>> availableCameras() async =>
      <CameraDescription>[
        const CameraDescription(
          name: 'wide',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
          lensType: CameraLensType.wide,
        ),
        if (ultraWideAvailable)
          const CameraDescription(
            name: 'ultra',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
            lensType: CameraLensType.ultraWide,
          ),
      ];
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      orientations.stream;
  @override
  Future<int> createCameraWithSettings(
    CameraDescription camera,
    MediaSettings settings,
  ) async {
    resolution.add(settings.resolutionPreset);
    actions.add('create ${camera.name}');
    return 1;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int id) =>
      Stream<CameraInitializedEvent>.value(
        CameraInitializedEvent(
          id,
          800,
          400,
          ExposureMode.auto,
          true,
          FocusMode.auto,
          focusPointSupported,
        ),
      );
  @override
  Stream<CameraErrorEvent> onCameraError(int id) =>
      Stream<CameraErrorEvent>.multi(
        (MultiStreamController<CameraErrorEvent> _) {},
      );
  @override
  Future<void> initializeCamera(
    int id, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}
  @override
  bool supportsImageStreaming() => true;
  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int id, {
    CameraImageStreamOptions? options,
  }) => frames.stream;
  @override
  Widget buildPreview(int id) => const ColoredBox(color: Color(0xff202020));
  @override
  Future<void> setJpegImageQuality(int id, int value) async =>
      quality.add(value);
  @override
  Future<void> setFlashMode(int id, FlashMode mode) async =>
      actions.add('flash ${mode.name}');
  @override
  Future<double> getMinZoomLevel(int id) async => 1;
  @override
  Future<double> getMaxZoomLevel(int id) async => 4;
  @override
  Future<void> setZoomLevel(int id, double zoom) async => zoomLevels.add(zoom);
  @override
  Future<double> getMinExposureOffset(int id) async => -2;
  @override
  Future<double> getMaxExposureOffset(int id) async => 2;
  @override
  Future<double> getExposureOffsetStepSize(int id) async => .5;
  @override
  Future<double> setExposureOffset(int id, double offset) async {
    exposureOffsets.add(offset);
    if (failExposure) {
      throw CameraException(
        'exposure_unavailable',
        'Synthetic unsupported offset',
      );
    }
    final Completer<double>? pending = exposureGate;
    exposureGate = null;
    return pending == null ? offset : pending.future;
  }

  @override
  Future<void> setFocusMode(int id, FocusMode mode) async =>
      actions.add('focus ${mode.name}');
  @override
  Future<void> setFocusPoint(int id, Point<double>? point) async {
    focus = point;
    if (point != null) focusPoints.add(point);
  }

  @override
  Future<void> setExposurePoint(int id, Point<double>? point) async =>
      exposure = point;
  @override
  Future<XFile> takePicture(int id) async {
    beforePicture?.call();
    expectSync(
      frames.hasListener,
      streamingCapture ? isTrue : isFalse,
      reason: streamingCapture
          ? 'iOS sweep photos preserve the live image stream.'
          : 'Stationary and manual capture pause the live image stream.',
    );
    actions.add('photo');
    if (failCapture) {
      throw PlatformException(
        code: 'capture_failed',
        message: 'Synthetic camera failure',
      );
    }
    return pendingPicture?.future ?? XFile(picturePath);
  }

  @override
  Future<void> dispose(int id) async {
    expectSync(
      frames.hasListener,
      isFalse,
      reason: 'Camera disposal must cancel live callbacks.',
    );
    actions.add('dispose');
  }
}

ScanSessionItem _refinePhotoObservation(
  ScanSession session,
  ScanCrop crop, {
  required String id,
  required String photoId,
}) {
  final ScanCrop photoCrop = ScanCrop(
    imagePath: '/tmp/synthetic-photo-$photoId-$id.png',
    width: crop.width,
    height: crop.height,
    rectified: crop.rectified,
    sourceCorners: crop.sourceCorners,
    lines: crop.lines,
    warnings: crop.warnings,
    sharpness: crop.sharpness,
  );
  final List<ScanSessionItem> prior = session.items.where((
    ScanSessionItem item,
  ) {
    final List<ScanPoint> a = item.crop.sourceCorners;
    final List<ScanPoint> b = crop.sourceCorners;
    return (item.photoId == photoId ||
            (session is _ControlledSession &&
                (session.refinementReceipts[photoId]?.contains(
                      item.liveCaptureReceiptId,
                    ) ??
                    false))) &&
        a.length == 4 &&
        b.length == 4 &&
        List<int>.generate(4, (int index) => index).every(
          (int index) =>
              (a[index].x - b[index].x).abs() < .000001 &&
              (a[index].y - b[index].y).abs() < .000001,
        );
  }).toList();
  expect(prior.length, lessThanOrEqualTo(1));
  final ScanSessionItem item;
  if (prior.isNotEmpty) {
    item = prior.single..crop = photoCrop;
  } else {
    item = ScanSessionItem(photoCrop, id: id, photoId: photoId);
    session.add(item);
  }
  if (session is _SavedCaptureAcknowledgement) {
    session.savedEvidence[item.id] = photoCrop;
  }
  return item;
}

Future<void> _show(
  WidgetTester tester,
  _Camera camera, {
  Size size = const Size(375, 667),
  double scale = 1,
  Future<bool> Function(String, List<List<ScanPoint>>)? onCaptured,
  Future<bool> Function(
    List<String>,
    List<List<ScanPoint>>,
    String,
    List<List<ScanPoint>>?,
  )?
  onFocusStackCaptured,
  ScanSession? session,
  Future<void> Function()? onClearCaptures,
  Future<bool> Function(
    List<String>,
    List<List<ScanPoint>>,
    String,
    List<List<ScanPoint>>,
  )?
  onUnidentifiedPhotoCaptured,
  bool singleShot = false,
  bool pushRoute = false,
  bool automaticCapture = false,
  bool useSession = true,
  bool stationaryFocusStack = false,
  ThemeMode theme = ThemeMode.dark,
  ValueListenable<GuidedCameraScreen>? cameraUpdates,
  DateTime Function()? feedbackClock,
}) async {
  final ScanSession? shownSession =
      session ??
      (automaticCapture && useSession
          ? _ControlledSession(
              recognizer: _UnusedRecognizer(),
              resolver: ScanResolver(catalog: _AutomaticCatalog()),
            )
          : null);
  if (session == null && shownSession != null) {
    addTearDown(shownSession.dispose);
  }
  Future<bool> handoff(
    List<String> paths,
    List<List<ScanPoint>> excludedRegions,
    String captureId,
    List<List<ScanPoint>>? targetRegions,
  ) {
    if (shownSession is _ControlledSession) {
      shownSession.rememberCapture(paths, captureId);
    }
    if (!automaticCapture) {
      expect(
        targetRegions,
        isNull,
        reason: 'Manual capture admits the complete photo.',
      );
    }
    return onFocusStackCaptured!(
      paths,
      excludedRegions,
      captureId,
      targetRegions,
    );
  }

  final CameraPlatform previous = CameraPlatform.instance;
  camera.streamingCapture =
      automaticCapture &&
      !stationaryFocusStack &&
      defaultTargetPlatform == TargetPlatform.iOS;
  CameraPlatform.instance = camera;
  addTearDown(() async {
    CameraPlatform.instance = previous;
    await camera.frames.close();
    await camera.orientations.close();
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(theme),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQueryData.fromView(View.of(context)).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: cameraUpdates != null
          ? ValueListenableBuilder<GuidedCameraScreen>(
              valueListenable: cameraUpdates,
              builder: (
                BuildContext context,
                GuidedCameraScreen screen,
                Widget? child,
              ) => screen,
            )
          : singleShot || pushRoute
          ? Builder(
              builder: (BuildContext context) => Scaffold(
                child: Center(
                  child: SecondaryButton(
                    onPressed: () => Arcane.push<void>(
                      context,
                      GuidedCameraScreen(
                        feedbackClock: feedbackClock,
                        automaticCapture: automaticCapture,
                        stationaryFocusStack: stationaryFocusStack,
                        session: shownSession,
                        onClearCaptures: onClearCaptures,
                        onUnidentifiedPhotoCaptured:
                            onUnidentifiedPhotoCaptured,
                        continuous: !singleShot,
                        onFocusStackCaptured: onFocusStackCaptured == null
                            ? null
                            : handoff,
                        multipleCards: onFocusStackCaptured != null,
                        onCaptured:
                            onCaptured ??
                            (
                              String _,
                              List<List<ScanPoint>> excludedRegions,
                            ) async => true,
                      ),
                    ),
                    child: const Text('Open camera'),
                  ),
                ),
              ),
            )
          : GuidedCameraScreen(
              feedbackClock: feedbackClock,
              automaticCapture: automaticCapture,
              stationaryFocusStack: stationaryFocusStack,
              session: shownSession,
              onClearCaptures: onClearCaptures,
              onUnidentifiedPhotoCaptured: onUnidentifiedPhotoCaptured,
              onCaptured:
                  onCaptured ??
                  (String _, List<List<ScanPoint>> excludedRegions) async =>
                      true,
              onFocusStackCaptured: onFocusStackCaptured == null
                  ? null
                  : handoff,
              multipleCards: onFocusStackCaptured != null,
            ),
    ),
  );
  await tester.pumpAndSettle();
  if (singleShot || pushRoute) {
    await tester.tap(find.text('Open camera'));
    await tester.pumpAndSettle();
  }
}

typedef _RawCaptureHandoff = Future<bool> Function(
  List<String>,
  List<List<ScanPoint>>,
  String,
  List<List<ScanPoint>>,
);

void _publishSavedPhotoCards(
  _ControlledSession session,
  List<String> paths,
  String captureId,
  Iterable<ScanCrop> crops,
) {
  session.rememberCapture(paths, captureId);
  int index = 0;
  for (final ScanCrop crop in crops) {
    final ScanSessionItem item = _refinePhotoObservation(
      session,
      crop,
      id: 'source-$captureId-${index++}',
      photoId: '${captureId}_0',
    );
    item.resolution = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_AutomaticPrinting(), const <ScanEvidence>{
          ScanEvidence.nameMatch,
        }),
      ],
      hints: ScanHints.fromCrop(crop),
      status: ScanResolutionStatus.needsReview,
    );
  }
  session.rawCompletedGroups.add(captureId);
  session.changed();
}

GuidedCameraScreen _mixedOwnerCamera(
  _ControlledSession session, {
  _RawCaptureHandoff? rawHandoff,
}) => GuidedCameraScreen(
  session: session,
  automaticCapture: true,
  multipleCards: true,
  onCaptured: (String path, List<List<ScanPoint>> excluded) async => true,
  onUnidentifiedPhotoCaptured: rawHandoff,
  onFocusStackCaptured:
      (
        List<String> paths,
        List<List<ScanPoint>> excluded,
        String captureId,
        List<List<ScanPoint>>? targets,
      ) async {
        _publishSavedPhotoCards(
          session,
          paths,
          captureId,
          targets!.map(
            (List<ScanPoint> corners) => _automaticCard(corners: corners),
          ),
        );
        return true;
      },
);

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (int frame = 0; frame < 30 && !done(); frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue);
}

ScanCrop _automaticCard({
  bool readable = true,
  bool titleOnly = false,
  List<ScanPoint>? corners,
}) => ScanCrop(
  imagePath: '',
  width: 1000,
  height: 1400,
  rectified: true,
  sourceCorners:
      corners ??
      const <ScanPoint>[
        ScanPoint(.1, .2),
        ScanPoint(.32, .2),
        ScanPoint(.32, .65),
        ScanPoint(.1, .65),
      ],
  lines: <ScanTextLine>[
    if (readable)
      const ScanTextLine(
        text: 'Lightning Bolt',
        confidence: .99,
        bounds: ScanBounds(.1, .04, .7, .03),
      ),
    if (readable && !titleOnly) ...const <ScanTextLine>[
      ScanTextLine(
        text: 'Instant',
        confidence: .99,
        bounds: ScanBounds(.1, .5, .7, .03),
      ),
      ScanTextLine(
        text: 'Lightning Bolt deals 3 damage to any target.',
        confidence: .99,
        bounds: ScanBounds(.1, .62, .8, .03),
      ),
      ScanTextLine(
        text: '149',
        confidence: .99,
        bounds: ScanBounds(.05, .87, .2, .03),
      ),
      ScanTextLine(
        text: 'M11 EN',
        confidence: .99,
        bounds: ScanBounds(.05, .93, .2, .03),
      ),
    ],
  ],
);

List<ScanCrop> _automaticGrid(int count) => <ScanCrop>[
  for (int index = 0; index < count; index++)
    _automaticCard(
      corners: <ScanPoint>[
        ScanPoint(.04 + (index % 4) * .19, .05 + (index ~/ 4) * .32),
        ScanPoint(.16 + (index % 4) * .19, .05 + (index ~/ 4) * .32),
        ScanPoint(.16 + (index % 4) * .19, .30 + (index ~/ 4) * .32),
        ScanPoint(.04 + (index % 4) * .19, .30 + (index ~/ 4) * .32),
      ],
    ),
];

ScanCrop _circleCard(String color) => ScanCrop(
  imagePath: '',
  width: 1000,
  height: 1400,
  rectified: true,
  sourceCorners: _automaticCard().sourceCorners,
  lines: <ScanTextLine>[
    ScanTextLine(
      text: 'Circle of Protection: $color',
      confidence: .99,
      bounds: const ScanBounds(.08, .04, .76, .03),
    ),
    const ScanTextLine(
      text: 'Enchantment',
      confidence: .99,
      bounds: ScanBounds(.08, .55, .76, .03),
    ),
    const ScanTextLine(
      text: 'Prevent all damage against you',
      confidence: .99,
      bounds: ScanBounds(.08, .64, .76, .03),
    ),
    ScanTextLine(
      text: 'from one ${color.toLowerCase()} source.',
      confidence: .99,
      bounds: const ScanBounds(.08, .68, .76, .03),
    ),
  ],
);

List<double> _circleAppearance(Map<String, Object?> fixture, String color) =>
    ((fixture[color]! as Map<String, Object?>)['rgb']! as List<Object?>)
        .map((Object? value) => (value! as num).toDouble())
        .toList();

class _AutomaticScene {
  int frameWidth = 800;
  ScanCrop crop = _automaticCard();
  List<ScanCrop> additionalCrops = <ScanCrop>[];
  List<ScanCrop> geometryCrops = <ScanCrop>[];
  double focusLensPosition = .5;
  double geometryConfidence = .99;
  Completer<void>? focusGate;
  bool focusAccepted = true;
  bool focusStatusSupported = true;
  Offset? focusStatusPoint;
  int focusStatusRequests = 0;
  int captureConfirmations = 0;
  bool focusAdjusting = false;
  bool exposureAdjusting = false;
  double? focusSharpness;
  Map<String, Object>? lighting;
  bool reversedAppearance = false;
  bool reversedRawAppearance = false;
  bool rawAppearanceSupported = false;
  bool rawAppearancePresent = true;
  bool rawAppearanceFlat = false;
  bool omitRawAppearance = false;
  bool showCards = true;
  bool showFocusCandidates = true;
  List<String> cardWarnings = <String>[];
  List<double>? previewAppearanceValues;
  List<ScanPoint>? previewAppearanceCorners;
  List<double>? rawAppearanceValues;
  List<double>? ownedAppearanceValues;
  Completer<void>? textGate;
  Completer<void>? frameGate;
  final List<bool> textRequests = <bool>[];
  final List<List<Object?>> exclusions = <List<Object?>>[];
  final List<List<Object?>> appearanceRequests = <List<Object?>>[];
  final List<Offset> nativeFocusPoints = <Offset>[];
  final List<bool> nativeSingleShotRequests = <bool>[];

  VoidCallback install() {
    final TargetPlatform? previous = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeCardRecognizer.channel, (
          MethodCall call,
        ) async {
          if (call.method == 'captureConfirmed') {
            captureConfirmations++;
            return true;
          }
          if (call.method == 'cameraFocusAtPoint') {
            final Map<Object?, Object?> arguments =
                call.arguments as Map<Object?, Object?>;
            nativeSingleShotRequests.add(arguments['singleShot'] == true);
            nativeFocusPoints.add(
              Offset(
                (arguments['x']! as num).toDouble(),
                (arguments['y']! as num).toDouble(),
              ),
            );
            await focusGate?.future;
            return focusAccepted;
          }
          if (call.method == 'cameraFocusStatus') {
            focusStatusRequests++;
            if (!focusStatusSupported) throw MissingPluginException();
            return <String, Object>{
              'isAdjustingFocus': focusAdjusting,
              'isAdjustingExposure': exposureAdjusting,
              'lensPosition': focusLensPosition,
              'focusMode': 0,
              if (focusStatusPoint != null) ...<String, double>{
                'focusPointX': focusStatusPoint!.dx,
                'focusPointY': focusStatusPoint!.dy,
              },
            };
          }
          if (call.method != 'detectFrame') {
            throw StateError('Unexpected scanner call ${call.method}');
          }
          final Map<Object?, Object?> arguments =
              call.arguments as Map<Object?, Object?>;
          textRequests.add(arguments['includeText'] == true);
          final Completer<void>? pendingFrame = frameGate;
          if (pendingFrame != null) await pendingFrame.future;
          if (arguments['includeText'] == true) await textGate?.future;
          final List<Object?> excluded =
              arguments['excludedRegions'] as List<Object?>? ?? <Object?>[];
          exclusions.add(List<Object?>.of(excluded));
          final List<Object?> requested =
              arguments['appearanceRegions'] as List<Object?>? ?? <Object?>[];
          appearanceRequests.add(List<Object?>.of(requested));
          final Map<String, Map<Object?, Object?>> sampled =
              <String, Map<Object?, Object?>>{};
          for (final Object? value in <Object?>[
            ...excluded,
            if (rawAppearanceSupported) ...requested,
          ]) {
            final Map<Object?, Object?> region =
                value! as Map<Object?, Object?>;
            final String id = region['id']! as String;
            if (id.startsWith('raw_') &&
                (!rawAppearanceSupported || omitRawAppearance)) {
              continue;
            }
            sampled[id] = region;
          }
          List<Map<String, double>> points(List<ScanPoint> corners) => corners
              .map(
                (ScanPoint point) => <String, double>{
                  'x': point.x,
                  'y': point.y,
                },
              )
              .toList();
          bool excludedCard(ScanCrop detected) => excluded.any((
            Object? region,
          ) {
            final List<Object?> corners =
                (region! as Map<Object?, Object?>)['corners']! as List<Object?>;
            if (corners.length != detected.sourceCorners.length) return false;
            for (int index = 0; index < corners.length; index++) {
              final Map<Object?, Object?> point =
                  corners[index]! as Map<Object?, Object?>;
              if ((point['x']! as num).toDouble() !=
                      detected.sourceCorners[index].x ||
                  (point['y']! as num).toDouble() !=
                      detected.sourceCorners[index].y) {
                return false;
              }
            }
            return true;
          });
          return <String, Object>{
            'width': frameWidth,
            'height': 400,
            'rectanglesSupported': true,
            'appearanceSamplingSupported': true,
            'appearanceSamples': <Object>[
              for (final Map<Object?, Object?> region in sampled.values)
                <String, Object>{
                  'id': region['id']! as String,
                  'corners':
                      (region['id']! as String).startsWith('preview_') &&
                          previewAppearanceCorners != null
                      ? points(previewAppearanceCorners!)
                      : region['corners']! as List<Object?>,
                  'present':
                      !(region['id']! as String).startsWith('raw_') ||
                      rawAppearancePresent,
                  'values':
                      ((region['id']! as String).startsWith('raw_')
                          ? rawAppearanceValues
                          : (region['id']! as String).startsWith('preview_')
                          ? previewAppearanceValues
                          : ownedAppearanceValues) ??
                      <double>[
                        for (int pixel = 0; pixel < 96; pixel++)
                          for (int channel = 0; channel < 3; channel++)
                            (region['id']! as String).startsWith('raw_') &&
                                    rawAppearanceFlat
                                ? .35
                                : .15 +
                                      ((reversedAppearance ||
                                                  ((region['id']! as String)
                                                          .startsWith('raw_') &&
                                                      reversedRawAppearance))
                                              ? 11 - pixel % 12
                                              : pixel % 12) /
                                          18 +
                                      channel * .025,
                      ],
                },
            ],
            'focusCandidates': <Object>[
              for (final ScanCrop detected in <ScanCrop>[
                if (showCards && showFocusCandidates) ...<ScanCrop>[
                  crop,
                  ...additionalCrops,
                  ...geometryCrops,
                ],
              ])
                <String, Object>{
                  'confidence': geometryConfidence,
                  'corners': points(detected.sourceCorners),
                  'warnings': <String>['geometry_only'],
                  'sharpness': ?focusSharpness,
                  'lighting': ?lighting,
                },
            ],
            'cards': <Object>[
              for (final ScanCrop detected in <ScanCrop>[
                if (showCards) ...<ScanCrop>[crop, ...additionalCrops],
              ])
                if (!excludedCard(detected))
                  <String, Object>{
                    'confidence': .99,
                    'corners': points(detected.sourceCorners),
                    'warnings': cardWarnings,
                    'lines': <Object>[
                      if (arguments['includeText'] == true)
                        for (final ScanTextLine line in detected.lines)
                          <String, Object>{
                            'text': line.text,
                            'confidence': line.confidence,
                            'bounds': <String, double>{
                              'x': line.bounds.x,
                              'y': line.bounds.y,
                              'width': line.bounds.width,
                              'height': line.bounds.height,
                            },
                          },
                    ],
                  },
            ],
          };
        });
    return () {
      debugDefaultTargetPlatformOverride = previous;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
    };
  }
}

CameraImageData _automaticFrame() => CameraImageData(
  format: const CameraImageFormat(ImageFormatGroup.bgra8888, raw: 1111970369),
  planes: <CameraImagePlane>[
    CameraImagePlane(bytes: Uint8List(16), bytesPerRow: 8, bytesPerPixel: 4),
  ],
  width: 2,
  height: 2,
);

const Map<String, Object> _washedLighting = <String, Object>{
  'highlightFraction': .2,
  'shadowFraction': .01,
  'meanLuminance': .85,
  'contrast': .15,
  'sampleCount': 256,
};
const Map<String, Object> _normalLighting = <String, Object>{
  'highlightFraction': .01,
  'shadowFraction': .05,
  'meanLuminance': .5,
  'contrast': .5,
  'sampleCount': 256,
};

Future<void> _automaticPulse(
  WidgetTester tester,
  _Camera camera, {
  int callbacks = 1,
}) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 450)),
  );
  if (camera.frames.hasListener) {
    for (int index = 0; index < callbacks; index++) {
      camera.frames.add(_automaticFrame());
    }
  }
  await tester.pump(const Duration(milliseconds: 100));
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Future<void> _automaticUntil(
  WidgetTester tester,
  _Camera camera,
  bool Function() done,
) async {
  for (int frame = 0; frame < 12 && !done(); frame++) {
    await _automaticPulse(tester, camera);
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(done(), isTrue);
}

Future<void> _dismissCamera(WidgetTester tester, _Camera camera) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _until(
    tester,
    () => camera.actions.isNotEmpty && camera.actions.last == 'dispose',
  );
}

Future<void> _holdRawCaptureAtDiscovery(
  WidgetTester tester,
  _Camera camera,
  _AutomaticScene scene,
) async {
  scene.geometryConfidence = .85;
  await _automaticPulse(tester, camera);
  await _until(tester, () => scene.textRequests.length == 1);
  await _automaticPulse(tester, camera);
  await _until(tester, () => scene.nativeFocusPoints.length == 1);
  expect(scene.nativeSingleShotRequests, <bool>[false]);
  scene.geometryConfidence = .99;
  await _automaticPulse(tester, camera);
  await _until(tester, () => scene.textRequests.length == 3);
  await _automaticPulse(tester, camera);
  await _until(tester, () => find.text('Focusing…').evaluate().isNotEmpty);
  expect(camera.actions, isNot(contains('photo')));
}

Future<void> _cameraEdgeSwipe(WidgetTester tester) async {
  await tester.dragFrom(const Offset(2, 300), const Offset(330, 0));
  await tester.pumpAndSettle();
}

void main() {
  for (final String failure in <String>['shutter', 'import', 'backlog']) {
    testWidgets('photo-first capture preserves evidence after $failure', (
      WidgetTester tester,
    ) async {
      final _AutomaticScene scene = _AutomaticScene();
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera()..failCapture = failure == 'shutter';
      final File? original = failure == 'import'
          ? (File(
              '${Directory.systemTemp.path}/collector-retry-source-${DateTime.now().microsecondsSinceEpoch}.jpg',
            )..writeAsBytesSync(<int>[255, 216, 4, 5, 255, 217]))
          : null;
      if (original != null) {
        camera.picturePath = original.path;
      }
      final _ProcessingSession session = _ProcessingSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: _AutomaticCatalog()),
      )..queuedPhotos = failure == 'backlog' ? 8 : 0;
      final _CaptureHaptics haptics = _CaptureHaptics();
      haptics.install();
      final List<List<String>> imports = <List<String>>[];
      final List<String> captureIds = <String>[];
      bool accept = failure != 'import';
      LiveCaptureOverlay overlay() =>
          tester.widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay));
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> exclusions,
                String captureId,
                List<List<ScanPoint>>? targets,
              ) async {
                imports.add(List<String>.of(paths));
                captureIds.add(captureId);
                expect(targets, hasLength(1));
                if (accept) {
                  _publishSavedPhotoCards(
                    session,
                    paths,
                    captureId,
                    targets!.map(
                      (List<ScanPoint> corners) =>
                          _automaticCard(corners: corners),
                    ),
                  );
                }
                return accept;
              },
        );
        if (failure == 'backlog') {
          for (int frame = 0; frame < 5; frame++) {
            await _automaticPulse(tester, camera);
          }
          expect(camera.actions, isNot(contains('photo')));
          expect(imports, isEmpty);
          expect(session.items, isEmpty);
          expect(overlay().safeToMoveTrackIds, isEmpty);
          expect(haptics.lightImpacts, 0);
          expect(scene.captureConfirmations, 0);
          session.queuedPhotos = 0;
          session.changed();
        } else if (failure == 'shutter') {
          await _automaticUntil(
            tester,
            camera,
            () => camera.actions.contains('photo'),
          );
          await _until(
            tester,
            () => find.textContaining('Capture failed').evaluate().isNotEmpty,
          );
          expect(imports, isEmpty);
          expect(session.items, isEmpty);
          expect(overlay().safeToMoveTrackIds, isEmpty);
          expect(haptics.lightImpacts, 0);
          expect(scene.captureConfirmations, 0);
          camera.failCapture = false;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(seconds: 4)),
          );
        }
        await _automaticUntil(tester, camera, () => imports.isNotEmpty);
        if (failure == 'import') {
          await _until(
            tester,
            () => find.text('Retry save').evaluate().isNotEmpty,
          );
          expect(overlay().safeToMoveTrackIds, isEmpty);
          expect(session.items, isEmpty);
          expect(haptics.lightImpacts, 0);
          expect(scene.captureConfirmations, 0);
          expect(original!.existsSync(), isTrue);
          expect(original.readAsBytesSync(), <int>[255, 216, 4, 5, 255, 217]);
          final int shots = camera.actions
              .where((String a) => a == 'photo')
              .length;
          accept = true;
          await tester.tap(find.text('Retry save'));
          await _until(tester, () => imports.length == 2);
          expect(imports.first, imports.last);
          expect(captureIds.toSet(), hasLength(1));
          expect(
            camera.actions.where((String a) => a == 'photo'),
            hasLength(shots),
          );
        }
        await _until(tester, () => overlay().safeToMoveTrackIds.isNotEmpty);
        expect(haptics.lightImpacts, 1);
        expect(scene.captureConfirmations, 1);
        expect(
          session.items,
          hasLength(1),
          reason:
              'Only the independently processed saved source enters the batch.',
        );
        expect(session.items.single.liveCaptureReceiptId, isNull);
        expect(find.text('Next card'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        session.dispose();
        haptics.restore();
        restore();
        if (original?.existsSync() == true) {
          original!.deleteSync();
        }
      }
    });
  }
  testWidgets(
    'distinct cards capture during sound grace without recapturing saved cards or replaying sound',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _ProcessingSession session = _ProcessingSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: _AutomaticCatalog()),
      );
      int captures = 0;
      final DateTime firstSignalAt = DateTime.utc(2026, 10, 15);
      DateTime feedbackNow = firstSignalAt;
      Future<void> quickFrame() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 110)),
        );
        camera.frames.add(_automaticFrame());
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }

      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          feedbackClock: () => feedbackNow,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> exclusions,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                _publishSavedPhotoCards(
                  session,
                  paths,
                  captureId,
                  targets.map(
                    (List<ScanPoint> corners) =>
                        _automaticCard(corners: corners),
                  ),
                );
                return true;
              },
        );
        await _automaticUntil(
          tester,
          camera,
          () => scene.captureConfirmations == 1,
        );
        expect(captures, 1);
        feedbackNow = firstSignalAt.add(const Duration(milliseconds: 300));
        await quickFrame();
        await quickFrame();
        expect(captures, 1);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        scene.additionalCrops = <ScanCrop>[
          _automaticCard(
            readable: false,
            corners: const <ScanPoint>[
              ScanPoint(.60, .20),
              ScanPoint(.82, .20),
              ScanPoint(.82, .65),
              ScanPoint(.60, .65),
            ],
          ),
        ];
        for (int frame = 0; frame < 8 && captures < 2; frame++) {
          await quickFrame();
        }
        await _until(tester, () => captures == 2);
        expect(scene.captureConfirmations, 1);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(2),
        );
        for (
          int frame = 0;
          frame < 5 &&
              tester
                      .widget<LiveCaptureOverlay>(
                        find.byType(LiveCaptureOverlay),
                      )
                      .safeToMovePhotoRegions
                      .length <
                  2;
          frame++
        ) {
          await quickFrame();
        }
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .safeToMovePhotoRegions,
          hasLength(2),
          reason: 'Both saved sources must pass framing and appearance proof inside the sound cooldown.',
        );
        expect(
          feedbackNow.difference(firstSignalAt),
          lessThan(ScanCaptureFeedback.signalGracePeriod),
        );
        expect(scene.captureConfirmations, 1);
        feedbackNow = firstSignalAt.add(ScanCaptureFeedback.signalGracePeriod);
        await quickFrame();
        expect(captures, 2);
        expect(scene.captureConfirmations, 1);
        scene.additionalCrops.add(
          _automaticCard(
            readable: false,
            corners: const <ScanPoint>[
              ScanPoint(.35, .20),
              ScanPoint(.55, .20),
              ScanPoint(.55, .65),
              ScanPoint(.35, .65),
            ],
          ),
        );
        await _automaticUntil(
          tester,
          camera,
          () => scene.captureConfirmations == 2,
        );
        expect(captures, 3);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(3),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        session.dispose();
        restore();
      }
    },
  );
  testWidgets(
    'saved photo survives removal and camera close while catalog is pending',
    (WidgetTester tester) async {
      final Directory directory = (await tester.runAsync<Directory>(
        () => Directory.systemTemp.createTemp('collector-photo-first-'),
      ))!;
      Hive.init(directory.path);
      final File source = File('${directory.path}/camera.jpg')
        ..writeAsBytesSync(<int>[255, 216, 1, 2, 3, 255, 217]);
      final _AutomaticScene scene = _AutomaticScene();
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera()..picturePath = source.path;
      final Map<String, Object?> fixture = jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final MtgCard card = MtgCard.fromJson(<String, Object?>{
        ...fixture,
        'name': 'Lightning Bolt',
        'type_line': 'Instant',
        'oracle_text': 'Lightning Bolt deals 3 damage to any target.',
        'set': 'm11',
        'collector_number': '149',
        'artist': 'Christopher Moeller',
        'image_uris': null,
        'illustration_id': null,
        'layout': 'normal',
        'card_faces': null,
      });
      final _DeferredPhotoCatalog catalog = _DeferredPhotoCatalog(card: card);
      final _SavedSourceRecognizer recognizer = _SavedSourceRecognizer(
        scene.crop,
      );
      final ScanDraftStore store = ScanDraftStore(
        userId: 'photo-first-removal',
      );
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: ScanResolver(catalog: catalog),
        store: store,
      );
      final _CaptureHaptics haptics = _CaptureHaptics();
      haptics.install();
      bool dismissed = false;
      final Completer<bool> acknowledgement = Completer<bool>();
      ({
        List<String> paths,
        List<List<ScanPoint>> exclusions,
        String captureId,
        List<List<ScanPoint>>? targets,
      })?
      handoff;
      try {
        await tester.runAsync(session.load);
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> exclusions,
                String captureId,
                List<List<ScanPoint>>? targets,
              ) {
                handoff = (
                  paths: paths,
                  exclusions: exclusions,
                  captureId: captureId,
                  targets: targets,
                );
                return acknowledgement.future;
              },
        );
        await _automaticUntil(tester, camera, () => handoff != null);
        expect(haptics.lightImpacts, 0);
        expect(source.existsSync(), isTrue);
        final bool saved = (await tester.runAsync(
          () => session.addFocusStack(
            handoff!.paths,
            ownedCameraSource: true,
            captureId: handoff!.captureId,
            targetRegions: handoff!.targets,
            excludedRegions: handoff!.exclusions,
          ),
        ))!;
        expect(saved, isTrue);
        acknowledgement.complete(saved);
        await _until(tester, () => recognizer.paths.isNotEmpty);
        expect(haptics.lightImpacts, 0);
        expect(
          session.pendingPhotoCaptures,
          1,
          reason: 'The active saved source still counts while OCR is blocked.',
        );
        expect(catalog.gate.isCompleted, isFalse);
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .safeToMoveTrackIds,
          isEmpty,
        );
        expect(
          source.existsSync(),
          isFalse,
          reason: 'The camera cache can disappear only after durable managed pixels exist.',
        );
        await _until(tester, () => recognizer.paths.isNotEmpty);
        final String managed = recognizer.paths.single;
        expect(File(managed).readAsBytesSync(), <int>[
          255,
          216,
          1,
          2,
          3,
          255,
          217,
        ]);
        expect(
          session.items.every(
            (ScanSessionItem item) => item.resolution == null,
          ),
          isTrue,
        );
        scene.showCards = false;
        await _automaticPulse(tester, camera);
        await _dismissCamera(tester, camera);
        dismissed = true;
        recognizer.gate.complete();
        catalog.gate.complete();
        for (
          int attempt = 0;
          attempt < 200 &&
              (session.items.length != 1 ||
                  session.items.single.resolution == null);
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(session.items, hasLength(1));
        expect(session.items.single.resolution, isNotNull);
        expect(session.items.single.printing!.id, catalog.card.id);
        expect(session.items.single.crop.imagePath, isNotEmpty);
        expect(File(session.items.single.crop.imagePath).existsSync(), isTrue);
        expect(camera.actions.where((String a) => a == 'photo'), hasLength(1));
        expect(haptics.lightImpacts, 0);
        List<ScanDraftItem>? persisted;
        Object? readError;
        bool readFinished = false;
        unawaited(
          store.readItems().then<void>(
            (List<ScanDraftItem> items) {
              persisted = items;
              readFinished = true;
            },
            onError: (Object error, StackTrace stack) {
              readError = error;
              readFinished = true;
            },
          ),
        );
        for (
          int attempt = 0;
          attempt < 200 && (!readFinished || session.running);
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(readFinished, isTrue);
        expect(readError, isNull);
        expect(persisted, isNotNull);
        expect(persisted, hasLength(1));
        expect(persisted!.single.crop.imagePath, isNotEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        if (!acknowledgement.isCompleted) acknowledgement.complete(false);
        if (!catalog.gate.isCompleted) catalog.gate.complete();
        if (!recognizer.gate.isCompleted) recognizer.gate.complete();
        if (!dismissed) await _dismissCamera(tester, camera);
        session.dispose();
        haptics.restore();
        restore();
        bool closed = false;
        Object? closeError;
        unawaited(
          Hive.close().then<void>(
            (_) {
              closed = true;
            },
            onError: (Object error, StackTrace stack) {
              closeError = error;
              closed = true;
            },
          ),
        );
        for (int attempt = 0; attempt < 200 && !closed; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(
          closed,
          isTrue,
          reason: 'Hive cleanup must drain in bounded time.',
        );
        expect(closeError, isNull);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
  for (final String framing in <String>[
    'full outline',
    'weak title',
    'weak footer',
    'footer in artwork',
    'missing outline',
  ]) {
    testWidgets(
      'saved basic-land framing with $framing keeps print uncertainty separate',
      (WidgetTester tester) async {
        final _AutomaticScene scene = _AutomaticScene()
          ..crop = _automaticCard(readable: false)
          ..rawAppearanceSupported = true;
        final VoidCallback restore = scene.install();
        final _Camera camera = _Camera();
        final _CaptureHaptics haptics = _CaptureHaptics()..install();
        final _ControlledSession session = _ControlledSession(
          recognizer: _UnusedRecognizer(),
          resolver: _NoLiveIdentityResolver(),
        );
        int captures = 0;
        try {
          await _show(
            tester,
            camera,
            automaticCapture: true,
            session: session,
            onUnidentifiedPhotoCaptured:
                (
                  List<String> paths,
                  List<List<ScanPoint>> excluded,
                  String captureId,
                  List<List<ScanPoint>> targets,
                ) async {
                  captures++;
                  _publishSavedPhotoCards(session, paths, captureId, <ScanCrop>[
                    ScanCrop(
                      imagePath: '',
                      width: 2650,
                      height: 4096,
                      rectified: true,
                      sourceCorners: targets.single,
                      warnings: <String>[
                        'border_recovered',
                        'partial_card',
                        'unread_footer',
                        if (framing != 'missing outline') 'basic_land_outline',
                      ],
                      lines: <ScanTextLine>[
                        ScanTextLine(
                          text: 'Snow-Covered Swamp',
                          confidence: framing == 'weak title' ? .5 : 1,
                          bounds: const ScanBounds(.066, .041, .57, .034),
                        ),
                        const ScanTextLine(
                          text: 'Basic Snow Land',
                          confidence: 1,
                          bounds: ScanBounds(.061, .825, .37, .051),
                        ),
                        ScanTextLine(
                          text: '82//254',
                          confidence: framing == 'weak footer' ? .2 : .30,
                          bounds: ScanBounds(
                            .046,
                            framing == 'footer in artwork' ? .45 : .9475,
                            .151,
                            .01875,
                          ),
                        ),
                      ],
                    ),
                  ]);
                  return true;
                },
          );
          await _automaticUntil(tester, camera, () => captures == 1);
          for (int frame = 0; frame < 3; frame++) {
            await _automaticPulse(tester, camera);
          }
          final bool complete = framing == 'full outline';
          expect(haptics.lightImpacts, complete ? 1 : 0);
          expect(scene.captureConfirmations, complete ? 1 : 0);
          expect(
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .safeToMovePhotoRegions,
            hasLength(complete ? 1 : 0),
          );
          expect(captures, 1);
          expect(session.items.single.crop.lines.last.text, '82//254');
          expect(session.items.single.crop.warnings, contains('unread_footer'));
          expect(
            session.items.single.resolution!.status,
            ScanResolutionStatus.needsReview,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await _dismissCamera(tester, camera);
          session.dispose();
          haptics.restore();
          restore();
        }
      },
    );
  }
  for (final String defect in <String>[
    'no_text',
    'incomplete_card',
    'capture_ownership_uncertain',
    'art_only',
  ]) {
    testWidgets('saved $defect remains silent without blocking another card', (
      WidgetTester tester,
    ) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _CaptureHaptics haptics = _CaptureHaptics()..install();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      int captures = 0;
      LiveCaptureOverlay overlay() =>
          tester.widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay));
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                _publishSavedPhotoCards(
                  session,
                  paths,
                  captureId,
                  targets.map((List<ScanPoint> corners) {
                    final ScanCrop good = _automaticCard(corners: corners);
                    if (corners.first.x > .5) return good;
                    return ScanCrop(
                      imagePath: '',
                      width: good.width,
                      height: good.height,
                      rectified: true,
                      sourceCorners: corners,
                      warnings: defect == 'art_only'
                          ? const <String>[]
                          : <String>[defect],
                      lines: defect == 'no_text'
                          ? const <ScanTextLine>[]
                          : defect == 'art_only'
                          ? const <ScanTextLine>[
                              ScanTextLine(
                                text: 'Clouds over a mountain',
                                confidence: .99,
                                bounds: ScanBounds(.1, .4, .8, .03),
                              ),
                            ]
                          : good.lines,
                    );
                  }),
                );
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => captures == 1);
        for (int frame = 0; frame < 3; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(captures, 1);
        expect(haptics.lightImpacts, 0);
        expect(scene.captureConfirmations, 0);
        expect(overlay().retainedPhotoRegions, hasLength(1));
        expect(overlay().safeToMovePhotoRegions, isEmpty);
        expect(overlay().safeToMoveTrackIds, isEmpty);
        expect(find.text('Hold steady'), findsOneWidget);
        scene.additionalCrops = <ScanCrop>[
          _automaticCard(
            readable: false,
            corners: const <ScanPoint>[
              ScanPoint(.60, .20),
              ScanPoint(.82, .20),
              ScanPoint(.82, .65),
              ScanPoint(.60, .65),
            ],
          ),
        ];
        await _automaticUntil(tester, camera, () => captures == 2);
        await _automaticUntil(tester, camera, () => haptics.lightImpacts == 1);
        expect(session.items, hasLength(2));
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(2),
        );
        expect(overlay().retainedPhotoRegions, hasLength(2));
        expect(overlay().safeToMovePhotoRegions, hasLength(1));
        expect(scene.captureConfirmations, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        session.dispose();
        haptics.restore();
        restore();
      }
    });
  }
  for (final bool stack in <bool>[false, true]) {
    testWidgets(
      '${stack ? "tracked" : "single"} source save and retry keep the shutter owner after session replacement',
      (WidgetTester tester) async {
        final _AutomaticScene scene = _AutomaticScene();
        final VoidCallback restore = scene.install();
        final _CaptureHaptics haptics = _CaptureHaptics()..install();
        final _Camera camera = _Camera()..pendingPicture = Completer<XFile>();
        final _ControlledSession original = _ControlledSession(
          recognizer: _UnusedRecognizer(),
          resolver: _NoLiveIdentityResolver(),
        );
        final _ControlledSession replacement = _ControlledSession(
          recognizer: _UnusedRecognizer(),
          resolver: _NoLiveIdentityResolver(),
        );
        final List<List<String>> originals = <List<String>>[];
        final List<String> captureIds = <String>[];
        final List<List<List<ScanPoint>>?> targetSets =
            <List<List<ScanPoint>>?>[];
        int replacementCalls = 0;
        bool accept = false;
        Future<bool> saveOriginal(
          List<String> paths,
          String captureId,
          List<List<ScanPoint>>? targets,
        ) async {
          originals.add(List<String>.of(paths));
          captureIds.add(captureId);
          targetSets.add(targets);
          if (!accept) return false;
          _refinePhotoObservation(
            original,
            scene.crop,
            id: 'owned-source',
            photoId: '${captureId}_0',
          );
          return true;
        }

        GuidedCameraScreen screen(ScanSession owner, bool initial) =>
            GuidedCameraScreen(
              session: owner,
              automaticCapture: true,
              multipleCards: stack,
              onCaptured: stack
                  ? null
                  : (String path, List<List<ScanPoint>> exclusions) async {
                      if (!initial) {
                        replacementCalls++;
                        return true;
                      }
                      return saveOriginal(
                        <String>[path],
                        'single-origin',
                        null,
                      );
                    },
              onFocusStackCaptured: !stack
                  ? null
                  : (
                      List<String> paths,
                      List<List<ScanPoint>> exclusions,
                      String captureId,
                      List<List<ScanPoint>>? targets,
                    ) async {
                      if (!initial) {
                        replacementCalls++;
                        return true;
                      }
                      return saveOriginal(paths, captureId, targets);
                    },
            );
        final ValueNotifier<GuidedCameraScreen> updates =
            ValueNotifier<GuidedCameraScreen>(screen(original, true));
        try {
          await _show(
            tester,
            camera,
            automaticCapture: true,
            session: original,
            cameraUpdates: updates,
          );
          await _automaticUntil(
            tester,
            camera,
            () => camera.actions.contains('photo'),
          );
          expect(originals, isEmpty);
          updates.value = screen(replacement, false);
          await tester.pump();
          camera.pendingPicture!.complete(
            XFile('/tmp/owned-shutter-${stack ? "stack" : "single"}.jpg'),
          );
          await _until(
            tester,
            () =>
                originals.length == 1 &&
                find.text('Retry save').evaluate().isNotEmpty,
          );
          expect(replacementCalls, 0);
          expect(original.items, isEmpty);
          expect(replacement.items, isEmpty);
          expect(haptics.lightImpacts, 0);
          accept = true;
          await tester.tap(find.text('Retry save'));
          await _until(
            tester,
            () =>
                originals.length == 2 &&
                find.text('Retry save').evaluate().isEmpty,
          );
          expect(originals.first, originals.last);
          expect(captureIds.toSet(), hasLength(1));
          if (stack) {
            expect(targetSets, everyElement(hasLength(1)));
            expect(
              targetSets.first!.single.map(
                (ScanPoint point) => (point.x, point.y),
              ),
              scene.crop.sourceCorners.map(
                (ScanPoint point) => (point.x, point.y),
              ),
            );
          }
          expect(original.items.single.crop.imagePath, isNotEmpty);
          expect(replacement.items, isEmpty);
          expect(replacementCalls, 0);
          expect(
            camera.actions.where((String action) => action == 'photo'),
            hasLength(1),
          );
          final LiveCaptureOverlay overlay = tester.widget<LiveCaptureOverlay>(
            find.byType(LiveCaptureOverlay),
          );
          expect(overlay.safeToMoveTrackIds, isEmpty);
          expect(overlay.safeToMovePhotoRegions, isEmpty);
          expect(overlay.retainedPhotoRegions, isEmpty);
          expect(
            overlay.tracks.every((LiveScanTrack track) => !track.captured),
            isTrue,
          );
          expect(haptics.lightImpacts, 0);
          expect(tester.takeException(), isNull);
        } finally {
          if (!camera.pendingPicture!.isCompleted) {
            camera.pendingPicture!.completeError(
              PlatformException(code: 'cancelled'),
            );
          }
          await _dismissCamera(tester, camera);
          updates.dispose();
          original.dispose();
          replacement.dispose();
          haptics.restore();
          restore();
        }
      },
    );
  }
  testWidgets(
    'discarded owned raw region gets bounded rediscovery without a shutter or duplicate rows',
    (WidgetTester tester) async {
      final ScanCrop unread = _automaticCard(readable: false);
      final ScanCrop readable = _automaticCard(
        corners: const <ScanPoint>[
          ScanPoint(.65, .2),
          ScanPoint(.87, .2),
          ScanPoint(.87, .65),
          ScanPoint(.65, .65),
        ],
      );
      final _AutomaticScene scene = _AutomaticScene()..crop = unread;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: _AutomaticCatalog()),
      );
      addTearDown(session.dispose);
      List<String>? paths;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> captured,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>>? targetRegions,
              ) async {
                paths = List<String>.of(captured);
                _refinePhotoObservation(
                  session,
                  readable,
                  id: 'saved-readable-source',
                  photoId: '${captureId}_0',
                );
                return true;
              },
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.exclusions.length == 1);
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.nativeFocusPoints.length == 1);
        scene.additionalCrops = <ScanCrop>[readable];
        await _automaticUntil(tester, camera, () => paths != null);
        List<LiveScanTrack> tracks() => tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks;
        await _until(
          tester,
          () => tracks().any((LiveScanTrack track) => track.captured),
        );
        await tester.pump(const Duration(seconds: 4));
        await _until(tester, () => scene.nativeFocusPoints.length == 2);
        final String group = session.captureGroup(paths!);
        await _until(tester, () => session.items.isNotEmpty);
        expect(session.items, hasLength(1));
        expect(session.items.single.liveIdentityName, isNull);
        expect(session.items.single.crop.imagePath, isNotEmpty);
        session.rawRegions[group] = <List<ScanPoint>>[readable.sourceCorners];
        session.rawCompletedGroups.add(group);
        session.changed();
        final int photos = camera.actions
            .where((String action) => action == 'photo')
            .length;
        await _automaticPulse(tester, camera);
        expect(
          scene.nativeFocusPoints,
          hasLength(2),
          reason: 'An existing selected review item cannot earn rediscovery.',
        );
        final ScanCrop foreign = _automaticCard(
          readable: false,
          corners: const <ScanPoint>[
            ScanPoint(.4, .1),
            ScanPoint(.6, .1),
            ScanPoint(.6, .4),
            ScanPoint(.4, .4),
          ],
        );
        scene.geometryCrops = <ScanCrop>[foreign];
        session.rawRegions[group] = <List<ScanPoint>>[foreign.sourceCorners];
        session.changed();
        await _automaticPulse(tester, camera);
        expect(
          scene.nativeFocusPoints,
          hasLength(2),
          reason:
              'Geometry not present at the owned shutter cannot grant a probe.',
        );
        scene.geometryCrops = <ScanCrop>[unread];
        session.rawRegions[group] = <List<ScanPoint>>[
          unread.sourceCorners,
          readable.sourceCorners,
        ];
        await _automaticPulse(tester, camera);
        session.changed();
        expect(
          scene.nativeFocusPoints,
          hasLength(2),
          reason: 'Competing current native observations cannot grant ambiguous rediscovery.',
        );
        scene.geometryCrops = <ScanCrop>[];
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.nativeFocusPoints.length == 3);
        expect(scene.nativeFocusPoints.last.dx, closeTo(.21, .001));
        for (int frame = 0; frame < 7; frame++) {
          session.changed();
          await _automaticPulse(tester, camera);
        }
        expect(
          scene.nativeFocusPoints,
          hasLength(4),
          reason: 'Only two extra probes are allowed despite repeated completion notifications.',
        );
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(photos),
        );
        expect(session.items, hasLength(1));
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );
  testWidgets(
    'new stable geometry gets one immediate discovery probe before the periodic timer',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      try {
        await _show(tester, camera, automaticCapture: true);
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.exclusions.length == 1);
        expect(
          scene.nativeFocusPoints,
          isEmpty,
          reason: 'One observation is insufficient.',
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.nativeFocusPoints.length == 1);
        expect(scene.exclusions, hasLength(2));
        expect(scene.nativeSingleShotRequests, <bool>[false]);
        expect(
          scene.nativeFocusPoints,
          hasLength(1),
          reason: 'No four-second timer tick was pumped.',
        );
        final Offset focused = scene.nativeFocusPoints.single;
        for (int frame = 0; frame < 4; frame++) {
          scene.crop = _automaticCard(
            readable: false,
            corners: <ScanPoint>[
              for (final ScanPoint point in scene.crop.sourceCorners)
                ScanPoint(point.x + .001, point.y),
            ],
          );
          await _automaticPulse(tester, camera);
        }
        expect(scene.nativeFocusPoints, <Offset>[
          focused,
        ], reason: 'Geometry jitter cannot reset the first-probe budget.');
        expect(
          camera.actions.where((String action) => action == 'photo'),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'continuous sweep discovery preserves explicit focus lock and manual tap focus',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      try {
        await _show(tester, camera, automaticCapture: true);
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.nativeFocusPoints.length == 1);
        for (int sample = 0; sample < 6; sample++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(scene.nativeSingleShotRequests, <bool>[false]);
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-adjustments')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-focus-lock')),
        );
        await tester.pump();
        expect(camera.actions, contains('focus locked'));
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-adjustments')),
        );
        await tester.pumpAndSettle();
        scene.crop = _automaticCard(
          readable: false,
          corners: const <ScanPoint>[
            ScanPoint(.6, .2),
            ScanPoint(.82, .2),
            ScanPoint(.82, .65),
            ScanPoint(.6, .65),
          ],
        );
        await _automaticPulse(tester, camera);
        await _automaticPulse(tester, camera);
        expect(scene.nativeSingleShotRequests, <bool>[false]);
        final Finder preview = find.byWidgetPredicate(
          (Widget widget) =>
              widget is ColoredBox && widget.color == const Color(0xff202020),
        );
        await tester.tap(preview);
        await tester.pump();
        await _until(tester, () => scene.nativeFocusPoints.length == 2);
        expect(scene.nativeSingleShotRequests, <bool>[false, false]);
        expect(
          find.bySemanticsLabel('Lock focus'),
          findsNothing,
          reason: 'The optics tray is closed after manual tap focus.',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  for (final String barrier in <String>['manual focus', 'pause', 'controls']) {
    testWidgets('immediate discovery respects $barrier', (
      WidgetTester tester,
    ) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      try {
        await _show(tester, camera, automaticCapture: true);
        if (barrier == 'manual focus') {
          final Finder preview = find.byWidgetPredicate(
            (Widget widget) =>
                widget is ColoredBox && widget.color == const Color(0xff202020),
          );
          await tester.tapAt(tester.getCenter(preview));
        } else {
          await tester.tap(
            find.byKey(
              ValueKey<String>(
                barrier == 'pause' ? 'camera-auto-pause' : 'camera-adjustments',
              ),
            ),
          );
        }
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        final int before = scene.nativeFocusPoints.length;
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(scene.nativeFocusPoints, hasLength(before));
        expect(
          camera.actions.where((String action) => action == 'photo'),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    });
  }

  testWidgets(
    'strong capture readiness and its pending durable save take precedence over discovery',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene();
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final Completer<bool> acknowledgement = Completer<bool>();
      bool saving = false;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          onCaptured: (String path, List<List<ScanPoint>> excludedRegions) {
            saving = true;
            return acknowledgement.future;
          },
        );
        await _automaticUntil(tester, camera, () => saving);
        expect(
          scene.nativeFocusPoints,
          isEmpty,
          reason: 'The stable readable card captures before a discovery probe.',
        );
        final int photos = camera.actions
            .where((String action) => action == 'photo')
            .length;
        scene.geometryCrops = <ScanCrop>[
          _automaticCard(
            readable: false,
            corners: const <ScanPoint>[
              ScanPoint(.65, .2),
              ScanPoint(.85, .2),
              ScanPoint(.85, .5),
              ScanPoint(.65, .5),
            ],
          ),
        ];
        for (int frame = 0; frame < 3; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          scene.nativeFocusPoints,
          isEmpty,
          reason: 'Discovery cannot compete with the active save.',
        );
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(photos),
        );
      } finally {
        if (!acknowledgement.isCompleted) acknowledgement.complete(false);
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadCollectorFonts);
  test(
    'capture exclusions retain exact coverage and defer above eight regions',
    () {
      List<ScanPoint> quad(double x, double y, double width, double height) =>
          <ScanPoint>[
            ScanPoint(x, y),
            ScanPoint(x + width, y),
            ScanPoint(x + width, y + height),
            ScanPoint(x, y + height),
          ];
      final List<ScanPoint> original = quad(.1, .1, .2, .3);
      final List<ScanPoint> inside = quad(.12, .12, .15, .2);
      final List<ScanPoint> drifted = quad(.11, .1, .2, .3);
      final List<List<ScanPoint>> protected =
          GuidedCameraScreen.freezeCaptureExclusions(<List<ScanPoint>>[
            inside,
            original,
            drifted,
            original,
          ])!;
      expect(protected, hasLength(2));
      expect(protected[0], orderedEquals(original));
      expect(protected[1], orderedEquals(drifted));
      expect(
        protected.expand((List<ScanPoint> region) => region),
        everyElement(isIn(<ScanPoint>[...original, ...drifted])),
        reason: 'Partial overlap cannot become a larger enclosing exclusion.',
      );
      final List<List<ScanPoint>> separate = <List<ScanPoint>>[
        for (int index = 0; index < 9; index++)
          quad(.01 + (index % 3) * .3, .01 + (index ~/ 3) * .3, .1, .2),
      ];
      expect(
        GuidedCameraScreen.freezeCaptureExclusions(separate.take(8)),
        hasLength(8),
      );
      expect(GuidedCameraScreen.freezeCaptureExclusions(separate), isNull);
      expect(() => protected.add(original), throwsUnsupportedError);
    },
  );
  testWidgets(
    'automatic focus-stack failure saves its completed photo and retains the capture receipt',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..additionalCrops = <ScanCrop>[
          _automaticCard(
            corners: const <ScanPoint>[
              ScanPoint(.58, .2),
              ScanPoint(.8, .2),
              ScanPoint(.8, .65),
              ScanPoint(.58, .65),
            ],
          ),
        ];
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _AutomaticCatalog catalog = _AutomaticCatalog();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: catalog),
      );
      addTearDown(session.dispose);
      List<String>? saved;
      camera.beforePicture = () {
        camera.failCapture = camera.actions.contains('photo');
      };
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          stationaryFocusStack: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excludedRegions,
                String captureId,
                List<List<ScanPoint>>? targetRegions,
              ) async {
                saved = List<String>.of(paths);
                final String group = captureId;
                final List<ScanCrop> savedCrops = <ScanCrop>[
                  scene.crop,
                  ...scene.additionalCrops,
                ];
                for (int index = 0; index < savedCrops.length; index++) {
                  _refinePhotoObservation(
                    session,
                    savedCrops[index],
                    id: 'partial-saved-$index',
                    photoId: '${group}_0',
                  ).resolution = ScanResolution(
                    candidates: <ScanCandidate>[
                      ScanCandidate(catalog.card, const <ScanEvidence>{
                        ScanEvidence.nameMatch,
                      }),
                    ],
                    hints: ScanHints.fromCrop(savedCrops[index]),
                    status: ScanResolutionStatus.needsReview,
                  );
                }
                session.changed();
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => saved != null);
        expect(saved, hasLength(1));
        List<LiveScanTrack> tracks() => tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks;
        await _until(
          tester,
          () => tracks().any((LiveScanTrack track) => track.capturedIdentified),
        );
        expect(
          find.text('Retry save'),
          findsNothing,
          reason: 'The completed first photo saves automatically.',
        );
        final int attempted = camera.actions
            .where((String action) => action == 'photo')
            .length;
        expect(
          attempted,
          2,
          reason: 'Two distinct card focus targets exercise failure on the second photo.',
        );
        for (int frame = 0; frame < 8; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(attempted),
        );
        expect(tracks(), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );
  testWidgets(
    'automatic stable cards capture without a shutter, respect pause, and retire saved green cards without reshooting',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene();
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _AutomaticCatalog catalog = _AutomaticCatalog();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: catalog),
      );
      addTearDown(session.dispose);
      final Completer<bool> acknowledgement = Completer<bool>();
      List<String>? capturedPaths;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excludedRegions,
                String captureId,
                List<List<ScanPoint>>? targetRegions,
              ) {
                capturedPaths = List<String>.of(paths);
                return acknowledgement.future.then((bool saved) {
                  if (saved) {
                    final ScanSessionItem item = _refinePhotoObservation(
                      session,
                      scene.crop,
                      id: 'saved-ack',
                      photoId: '${captureId}_0',
                    );
                    item.resolution = ScanResolution(
                      candidates: <ScanCandidate>[
                        ScanCandidate(catalog.card, const <ScanEvidence>{
                          ScanEvidence.nameMatch,
                        }),
                      ],
                      hints: ScanHints.fromCrop(scene.crop),
                      status: ScanResolutionStatus.needsReview,
                    );
                    session.changed();
                  }
                  return saved;
                });
              },
        );
        expect(
          find.byKey(const ValueKey<String>('camera-shutter')),
          findsNothing,
        );
        expect(find.text('Capture photo'), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-auto-pause')),
        );
        await tester.pump();
        expect(find.text('Paused'), findsOneWidget);
        for (int frame = 0; frame < 5; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          camera.actions.where((String action) => action == 'photo'),
          isEmpty,
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-auto-pause')),
        );
        await tester.pump();
        await _automaticUntil(tester, camera, () => capturedPaths != null);
        expect(
          capturedPaths,
          hasLength(1),
          reason: 'One new card needs one focused photo.',
        );
        expect(
          camera.actions.where((String action) => action == 'photo').length,
          capturedPaths!.length,
        );
        List<LiveScanTrack> tracks() => tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks;
        expect(acknowledgement.isCompleted, isFalse);
        expect(session.items, isEmpty);
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .safeToMoveTrackIds,
          isEmpty,
        );
        acknowledgement.complete(true);
        await _until(
          tester,
          () => tracks().any((LiveScanTrack track) => track.captured),
        );
        await _until(
          tester,
          () => tracks().any((LiveScanTrack track) => track.capturedIdentified),
        );
        expect(session.items, hasLength(1));
        expect(session.items.single.liveIdentityName, isNull);
        expect(
          session.items.single.resolution!.status,
          ScanResolutionStatus.needsReview,
        );
        expect(
          session.captureReadComplete(capturedPaths!),
          isTrue,
          reason: 'The synthetic saved-photo reader completed independently of live text.',
        );
        final int photos = camera.actions
            .where((String action) => action == 'photo')
            .length;
        for (int frame = 0; frame < 3; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          scene.exclusions.any((List<Object?> regions) => regions.isNotEmpty),
          isTrue,
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 3300)),
        );
        await tester.pump();
        for (int frame = 0; frame < 5; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          tracks(),
          isEmpty,
          reason: 'Completed cards leave active AR after their brief acknowledgement.',
        );
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(photos),
          reason: 'The same mounted physical card remains excluded after its green label retires.',
        );
        scene.geometryCrops = <ScanCrop>[
          _automaticCard(
            readable: false,
            corners: const <ScanPoint>[
              ScanPoint(.58, .2),
              ScanPoint(.8, .2),
              ScanPoint(.8, .65),
              ScanPoint(.58, .65),
            ],
          ),
        ];
        final int previousFocus = scene.nativeFocusPoints.length;
        for (int frame = 0; frame < 12; frame++) {
          await _automaticPulse(tester, camera);
          await tester.pump(const Duration(seconds: 2));
        }
        final List<Offset> probes = scene.nativeFocusPoints
            .skip(previousFocus)
            .toList();
        expect(
          probes,
          isNotEmpty,
          reason: 'A saved foreground card cannot block background focus discovery.',
        );
        expect(probes.length, lessThanOrEqualTo(2));
        expect(
          probes.every(
            (Offset point) =>
                (point.dx - .69).abs() < .001 && (point.dy - .425).abs() < .001,
          ),
          isTrue,
        );
        expect(
          tracks(),
          isEmpty,
          reason: 'Geometry probes are not identified cards.',
        );
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(photos),
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!acknowledgement.isCompleted) {
          acknowledgement.complete(true);
        }
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'temporary correction suspension releases the camera and preserves mounted-card ownership after fresh resume observations',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _AutomaticCatalog catalog = _AutomaticCatalog();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: catalog),
      );
      addTearDown(session.dispose);
      int captures = 0;
      GuidedCameraScreen screen({required bool active}) => GuidedCameraScreen(
        active: active,
        automaticCapture: true,
        multipleCards: true,
        session: session,
        onFocusStackCaptured:
            (
              List<String> paths,
              List<List<ScanPoint>> excludedRegions,
              String captureId,
              List<List<ScanPoint>>? targetRegions,
            ) async {
              captures++;
              session.rememberCapture(paths, captureId);
              final ScanSessionItem saved = _refinePhotoObservation(
                session,
                scene.crop,
                id: 'mounted-before-correction-$captures',
                photoId: '${captureId}_0',
              );
              saved.resolution = ScanResolution(
                candidates: <ScanCandidate>[
                  ScanCandidate(catalog.card, const <ScanEvidence>{
                    ScanEvidence.nameMatch,
                  }),
                ],
                hints: ScanHints.fromCrop(scene.crop),
                status: ScanResolutionStatus.needsReview,
              );
              session.changed();
              return true;
            },
      );
      final ValueNotifier<GuidedCameraScreen> updates =
          ValueNotifier<GuidedCameraScreen>(screen(active: true));
      addTearDown(updates.dispose);
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          cameraUpdates: updates,
        );
        await _automaticUntil(tester, camera, () => captures == 1);
        await _until(
          tester,
          () => tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .any((LiveScanTrack track) => track.capturedIdentified),
        );
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(session.items, hasLength(1));
        final int photos = camera.actions
            .where((String action) => action == 'photo')
            .length;
        final String savedId = session.items.single.id;

        updates.value = screen(active: false);
        await tester.pump();
        await _until(tester, () => camera.actions.last == 'dispose');
        expect(camera.frames.hasListener, isFalse);
        expect(camera.actions, contains('stream stop'));
        final int observations = scene.textRequests.length;
        for (int frame = 0; frame < 4; frame++) {
          camera.frames.add(_automaticFrame());
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(scene.textRequests, hasLength(observations));
        expect(captures, 1);

        final int requestedAppearances = scene.appearanceRequests.length;
        updates.value = screen(active: true);
        await tester.pump();
        await _until(tester, () => camera.frames.hasListener);
        expect(
          camera.actions.where((String action) => action == 'create wide'),
          hasLength(2),
        );
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(photos),
          reason: 'Reopening cannot capture before a fresh scene observation.',
        );
        for (int frame = 0; frame < 10; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          scene.appearanceRequests
              .skip(requestedAppearances)
              .any((List<Object?> regions) => regions.isNotEmpty),
          isTrue,
          reason: 'The resumed camera rechecks the saved physical footprint.',
        );
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(photos),
          reason: 'Returning from correction does not rescan an unmoved card.',
        );
        expect(captures, 1);
        expect(session.items.map((ScanSessionItem item) => item.id), <String>[
          savedId,
        ]);
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'blurry discovery after a saved receipt keeps the physical lens and duplicate protection',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene();
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _AutomaticCatalog catalog = _AutomaticCatalog();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: catalog),
      );
      addTearDown(session.dispose);
      int captures = 0;
      String? savedId;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> exclusions,
                String captureId,
                List<List<ScanPoint>>? targetRegions,
              ) async {
                captures++;
                final String group = captureId;
                final ScanSessionItem? prior = session
                    .capturedItems(paths)
                    .firstOrNull;
                final ScanSessionItem saved =
                    prior ??
                    ScanSessionItem(
                      scene.crop,
                      id: 'saved-before-blurry-discovery',
                      photoId: '${group}_0',
                    );
                saved.resolution = ScanResolution(
                  candidates: <ScanCandidate>[
                    ScanCandidate(catalog.card, const <ScanEvidence>{
                      ScanEvidence.nameMatch,
                    }),
                  ],
                  hints: ScanHints.fromCrop(scene.crop),
                  status: ScanResolutionStatus.needsReview,
                );
                if (prior == null) session.add(saved);
                savedId = saved.id;
                session.rawCompletedGroups.add(group);
                session.changed();
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => captures == 1);
        await _until(
          tester,
          () => tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .any((LiveScanTrack track) => track.capturedIdentified),
        );
        final String ownerId = tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks
            .singleWhere((LiveScanTrack track) => track.capturedIdentified)
            .id;
        scene.focusLensPosition = 0;
        scene.focusSharpness = .03;
        scene.additionalCrops = <ScanCrop>[
          _automaticCard(
            titleOnly: true,
            corners: const <ScanPoint>[
              ScanPoint(.58, .2),
              ScanPoint(.8, .2),
              ScanPoint(.8, .65),
              ScanPoint(.58, .65),
            ],
          ),
        ];
        List<LiveScanTrack> blurryTracks() => tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks
            .where((LiveScanTrack track) => track.corners.first.x == .58)
            .toList();
        await _automaticUntil(
          tester,
          camera,
          () => blurryTracks().any(
            (LiveScanTrack track) => track.hasCardEvidence && !track.captured,
          ),
        );
        expect(blurryTracks(), hasLength(1));
        expect(blurryTracks().single.hasCardEvidence, isTrue);
        expect(blurryTracks().single.captured, isFalse);
        for (int frame = 0; frame < 8; frame++) {
          await _automaticPulse(tester, camera);
          await tester.pump(const Duration(seconds: 1));
        }
        expect(
          scene.nativeFocusPoints.any(
            (Offset point) =>
                (point.dx - .69).abs() < .001 && (point.dy - .425).abs() < .001,
          ),
          isTrue,
          reason: 'The soft new card still receives autofocus discovery.',
        );
        expect(camera.actions, contains('create wide'));
        expect(camera.actions, isNot(contains('create ultra')));
        expect(camera.actions, isNot(contains('stream stop')));
        expect(blurryTracks(), hasLength(1));
        expect(blurryTracks().single.hasCardEvidence, isTrue);
        expect(blurryTracks().single.captured, isFalse);
        expect(captures, 1);
        expect(session.items, hasLength(1));
        expect(savedId, isNotNull);
        expect(session.items.single.id, savedId);
        final Map<Object?, Object?> owner = scene.appearanceRequests.last
            .cast<Map<Object?, Object?>>()
            .singleWhere(
              (Map<Object?, Object?> region) => region['id'] == ownerId,
            );
        expect(
          (owner['corners']! as List<Object?>).map((Object? value) {
            final Map<Object?, Object?> point = value! as Map<Object?, Object?>;
            return (
              (point['x']! as num).toDouble(),
              (point['y']! as num).toDouble(),
            );
          }),
          scene.crop.sourceCorners.map((ScanPoint point) => (point.x, point.y)),
        );
        for (int attempt = 0; attempt < 3; attempt++) {
          final int previousFrames = scene.textRequests.length;
          await _automaticPulse(tester, camera);
          await _until(
            tester,
            () => scene.textRequests.length > previousFrames,
          );
          if (!scene.textRequests.last) break;
        }
        expect(scene.textRequests.last, isFalse);
        expect(
          scene.exclusions.last.map(
            (Object? value) => (value! as Map<Object?, Object?>)['id'],
          ),
          contains(ownerId),
          reason: 'The original saved physical region keeps its OCR exclusion.',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'a pending saved card requests focus without another photo or premature green, then stops after saved identification',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene();
      final ScanCrop pending = _automaticCard(
        corners: const <ScanPoint>[
          ScanPoint(.58, .2),
          ScanPoint(.8, .2),
          ScanPoint(.8, .65),
          ScanPoint(.58, .65),
        ],
      );
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _AutomaticCatalog catalog = _AutomaticCatalog();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: catalog),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> exclusions,
                String captureId,
                List<List<ScanPoint>>? targetRegions,
              ) async {
                captures++;
                final String group = captureId;
                for (final (int, ScanCrop) source in <(int, ScanCrop)>[
                  (0, scene.crop),
                  (1, pending),
                ]) {
                  _refinePhotoObservation(
                    session,
                    source.$2,
                    id: 'pending-focus-${source.$1}',
                    photoId: '${group}_0',
                  ).resolution = ScanResolution(
                    candidates: <ScanCandidate>[
                      ScanCandidate(catalog.card, const <ScanEvidence>{
                        ScanEvidence.nameMatch,
                      }),
                    ],
                    hints: ScanHints.fromCrop(source.$2),
                    status: ScanResolutionStatus.needsReview,
                  );
                }
                session.changed();
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => captures == 1);
        await _until(
          tester,
          () => tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .any((LiveScanTrack track) => track.capturedIdentified),
        );
        bool pendingFocused() => scene.nativeFocusPoints.any(
          (Offset point) =>
              (point.dx - .69).abs() < .001 && (point.dy - .425).abs() < .001,
        );
        for (int frame = 0; frame < 12 && !pendingFocused(); frame++) {
          await _automaticPulse(tester, camera);
          await tester.pump(const Duration(seconds: 1));
        }
        expect(
          pendingFocused(),
          isTrue,
          reason: 'Saved-photo evidence keeps discovery active after the live outline disappears.',
        );
        expect(captures, 1);
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .where((LiveScanTrack track) => track.capturedIdentified),
          hasLength(lessThanOrEqualTo(1)),
        );
        scene.additionalCrops = <ScanCrop>[pending];
        await _automaticUntil(
          tester,
          camera,
          () => tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .any(
                (LiveScanTrack track) =>
                    track.capturedIdentified &&
                    track.crop.sourceCorners.first.x == .58,
              ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 700)),
        );
        await tester.pump();
        final int focused = scene.nativeFocusPoints.length;
        for (int frame = 0; frame < 8; frame++) {
          await _automaticPulse(tester, camera);
          await tester.pump(const Duration(seconds: 1));
        }
        expect(captures, 1);
        expect(
          scene.nativeFocusPoints,
          hasLength(focused),
          reason: 'Identified saved cards no longer request focus.',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );
  testWidgets(
    'two initial geometry observations save a raw photo before blocked live OCR',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..textGate = Completer<void>();
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: _AutomaticCatalog()),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                expect(paths, hasLength(1));
                expect(targets, hasLength(1));
                expect(
                  targets.single.map((ScanPoint p) => (p.x, p.y)),
                  scene.crop.sourceCorners.map((ScanPoint p) => (p.x, p.y)),
                );
                captures++;
                return true;
              },
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        expect(scene.textRequests, <bool>[false]);
        expect(captures, 0);
        scene.crop = _automaticCard(
          readable: false,
          corners: <ScanPoint>[
            for (final ScanPoint point in scene.crop.sourceCorners)
              ScanPoint(point.x + .004, point.y + .002),
          ],
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 2);
        await _until(tester, () => captures == 1);
        await _until(
          tester,
          () =>
              tester
                  .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                  .retainedPhotoRegions
                  .length ==
              1,
        );
        expect(scene.textRequests, <bool>[false, false]);
        expect(scene.nativeFocusPoints, isEmpty);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          hasLength(1),
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 3);
        expect(scene.textRequests, <bool>[false, false, true]);
        expect(scene.textGate!.isCompleted, isFalse);
        expect(captures, 1);
        expect(session.items, isEmpty);
        expect(camera.actions, isNot(contains('stream stop')));
        expect(tester.takeException(), isNull);
      } finally {
        if (!scene.textGate!.isCompleted) scene.textGate!.complete();
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  testWidgets(
    'two OCR-backed sweep observations capture without a third dwell frame',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene();
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>>? targets,
              ) async {
                expect(paths, hasLength(1));
                captures++;
                return true;
              },
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        expect(captures, 0);
        await _automaticPulse(tester, camera);
        await _until(tester, () => captures == 1);
        expect(scene.textRequests, hasLength(2));
        expect(scene.nativeSingleShotRequests, isEmpty);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  testWidgets(
    'washed title with readable type and rules still receives exposure recovery before a fresh photo',
    (WidgetTester tester) async {
      final ScanCrop complete = _automaticCard();
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = ScanCrop(
          imagePath: '',
          width: complete.width,
          height: complete.height,
          rectified: true,
          sourceCorners: complete.sourceCorners,
          lines: complete.lines
              .where(
                (ScanTextLine line) =>
                    line.bounds.y > .13 && line.bounds.y < .8,
              )
              .toList(),
        )
        ..lighting = _washedLighting;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final ValueNotifier<GuidedCameraScreen> updates =
          ValueNotifier<GuidedCameraScreen>(
            GuidedCameraScreen(automaticCapture: true, session: session),
          );
      addTearDown(updates.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          cameraUpdates: updates,
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        await _until(
          tester,
          () =>
              tester
                  .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                  .tracks
                  .length ==
              1,
        );
        final LiveScanTrack observed = tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks
            .single;
        expect(observed.hasCardEvidence, isTrue);
        expect(observed.hasVerifiedLiveIdentity, isFalse);
        expect(camera.exposureOffsets, isEmpty);
        await _automaticPulse(tester, camera);
        await _until(tester, () => camera.exposureOffsets.length == 1);
        await _until(
          tester,
          () => find.text('Adjusting light…').evaluate().isEmpty,
        );
        expect(camera.exposureOffsets, <double>[-.5]);
        expect(captures, 0);
        expect(camera.actions, isNot(contains('photo')));
        updates.value = GuidedCameraScreen(
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                return true;
              },
        );
        await tester.pump();
        await _automaticPulse(tester, camera);
        await _until(tester, () => captures == 1);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(
          session.items,
          isEmpty,
          reason:
              'Exposure recovery does not invent missing identity evidence.',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  testWidgets(
    'two washed card frames reduce exposure once before the next fresh shutter',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..lighting = _washedLighting;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String id,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                return true;
              },
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        expect(camera.exposureOffsets, isEmpty);
        await _automaticPulse(tester, camera);
        await _until(tester, () => camera.exposureOffsets.isNotEmpty);
        await _until(
          tester,
          () => find.text('Adjusting light…').evaluate().isEmpty,
        );
        expect(camera.exposureOffsets, <double>[-.5]);
        expect(captures, 0);
        expect(camera.actions, isNot(contains('photo')));
        await _automaticPulse(tester, camera);
        await _until(tester, () => captures == 1);
        expect(camera.exposureOffsets, hasLength(1));
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-adjustments')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Exposure -0.5 EV'), findsOneWidget);
        expect(camera.actions, isNot(contains('create ultra')));
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  for (final String condition in <String>[
    'clean',
    'readable',
    'missing stats',
  ]) {
    testWidgets('$condition cards capture without automatic exposure changes', (
      WidgetTester tester,
    ) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: condition == 'readable')
        ..lighting = condition == 'clean'
            ? _normalLighting
            : condition == 'readable'
            ? _washedLighting
            : null;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      Future<bool> raw(
        List<String> paths,
        List<List<ScanPoint>> excluded,
        String id,
        List<List<ScanPoint>> targets,
      ) async {
        captures++;
        return true;
      }

      Future<bool> read(
        List<String> paths,
        List<List<ScanPoint>> excluded,
        String id,
        List<List<ScanPoint>>? targets,
      ) async {
        captures++;
        return true;
      }

      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured: condition == 'readable' ? null : raw,
          onFocusStackCaptured: condition == 'readable' ? read : null,
        );
        await _automaticUntil(tester, camera, () => captures == 1);
        expect(camera.exposureOffsets, isEmpty);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    });
  }

  testWidgets(
    'sustained normal card lighting restores automatic exposure toward neutral',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..lighting = _washedLighting
        ..focusAccepted = false;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      try {
        await _show(tester, camera, automaticCapture: true);
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        await _automaticPulse(tester, camera);
        await _until(tester, () => camera.exposureOffsets.length == 1);
        expect(camera.exposureOffsets.single, -.5);
        scene.lighting = _normalLighting;
        final int beforeCleanFrames = scene.textRequests.length;
        // Restoration needs two seconds of observed clean frames. A fixed
        // six-frame burst can end early when camera work drops a callback.
        await _automaticUntil(
          tester,
          camera,
          () => camera.exposureOffsets.length == 2,
        );
        expect(
          scene.textRequests.length - beforeCleanFrames,
          greaterThanOrEqualTo(3),
        );
        expect(camera.exposureOffsets, <double>[-.5, 0]);
        expect(camera.actions, isNot(contains('photo')));
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  testWidgets(
    'partial-only observations pause restoration while a truly empty scene can restore exposure',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..lighting = _washedLighting
        ..focusAccepted = false;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      try {
        await _show(tester, camera, automaticCapture: true);
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        await _automaticPulse(tester, camera);
        await _until(tester, () => camera.exposureOffsets.length == 1);
        scene
          ..lighting = null
          ..showFocusCandidates = false
          ..cardWarnings = <String>['partial_card'];
        for (int frame = 0; frame < 6; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(camera.exposureOffsets, <double>[-.5]);
        scene.showCards = false;
        for (int frame = 0; frame < 6; frame++) {
          await _automaticPulse(tester, camera);
        }
        await _until(tester, () => camera.exposureOffsets.length == 2);
        expect(camera.exposureOffsets, <double>[-.5, 0]);
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  testWidgets(
    'exposure compensation preserves an already captured neighbor and receipt exclusions',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final List<String> receipts = <String>[];
      final List<List<List<ScanPoint>>> exclusions = <List<List<ScanPoint>>>[];
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String id,
                List<List<ScanPoint>> targets,
              ) async {
                receipts.add(id);
                exclusions.add(excluded);
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => receipts.length == 1);
        await _until(
          tester,
          () =>
              tester
                  .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                  .retainedPhotoRegions
                  .length ==
              1,
        );
        final ScanCrop original = scene.crop;
        scene.additionalCrops = <ScanCrop>[original];
        scene.crop = _automaticCard(
          readable: false,
          corners: const <ScanPoint>[
            ScanPoint(.6, .2),
            ScanPoint(.82, .2),
            ScanPoint(.82, .65),
            ScanPoint(.6, .65),
          ],
        );
        scene.lighting = _washedLighting;
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length >= 3);
        await _automaticPulse(tester, camera);
        await _until(tester, () => camera.exposureOffsets.length == 1);
        expect(receipts, hasLength(1));
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          hasLength(1),
        );
        await _automaticUntil(tester, camera, () => receipts.length == 2);
        await _until(
          tester,
          () =>
              tester
                  .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                  .retainedPhotoRegions
                  .length ==
              2,
        );
        expect(receipts.toSet(), hasLength(2));
        expect(exclusions.last, hasLength(1));
        expect(
          exclusions.last.single.map((ScanPoint p) => (p.x, p.y)),
          original.sourceCorners.map((ScanPoint p) => (p.x, p.y)),
        );
        expect(
          camera.actions.where((String action) => action == 'create wide'),
          hasLength(1),
        );
        expect(camera.actions, isNot(contains('create ultra')));
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  testWidgets(
    'manual exposure queues after held automatic work and persists across controls and resume',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..lighting = _washedLighting
        ..focusAccepted = false;
      final VoidCallback restore = scene.install();
      addTearDown(restore);
      final Completer<double> exposure = Completer<double>();
      final _Camera camera = _Camera()..exposureGate = exposure;
      try {
        await _show(tester, camera, automaticCapture: true);
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        await _automaticPulse(tester, camera);
        await _until(tester, () => camera.exposureOffsets.length == 1);
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-adjustments')),
        );
        await tester.pump();
        final Finder exposureControl = find.bySemanticsLabel('Exposure');
        await tester.ensureVisible(exposureControl);
        await tester.pump();
        final SemanticsNode node = tester.getSemantics(exposureControl);
        node.owner!.performAction(node.id, SemanticsAction.increase);
        await tester.pump();
        expect(find.text('Exposure 0.5 EV'), findsOneWidget);
        expect(
          camera.exposureOffsets,
          <double>[-.5],
          reason:
              'The explicit command waits for the real pending offset call.',
        );
        exposure.complete(-.5);
        await _until(tester, () => camera.exposureOffsets.length == 2);
        expect(camera.exposureOffsets, <double>[-.5, .5]);
        expect(find.text('Exposure 0.5 EV'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-adjustments')),
        );
        await tester.pumpAndSettle();
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(camera.exposureOffsets, hasLength(2));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        await _until(tester, () => camera.actions.last == 'dispose');
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await _until(tester, () => camera.frames.hasListener);
        expect(camera.exposureOffsets, <double>[-.5, .5, .5]);
        for (int frame = 0; frame < 3; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(camera.exposureOffsets, hasLength(3));
        expect(tester.takeException(), isNull);
      } finally {
        if (!exposure.isCompleted) exposure.complete(-.5);
        try {
          await _dismissCamera(tester, camera);
          await tester.pump(const Duration(milliseconds: 200));
        } finally {
          restore();
          semantics.dispose();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
      }
    },
  );

  for (final String interruption in <String>['pause', 'clear', 'lens']) {
    testWidgets('$interruption rejects a late automatic exposure result', (
      WidgetTester tester,
    ) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..lighting = _washedLighting
        ..focusAccepted = false;
      final VoidCallback restore = scene.install();
      final Completer<double> exposure = Completer<double>();
      final _Camera camera = _Camera()..exposureGate = exposure;
      int clears = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          onClearCaptures: () async {
            clears++;
          },
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        await _automaticPulse(tester, camera);
        await _until(tester, () => camera.exposureOffsets.length == 1);
        if (interruption == 'pause') {
          await tester.tap(
            find.byKey(const ValueKey<String>('camera-auto-pause')),
          );
          await tester.pump();
        }
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-adjustments')),
        );
        await tester.pump();
        if (interruption == 'clear') {
          final Finder clear = find.byKey(
            const ValueKey<String>('camera-clear-captures'),
          );
          await tester.ensureVisible(clear);
          await tester.pump();
          await tester.tap(clear);
          await _until(tester, () => clears == 1 && camera.frames.hasListener);
        } else if (interruption == 'lens') {
          await tester.tap(
            find.byKey(const ValueKey<String>('camera-lens-selector')),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.text('Ultra-wide').hitTestable().last);
          await _until(
            tester,
            () =>
                camera.actions.contains('create ultra') &&
                camera.frames.hasListener,
          );
          await tester.pumpAndSettle();
        }
        exposure.complete(-.5);
        await tester.pump();
        await _until(
          tester,
          () => find.text('Adjusting light…').evaluate().isEmpty,
        );
        if (interruption == 'clear') {
          await tester.tap(
            find.byKey(const ValueKey<String>('camera-adjustments')),
          );
          await tester.pump();
        }
        expect(find.text('Exposure 0.0 EV'), findsOneWidget);
        expect(camera.actions, isNot(contains('photo')));
        expect(tester.takeException(), isNull);
      } finally {
        if (!exposure.isCompleted) exposure.complete(-.5);
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    });
  }

  for (final bool held in <bool>[false, true]) {
    testWidgets(
      'unsupported automatic exposure clears its bounded gate and permits shutter held=$held',
      (WidgetTester tester) async {
        final _AutomaticScene scene = _AutomaticScene()
          ..crop = _automaticCard(readable: false)
          ..lighting = _washedLighting;
        final VoidCallback restore = scene.install();
        final Completer<double> exposure = Completer<double>();
        final _Camera camera = _Camera()
          ..failExposure = !held
          ..exposureGate = held ? exposure : null;
        final ScanSession session = ScanSession(
          recognizer: _UnusedRecognizer(),
          resolver: _NoLiveIdentityResolver(),
        );
        addTearDown(session.dispose);
        int captures = 0;
        try {
          await _show(
            tester,
            camera,
            automaticCapture: true,
            session: session,
            onUnidentifiedPhotoCaptured:
                (
                  List<String> paths,
                  List<List<ScanPoint>> excluded,
                  String id,
                  List<List<ScanPoint>> targets,
                ) async {
                  captures++;
                  return true;
                },
          );
          await _automaticPulse(tester, camera);
          await _until(tester, () => scene.textRequests.length == 1);
          await _automaticPulse(tester, camera);
          await _until(tester, () => camera.exposureOffsets.length == 1);
          if (held) await tester.pump(const Duration(milliseconds: 450));
          await _until(
            tester,
            () => find.text('Adjusting light…').evaluate().isEmpty,
          );
          await _automaticPulse(tester, camera);
          await _until(tester, () => captures == 1);
          for (int frame = 0; frame < 3; frame++) {
            await _automaticPulse(tester, camera);
          }
          expect(camera.exposureOffsets, hasLength(1));
          expect(
            camera.actions.where((String action) => action == 'photo'),
            hasLength(1),
          );
          if (held) {
            exposure.complete(-.5);
            await tester.pump();
          }
          expect(tester.takeException(), isNull);
        } finally {
          if (held && !exposure.isCompleted) exposure.complete(-.5);
          await _dismissCamera(tester, camera);
          await tester.pump(const Duration(milliseconds: 200));
          restore();
        }
      },
    );
  }

  testWidgets(
    'blurred near-limit raw contour selects closer optics before shutter and requires new-lens frames',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..focusSharpness = .04
        ..focusLensPosition = .002;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                return true;
              },
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        expect(scene.focusStatusRequests, 0);
        expect(camera.actions, isNot(contains('create ultra')));
        await _automaticPulse(tester, camera);
        await _until(
          tester,
          () =>
              camera.actions.contains('create ultra') &&
              camera.frames.hasListener,
        );
        expect(scene.focusStatusRequests, 1);
        expect(captures, 0);
        expect(camera.actions, isNot(contains('photo')));
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          isEmpty,
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 3);
        expect(
          captures,
          0,
          reason: 'The previous lens cannot lend the second proof frame.',
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => captures == 1);
        expect(scene.nativeFocusPoints, isEmpty);
        expect(
          camera.actions.where((String action) => action == 'create ultra'),
          hasLength(1),
        );
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(
          session.items,
          isEmpty,
          reason: 'Selecting optics does not identify a card.',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  for (final String condition in <String>[
    'sharp',
    'unknown sharpness',
    'nonfinite sharpness',
    'distant focus',
    'unavailable telemetry',
    'adjusting focus',
    'missing closer lens',
    'locked focus',
    'manual tap focus',
  ]) {
    testWidgets('$condition raw geometry retains ordinary optics and shutter', (
      WidgetTester tester,
    ) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..focusSharpness = .04
        ..focusLensPosition = .002;
      switch (condition) {
        case 'sharp':
          scene.focusSharpness = .3;
        case 'unknown sharpness':
          scene.focusSharpness = null;
        case 'nonfinite sharpness':
          scene.focusSharpness = double.nan;
        case 'distant focus':
          scene.focusLensPosition = .5;
        case 'unavailable telemetry':
          scene.focusStatusSupported = false;
        case 'adjusting focus':
          scene.focusAdjusting = true;
        case 'manual tap focus':
          scene.focusStatusPoint = const Offset(.5, .5);
          scene.focusAdjusting = true;
      }
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera()
        ..ultraWideAvailable = condition != 'missing closer lens';
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                return true;
              },
        );
        if (condition == 'locked focus') {
          await tester.tap(
            find.byKey(const ValueKey<String>('camera-adjustments')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey<String>('camera-focus-lock')),
          );
          await tester.pump();
          expect(camera.actions, contains('focus locked'));
          await tester.tap(
            find.byKey(const ValueKey<String>('camera-adjustments')),
          );
          await tester.pumpAndSettle();
        }
        if (condition == 'manual tap focus') {
          final Finder preview = find.byWidgetPredicate(
            (Widget widget) =>
                widget is ColoredBox && widget.color == const Color(0xff202020),
          );
          await tester.tap(preview);
          await tester.pump();
          await _until(tester, () => scene.nativeFocusPoints.length == 1);
        }
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        expect(captures, 0);
        await _automaticPulse(tester, camera);
        await _until(tester, () => captures == 1);
        expect(camera.actions, isNot(contains('create ultra')));
        if (condition == 'manual tap focus') {
          expect(scene.nativeFocusPoints, hasLength(1));
          expect(
            scene.focusStatusRequests,
            0,
            reason: 'Recent tap focus keeps automatic target preflight idle.',
          );
        }
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    });
  }

  testWidgets(
    'a manually chosen wide lens prevents raw preflight from overriding the selection',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..focusSharpness = .04
        ..focusLensPosition = .002;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                return true;
              },
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-adjustments')),
        );
        await tester.pumpAndSettle();
        final Finder lens = find.byKey(
          const ValueKey<String>('camera-lens-selector'),
        );
        await tester.tap(lens);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Ultra-wide').hitTestable().last);
        await _until(
          tester,
          () =>
              camera.actions.contains('create ultra') &&
              camera.frames.hasListener,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(lens);
        await tester.pumpAndSettle();
        await tester.tap(lens);
        await tester.pump(const Duration(milliseconds: 300));
        await _until(
          tester,
          () => find.text('Wide').hitTestable().evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Wide').hitTestable().last);
        await _until(
          tester,
          () =>
              camera.actions
                      .where((String action) => action == 'create wide')
                      .length ==
                  2 &&
              camera.frames.hasListener,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-adjustments')),
        );
        await tester.pumpAndSettle();
        expect(
          lens,
          findsNothing,
          reason:
              'Close the settled optics tray before admitting fresh frames.',
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        await _automaticPulse(tester, camera);
        await _until(tester, () => captures == 1);
        expect(
          camera.actions.where((String action) => action == 'create ultra'),
          hasLength(1),
        );
        expect(scene.focusStatusRequests, 1);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  testWidgets(
    'an owned raw neighbor prevents automatic closer-lens switching for the next card',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                if (captures == 1) {
                  expect(excluded, hasLength(1));
                  expect(
                    excluded.single.map((ScanPoint p) => (p.x, p.y)),
                    scene.additionalCrops.single.sourceCorners.map(
                      (ScanPoint p) => (p.x, p.y),
                    ),
                  );
                }
                captures++;
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => captures == 1);
        await _until(
          tester,
          () =>
              tester
                  .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                  .retainedPhotoRegions
                  .length ==
              1,
        );
        scene.additionalCrops = <ScanCrop>[scene.crop];
        scene.crop = _automaticCard(
          readable: false,
          corners: const <ScanPoint>[
            ScanPoint(.6, .2),
            ScanPoint(.82, .2),
            ScanPoint(.82, .65),
            ScanPoint(.6, .65),
          ],
        );
        scene.focusSharpness = .04;
        scene.focusLensPosition = .002;
        await _automaticUntil(tester, camera, () => captures == 2);
        await _until(
          tester,
          () =>
              tester
                  .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                  .retainedPhotoRegions
                  .length ==
              2,
        );
        expect(camera.actions, isNot(contains('create ultra')));
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(2),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  testWidgets(
    'ambiguous raw contours cannot select closer optics or acquire a receipt',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..focusSharpness = .04
        ..focusLensPosition = .002;
      scene.geometryCrops = <ScanCrop>[scene.crop];
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                return true;
              },
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 2);
        expect(captures, 0);
        expect(camera.actions, isNot(contains('create ultra')));
        expect(camera.actions, isNot(contains('photo')));
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  for (final String unavailable in <String>['rejected', 'unsupported']) {
    testWidgets(
      '$unavailable discovery focus cannot require unavailable raw readiness telemetry',
      (WidgetTester tester) async {
        final _AutomaticScene scene = _AutomaticScene()
          ..crop = _automaticCard(readable: false)
          ..geometryConfidence = .85
          ..focusAccepted = false
          ..focusStatusSupported = false;
        final VoidCallback restore = scene.install();
        final _Camera camera = _Camera()
          ..focusPointSupported = unavailable != 'unsupported';
        final ScanSession session = ScanSession(
          recognizer: _UnusedRecognizer(),
          resolver: _NoLiveIdentityResolver(),
        );
        addTearDown(session.dispose);
        int captures = 0;
        try {
          await _show(
            tester,
            camera,
            automaticCapture: true,
            session: session,
            onUnidentifiedPhotoCaptured:
                (
                  List<String> paths,
                  List<List<ScanPoint>> excluded,
                  String captureId,
                  List<List<ScanPoint>> targets,
                ) async {
                  captures++;
                  return true;
                },
          );
          await _automaticPulse(tester, camera);
          await _until(tester, () => scene.textRequests.length == 1);
          await _automaticPulse(tester, camera);
          await _until(tester, () => scene.exclusions.length == 2);
          if (unavailable == 'rejected') {
            await _until(tester, () => scene.nativeFocusPoints.length == 1);
          } else {
            expect(scene.nativeFocusPoints, isEmpty);
          }
          expect(captures, 0);
          scene.geometryConfidence = .99;
          await _automaticPulse(tester, camera);
          await _until(tester, () => scene.textRequests.length == 3);
          await _automaticPulse(tester, camera);
          await _until(tester, () => captures == 1);
          expect(scene.focusStatusRequests, unavailable == 'rejected' ? 1 : 0);
          expect(
            camera.actions.where((String action) => action == 'photo'),
            hasLength(1),
          );
          expect(tester.takeException(), isNull);
        } finally {
          await _dismissCamera(tester, camera);
          await tester.pump(const Duration(milliseconds: 200));
          restore();
        }
      },
    );
  }

  for (final String condition in <String>[
    'off target',
    'matching point',
    'removed',
  ]) {
    final bool removed = condition == 'removed';
    final bool matchingPoint = condition == 'matching point';
    testWidgets(
      removed
          ? 'initial raw focus cannot shutter a target removed while settling'
          : matchingPoint
          ? 'initial raw capture requests autofocus even when the native point already matches'
          : 'initial raw capture focuses its unreadable target before shutter',
      (WidgetTester tester) async {
        final ScanCrop near = _automaticCard(readable: false);
        final _AutomaticScene scene = _AutomaticScene()
          ..crop = near
          ..focusStatusPoint = matchingPoint
              ? const Offset(.425, .79)
              : const Offset(.5, .5);
        final VoidCallback restore = scene.install();
        final _Camera camera = _Camera()..ultraWideAvailable = false;
        final ScanSession session = ScanSession(
          recognizer: _UnusedRecognizer(),
          resolver: _NoLiveIdentityResolver(),
        );
        addTearDown(session.dispose);
        final List<List<List<ScanPoint>>> captures = <List<List<ScanPoint>>>[];
        try {
          await _show(
            tester,
            camera,
            automaticCapture: true,
            session: session,
            onUnidentifiedPhotoCaptured:
                (
                  List<String> paths,
                  List<List<ScanPoint>> excluded,
                  String captureId,
                  List<List<ScanPoint>> targets,
                ) async {
                  captures.add(targets);
                  return true;
                },
          );
          await _automaticPulse(tester, camera);
          await _until(tester, () => scene.textRequests.length == 1);
          expect(scene.nativeFocusPoints, isEmpty);
          expect(scene.focusStatusRequests, 0);
          expect(camera.actions, isNot(contains('photo')));

          await _automaticPulse(tester, camera);
          await _until(
            tester,
            () =>
                scene.nativeFocusPoints.isNotEmpty ||
                camera.actions.contains('photo'),
          );
          expect(
            camera.actions,
            isNot(contains('photo')),
            reason: matchingPoint
                ? 'A default focus point on a new card does not prove '
                      'autofocus has acquired its distance.'
                : 'Initial stable geometry cannot authorize a shutter while '
                      'the lens is settled outside the unreadable card.',
          );
          expect(scene.focusStatusRequests, greaterThan(0));
          expect(scene.nativeFocusPoints.first.dx, closeTo(.21, .001));
          expect(scene.nativeFocusPoints.first.dy, closeTo(.425, .001));
          if (matchingPoint) scene.focusAdjusting = true;
          for (int frame = 0; frame < 3; frame++) {
            await _automaticPulse(tester, camera);
            await tester.pump(const Duration(milliseconds: 250));
          }
          expect(camera.actions, isNot(contains('photo')));
          expect(captures, isEmpty);

          scene.focusStatusPoint = const Offset(.425, .79);
          scene.focusAdjusting = true;
          for (int frame = 0; frame < 3; frame++) {
            await _automaticPulse(tester, camera);
            await tester.pump(const Duration(milliseconds: 250));
          }
          expect(camera.actions, isNot(contains('photo')));
          if (matchingPoint) {
            expect(
              scene.nativeFocusPoints,
              hasLength(1),
              reason: 'Bounded retries reuse the successful target request.',
            );
          }
          if (removed) {
            scene.showCards = false;
            await _automaticPulse(tester, camera);
          }
          scene.focusAdjusting = false;
          for (int sample = 0; sample < 6; sample++) {
            await tester.pump(const Duration(milliseconds: 100));
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          }
          expect(
            camera.actions,
            isNot(contains('photo')),
            reason: removed
                ? 'Settling focus cannot restore a disappeared target.'
                : 'Settled telemetry still needs a later target frame.',
          );
          expect(captures, isEmpty);
          if (removed) {
            for (int frame = 0; frame < 3; frame++) {
              await _automaticPulse(tester, camera);
            }
            expect(camera.actions, isNot(contains('photo')));
            expect(captures, isEmpty);
          }
          final int focusRequestsBeforeReappearance =
              scene.nativeFocusPoints.length;
          if (removed) scene.showCards = true;
          await _automaticUntil(tester, camera, () => captures.length == 1);
          if (removed) {
            expect(
              scene.nativeFocusPoints,
              hasLength(focusRequestsBeforeReappearance + 1),
              reason:
                  'A new contour at the same point needs its own autofocus '
                  'request after the previous target disappeared.',
            );
          }
          expect(
            captures.single.single.map((ScanPoint point) => (point.x, point.y)),
            near.sourceCorners.map((ScanPoint point) => (point.x, point.y)),
          );
          expect(
            camera.actions.where((String action) => action == 'photo'),
            hasLength(1),
          );
          expect(tester.takeException(), isNull);
        } finally {
          await _dismissCamera(tester, camera);
          await tester.pump(const Duration(milliseconds: 200));
          restore();
        }
      },
    );
  }

  testWidgets(
    'discovery focus cannot own a target after its focus point becomes ambiguous',
    (WidgetTester tester) async {
      final Completer<void> discovery = Completer<void>();
      final Completer<void> targeted = Completer<void>();
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..focusStatusPoint = const Offset(.425, .79)
        ..focusGate = discovery;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera()..ultraWideAvailable = false;
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                return true;
              },
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        expect(scene.nativeFocusPoints, isEmpty);
        await tester.pump(const Duration(seconds: 4));
        await _until(tester, () => scene.nativeFocusPoints.length == 1);
        expect(scene.nativeFocusPoints.single.dx, closeTo(.21, .001));
        expect(scene.nativeFocusPoints.single.dy, closeTo(.425, .001));
        expect(camera.actions, isNot(contains('photo')));

        scene.geometryCrops = <ScanCrop>[
          _automaticCard(
            readable: false,
            corners: const <ScanPoint>[
              ScanPoint(.20, .20),
              ScanPoint(.47, .20),
              ScanPoint(.47, .65),
              ScanPoint(.20, .65),
            ],
          ),
        ];
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.exclusions.length == 2);
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.exclusions.length == 3);
        expect(camera.actions, isNot(contains('photo')));

        scene.focusGate = targeted;
        discovery.complete();
        await _automaticUntil(
          tester,
          camera,
          () =>
              scene.nativeFocusPoints.length >= 2 ||
              camera.actions.contains('photo'),
        );
        expect(
          camera.actions,
          isNot(contains('photo')),
          reason:
              'Discovery began with one owner, but the focus point overlapped '
              'two distinct contours when its request completed.',
        );
        expect(
          scene.nativeFocusPoints,
          hasLength(2),
          reason:
              'The raw target still needs its own successful focus request.',
        );
        expect(captures, 0);
        expect(tester.takeException(), isNull);
      } finally {
        if (!discovery.isCompleted) discovery.complete();
        if (!targeted.isCompleted) targeted.complete();
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  testWidgets(
    'first raw shutter requires settled focus for its current target',
    (WidgetTester tester) async {
      final ScanCrop near = _automaticCard(readable: false);
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(
          readable: false,
          corners: const <ScanPoint>[
            ScanPoint(.7, .2),
            ScanPoint(.92, .2),
            ScanPoint(.92, .65),
            ScanPoint(.7, .65),
          ],
        )
        ..geometryConfidence = .85
        ..focusGate = Completer<void>()
        ..focusStatusPoint = const Offset(.425, .19);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final List<List<List<ScanPoint>>> captures = <List<List<ScanPoint>>>[];
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures.add(targets);
                return true;
              },
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 1);
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.nativeFocusPoints.length == 1);
        expect(scene.nativeFocusPoints.single.dx, closeTo(.81, .001));
        expect(scene.nativeFocusPoints.single.dy, closeTo(.425, .001));
        expect(camera.actions, isNot(contains('photo')));

        scene.crop = near;
        scene.geometryConfidence = .99;
        await _automaticPulse(tester, camera);
        await _automaticPulse(tester, camera);
        scene.focusGate!.complete();
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(scene.focusStatusRequests, greaterThan(0));
        expect(
          camera.actions,
          isNot(contains('photo')),
          reason:
              'Settled focus on the rear card cannot authorize the first '
              'shutter for a different unreadable near card.',
        );
        expect(captures, isEmpty);

        // Portrait preview (x, y) maps to native focus coordinates (y, 1 - x).
        scene.focusStatusPoint = const Offset(.425, .79);
        scene.focusAdjusting = true;
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(camera.actions, isNot(contains('photo')));
        expect(captures, isEmpty);

        scene.focusAdjusting = false;
        await _automaticUntil(tester, camera, () => captures.length == 1);
        expect(
          captures.single.single.map((ScanPoint point) => (point.x, point.y)),
          near.sourceCorners.map((ScanPoint point) => (point.x, point.y)),
        );
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!scene.focusGate!.isCompleted) scene.focusGate!.complete();
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  testWidgets(
    'raw shutter rejects a pre-focus frame that finishes after focus settles',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..focusGate = Completer<void>()
        ..focusStatusPoint = const Offset(.425, .79);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                return true;
              },
        );
        await _holdRawCaptureAtDiscovery(tester, camera, scene);
        scene.frameGate = Completer<void>();
        final int requestsBefore = scene.textRequests.length;
        final int completedBefore = scene.exclusions.length;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
        camera.frames.add(_automaticFrame());
        await _until(tester, () => scene.textRequests.length > requestsBefore);
        expect(scene.exclusions, hasLength(completedBefore));

        scene.focusGate!.complete();
        for (int tick = 0; tick < 12; tick++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        }
        expect(scene.focusStatusRequests, greaterThan(0));
        expect(camera.actions, isNot(contains('photo')));

        scene.frameGate!.complete();
        await _until(tester, () => scene.exclusions.length > completedBefore);
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          camera.actions,
          isNot(contains('photo')),
          reason:
              'Finishing OCR after focus settles does not make the '
              'pixels of an earlier camera frame current.',
        );
        expect(captures, 0);

        scene.frameGate = null;
        await _automaticUntil(tester, camera, () => captures == 1);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!scene.focusGate!.isCompleted) scene.focusGate!.complete();
        if (scene.frameGate case final Completer<void> pending) {
          if (!pending.isCompleted) pending.complete();
        }
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  testWidgets(
    'raw capture waits for active discovery and snapshots fresh handheld geometry',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..focusGate = Completer<void>();
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final List<List<List<ScanPoint>>> captures = <List<List<ScanPoint>>>[];
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures.add(targets);
                return true;
              },
        );
        await _holdRawCaptureAtDiscovery(tester, camera, scene);
        scene.crop = _automaticCard(
          readable: false,
          corners: <ScanPoint>[
            for (final ScanPoint point in scene.crop.sourceCorners)
              ScanPoint(point.x + .003, point.y + .001),
          ],
        );
        await _automaticPulse(tester, camera);
        await _until(tester, () => scene.textRequests.length == 5);
        expect(captures, isEmpty);
        scene.focusGate!.complete();
        await _until(tester, () => captures.isNotEmpty);
        expect(captures, hasLength(1));
        expect(
          captures.single.single.map((ScanPoint p) => (p.x, p.y)),
          scene.crop.sourceCorners.map((ScanPoint p) => (p.x, p.y)),
        );
        expect(scene.nativeSingleShotRequests, <bool>[false]);
        await _until(
          tester,
          () =>
              tester
                  .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                  .retainedPhotoRegions
                  .length ==
              1,
        );
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!scene.focusGate!.isCompleted) scene.focusGate!.complete();
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  testWidgets(
    'settled sweep autofocus permits raw capture while autoexposure changes',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..focusGate = Completer<void>()
        ..exposureAdjusting = true;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                return true;
              },
        );
        await _holdRawCaptureAtDiscovery(tester, camera, scene);
        scene.focusGate!.complete();
        await _until(tester, () => captures == 1);
        expect(scene.exposureAdjusting, isTrue);
        expect(scene.nativeSingleShotRequests, <bool>[false]);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!scene.focusGate!.isCompleted) scene.focusGate!.complete();
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  testWidgets(
    'raw focus timeout defers shutter until a settled fresh-frame retry',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..focusGate = Completer<void>();
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                return true;
              },
        );
        await _holdRawCaptureAtDiscovery(tester, camera, scene);
        await tester.pump(const Duration(milliseconds: 1100));
        await tester.pump();
        expect(find.text('Focusing…'), findsNothing);
        expect(camera.actions, isNot(contains('photo')));
        expect(captures, 0);
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          isEmpty,
        );
        scene.focusGate!.complete();
        for (int sample = 0; sample < 6; sample++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(captures, 0);
        await _automaticPulse(tester, camera);
        await _until(tester, () => captures == 1);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(scene.nativeSingleShotRequests, <bool>[false]);
        expect(tester.takeException(), isNull);
      } finally {
        if (!scene.focusGate!.isCompleted) scene.focusGate!.complete();
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  for (final String interruption in <String>['pause', 'clear', 'rotation']) {
    testWidgets(
      '$interruption during raw discovery wait cannot shutter stale geometry',
      (WidgetTester tester) async {
        final _AutomaticScene scene = _AutomaticScene()
          ..crop = _automaticCard(readable: false)
          ..focusGate = Completer<void>();
        final VoidCallback restore = scene.install();
        final _Camera camera = _Camera();
        final ScanSession session = ScanSession(
          recognizer: _UnusedRecognizer(),
          resolver: _NoLiveIdentityResolver(),
        );
        addTearDown(session.dispose);
        int captures = 0;
        int clears = 0;
        try {
          await _show(
            tester,
            camera,
            automaticCapture: true,
            session: session,
            onClearCaptures: () async {
              clears++;
            },
            onUnidentifiedPhotoCaptured:
                (
                  List<String> paths,
                  List<List<ScanPoint>> excluded,
                  String captureId,
                  List<List<ScanPoint>> targets,
                ) async {
                  captures++;
                  return true;
                },
          );
          await _holdRawCaptureAtDiscovery(tester, camera, scene);
          switch (interruption) {
            case 'pause':
              await tester.tap(
                find.byKey(const ValueKey<String>('camera-auto-pause')),
              );
              await tester.pump();
            case 'clear':
              await tester.tap(
                find.byKey(const ValueKey<String>('camera-adjustments')),
              );
              await tester.pump();
              final Finder clear = find.byKey(
                const ValueKey<String>('camera-clear-captures'),
              );
              await tester.ensureVisible(clear);
              await tester.pump();
              await tester.tap(clear);
              await tester.pump();
              expect(
                clears,
                0,
                reason: 'Clear drains active discovery and capture work.',
              );
            case 'rotation':
              camera.orientations.add(
                const DeviceOrientationChangedEvent(
                  DeviceOrientation.landscapeLeft,
                ),
              );
              await tester.pump();
          }
          scene.focusGate!.complete();
          for (int sample = 0; sample < 7; sample++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          if (interruption == 'clear') await _until(tester, () => clears == 1);
          expect(captures, 0);
          expect(camera.actions, isNot(contains('photo')));
          expect(
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .retainedPhotoRegions,
            isEmpty,
          );
          expect(tester.takeException(), isNull);
        } finally {
          if (!scene.focusGate!.isCompleted) scene.focusGate!.complete();
          await _dismissCamera(tester, camera);
          await tester.pump(const Duration(milliseconds: 200));
          restore();
        }
      },
    );
  }

  testWidgets(
    'moving unowned contours cannot indefinitely postpone due live OCR',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: _AutomaticCatalog()),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                return true;
              },
        );
        for (int index = 0; index < 6; index++) {
          final double left = index.isEven ? .10 : .64;
          scene.crop = _automaticCard(
            readable: false,
            corners: <ScanPoint>[
              ScanPoint(left, .20),
              ScanPoint(left + .22, .20),
              ScanPoint(left + .22, .65),
              ScanPoint(left, .65),
            ],
          );
          if (index == 3) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 1100)),
            );
          }
          await _automaticPulse(tester, camera);
          await _until(tester, () => scene.textRequests.length == index + 1);
        }
        expect(scene.textRequests, <bool>[
          false,
          false,
          true,
          false,
          false,
          true,
        ]);
        expect(captures, 0);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 200));
        restore();
      }
    },
  );

  testWidgets(
    'raw saved identity turns green only after fresh live OCR without another shutter or quantity',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _RawPhotoRecognizer recognizer = _RawPhotoRecognizer(
        _automaticCard(),
      )..gate = Completer<void>();
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: ScanResolver(catalog: _AutomaticCatalog()),
      );
      addTearDown(session.dispose);
      int photos = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) {
                photos++;
                return session.addFocusStack(
                  paths,
                  captureId: captureId,
                  targetRegions: targets,
                  diagnosticOnly: false,
                );
              },
        );
        await _automaticUntil(
          tester,
          camera,
          () => photos == 1 && recognizer.calls == 1,
        );
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          hasLength(1),
        );
        expect(session.items, isEmpty);
        recognizer.gate!.complete();
        await _until(
          tester,
          () =>
              session.items.isNotEmpty &&
              session.items.single.resolution != null,
        );
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .any((LiveScanTrack track) => track.capturedIdentified),
          isFalse,
        );
        scene.crop = _automaticCard();
        await _automaticUntil(
          tester,
          camera,
          () => tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .any((LiveScanTrack track) => track.capturedIdentified),
        );
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          isEmpty,
        );
        expect(session.items, hasLength(1));
        expect(session.items.single.liveCaptureReceiptId, isNull);
        expect(session.items.single.crop.imagePath, isNotEmpty);
        expect(
          session.items.single.resolution!.candidates.first.card.name,
          'Lightning Bolt',
        );
        final int focused = scene.nativeFocusPoints.length;
        for (int frame = 0; frame < 6; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(photos, 1);
        expect(session.items, hasLength(1));
        expect(scene.nativeFocusPoints, hasLength(focused));
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!recognizer.gate!.isCompleted) {
          recognizer.gate!.complete();
        }
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  for (final bool alreadyIdentified in <bool>[false, true]) {
    testWidgets(
      'visually similar Ice Age Blue to Red swap ${alreadyIdentified ? 'revokes completed green on bounded OCR verification' : 'cannot inherit a pending Blue photo result'}',
      (WidgetTester tester) async {
        final Map<String, Object?> fixture = jsonDecode(
          File('test/fixtures/ice_circle_appearance.json').readAsStringSync(),
        ) as Map<String, Object?>;
        final List<double> blue = _circleAppearance(fixture, 'blue');
        final List<double> red = _circleAppearance(fixture, 'red');
        expect((fixture['difference']! as num).toDouble(), lessThan(.38));
        expect(
          ScanResolver.rulesSearchPhrase(
            ScanHints.fromCrop(_circleCard('Blue')).rulesText,
          ),
          isNotNull,
        );
        final _AutomaticScene scene = _AutomaticScene()
          ..crop = _automaticCard(readable: false)
          ..rawAppearanceSupported = true
          ..previewAppearanceValues = blue
          ..rawAppearanceValues = blue
          ..ownedAppearanceValues = blue;
        final VoidCallback restore = scene.install();
        final _Camera camera = _Camera();
        final _RawPhotoRecognizer recognizer = _RawPhotoRecognizer(
          _circleCard('Blue'),
        )..gate = Completer<void>();
        final ScanSession session = ScanSession(
          recognizer: recognizer,
          resolver: ScanResolver(
            catalog: _AutomaticCatalog(card: _CirclePrinting()),
          ),
        );
        addTearDown(session.dispose);
        int photos = 0;
        List<LiveScanTrack> tracks() => tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks;
        try {
          await _show(
            tester,
            camera,
            automaticCapture: true,
            session: session,
            onUnidentifiedPhotoCaptured:
                (
                  List<String> paths,
                  List<List<ScanPoint>> excluded,
                  String captureId,
                  List<List<ScanPoint>> targets,
                ) {
                  photos++;
                  return session.addFocusStack(
                    paths,
                    captureId: captureId,
                    targetRegions: targets,
                    diagnosticOnly: false,
                  );
                },
          );
          await _automaticUntil(
            tester,
            camera,
            () => photos == 1 && recognizer.calls == 1,
          );
          if (!alreadyIdentified) scene.rawAppearanceValues = red;
          recognizer.gate!.complete();
          await _until(
            tester,
            () =>
                session.items.isNotEmpty &&
                session.items.single.resolution != null,
          );
          if (alreadyIdentified) {
            scene.crop = _circleCard('Blue');
            await _automaticUntil(
              tester,
              camera,
              () => tracks().any(
                (LiveScanTrack track) => track.capturedIdentified,
              ),
            );
            final String ownerId = tracks()
                .singleWhere((LiveScanTrack track) => track.capturedIdentified)
                .id;
            bool ownerSampled() =>
                scene.appearanceRequests.isNotEmpty &&
                scene.appearanceRequests.last.any(
                  (Object? value) =>
                      (value! as Map<Object?, Object?>)['id'] == ownerId,
                );
            for (int frame = 0; frame < 4; frame++) {
              await _automaticPulse(tester, camera);
            }
            expect(ownerSampled(), isTrue);
            await tester.tap(
              find.byKey(const ValueKey<String>('camera-auto-pause')),
            );
            scene.crop = _circleCard('Red');
            scene.ownedAppearanceValues = red;
            await _automaticUntil(tester, camera, () => !ownerSampled());
          } else {
            for (int frame = 0; frame < 6; frame++) {
              await _automaticPulse(tester, camera);
            }
            expect(
              tester
                  .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                  .retainedPhotoRegions,
              hasLength(1),
            );
          }
          expect(
            tracks().any((LiveScanTrack track) => track.capturedIdentified),
            isFalse,
          );
          expect(session.items, hasLength(1));
          expect(
            session.items.single.resolution!.candidates.first.card.name,
            'Circle of Protection: Blue',
          );
          expect(photos, 1);
          expect(
            camera.actions.where((String action) => action == 'photo'),
            hasLength(1),
          );
          expect(tester.takeException(), isNull);
        } finally {
          if (!recognizer.gate!.isCompleted) recognizer.gate!.complete();
          await _dismissCamera(tester, camera);
          restore();
        }
      },
    );
  }

  testWidgets(
    'a raw appearance replacement cannot inherit the original photo background result',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _RawPhotoRecognizer recognizer = _RawPhotoRecognizer(
        _automaticCard(),
      )..gate = Completer<void>();
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: ScanResolver(catalog: _AutomaticCatalog()),
      );
      addTearDown(session.dispose);
      int photos = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) {
                photos++;
                return session.addFocusStack(
                  paths,
                  captureId: captureId,
                  targetRegions: targets,
                  diagnosticOnly: false,
                );
              },
        );
        await _automaticUntil(
          tester,
          camera,
          () => photos == 1 && recognizer.calls == 1,
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-auto-pause')),
        );
        for (int frame = 0; frame < 5; frame++) {
          await _automaticPulse(tester, camera);
        }
        scene.reversedRawAppearance = true;
        await _automaticPulse(tester, camera);
        recognizer.gate!.complete();
        await _until(
          tester,
          () =>
              session.items.isNotEmpty &&
              session.items.single.resolution != null,
        );
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .any((LiveScanTrack track) => track.capturedIdentified),
          isFalse,
        );
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          isEmpty,
        );
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .any((LiveScanTrack track) => track.capturedIdentified),
          isFalse,
        );
        expect(session.items, hasLength(1));
        expect(photos, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!recognizer.gate!.isCompleted) {
          recognizer.gate!.complete();
        }
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'unanchored raw appearance cannot turn green until fresh live OCR corroborates the saved identity',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _RawPhotoRecognizer(_automaticCard()),
        resolver: ScanResolver(catalog: _AutomaticCatalog()),
      );
      addTearDown(session.dispose);
      int photos = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) {
                photos++;
                return session.addFocusStack(
                  paths,
                  captureId: captureId,
                  targetRegions: targets,
                  diagnosticOnly: false,
                );
              },
        );
        await _automaticUntil(
          tester,
          camera,
          () =>
              session.items.isNotEmpty &&
              session.items.single.resolution != null,
        );
        scene.rawAppearanceSupported = true;
        for (int frame = 0; frame < 5; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .any((LiveScanTrack track) => track.capturedIdentified),
          isFalse,
        );
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          hasLength(1),
        );
        scene.crop = _automaticCard();
        await _automaticUntil(
          tester,
          camera,
          () => tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .any((LiveScanTrack track) => track.capturedIdentified),
        );
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          isEmpty,
        );
        expect(session.items, hasLength(1));
        expect(photos, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'a same-rectangle replacement during raw durable handoff cannot establish the photographed baseline',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _RawPhotoRecognizer(_automaticCard()),
        resolver: ScanResolver(catalog: _AutomaticCatalog()),
      );
      addTearDown(session.dispose);
      final Completer<void> durableHandoff = Completer<void>();
      int photos = 0;
      bool saved = false;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                photos++;
                await durableHandoff.future;
                saved = await session.addFocusStack(
                  paths,
                  captureId: captureId,
                  targetRegions: targets,
                  diagnosticOnly: false,
                );
                return saved;
              },
        );
        await _automaticUntil(tester, camera, () => photos == 1);
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .safeToMovePhotoRegions,
          isEmpty,
        );
        scene.reversedAppearance = true;
        scene.frameWidth = 801;
        await _automaticPulse(tester, camera);
        await _until(
          tester,
          () =>
              tester
                  .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                  .transform
                  .sourceSize
                  .width ==
              801,
        );
        durableHandoff.complete();
        await _until(
          tester,
          () =>
              saved &&
              session.items.isNotEmpty &&
              session.items.single.resolution != null,
        );
        await tester.pump();
        expect(scene.captureConfirmations, 0);
        expect(find.text('Next card'), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-auto-pause')),
        );
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .any((LiveScanTrack track) => track.capturedIdentified),
          isFalse,
        );
        for (int frame = 0; frame < 5; frame++) {
          await _automaticPulse(tester, camera);
          expect(
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .safeToMovePhotoRegions,
            isEmpty,
          );
          expect(
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .safeToMoveTrackIds,
            isEmpty,
          );
          expect(
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .tracks
                .any((LiveScanTrack track) => track.capturedIdentified),
            isFalse,
          );
        }
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          isEmpty,
        );
        expect(session.items, hasLength(1));
        expect(
          session.items.single.resolution!.candidates.first.card.name,
          'Lightning Bolt',
        );
        expect(photos, 1);
        expect(scene.captureConfirmations, 0);
        expect(tester.takeException(), isNull);
      } finally {
        if (!durableHandoff.isCompleted) {
          durableHandoff.complete();
        }
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  for (final String ownerChange in <String>['session', 'orientation']) {
    testWidgets(
      'late raw photo results cannot turn green after a $ownerChange change',
      (WidgetTester tester) async {
        final _AutomaticScene scene = _AutomaticScene()
          ..crop = _automaticCard(readable: false);
        final VoidCallback restore = scene.install();
        final _CaptureHaptics haptics = _CaptureHaptics()..install();
        addTearDown(haptics.restore);
        final _Camera camera = _Camera();
        final _RawPhotoRecognizer recognizer = _RawPhotoRecognizer(
          _automaticCard(),
        )..gate = Completer<void>();
        final ScanSession session = ScanSession(
          recognizer: recognizer,
          resolver: ScanResolver(catalog: _AutomaticCatalog()),
        );
        final ScanSession replacement = ScanSession(
          recognizer: _UnusedRecognizer(),
          resolver: _NoLiveIdentityResolver(),
        );
        addTearDown(session.dispose);
        addTearDown(replacement.dispose);
        int photos = 0;
        Future<bool> handoff(
          List<String> paths,
          List<List<ScanPoint>> excluded,
          String captureId,
          List<List<ScanPoint>> targets,
        ) {
          photos++;
          return session.addFocusStack(
            paths,
            captureId: captureId,
            targetRegions: targets,
            diagnosticOnly: false,
          );
        }

        final ValueNotifier<GuidedCameraScreen> cameraUpdates =
            ValueNotifier<GuidedCameraScreen>(
              GuidedCameraScreen(
                automaticCapture: true,
                session: session,
                onUnidentifiedPhotoCaptured: handoff,
                onCaptured: (
                  String path,
                  List<List<ScanPoint>> excluded,
                ) async => true,
              ),
            );
        addTearDown(cameraUpdates.dispose);
        try {
          await _show(
            tester,
            camera,
            automaticCapture: true,
            session: session,
            cameraUpdates: cameraUpdates,
          );
          await _automaticUntil(
            tester,
            camera,
            () => photos == 1 && recognizer.calls == 1,
          );
          expect(haptics.lightImpacts, 0);
          await tester.tap(
            find.byKey(const ValueKey<String>('camera-auto-pause')),
          );
          if (ownerChange == 'session') {
            cameraUpdates.value = GuidedCameraScreen(
              automaticCapture: true,
              session: replacement,
              onUnidentifiedPhotoCaptured: handoff,
              onCaptured: (String path, List<List<ScanPoint>> excluded) async =>
                  true,
            );
          } else {
            camera.orientations.add(
              const DeviceOrientationChangedEvent(
                DeviceOrientation.landscapeLeft,
              ),
            );
          }
          await tester.pump();
          await _until(
            tester,
            () =>
                find.byType(LiveCaptureOverlay).evaluate().isNotEmpty &&
                tester
                    .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                    .retainedPhotoRegions
                    .isEmpty,
          );
          recognizer.gate!.complete();
          await _until(
            tester,
            () =>
                session.items.isNotEmpty &&
                session.items.single.resolution != null,
          );
          for (int frame = 0; frame < 3; frame++) {
            await _automaticPulse(tester, camera);
          }
          expect(
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .tracks
                .any((LiveScanTrack track) => track.capturedIdentified),
            isFalse,
          );
          expect(session.items, hasLength(1));
          expect(replacement.items, isEmpty);
          expect(photos, 1);
          expect(haptics.lightImpacts, 0);
          expect(find.text('Next card'), findsNothing);
          expect(
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .safeToMovePhotoRegions,
            isEmpty,
          );
          expect(
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .safeToMoveTrackIds,
            isEmpty,
          );
          expect(tester.takeException(), isNull);
        } finally {
          if (!recognizer.gate!.isCompleted) {
            recognizer.gate!.complete();
          }
          await _dismissCamera(tester, camera);
          restore();
        }
      },
    );
  }

  for (final String outcome in <String>[
    'transfers an empty source',
    'keeps its existing item',
    'keeps a discarded item',
    'keeps a retryable failed source',
  ]) {
    final bool discardedItem = outcome == 'keeps a discarded item';
    final bool retainedItem =
        outcome == 'keeps its existing item' || discardedItem;
    final bool detailFailure = outcome == 'keeps a retryable failed source';
    final bool canTransfer = !retainedItem && !detailFailure;
    testWidgets(
      'raw ownership $outcome without releasing the neighboring card',
      (WidgetTester tester) async {
        const List<ScanPoint> left = <ScanPoint>[
          ScanPoint(.08, .2),
          ScanPoint(.34, .2),
          ScanPoint(.34, .7),
          ScanPoint(.08, .7),
        ];
        const List<ScanPoint> right = <ScanPoint>[
          ScanPoint(.6, .2),
          ScanPoint(.86, .2),
          ScanPoint(.86, .7),
          ScanPoint(.6, .7),
        ];
        final _AutomaticScene scene = _AutomaticScene()
          ..crop = _automaticCard(readable: false, corners: left)
          ..additionalCrops = <ScanCrop>[
            _automaticCard(readable: false, corners: right),
          ]
          ..rawAppearanceSupported = true;
        final VoidCallback restore = scene.install();
        final _Camera camera = _Camera();
        final _ControlledSession session = _ControlledSession(
          recognizer: _UnusedRecognizer(),
          resolver: ScanResolver(catalog: _AutomaticCatalog()),
        );
        addTearDown(session.dispose);
        int rawCaptures = 0;
        int recoveries = 0;
        List<String>? rawPaths;
        String? rawId;
        List<List<ScanPoint>>? rawTargets;
        List<List<ScanPoint>>? recoveredTargets;
        List<List<ScanPoint>>? recoveredExclusions;
        try {
          await _show(
            tester,
            camera,
            automaticCapture: true,
            session: session,
            onUnidentifiedPhotoCaptured:
                (
                  List<String> paths,
                  List<List<ScanPoint>> excluded,
                  String captureId,
                  List<List<ScanPoint>> targets,
                ) async {
                  rawCaptures++;
                  rawPaths = List<String>.of(paths);
                  rawId = captureId;
                  session.rememberCapture(paths, captureId);
                  rawTargets = targets;
                  return true;
                },
            onFocusStackCaptured:
                (
                  List<String> paths,
                  List<List<ScanPoint>> excluded,
                  String captureId,
                  List<List<ScanPoint>>? targets,
                ) async {
                  recoveries++;
                  recoveredTargets = targets;
                  recoveredExclusions = excluded;
                  _refinePhotoObservation(
                    session,
                    scene.crop,
                    id: 'recovered-left',
                    photoId: '${captureId}_0',
                  );
                  session.changed();
                  return true;
                },
          );
          await _automaticUntil(tester, camera, () => rawCaptures == 1);
          expect(rawTargets, hasLength(2));
          if (retainedItem) {
            _refinePhotoObservation(
              session,
              scene.crop,
              id: 'existing-left',
              photoId: '${rawId!}_0',
            );
          }
          if (discardedItem) {
            session.changed();
            await session.remove(session.items.single);
          }
          session.rawCompletedGroups.add(session.captureGroup(rawPaths!));
          if (detailFailure) {
            session.failedDetailGroups.add(session.captureGroup(rawPaths!));
          }
          session.changed();
          scene.crop = _automaticCard(corners: left);
          for (int frame = 0; frame < 10; frame++) {
            await _automaticPulse(tester, camera);
          }
          expect(rawCaptures, 1);
          expect(recoveries, canTransfer ? 1 : 0);
          if (canTransfer) {
            expect(recoveredTargets, hasLength(1));
            expect(recoveredExclusions, hasLength(1));
            expect(
              recoveredTargets!.single.map(
                (ScanPoint point) => (point.x, point.y),
              ),
              left.map((ScanPoint point) => (point.x, point.y)),
            );
            expect(
              recoveredExclusions!.single.map(
                (ScanPoint point) => (point.x, point.y),
              ),
              right.map((ScanPoint point) => (point.x, point.y)),
            );
          }
          expect(
            session.items,
            hasLength(detailFailure || discardedItem ? 0 : 1),
          );
          expect(
            camera.actions.where((String action) => action == 'photo'),
            hasLength(canTransfer ? 2 : 1),
          );
          expect(tester.takeException(), isNull);
        } finally {
          await _dismissCamera(tester, camera);
          restore();
        }
      },
    );
  }

  testWidgets(
    'empty fast presence holds its card while detailed reading is pending',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene();
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _PresencePhotoRecognizer recognizer = _PresencePhotoRecognizer(
        scene.crop,
      )..emptyPresence = true;
      final _RecognitionSession session = _RecognitionSession(
        recognizer: recognizer,
        resolver: ScanResolver(catalog: _AutomaticCatalog()),
      );
      addTearDown(session.dispose);
      int captures = 0;
      List<String>? firstPaths;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>>? targets,
              ) {
                captures++;
                firstPaths ??= List<String>.of(paths);
                return session.addFocusStack(
                  paths,
                  captureId: captureId,
                  targetRegions: targets,
                  excludedRegions: excluded,
                  preferFastPresence: true,
                );
              },
        );
        await _automaticUntil(tester, camera, () => recognizer.deepCalls == 1);
        expect(session.captureReadComplete(firstPaths!), isTrue);
        expect(session.captureDetailsPending(firstPaths!), isTrue);
        expect(session.items, isEmpty);
        for (int frame = 0; frame < 8; frame++) {
          session.changed();
          await _automaticPulse(tester, camera);
        }
        expect(captures, 1);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
          reason: 'The saved image is still being read; no replacement exposure is needed.',
        );
        recognizer.deep.complete();
        await _until(
          tester,
          () =>
              !session.captureDetailsPending(firstPaths!) &&
              session.items.isNotEmpty,
        );
        for (int frame = 0; frame < 3; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(captures, 1);
        expect(session.items, hasLength(1));
        expect(tester.takeException(), isNull);
      } finally {
        if (!recognizer.deep.isCompleted) recognizer.deep.complete();
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'saved-card quality waits for pixels and confirms before catalog lookup on a narrow large-text phone',
    (WidgetTester tester) async {
      final _CaptureHaptics haptics = _CaptureHaptics()..install();
      addTearDown(haptics.restore);
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      addTearDown(restore);
      final _Camera camera = _Camera();
      final ScanCrop readable = _automaticCard();
      final ScanCrop savedCard = ScanCrop(
        imagePath: '',
        width: readable.width,
        height: readable.height,
        rectified: true,
        sourceCorners: readable.sourceCorners,
        lines: readable.lines
            .where((ScanTextLine line) => line.text != '149')
            .toList(),
      );
      final _PresencePhotoRecognizer recognizer = _PresencePhotoRecognizer(
        savedCard,
      )..gate = Completer<void>();
      final _DeferredPhotoCatalog catalog = _DeferredPhotoCatalog(
        card: _AutomaticPrinting(),
      );
      final _RecognitionSession session = _RecognitionSession(
        recognizer: recognizer,
        resolver: ScanResolver(catalog: catalog),
      );
      addTearDown(session.dispose);
      final Completer<void> acknowledgement = Completer<void>();
      int captures = 0;
      LiveCaptureOverlay overlay() =>
          tester.widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay));
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          size: const Size(320, 667),
          scale: 2.35,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String id,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                await acknowledgement.future;
                return session.addFocusStack(
                  paths,
                  captureId: id,
                  targetRegions: targets,
                  diagnosticOnly: false,
                  preferFastPresence: true,
                );
              },
        );
        await _automaticUntil(tester, camera, () => captures == 1);
        expect(haptics.lightImpacts, 0);
        expect(scene.captureConfirmations, 0);
        final Rect previewBeforeSave = tester.getRect(
          find.byType(LiveCaptureOverlay),
        );
        expect(find.text('Next card'), findsNothing);
        expect(overlay().safeToMovePhotoRegions, isEmpty);
        expect(overlay().safeToMoveTrackIds, isEmpty);
        acknowledgement.complete();
        await _until(tester, () => recognizer.calls == 1);
        expect(haptics.lightImpacts, 0);
        expect(scene.captureConfirmations, 0);
        expect(overlay().safeToMovePhotoRegions, isEmpty);
        expect(overlay().retainedPhotoRegions, hasLength(1));
        await _automaticPulse(tester, camera);
        expect(haptics.lightImpacts, 0);
        expect(catalog.gate.isCompleted, isFalse);
        expect(recognizer.deep.isCompleted, isFalse);
        recognizer.gate!.complete();
        await _until(
          tester,
          () =>
              session.items.length == 1 &&
              hasVerifiedSavedCardCapturePresence(session.items.single.crop),
        );
        expect(
          haptics.lightImpacts,
          0,
          reason: 'Readable pixels alone do not acknowledge durable capture.',
        );
        expect(scene.captureConfirmations, 0);
        session.savedEvidence[session.items.single.id] =
            session.items.single.crop;
        session.changed();
        await _until(
          tester,
          () =>
              haptics.lightImpacts == 1 &&
              recognizer.calls == 1 &&
              find.text('Next card').evaluate().isNotEmpty,
        );
        expect(catalog.gate.isCompleted, isFalse);
        expect(scene.captureConfirmations, 1);
        expect(
          tester.getRect(find.byType(LiveCaptureOverlay)),
          previewBeforeSave,
          reason: 'Capture feedback must not resize the viewfinder.',
        );
        expect(session.items, hasLength(1));
        expect(session.items.single.resolution, isNull);
        final Finder cue = find.text('Next card');
        expect(cue.hitTestable(), findsOneWidget);
        expect(tester.getRect(cue).width, lessThanOrEqualTo(296));
        expect(
          tester.getRect(cue).bottom,
          lessThanOrEqualTo(
            tester
                .getRect(find.byKey(const ValueKey<String>('camera-review')))
                .top,
          ),
        );
        await _automaticPulse(tester, camera);
        await _until(
          tester,
          () => overlay().safeToMovePhotoRegions.length == 1,
        );
        expect(
          overlay().safeToMoveTrackIds,
          isEmpty,
          reason: 'A saved image is not a verified identity.',
        );
        expect(session.items.single.crop.warnings, contains('details_pending'));
        expect(session.items.single.exactMatch, isFalse);
        recognizer.deep.complete();
        catalog.gate.complete();
        await _until(
          tester,
          () =>
              session.items.isNotEmpty &&
              session.items.single.resolution != null,
        );
        for (int update = 0; update < 3; update++) {
          session.changed();
          await tester.pump();
        }
        expect(haptics.lightImpacts, 1);
        expect(scene.captureConfirmations, 1);
        expect(captures, 1);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!acknowledgement.isCompleted) acknowledgement.complete();
        if (!recognizer.gate!.isCompleted) recognizer.gate!.complete();
        if (!catalog.gate.isCompleted) catalog.gate.complete();
        if (!recognizer.deep.isCompleted) recognizer.deep.complete();
        try {
          await _dismissCamera(tester, camera);
        } finally {
          restore();
          haptics.restore();
        }
      }
    },
  );

  testWidgets(
    'failed photo handoff has no saved capture cue haptic or checked pane',
    (WidgetTester tester) async {
      final _CaptureHaptics haptics = _CaptureHaptics()..install();
      addTearDown(haptics.restore);
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false);
      final VoidCallback restore = scene.install();
      addTearDown(restore);
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int attempts = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String id,
                List<List<ScanPoint>> targets,
              ) async {
                attempts++;
                return false;
              },
        );
        await _automaticUntil(tester, camera, () => attempts == 1);
        await _until(
          tester,
          () => find.text('Save failed').evaluate().isNotEmpty,
        );
        final LiveCaptureOverlay overlay = tester.widget<LiveCaptureOverlay>(
          find.byType(LiveCaptureOverlay),
        );
        expect(overlay.safeToMovePhotoRegions, isEmpty);
        expect(overlay.safeToMoveTrackIds, isEmpty);
        expect(find.text('Next card'), findsNothing);
        expect(haptics.lightImpacts, 0);
        expect(scene.captureConfirmations, 0);
        expect(tester.takeException(), isNull);
      } finally {
        try {
          await _dismissCamera(tester, camera);
        } finally {
          restore();
          haptics.restore();
        }
      }
    },
  );

  testWidgets(
    'fresh native contours capture one ordinary photo without live OCR and protect later strong observations',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _RawPhotoRecognizer recognizer = _RawPhotoRecognizer(scene.crop);
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final List<List<List<ScanPoint>>> exclusions = <List<List<ScanPoint>>>[];
      int ordinaryImports = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> protected,
                String captureId,
                List<List<ScanPoint>> targets,
              ) {
                ordinaryImports++;
                exclusions.add(protected);
                expect(targets, hasLength(1));
                return session.addFocusStack(
                  paths,
                  captureId: captureId,
                  diagnosticOnly: false,
                  targetRegions: targets,
                );
              },
        );
        await _automaticUntil(
          tester,
          camera,
          () => ordinaryImports == 1 && session.photosRead == 1,
        );
        expect(recognizer.calls, 1);
        expect(session.items, hasLength(1));
        expect(session.items.single.liveCaptureReceiptId, isNull);
        expect(session.items.single.liveIdentityName, isNull);
        expect(scene.nativeFocusPoints, isEmpty);
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          hasLength(1),
        );
        scene.crop = _automaticCard();
        for (int frame = 0; frame < 6; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(session.items, hasLength(1));
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .any((LiveScanTrack track) => track.capturedIdentified),
          isFalse,
        );
        final ScanCrop first = scene.crop;
        scene.crop = _automaticCard(
          readable: false,
          corners: const <ScanPoint>[
            ScanPoint(.6, .2),
            ScanPoint(.82, .2),
            ScanPoint(.82, .65),
            ScanPoint(.6, .65),
          ],
        );
        scene.additionalCrops = <ScanCrop>[first];
        recognizer.crop = scene.crop;
        camera.picturePath = '/tmp/synthetic-raw-disjoint-card.jpg';
        await _automaticUntil(
          tester,
          camera,
          () => ordinaryImports == 2 && session.photosRead == 2,
        );
        expect(session.items, hasLength(2));
        expect(exclusions.last, hasLength(1));
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(2),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'ordinary contour save failure preserves the original until retry and respects capture pause',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final File original = File(
        '${Directory.systemTemp.path}/collector-raw-retain-${DateTime.now().microsecondsSinceEpoch}.jpg',
      )..writeAsBytesSync(<int>[1, 2, 3]);
      camera.picturePath = original.path;
      bool save = false;
      int attempts = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> protected,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                attempts++;
                expect(paths, <String>[original.path]);
                return save;
              },
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-auto-pause')),
        );
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(attempts, 0);
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-auto-pause')),
        );
        await _automaticUntil(tester, camera, () => attempts == 1);
        expect(original.existsSync(), isTrue);
        expect(
          find.text('Save failed. Free storage, retry or discard.'),
          findsOneWidget,
        );
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(attempts, 1);
        save = true;
        await tester.tap(find.text('Retry save'));
        await _until(tester, () => attempts == 2);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
        if (original.existsSync()) original.deleteSync();
      }
    },
  );

  testWidgets(
    'raw appearance samples keep the shutter footprint through contour jitter',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..rawAppearanceSupported = true;
      final List<ScanPoint> frozen = scene.crop.sourceCorners;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final List<String> captures = <String>[];
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures.add(captureId);
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => captures.length == 1);
        final String receipt = 'raw_${captures.single}_0';
        final List<List<ScanPoint>> contours = <List<ScanPoint>>[
          frozen
              .map(
                (ScanPoint point) => ScanPoint(point.x + .008, point.y - .006),
              )
              .toList(),
          const <ScanPoint>[
            ScanPoint(.1154, .2315),
            ScanPoint(.3046, .2315),
            ScanPoint(.3046, .6185),
            ScanPoint(.1154, .6185),
          ],
          const <ScanPoint>[
            ScanPoint(.13, .19),
            ScanPoint(.34, .22),
            ScanPoint(.29, .66),
            ScanPoint(.08, .63),
          ],
          frozen,
        ];
        for (final (int contourIndex, List<ScanPoint> corners)
            in contours.indexed) {
          scene.appearanceRequests.clear();
          scene.crop = _automaticCard(readable: false, corners: corners);
          for (int frame = 0; frame < 4; frame++) {
            await _automaticPulse(tester, camera);
          }
          final List<Map<Object?, Object?>> samples = scene.appearanceRequests
              .expand((List<Object?> regions) => regions)
              .whereType<Map<Object?, Object?>>()
              .where((Map<Object?, Object?> sample) => sample['id'] == receipt)
              .toList();
          expect(samples, isNotEmpty);
          for (final Map<Object?, Object?> sample in samples) {
            final List<Object?> points = sample['corners']! as List<Object?>;
            expect(
              points.map((Object? value) {
                final Map<Object?, Object?> point =
                    value! as Map<Object?, Object?>;
                return (point['x'], point['y']);
              }),
              frozen.map((ScanPoint point) => (point.x, point.y)),
              reason: 'Contour refinement must not move the pixels compared with the shutter baseline.',
            );
          }
          expect(captures, hasLength(1));
          expect(
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .retainedPhotoRegions,
            hasLength(1),
            reason: 'Contour $contourIndex still overlaps the frozen card.',
          );
        }
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  test('saved-card panel admission uses polygon containment and size', () {
    const List<ScanPoint> owner = <ScanPoint>[
      ScanPoint(.5486111044883728, .546875),
      ScanPoint(.9236111044883728, .5625),
      ScanPoint(1, .90234375),
      ScanPoint(.5069444179534912, .90625),
    ];
    const List<List<ScanPoint>> panels = <List<ScanPoint>>[
      <ScanPoint>[
        ScanPoint(.5067209005355835, .8180749118328094),
        ScanPoint(.6923678517341614, .8315505087375641),
        ScanPoint(.6923678517341614, .8996445015072823),
        ScanPoint(.5140377283096313, .8869943618774414),
      ],
      <ScanPoint>[
        ScanPoint(.5410077571868896, .5354828536510468),
        ScanPoint(.9139537811279297, .5522002875804901),
        ScanPoint(.9973424673080444, .7627191245555878),
        ScanPoint(.5116420984268188, .7342911958694458),
      ],
    ];
    for (final List<ScanPoint> panel in panels) {
      expect(GuidedCameraScreen.isCapturedCardPanel(panel, owner), isTrue);
      expect(
        GuidedCameraScreen.isCapturedCardPanel(
          panel.reversed.toList(),
          owner.reversed.toList(),
        ),
        isTrue,
      );
    }
    expect(GuidedCameraScreen.isCapturedCardPanel(owner, owner), isFalse);
    expect(
      GuidedCameraScreen.isCapturedCardPanel(
        const <ScanPoint>[
          ScanPoint(.50, .18),
          ScanPoint(.64, .32),
          ScanPoint(.50, .46),
          ScanPoint(.36, .32),
        ],
        const <ScanPoint>[
          ScanPoint(.3, .1),
          ScanPoint(.55, .35),
          ScanPoint(.3, .6),
          ScanPoint(.05, .35),
        ],
      ),
      isFalse,
      reason: 'An adjacent rotated card can overlap the bounding box.',
    );
    expect(
      GuidedCameraScreen.isCapturedCardPanel(const <ScanPoint>[
        ScanPoint(.01, .01),
        ScanPoint(.99, .01),
        ScanPoint(.99, .99),
        ScanPoint(.01, .99),
      ], owner),
      isFalse,
      reason:
          'A background rectangle enclosing the owner is not an inner panel.',
    );
  });

  for (final bool tracked in <bool>[false, true]) {
    testWidgets(
      '${tracked ? 'tracked' : 'raw'} saved crop suppresses internal panel exposures',
      (WidgetTester tester) async {
        const List<ScanPoint> frozen = <ScanPoint>[
          ScanPoint(.5308334829985092, .5481386238879689),
          ScanPoint(.8977419757348146, .5481386238879689),
          ScanPoint(.8977419757348146, .8960601808686586),
          ScanPoint(.5308334829985092, .8960601808686586),
        ];
        const List<ScanPoint> saved = <ScanPoint>[
          ScanPoint(.5486111044883728, .546875),
          ScanPoint(.9236111044883728, .5625),
          ScanPoint(1, .90234375),
          ScanPoint(.5069444179534912, .90625),
        ];
        final _AutomaticScene scene = _AutomaticScene()
          ..crop = _automaticCard(readable: tracked, corners: frozen)
          ..rawAppearanceSupported = true;
        final VoidCallback restore = scene.install();
        final _Camera camera = _Camera();
        final _ControlledSession session = _ControlledSession(
          recognizer: _UnusedRecognizer(),
          resolver: _NoLiveIdentityResolver(),
        );
        addTearDown(session.dispose);
        int captures = 0;
        Future<bool> save(
          List<String> paths,
          List<List<ScanPoint>> excluded,
          String captureId,
          List<List<ScanPoint>>? targets,
        ) async {
          captures++;
          session.rememberCapture(paths, captureId);
          _refinePhotoObservation(
            session,
            _automaticCard(readable: false, corners: saved),
            id: 'owned-$captureId',
            photoId: '${captureId}_0',
          );
          return true;
        }

        try {
          await _show(
            tester,
            camera,
            automaticCapture: true,
            session: session,
            onFocusStackCaptured: tracked ? save : null,
            onUnidentifiedPhotoCaptured: save,
          );
          await _automaticUntil(tester, camera, () => captures == 1);
          scene
            ..crop = _automaticCard(readable: false, corners: frozen)
            ..geometryCrops = <ScanCrop>[
              _automaticCard(
                readable: false,
                corners: const <ScanPoint>[
                  ScanPoint(.5067209005355835, .8180749118328094),
                  ScanPoint(.6923678517341614, .8315505087375641),
                  ScanPoint(.6923678517341614, .8996445015072823),
                  ScanPoint(.5140377283096313, .8869943618774414),
                ],
              ),
              _automaticCard(
                readable: false,
                corners: const <ScanPoint>[
                  ScanPoint(.5410077571868896, .5354828536510468),
                  ScanPoint(.9139537811279297, .5522002875804901),
                  ScanPoint(.9973424673080444, .7627191245555878),
                  ScanPoint(.5116420984268188, .7342911958694458),
                ],
              ),
            ];
          for (int frame = 0; frame < 6; frame++) {
            await _automaticPulse(tester, camera);
          }
          expect(captures, 1);
          expect(
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .observedPhotoRegions,
            isEmpty,
            reason: 'Internal panels must not become new raw capture targets.',
          );
          expect(
            camera.actions.where((String action) => action == 'photo'),
            hasLength(1),
          );
          expect(tester.takeException(), isNull);
        } finally {
          await _dismissCamera(tester, camera);
          await tester.pump(const Duration(seconds: 2));
          restore();
        }
      },
    );
  }

  for (final bool replaced in <bool>[false, true]) {
    testWidgets(
      'saved source pixels ${replaced ? 'reject a replacement' : 'confirm the original'} after delayed reading',
      (WidgetTester tester) async {
        final _AutomaticScene scene = _AutomaticScene()
          ..crop = _automaticCard(readable: false)
          ..rawAppearanceSupported = true
          ..previewAppearanceValues = List<double>.filled(288, .35);
        final VoidCallback restore = scene.install();
        final _CaptureHaptics haptics = _CaptureHaptics()..install();
        addTearDown(haptics.restore);
        final _Camera camera = _Camera();
        final _ControlledSession session = _ControlledSession(
          recognizer: _UnusedRecognizer(),
          resolver: _NoLiveIdentityResolver(),
        );
        addTearDown(session.dispose);
        String? originalCapture;
        List<String>? originalPaths;
        List<ScanPoint>? originalTarget;
        int captures = 0;
        LiveCaptureOverlay overlay() =>
            tester.widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay));
        try {
          await _show(
            tester,
            camera,
            automaticCapture: true,
            session: session,
            onUnidentifiedPhotoCaptured:
                (
                  List<String> paths,
                  List<List<ScanPoint>> excluded,
                  String captureId,
                  List<List<ScanPoint>> targets,
                ) async {
                  captures++;
                  session.rememberCapture(paths, captureId);
                  originalCapture ??= captureId;
                  originalPaths ??= paths;
                  originalTarget ??= targets.single;
                  return true;
                },
          );
          await _automaticUntil(tester, camera, () => captures == 1);
          scene.reversedRawAppearance = replaced;
          for (int frame = 0; frame < 4; frame++) {
            await _automaticPulse(tester, camera);
          }
          expect(captures, 1);
          expect(haptics.lightImpacts, 0);
          expect(overlay().safeToMovePhotoRegions, isEmpty);
          session.sourceAppearances[originalCapture!] = <SavedTargetAppearance>[
            SavedTargetAppearance(
              corners: originalTarget!,
              values: <double>[
                for (int pixel = 0; pixel < 96; pixel++)
                  for (int channel = 0; channel < 3; channel++)
                    .15 + (pixel % 12) / 18 + channel * .025,
              ],
              present: true,
            ),
          ];
          _refinePhotoObservation(
            session,
            _automaticCard(corners: originalTarget),
            id: 'saved-original',
            photoId: '${originalCapture!}_0',
          );
          session.rawCompletedGroups.add(session.captureGroup(originalPaths!));
          session.changed();
          if (replaced) {
            camera.picturePath = '/tmp/synthetic-current-replacement.jpg';
            for (int frame = 0; frame < 4; frame++) {
              await _automaticPulse(tester, camera);
              expect(overlay().safeToMovePhotoRegions, isEmpty);
              expect(haptics.lightImpacts, 0);
              expect(scene.captureConfirmations, 0);
            }
          } else {
            await _until(tester, () => haptics.lightImpacts == 1);
            expect(scene.captureConfirmations, 1);
            expect(overlay().safeToMovePhotoRegions, hasLength(1));
            for (int frame = 0; frame < 3; frame++) {
              await _automaticPulse(tester, camera);
            }
            expect(captures, 1);
            expect(haptics.lightImpacts, 1);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await _dismissCamera(tester, camera);
          await tester.pump(const Duration(seconds: 2));
          restore();
        }
      },
    );
  }

  testWidgets(
    'raw receipt ignores a preview baseline from a different footprint',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..rawAppearanceSupported = true
        ..reversedRawAppearance = true
        ..previewAppearanceCorners = const <ScanPoint>[
          ScanPoint(.108, .194),
          ScanPoint(.328, .194),
          ScanPoint(.328, .644),
          ScanPoint(.108, .644),
        ];
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final List<String> receipts = <String>[];
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                receipts.add(captureId);
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => receipts.length == 1);
        expect(
          scene.appearanceRequests
              .expand((List<Object?> regions) => regions)
              .whereType<Map<Object?, Object?>>()
              .any(
                (Map<Object?, Object?> sample) =>
                    (sample['id']! as String).startsWith('preview_'),
              ),
          isTrue,
        );
        for (int frame = 0; frame < 8; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          receipts,
          hasLength(1),
          reason:
              'A nearby preview region cannot establish the shutter pixels.',
        );
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          hasLength(1),
        );
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        scene.reversedRawAppearance = false;
        camera.picturePath = '/tmp/synthetic-new-card-after-baseline.jpg';
        await _automaticUntil(tester, camera, () => receipts.length == 2);
        expect(receipts.toSet(), hasLength(2));
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'raw receipts survive unknown frames and rearm after sustained native appearance change',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final List<String> receipts = <String>[];
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                receipts.add(captureId);
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => receipts.length == 1);
        for (int frame = 0; frame < 5; frame++) {
          await _automaticPulse(tester, camera);
        }
        final Set<String> initialIds = scene.appearanceRequests
            .expand((List<Object?> regions) => regions)
            .map(
              (Object? region) =>
                  (region! as Map<Object?, Object?>)['id']! as String,
            )
            .where((String id) => id.startsWith('raw_'))
            .toSet();
        expect(initialIds, <String>{'raw_${receipts.single}_0'});
        scene
          ..showCards = false
          ..omitRawAppearance = true;
        for (int frame = 0; frame < 6; frame++) {
          await _automaticPulse(tester, camera);
        }
        scene
          ..showCards = true
          ..omitRawAppearance = false;
        for (int frame = 0; frame < 5; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          receipts,
          hasLength(1),
          reason: 'Unknown frames cannot prove that a card left.',
        );
        scene.reversedAppearance = true;
        camera.picturePath = '/tmp/synthetic-replaced-raw-card.jpg';
        await _automaticUntil(tester, camera, () => receipts.length == 2);
        expect(receipts.toSet(), hasLength(2));
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .any((LiveScanTrack track) => track.capturedIdentified),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'raw receipts rearm only after repeated native flat background evidence',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => captures == 1);
        scene
          ..showCards = false
          ..rawAppearancePresent = false
          ..rawAppearanceFlat = true;
        for (int frame = 0; frame < 6; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(captures, 1);
        scene
          ..showCards = true
          ..rawAppearancePresent = true
          ..rawAppearanceFlat = false;
        camera.picturePath = '/tmp/synthetic-returned-raw-card.jpg';
        await _automaticUntil(tester, camera, () => captures == 2);
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'eight raw owners retire on a changed textured desk and allow the ninth card',
    (WidgetTester tester) async {
      final List<ScanCrop> cards = _automaticGrid(8)
          .map(
            (ScanCrop card) =>
                _automaticCard(readable: false, corners: card.sourceCorners),
          )
          .toList();
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = cards.first
        ..additionalCrops = cards.skip(1).toList()
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final List<int> admittedCards = <int>[];
      LiveCaptureOverlay overlay() =>
          tester.widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay));
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                admittedCards.add(targets.length);
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => admittedCards.isNotEmpty);
        await _until(tester, () => overlay().retainedPhotoRegions.length == 8);
        expect(admittedCards, <int>[8]);
        expect(session.pendingPhotoCaptures, 0);
        scene
          ..showCards = false
          ..rawAppearancePresent = false
          ..reversedRawAppearance = true;
        await _automaticPulse(tester, camera);
        scene
          ..showCards = true
          ..rawAppearancePresent = true
          ..reversedRawAppearance = false;
        await _automaticPulse(tester, camera);
        await _until(tester, () => overlay().retainedPhotoRegions.length == 8);
        expect(admittedCards, <int>[8]);
        scene
          ..showCards = false
          ..rawAppearancePresent = false
          ..reversedRawAppearance = true;
        for (int frame = 0; frame < 6; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(admittedCards, <int>[8]);
        scene
          ..crop = _automaticCard(readable: false)
          ..additionalCrops = <ScanCrop>[]
          ..showCards = true
          ..rawAppearancePresent = true
          ..reversedRawAppearance = false;
        camera.picturePath = '/tmp/synthetic-ninth-raw-card.jpg';
        await _automaticUntil(tester, camera, () => admittedCards.length == 2);
        expect(admittedCards, <int>[8, 1]);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(2),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  for (final String evidence in <String>[
    'same original',
    'illumination shift',
    'missing shutter baseline',
    'overlapping partial geometry',
  ]) {
    testWidgets('textured raw absence preserves ownership with $evidence', (
      WidgetTester tester,
    ) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..rawAppearanceSupported = true;
      if (evidence == 'missing shutter baseline') {
        scene.previewAppearanceValues = List<double>.filled(288, .35);
      }
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final ScanSession session = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                captures++;
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => captures == 1);
        scene
          ..showCards = false
          ..rawAppearancePresent = false;
        if (evidence == 'illumination shift') {
          scene.rawAppearanceValues = <double>[
            for (int pixel = 0; pixel < 96; pixel++)
              for (int channel = 0; channel < 3; channel++)
                (.15 + (pixel % 12) / 18 + channel * .025) * .65,
          ];
        } else if (evidence != 'same original') {
          scene.reversedRawAppearance = true;
        }
        if (evidence == 'overlapping partial geometry') {
          scene
            ..showCards = true
            ..geometryConfidence = .5
            ..crop = _automaticCard(
              readable: false,
              corners: const <ScanPoint>[
                ScanPoint(.15, .30),
                ScanPoint(.25, .30),
                ScanPoint(.25, .45),
                ScanPoint(.15, .45),
              ],
            );
        }
        for (int frame = 0; frame < 6; frame++) {
          await _automaticPulse(tester, camera);
        }
        scene
          ..showCards = true
          ..rawAppearancePresent = true
          ..reversedRawAppearance = false
          ..rawAppearanceValues = null
          ..geometryConfidence = .99
          ..crop = _automaticCard(readable: false);
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(captures, 1);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    });
  }

  testWidgets(
    'busy camera callbacks cannot starve four raw appearance receipts under strong ROI load',
    (WidgetTester tester) async {
      final List<ScanCrop> strong = _automaticGrid(6);
      final List<ScanCrop> raw = <ScanCrop>[
        for (int index = 0; index < 4; index++)
          _automaticCard(
            readable: false,
            corners: <ScanPoint>[
              ScanPoint(.08 + index * .2, .72),
              ScanPoint(.21 + index * .2, .72),
              ScanPoint(.21 + index * .2, .98),
              ScanPoint(.08 + index * .2, .98),
            ],
          ),
      ];
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = strong.first
        ..additionalCrops = strong.skip(1).toList()
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: _AutomaticCatalog()),
      );
      addTearDown(session.dispose);
      String? rawCaptureId;
      int rawCaptures = 0;
      final ValueNotifier<GuidedCameraScreen> cameraUpdates =
          ValueNotifier<GuidedCameraScreen>(_mixedOwnerCamera(session));
      addTearDown(cameraUpdates.dispose);
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          cameraUpdates: cameraUpdates,
        );
        await _automaticUntil(
          tester,
          camera,
          () =>
              session.items.length == 6 &&
              session.items.every(
                (ScanSessionItem item) =>
                    item.resolution != null && item.crop.imagePath.isNotEmpty,
              ),
        );
        cameraUpdates.value = _mixedOwnerCamera(
          session,
          rawHandoff:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                expect(targets, hasLength(4));
                rawCaptureId = captureId;
                rawCaptures++;
                return true;
              },
        );
        await tester.pump();
        scene
          ..crop = raw.first
          ..additionalCrops = raw.skip(1).toList();
        await _automaticUntil(tester, camera, () => rawCaptures == 1);
        scene.appearanceRequests.clear();
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera, callbacks: 4);
        }
        final List<List<Object?>> mixed = scene.appearanceRequests
            .where(
              (List<Object?> regions) => regions.any(
                (Object? region) =>
                    ((region! as Map<Object?, Object?>)['id']! as String)
                        .startsWith('raw_'),
              ),
            )
            .toList();
        expect(
          mixed,
          hasLength(4),
          reason: 'Only one callback in each burst reaches native analysis.',
        );
        expect(
          mixed.every((List<Object?> regions) => regions.length == 8),
          isTrue,
        );
        final Set<String> sampledRawIds = mixed
            .expand((List<Object?> regions) => regions)
            .map(
              (Object? region) =>
                  (region! as Map<Object?, Object?>)['id']! as String,
            )
            .where((String id) => id.startsWith('raw_'))
            .toSet();
        expect(sampledRawIds, <String>{
          for (int index = 0; index < 4; index++) 'raw_${rawCaptureId!}_$index',
        });
        expect(rawCaptures, 1);
        expect(session.items, hasLength(6));
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'eight completed owners each receive bounded readable verification after visual retirement without another quantity',
    (WidgetTester tester) async {
      final List<ScanCrop> cards = _automaticGrid(8);
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = cards.first
        ..additionalCrops = cards.skip(1).toList()
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: _AutomaticCatalog()),
      );
      addTearDown(session.dispose);
      List<LiveScanTrack> identified() => tester
          .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
          .tracks
          .where((LiveScanTrack track) => track.capturedIdentified)
          .toList();
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>>? targets,
              ) async {
                _publishSavedPhotoCards(session, paths, captureId, cards);
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => identified().length == 8);
        final Set<String> owners = identified()
            .map((LiveScanTrack track) => track.id)
            .toSet();
        final int photos = camera.actions
            .where((String action) => action == 'photo')
            .length;
        scene.exclusions.clear();
        scene.appearanceRequests.clear();
        scene.textRequests.clear();
        for (int frame = 0; frame < 26; frame++) {
          await _automaticPulse(tester, camera, callbacks: 4);
        }
        final Set<String> verified = <String>{};
        int textFrames = 0;
        for (int index = 0; index < scene.exclusions.length; index++) {
          final Set<String> masked = scene.exclusions[index]
              .map(
                (Object? value) =>
                    (value! as Map<Object?, Object?>)['id']! as String,
              )
              .toSet();
          if (scene.textRequests[index]) {
            textFrames++;
            expect(masked, hasLength(7));
            final Set<String> readable = owners.difference(masked);
            expect(readable, hasLength(1));
            verified.addAll(readable);
          } else {
            expect(masked, owners);
          }
          expect(scene.appearanceRequests[index], hasLength(8));
        }
        expect(textFrames, greaterThanOrEqualTo(8));
        expect(verified, owners);
        expect(
          scene.appearanceRequests.last
              .map(
                (Object? value) =>
                    (value! as Map<Object?, Object?>)['id']! as String,
              )
              .toSet(),
          owners,
        );
        expect(identified(), isEmpty);
        expect(session.items, hasLength(8));
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(photos),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'eight visible saved contours cannot crowd a new raw contour out of observations',
    (WidgetTester tester) async {
      final List<ScanCrop> strong = _automaticGrid(8);
      final ScanCrop raw = _automaticCard(
        readable: false,
        corners: const <ScanPoint>[
          ScanPoint(.83, .65),
          ScanPoint(.97, .65),
          ScanPoint(.97, .94),
          ScanPoint(.83, .94),
        ],
      );
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = strong.first
        ..additionalCrops = strong.skip(1).toList()
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: _AutomaticCatalog()),
      );
      addTearDown(session.dispose);
      int rawCaptures = 0;
      List<List<ScanPoint>>? capturedTargets;
      List<List<ScanPoint>>? capturedExclusions;
      final ValueNotifier<GuidedCameraScreen> cameraUpdates =
          ValueNotifier<GuidedCameraScreen>(_mixedOwnerCamera(session));
      addTearDown(cameraUpdates.dispose);
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          cameraUpdates: cameraUpdates,
        );
        await _automaticUntil(
          tester,
          camera,
          () =>
              session.items.length == 8 &&
              session.items.every(
                (ScanSessionItem item) =>
                    item.resolution != null && item.crop.imagePath.isNotEmpty,
              ),
        );
        cameraUpdates.value = _mixedOwnerCamera(
          session,
          rawHandoff:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                capturedTargets = targets;
                capturedExclusions = excluded;
                rawCaptures++;
                return true;
              },
        );
        await tester.pump();
        scene.geometryCrops = <ScanCrop>[raw];
        await _automaticUntil(tester, camera, () => rawCaptures == 1);
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(rawCaptures, 1);
        expect(
          capturedTargets!
              .map(
                (List<ScanPoint> region) => region
                    .map((ScanPoint point) => (point.x, point.y))
                    .toList(),
              )
              .toList(),
          <List<(double, double)>>[
            raw.sourceCorners
                .map((ScanPoint point) => (point.x, point.y))
                .toList(),
          ],
        );
        expect(capturedExclusions, hasLength(8));
        expect(session.items, hasLength(8));
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'raw appearance receipts receive native slots while eight strong receipts remain owned',
    (WidgetTester tester) async {
      final List<ScanCrop> strong = _automaticGrid(8);
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = strong.first
        ..additionalCrops = strong.skip(1).toList()
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: _AutomaticCatalog()),
      );
      addTearDown(session.dispose);
      int rawCaptures = 0;
      final ValueNotifier<GuidedCameraScreen> cameraUpdates =
          ValueNotifier<GuidedCameraScreen>(_mixedOwnerCamera(session));
      addTearDown(cameraUpdates.dispose);
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          cameraUpdates: cameraUpdates,
        );
        await _automaticUntil(
          tester,
          camera,
          () =>
              session.items.length == 8 &&
              session.items.every(
                (ScanSessionItem item) =>
                    item.resolution != null && item.crop.imagePath.isNotEmpty,
              ),
        );
        cameraUpdates.value = _mixedOwnerCamera(
          session,
          rawHandoff:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                rawCaptures++;
                return true;
              },
        );
        await tester.pump();
        scene
          ..crop = _automaticCard(
            readable: false,
            corners: const <ScanPoint>[
              ScanPoint(.83, .65),
              ScanPoint(.97, .65),
              ScanPoint(.97, .94),
              ScanPoint(.83, .94),
            ],
          )
          ..additionalCrops = <ScanCrop>[];
        await _automaticUntil(tester, camera, () => rawCaptures == 1);
        final int focusProbes = scene.nativeFocusPoints.length;
        for (int frame = 0; frame < 5; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          scene.nativeFocusPoints,
          hasLength(focusProbes),
          reason:
              'A durably owned raw photo must not be refocused by discovery.',
        );
        final List<List<Object?>> mixed = scene.appearanceRequests
            .where(
              (List<Object?> regions) => regions.any(
                (Object? region) =>
                    ((region! as Map<Object?, Object?>)['id']! as String)
                        .startsWith('raw_'),
              ),
            )
            .toList();
        expect(mixed, isNotEmpty);
        expect(
          mixed.every((List<Object?> regions) => regions.length == 8),
          isTrue,
        );
        final Set<String> strongIds = mixed
            .expand((List<Object?> regions) => regions)
            .map(
              (Object? region) =>
                  (region! as Map<Object?, Object?>)['id']! as String,
            )
            .where((String id) => !id.startsWith('raw_'))
            .toSet();
        expect(strongIds, hasLength(8));
        expect(session.items, hasLength(8));
        scene.reversedRawAppearance = true;
        camera.picturePath = '/tmp/synthetic-raw-rearmed-under-load.jpg';
        await _automaticUntil(tester, camera, () => rawCaptures == 2);
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'raw shutter and pending retries retain their original session handoff',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera()..pendingPicture = Completer<XFile>();
      final ScanSession original = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      final ScanSession replacement = ScanSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(original.dispose);
      addTearDown(replacement.dispose);
      bool save = false;
      int originalCalls = 0;
      int replacementCalls = 0;
      final ValueNotifier<GuidedCameraScreen> cameraUpdates =
          ValueNotifier<GuidedCameraScreen>(
            GuidedCameraScreen(
              session: original,
              onUnidentifiedPhotoCaptured:
                  (
                    List<String> paths,
                    List<List<ScanPoint>> excluded,
                    String captureId,
                    List<List<ScanPoint>> targets,
                  ) async {
                    originalCalls++;
                    return save;
                  },
              onCaptured: (String path, List<List<ScanPoint>> excluded) async =>
                  true,
            ),
          );
      addTearDown(cameraUpdates.dispose);
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: original,
          cameraUpdates: cameraUpdates,
        );
        await _automaticUntil(
          tester,
          camera,
          () => camera.actions.contains('photo'),
        );
        cameraUpdates.value = GuidedCameraScreen(
          session: replacement,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> targets,
              ) async {
                replacementCalls++;
                return true;
              },
          onCaptured: (String path, List<List<ScanPoint>> excluded) async =>
              true,
        );
        await tester.pump();
        camera.pendingPicture!.complete(
          XFile('/tmp/synthetic-original-session-photo.jpg'),
        );
        await _until(tester, () => originalCalls == 1);
        expect(replacementCalls, 0);
        expect(find.text('Retry save'), findsOneWidget);
        save = true;
        await tester.tap(find.text('Retry save'));
        await _until(
          tester,
          () =>
              originalCalls == 2 && find.text('Retry save').evaluate().isEmpty,
        );
        expect(replacementCalls, 0);
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          isEmpty,
        );
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!camera.pendingPicture!.isCompleted) {
          camera.pendingPicture!.completeError(StateError('test ended'));
        }
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'a completed raw scene preserves observations and allows the next card to capture',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene();
      final ScanCrop firstCrop = scene.crop;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _ProcessingSession session = _ProcessingSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final List<List<String>> captures = <List<String>>[];
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> exclusions,
                String captureId,
                List<List<ScanPoint>>? targetRegions,
              ) async {
                captures.add(List<String>.of(paths));
                _refinePhotoObservation(
                  session,
                  scene.crop,
                  id: 'completed-scene-${captures.length}',
                  photoId: '${captureId}_0',
                );
                session.rawCompletedGroups.add(captureId);
                session.changed();
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => captures.length == 1);
        scene.crop = _automaticCard(
          corners: const <ScanPoint>[
            ScanPoint(.58, .2),
            ScanPoint(.8, .2),
            ScanPoint(.8, .65),
            ScanPoint(.58, .65),
          ],
        );
        scene.additionalCrops = <ScanCrop>[firstCrop];
        camera.picturePath = '/tmp/synthetic-empty-receipt-next-card.jpg';
        await _automaticUntil(tester, camera, () => captures.length == 2);
        expect(session.items, hasLength(2));
        expect(
          session.items.every(
            (ScanSessionItem item) => item.liveIdentityName == null,
          ),
          isTrue,
        );
        expect(session.running, isTrue);
        expect(
          captures.every((List<String> paths) => paths.length == 1),
          isTrue,
          reason: 'Only the new card needs a focused photo.',
        );
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .every((LiveScanTrack track) => !track.capturedIdentified),
          isTrue,
          reason: 'A processing receipt without saved identity cannot turn a card green.',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );
  testWidgets(
    'unread frozen geometry prevents duplicate ownership while a disjoint card captures',
    (WidgetTester tester) async {
      final ScanCrop middle = _automaticCard(
        corners: const <ScanPoint>[
          ScanPoint(.4, .2),
          ScanPoint(.62, .2),
          ScanPoint(.62, .65),
          ScanPoint(.4, .65),
        ],
      );
      final ScanCrop rear = _automaticCard(
        corners: const <ScanPoint>[
          ScanPoint(.7, .2),
          ScanPoint(.92, .2),
          ScanPoint(.92, .65),
          ScanPoint(.7, .65),
        ],
      );
      final _AutomaticScene scene = _AutomaticScene()
        ..geometryCrops = <ScanCrop>[middle];
      final ScanCrop front = scene.crop;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final List<List<String>> captures = <List<String>>[];
      final List<List<List<ScanPoint>>> exclusions = <List<List<ScanPoint>>>[];
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excludedRegions,
                String captureId,
                List<List<ScanPoint>>? targetRegions,
              ) async {
                captures.add(List<String>.of(paths));
                exclusions.add(excludedRegions);
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => captures.length == 1);
        scene.geometryCrops.clear();
        scene.additionalCrops = <ScanCrop>[middle];
        camera.picturePath = '/tmp/synthetic-disjoint-frozen-region.jpg';
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(captures, hasLength(1));
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .singleWhere((LiveScanTrack track) => track.corners.first.x == .4)
              .captured,
          isFalse,
          reason: 'The newly readable card waits for its original photo OCR.',
        );
        scene.additionalCrops = <ScanCrop>[middle, rear];
        await _automaticUntil(tester, camera, () => captures.length == 2);
        expect(
          session.items,
          isEmpty,
          reason: 'Saved-source recognition has not supplied any crop yet.',
        );
        expect(
          session.items.every(
            (ScanSessionItem item) => item.liveIdentityName == null,
          ),
          isTrue,
        );
        expect(
          captures.every((List<String> paths) => paths.length == 1),
          isTrue,
        );
        expect(
          exclusions.last.map((List<ScanPoint> corners) => corners.first.x),
          unorderedEquals(<double>[.1, .4]),
        );
        final List<LiveScanTrack> tracks = tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks;
        expect(
          tracks
              .singleWhere((LiveScanTrack track) => track.corners.first.x == .4)
              .captured,
          isFalse,
          reason: 'Suppression of an unread region cannot grant it a second receipt.',
        );
        for (int group = 0; group < captures.length; group++) {
          final String id = session.captureGroup(captures[group]);
          final List<ScanCrop> crops = group == 0
              ? <ScanCrop>[front, middle]
              : <ScanCrop>[rear];
          for (int index = 0; index < crops.length; index++) {
            _refinePhotoObservation(
              session,
              crops[index],
              id: 'frozen-$group-$index',
              photoId: '${id}_0',
            );
          }
          session.rawCompletedGroups.add(id);
        }
        session.changed();
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(captures, hasLength(2));
        expect(session.items, hasLength(3));
        expect(camera.actions, isNot(contains('stream stop')));
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'missing raw cards at two depths get separate focused sweep photos without duplicate crops',
    (WidgetTester tester) async {
      final ScanCrop middle = _automaticCard(
        corners: const <ScanPoint>[
          ScanPoint(.4, .2),
          ScanPoint(.62, .2),
          ScanPoint(.62, .65),
          ScanPoint(.4, .65),
        ],
      );
      final ScanCrop rear = _automaticCard(
        corners: const <ScanPoint>[
          ScanPoint(.7, .2),
          ScanPoint(.92, .2),
          ScanPoint(.92, .65),
          ScanPoint(.7, .65),
        ],
      );
      final _AutomaticScene scene = _AutomaticScene()
        ..additionalCrops = <ScanCrop>[middle, rear];
      final ScanCrop front = scene.crop;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final List<List<String>> captures = <List<String>>[];
      final List<List<List<ScanPoint>>> exclusions = <List<List<ScanPoint>>>[];
      final List<List<List<ScanPoint>>?> capturedTargets =
          <List<List<ScanPoint>>?>[];
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excludedRegions,
                String captureId,
                List<List<ScanPoint>>? targetRegions,
              ) async {
                captures.add(List<String>.of(paths));
                exclusions.add(excludedRegions);
                capturedTargets.add(
                  targetRegions
                      ?.map(
                        (List<ScanPoint> corners) =>
                            List<ScanPoint>.of(corners),
                      )
                      .toList(),
                );
                final String group = captureId;
                final List<ScanCrop> crops = switch (captures.length) {
                  1 => <ScanCrop>[front],
                  2 => <ScanCrop>[middle],
                  _ => <ScanCrop>[rear],
                };
                for (int index = 0; index < crops.length; index++) {
                  _refinePhotoObservation(
                    session,
                    crops[index],
                    id: 'adaptive-${captures.length}-$index',
                    photoId: '${group}_0',
                  );
                }
                session.rawCompletedGroups.add(group);
                if (captures.length == 1) {
                  session.failedPhotoCount = 1;
                }
                camera.picturePath =
                    '/tmp/synthetic-depth-recovery-${captures.length}.jpg';
                session.changed();
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => captures.length == 1);
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(captures, hasLength(1));
        expect(session.items, hasLength(1));
        expect(
          session.items.where(
            (ScanSessionItem item) => item.crop.imagePath.isNotEmpty,
          ),
          hasLength(1),
        );
        expect(
          session.items.where(
            (ScanSessionItem item) => item.crop.imagePath.isEmpty,
          ),
          isEmpty,
        );
        expect(scene.nativeFocusPoints, isEmpty);
        session.failedPhotoCount = 0;
        session.storageError = 'Synthetic storage failure';
        session.changed();
        for (int frame = 0; frame < 3; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(captures, hasLength(1));
        expect(scene.nativeFocusPoints, isEmpty);
        session.storageError = null;
        session.changed();
        await _automaticUntil(tester, camera, () => captures.length == 3);
        expect(
          captures.every((List<String> paths) => paths.length == 1),
          isTrue,
        );
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(3),
        );
        expect(capturedTargets, hasLength(3));
        expect(capturedTargets, everyElement(isNotNull));
        for (int capture = 1; capture < capturedTargets.length; capture++) {
          final List<List<ScanPoint>> targets = capturedTargets[capture]!;
          final List<ScanPoint> expected =
              (capture == 1 ? middle : rear).sourceCorners;
          expect(
            targets,
            hasLength(1),
            reason: 'A focused recovery photo excludes neighboring cards.',
          );
          expect(targets.single, hasLength(4));
          for (int point = 0; point < expected.length; point++) {
            expect(targets.single[point].x, closeTo(expected[point].x, 1e-6));
            expect(targets.single[point].y, closeTo(expected[point].y, 1e-6));
          }
        }
        expect(exclusions.first, isEmpty);
        expect(exclusions[1], hasLength(2));
        expect(
          exclusions[1].map((List<ScanPoint> corners) => corners.first.x),
          unorderedEquals(<double>[.1, .7]),
          reason: 'The unattempted rear receipt stays protected while the middle card refocuses.',
        );
        expect(exclusions.last, hasLength(2));
        expect(
          exclusions.last.map((List<ScanPoint> corners) => corners.first.x),
          unorderedEquals(<double>[.1, .4]),
        );
        expect(scene.nativeFocusPoints, hasLength(2));
        expect(scene.nativeSingleShotRequests, <bool>[false, false]);
        expect(
          scene.nativeFocusPoints.first.dx,
          closeTo(.51, .001),
          reason: 'The first missing depth receives its own focused shutter.',
        );
        expect(scene.nativeFocusPoints.last.dx, closeTo(.81, .001));
        expect(
          scene.nativeFocusPoints.every(
            (Offset point) => (point.dy - .425).abs() < .001,
          ),
          isTrue,
        );
        expect(session.items, hasLength(3));
        expect(
          session.items.every(
            (ScanSessionItem item) => item.liveIdentityName == null,
          ),
          isTrue,
        );
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(captures, hasLength(3));
        expect(session.items, hasLength(3));
        expect(camera.actions, isNot(contains('stream stop')));
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'sweep keeps tracking through photo and save and never marks a replacement from the old receipt',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene();
      final ScanCrop photographed = scene.crop;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera()..pendingPicture = Completer<XFile>();
      final Completer<bool> acknowledgement = Completer<bool>();
      final _AutomaticCatalog catalog = _AutomaticCatalog();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: ScanResolver(catalog: catalog),
      );
      addTearDown(session.dispose);
      int imports = 0;
      List<LiveScanTrack> tracks() => tester
          .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
          .tracks;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> exclusions,
                String captureId,
                List<List<ScanPoint>>? targetRegions,
              ) {
                imports++;
                expect(paths, hasLength(1));
                final ScanSessionItem admitted = _refinePhotoObservation(
                  session,
                  photographed,
                  id: 'frozen-source',
                  photoId: '${captureId}_0',
                );
                expect(admitted.photoId, '${captureId}_0');
                admitted.resolution = ScanResolution(
                  candidates: <ScanCandidate>[
                    ScanCandidate(catalog.card, const <ScanEvidence>{
                      ScanEvidence.nameMatch,
                    }),
                  ],
                  hints: ScanHints.fromCrop(photographed),
                  status: ScanResolutionStatus.needsReview,
                );
                session.changed();
                return acknowledgement.future;
              },
        );
        await _automaticUntil(
          tester,
          camera,
          () => camera.actions.contains('photo'),
        );
        expect(camera.frames.hasListener, isTrue);
        expect(camera.actions, isNot(contains('stream stop')));
        expect(session.items, isEmpty);
        expect(scene.captureConfirmations, 0);
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .safeToMoveTrackIds,
          isEmpty,
        );
        for (int frame = 0; frame < 3; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          tracks().every((LiveScanTrack track) => !track.capturedIdentified),
          isTrue,
        );
        scene.reversedAppearance = true;
        scene.crop = ScanCrop(
          imagePath: '',
          width: 1000,
          height: 1400,
          rectified: true,
          sourceCorners: photographed.sourceCorners,
          lines: const <ScanTextLine>[
            ScanTextLine(
              text: 'Counterspell',
              confidence: .99,
              bounds: ScanBounds(.1, .04, .7, .03),
            ),
            ScanTextLine(
              text: 'Instant',
              confidence: .99,
              bounds: ScanBounds(.1, .5, .7, .03),
            ),
            ScanTextLine(
              text: 'Counter target spell.',
              confidence: .99,
              bounds: ScanBounds(.1, .62, .8, .03),
            ),
          ],
        );
        await _automaticUntil(
          tester,
          camera,
          () => tracks().any(
            (LiveScanTrack track) =>
                ScanHints.fromCrop(track.crop).names.contains('Counterspell'),
          ),
        );
        expect(
          tracks().every((LiveScanTrack track) => !track.captured),
          isTrue,
        );
        camera.pendingPicture!.complete(XFile(camera.picturePath));
        await _until(tester, () => imports == 1);
        expect(camera.frames.hasListener, isTrue);
        for (int frame = 0; frame < 3; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(imports, 1);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        expect(
          tracks().every((LiveScanTrack track) => !track.captured),
          isTrue,
        );
        acknowledgement.complete(true);
        await _until(tester, () => find.text('Saving…').evaluate().isEmpty);
        expect(session.items, hasLength(1));
        expect(session.items.single.printing!.name, 'Lightning Bolt');
        expect(scene.captureConfirmations, 0);
        expect(find.text('Next card'), findsNothing);
        expect(
          tracks()
              .where(
                (LiveScanTrack track) =>
                    ScanHints.fromCrop(track.crop).names
                        .contains('Counterspell'),
              )
              .every((LiveScanTrack track) => !track.capturedIdentified),
          isTrue,
          reason:
              'The saved Lightning Bolt receipt belongs to the shutter scene.',
        );
        expect(camera.actions, isNot(contains('stream stop')));
        expect(tester.takeException(), isNull);
      } finally {
        if (!acknowledgement.isCompleted) acknowledgement.complete(false);
        if (!camera.pendingPicture!.isCompleted) {
          camera.pendingPicture!.completeError(
            CameraException('cancelled', 'Test ended before capture.'),
          );
        }
        await _dismissCamera(tester, camera);
        await tester.pump(const Duration(milliseconds: 500));
        restore();
      }
    },
  );

  testWidgets(
    'sweep captures new cards before prior OCR completes and pauses at bounded backlog',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene();
      final ScanCrop firstCrop = scene.crop;
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _ProcessingSession session = _ProcessingSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final List<List<String>> captures = <List<String>>[];
      final List<List<List<ScanPoint>>> excluded = <List<List<ScanPoint>>>[];
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> exclusions,
                String captureId,
                List<List<ScanPoint>>? targetRegions,
              ) async {
                captures.add(List<String>.of(paths));
                excluded.add(exclusions);
                final ScanSessionItem item = _refinePhotoObservation(
                  session,
                  scene.crop,
                  id: 'source-${captures.length}',
                  photoId: '${captureId}_0',
                );
                item.resolution = null;
                session.changed();
                return true;
              },
        );
        await _automaticUntil(tester, camera, () => captures.length == 1);
        await _until(
          tester,
          () => tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .any((LiveScanTrack track) => track.captured),
        );
        expect(session.running, isTrue);
        expect(session.items, hasLength(1));
        expect(session.items.single.liveIdentityName, isNull);
        final int photosBefore = camera.actions
            .where((String action) => action == 'photo')
            .length;
        scene.crop = _automaticCard(
          corners: const <ScanPoint>[
            ScanPoint(.58, .2),
            ScanPoint(.8, .2),
            ScanPoint(.8, .65),
            ScanPoint(.58, .65),
          ],
        );
        scene.additionalCrops = <ScanCrop>[firstCrop];
        camera.picturePath = '/tmp/synthetic-next-card.jpg';
        await _automaticUntil(tester, camera, () => captures.length == 2);
        expect(
          captures,
          hasLength(2),
          reason: 'A durable source photo permits a new physical scene while OCR is pending.',
        );
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(photosBefore + 1),
        );
        expect(
          captures.every((List<String> paths) => paths.length == 1),
          isTrue,
        );
        expect(camera.actions, isNot(contains('stream stop')));
        expect(session.items, hasLength(2));
        final String firstGroup = session.captureGroup(captures.first);
        final ScanSessionItem firstItem = session.items.singleWhere(
          (ScanSessionItem item) => item.photoId == '${firstGroup}_0',
        );
        firstItem
          ..crop = firstCrop
          ..resolution = null;
        session.queuedPhotos = 8;
        session.changed();
        final ScanCrop secondCrop = scene.crop;
        scene.crop = _automaticCard(
          corners: const <ScanPoint>[
            ScanPoint(.34, .52),
            ScanPoint(.56, .52),
            ScanPoint(.56, .97),
            ScanPoint(.34, .97),
          ],
        );
        scene.additionalCrops = <ScanCrop>[firstCrop, secondCrop];
        camera.picturePath = '/tmp/synthetic-third-card.jpg';
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          captures,
          hasLength(2),
          reason: 'Eight queued photos bound automatic admission even after raw-card receipt.',
        );
        expect(firstItem.resolution, isNull);
        expect(session.items, hasLength(2));
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks
              .every((LiveScanTrack track) => !track.capturedIdentified),
          isTrue,
        );
        session.queuedPhotos = 0;
        session.changed();
        await _automaticUntil(tester, camera, () => captures.length == 3);
        expect(
          session.running,
          isTrue,
          reason: 'Catalog processing is still in progress while the next physical card captures.',
        );
        expect(firstItem.resolution, isNull);
        expect(session.items, hasLength(3));
        expect(excluded.first, isEmpty);
        expect(excluded[1], hasLength(1));
        expect(
          excluded[1].single.map((ScanPoint point) => point.x),
          firstCrop.sourceCorners.map((ScanPoint point) => point.x),
        );
        expect(
          excluded[1].single.map((ScanPoint point) => point.y),
          firstCrop.sourceCorners.map((ScanPoint point) => point.y),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'automatic capture ignores desk rectangles and uncorroborated title-only OCR',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      int saved = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          onCaptured:
              (String path, List<List<ScanPoint>> excludedRegions) async {
                saved++;
                return true;
              },
        );
        for (int frame = 0; frame < 6; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks,
          isEmpty,
        );
        scene.crop = _automaticCard(titleOnly: true);
        for (int frame = 0; frame < 6; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(
          camera.actions.where((String action) => action == 'photo'),
          isEmpty,
        );
        expect(saved, 0);
        expect(
          find.byKey(const ValueKey<String>('camera-shutter')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'automatic camera without a session prevents dismissal until its required photo save succeeds',
    (WidgetTester tester) async {
      final Directory directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('camera-without-session-'),
      ))!;
      Hive.init(directory.path);
      await tester.runAsync(() => Hive.openBox<String>('scanner_printings_v1'));
      final _AutomaticScene scene = _AutomaticScene();
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera()..pendingPicture = Completer<XFile>();
      final Completer<bool> firstSave = Completer<bool>();
      final List<String> imports = <String>[];
      Future<bool> save(String path) {
        imports.add(path);
        return imports.length == 1
            ? firstSave.future
            : Future<bool>.value(true);
      }

      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          pushRoute: true,
          useSession: false,
          onCaptured: (String path, List<List<ScanPoint>> _) => save(path),
        );
        await _automaticUntil(
          tester,
          camera,
          () => camera.actions.contains('photo'),
        );
        await _cameraEdgeSwipe(tester);
        expect(find.byType(GuidedCameraScreen), findsOneWidget);
        camera.pendingPicture!.complete(XFile(camera.picturePath));
        await _until(tester, () => imports.length == 1);
        firstSave.complete(false);
        await _until(
          tester,
          () =>
              find
                  .widgetWithText(SecondaryButton, 'Retry save')
                  .evaluate()
                  .isNotEmpty &&
              tester
                      .widget<SecondaryButton>(
                        find.widgetWithText(SecondaryButton, 'Retry save'),
                      )
                      .onPressed !=
                  null,
        );
        expect(find.text('Save failed'), findsOneWidget);
        final Finder review = find.byKey(
          const ValueKey<String>('camera-review'),
        );
        expect(review, findsOneWidget);
        expect(tester.widget<PrimaryButton>(review).onPressed, isNull);
        await _cameraEdgeSwipe(tester);
        expect(find.byType(GuidedCameraScreen), findsOneWidget);
        await tester.tap(find.text('Retry save'));
        await _until(
          tester,
          () =>
              imports.length == 2 &&
              review.evaluate().isNotEmpty &&
              tester.widget<PrimaryButton>(review).onPressed != null,
        );
        expect(imports, <String>[camera.picturePath, camera.picturePath]);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(1),
        );
        await tester.tap(review);
        await _until(tester, () => camera.actions.last == 'dispose');
        await tester.pumpAndSettle();
        expect(find.byType(GuidedCameraScreen), findsNothing);
        expect(find.text('Open camera').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        if (!camera.pendingPicture!.isCompleted) {
          camera.pendingPicture!.complete(XFile(camera.picturePath));
        }
        if (!firstSave.isCompleted) {
          firstSave.complete(true);
        }
        await _dismissCamera(tester, camera);
        restore();
        await tester.runAsync(Hive.close);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'idle automatic iOS camera exits through an actual edge swipe without photographing',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      try {
        await _show(tester, camera, automaticCapture: true, pushRoute: true);
        expect(
          find.byKey(const ValueKey<String>('camera-shutter')),
          findsNothing,
        );
        await _cameraEdgeSwipe(tester);
        await _until(tester, () => camera.actions.last == 'dispose');
        expect(find.byType(GuidedCameraScreen), findsNothing);
        expect(find.text('Open camera').hitTestable(), findsOneWidget);
        expect(
          camera.actions.where((String action) => action == 'photo'),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _dismissCamera(tester, camera);
        restore();
      }
    },
  );

  testWidgets(
    'saved recognition identifies only its captured focus group and detaches after reset and disposal',
    (WidgetTester tester) async {
      final TargetPlatform? previousPlatform =
          debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final ScryfallScanCatalog catalog = ScryfallScanCatalog();
        final ScanResolver resolver = ScanResolver(catalog: catalog);
        final _ControlledSession session = _ControlledSession(
          recognizer: _UnusedRecognizer(),
          resolver: resolver,
        );
        addTearDown(session.dispose);
        addTearDown(catalog.close);
        ScanCrop crop(double x, String title) => ScanCrop(
          imagePath: '',
          width: 1000,
          height: 1400,
          rectified: true,
          sourceCorners: <ScanPoint>[
            ScanPoint(x, .3),
            ScanPoint(x + .18, .3),
            ScanPoint(x + .18, .65),
            ScanPoint(x, .65),
          ],
          lines: <ScanTextLine>[
            ScanTextLine(
              text: title,
              confidence: .99,
              bounds: const ScanBounds(.1, .04, .7, .03),
            ),
            const ScanTextLine(
              text: 'Instant',
              confidence: .99,
              bounds: ScanBounds(.1, .5, .7, .03),
            ),
            const ScanTextLine(
              text: 'Deal three damage to any target.',
              confidence: .99,
              bounds: ScanBounds(.1, .6, .8, .03),
            ),
          ],
        );
        final ScanCrop first = crop(.1, 'Lightning Bolt');
        final ScanCrop second = crop(.65, 'Lava Spike');
        ScanResolution identified(ScanCrop saved, String id, String name) =>
            ScanResolution(
              candidates: <ScanCandidate>[
                ScanCandidate(_SavedCard(id, name), const <ScanEvidence>{
                  ScanEvidence.nameMatch,
                }),
              ],
              hints: ScanHints.fromCrop(saved),
              status: ScanResolutionStatus.needsReview,
            );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeCardRecognizer.channel, (
              MethodCall call,
            ) async {
              if (call.method == 'cameraFocusAtPoint') return true;
              if (call.method == 'cameraFocusStatus') {
                return <String, Object>{
                  'isAdjustingFocus': false,
                  'isAdjustingExposure': false,
                  'lensPosition': .5,
                  'focusMode': 0,
                };
              }
              return <String, Object>{
                'width': 800,
                'height': 400,
                'rectanglesSupported': true,
                'cards': <Object>[
                  for (final ScanCrop saved in <ScanCrop>[first, second])
                    <String, Object>{
                      'confidence': .99,
                      'corners': saved.sourceCorners
                          .map(
                            (ScanPoint point) => <String, double>{
                              'x': point.x,
                              'y': point.y,
                            },
                          )
                          .toList(),
                      'lines': saved.lines
                          .map(
                            (ScanTextLine line) => <String, Object>{
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
                      'warnings': <String>[],
                    },
                ],
              };
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(NativeCardRecognizer.channel, null),
        );
        final _Camera camera = _Camera();
        final Completer<bool> acknowledgement = Completer<bool>();
        List<String>? paths;
        await _show(
          tester,
          camera,
          session: session,
          onFocusStackCaptured:
              (
                List<String> captured,
                List<List<ScanPoint>> excludedRegions,
                String captureId,
                List<List<ScanPoint>>? targetRegions,
              ) {
                paths = List<String>.of(captured);
                return acknowledgement.future;
              },
        );
        expect(session.hasObservers, isTrue);
        CameraImageData frame() => CameraImageData(
          format: const CameraImageFormat(
            ImageFormatGroup.bgra8888,
            raw: 1111970369,
          ),
          planes: <CameraImagePlane>[
            CameraImagePlane(
              bytes: Uint8List(16),
              bytesPerRow: 8,
              bytesPerPixel: 4,
            ),
          ],
          width: 2,
          height: 2,
        );
        List<LiveScanTrack> tracks() => tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks;
        camera.frames.add(frame());
        await _until(tester, () => tracks().length == 2);
        final List<String> originalIds = tracks()
            .map((LiveScanTrack track) => track.id)
            .toList();
        await tester.tap(find.byKey(const ValueKey<String>('camera-shutter')));
        for (int index = 0; index < 80 && paths == null; index++) {
          await tester.pump(const Duration(milliseconds: 250));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        }
        expect(paths, isNotNull);
        final String group = session.captureGroup(paths!);
        final String oldGroup = ScanDraftStore.focusStackCaptureId(
          List<String>.filled(paths!.length, '/tmp/previous-focus-scene.jpg'),
        );
        final ScanSessionItem matching = ScanSessionItem(
          first,
          id: 'current-first',
          photoId: '${group}_0',
        );
        final ScanSessionItem old = ScanSessionItem(
          second,
          id: 'previous-second',
          photoId: '${oldGroup}_0',
        )..resolution = identified(second, 'lava-spike', 'Lava Spike');
        final ScanCrop elsewhere = crop(.4, 'Lava Spike');
        final ScanSessionItem unrelated = ScanSessionItem(
          elsewhere,
          id: 'current-elsewhere',
          photoId: '${group}_1',
        )..resolution = identified(elsewhere, 'lava-spike', 'Lava Spike');
        session.add(matching);
        session.add(old);
        session.add(unrelated);
        session.changed();
        await tester.pump();
        expect(tracks().any((LiveScanTrack track) => track.captured), isFalse);
        acknowledgement.complete(true);
        await _until(
          tester,
          () =>
              tracks().where((LiveScanTrack track) => track.captured).length ==
              2,
        );
        expect(tracks().map((LiveScanTrack track) => track.id), originalIds);
        expect(
          tracks().any((LiveScanTrack track) => track.capturedIdentified),
          isFalse,
        );
        matching.resolution = identified(
          first,
          'lightning-bolt',
          'Lightning Bolt',
        );
        session.changed();
        await tester.pump();
        expect(tracks().first.capturedIdentified, isTrue);
        expect(
          tracks().first.resolution!.candidates.single.card.id,
          'lightning-bolt',
        );
        expect(tracks().last.captured, isTrue);
        expect(tracks().last.capturedIdentified, isFalse);
        await tester.tap(find.text('Clear markers'));
        await tester.pump();
        expect(tracks(), isEmpty);
        matching.resolution = identified(
          first,
          'late-old-printing',
          'Lightning Bolt',
        );
        session.changed();
        camera.frames.add(frame());
        await _until(tester, () => tracks().length == 2);
        session.changed();
        await tester.pump();
        expect(tracks().any((LiveScanTrack track) => track.captured), isFalse);
        expect(
          tracks().any((LiveScanTrack track) => track.capturedIdentified),
          isFalse,
        );
        expect(
          tracks().map((LiveScanTrack track) => track.id),
          isNot(originalIds),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await _until(tester, () => camera.actions.last == 'dispose');
        expect(session.hasObservers, isFalse);
        session.changed();
        await tester.pump();
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
  );
  for (final ({Size size, double scale}) configuration
      in <({Size size, double scale})>[
        (size: const Size(320, 667), scale: 1),
        (size: const Size(400, 800), scale: 1),
        (size: const Size(375, 667), scale: 2.35),
        (size: const Size(667, 375), scale: 1.8),
      ]) {
    testWidgets(
      'automatic camera keeps only review pause and controls visible at ${configuration.size} scale ${configuration.scale}',
      (WidgetTester tester) async {
        final _Camera camera = _Camera();
        final _ProcessingSession session = _ProcessingSession(
          recognizer: _UnusedRecognizer(),
          resolver: _NoLiveIdentityResolver(),
        )..queuedPhotos = 3;
        session.items.add(ScanSessionItem(_automaticCard(), id: 'captured'));
        addTearDown(session.dispose);
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onClearCaptures: () async {},
          size: configuration.size,
          scale: configuration.scale,
        );
        try {
          if (configuration.scale > 1.5) {
            expect(find.text('Review 1'), findsNothing);
            expect(
              find.descendant(
                of: find.byKey(const ValueKey<String>('camera-review')),
                matching: find.text('1'),
              ),
              findsOneWidget,
            );
          } else {
            expect(find.text('Review 1'), findsOneWidget);
          }
          expect(
            find.bySemanticsLabel(RegExp('Review captures for')),
            findsOneWidget,
          );
          expect(session.pendingPhotoCaptures, 3);
          expect(
            tester
                .widget<PrimaryButton>(
                  find.byKey(const ValueKey<String>('camera-review')),
                )
                .onPressed,
            isNotNull,
          );
          expect(find.byType(AppBar), findsNothing);
          expect(find.text('Capture photo'), findsNothing);
          expect(
            find.byKey(const ValueKey<String>('camera-torch')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey<String>('camera-focus-lock')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey<String>('camera-lens-selector')),
            findsNothing,
          );
          for (final String key in <String>[
            'camera-review',
            'camera-auto-pause',
            'camera-adjustments',
          ]) {
            final Finder control = find.byKey(ValueKey<String>(key));
            expect(control.hitTestable(), findsOneWidget);
            final Size target = tester.getSize(control);
            expect(target.width, greaterThanOrEqualTo(44));
            expect(target.height, greaterThanOrEqualTo(44));
          }
          expect(
            tester.getSize(find.byType(LiveCaptureOverlay)).height,
            greaterThan(configuration.size.height * .6),
          );
          await tester.tap(
            find.byKey(const ValueKey<String>('camera-adjustments')),
          );
          await tester.pumpAndSettle();
          for (final String key in <String>[
            'camera-torch',
            'camera-focus-lock',
            'camera-lens-selector',
            'camera-clear-captures',
          ]) {
            final Finder control = find.byKey(ValueKey<String>(key));
            await tester.ensureVisible(control);
            await tester.pumpAndSettle();
            expect(control.hitTestable(), findsOneWidget);
          }
          await tester.ensureVisible(find.text('Exposure 0.0 EV'));
          await tester.pumpAndSettle();
          expect(find.text('Exposure 0.0 EV').hitTestable(), findsOneWidget);
          expect(
            find.byKey(const ValueKey<String>('camera-review')).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await _dismissCamera(tester, camera);
        }
      },
    );
  }
  testWidgets(
    'clear waits for the raw photo acknowledgement then removes ownership and permits the same card again',
    (WidgetTester tester) async {
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false)
        ..rawAppearanceSupported = true;
      final VoidCallback restore = scene.install();
      final _CaptureHaptics haptics = _CaptureHaptics()..install();
      addTearDown(haptics.restore);
      final _Camera camera = _Camera();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      final Completer<bool> acknowledgement = Completer<bool>();
      final List<List<List<ScanPoint>>> exclusions = <List<List<ScanPoint>>>[];
      int captures = 0;
      int clears = 0;
      bool handoffFinished = false;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> regions,
              ) async {
                captures++;
                exclusions.add(excluded);
                if (captures == 1) await acknowledgement.future;
                _refinePhotoObservation(
                  session,
                  _automaticCard(corners: scene.crop.sourceCorners),
                  id: 'raw-$captures',
                  photoId: '${captureId}_0',
                );
                session.rememberCapture(paths, captureId);
                session.rawCompletedGroups.add(captureId);
                session.changed();
                handoffFinished = true;
                return true;
              },
          onClearCaptures: () async {
            expect(handoffFinished, isTrue);
            clears++;
            session.items.clear();
            session.changed();
          },
        );
        await _automaticUntil(tester, camera, () => captures == 1);
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-adjustments')),
        );
        await tester.pump();
        final Finder clear = find.byKey(
          const ValueKey<String>('camera-clear-captures'),
        );
        await tester.ensureVisible(clear);
        await tester.pump();
        await tester.tap(clear);
        await tester.pump();
        expect(clears, 0);
        expect(find.text('Discarding'), findsWidgets);
        await _automaticPulse(tester, camera);
        expect(captures, 1);
        acknowledgement.complete(true);
        await _until(
          tester,
          () =>
              clears == 1 &&
              camera.frames.hasListener &&
              find.text('Discarding').evaluate().isEmpty,
        );
        expect(session.items, isEmpty);
        final LiveCaptureOverlay overlay = tester.widget<LiveCaptureOverlay>(
          find.byType(LiveCaptureOverlay),
        );
        expect(overlay.tracks, isEmpty);
        expect(overlay.retainedPhotoRegions, isEmpty);
        expect(overlay.safeToMovePhotoRegions, isEmpty);
        expect(overlay.safeToMoveTrackIds, isEmpty);
        expect(haptics.lightImpacts, 0);
        expect(find.text('Next card'), findsNothing);
        expect(find.text('Review'), findsOneWidget);
        expect(
          find.bySemanticsLabel('Resume automatic capture'),
          findsOneWidget,
        );
        for (int frame = 0; frame < 4; frame++) {
          await _automaticPulse(tester, camera);
        }
        expect(captures, 1);
        expect(
          session.items,
          isEmpty,
          reason: 'Cards left in view must not repopulate a cleared batch.',
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-auto-pause')),
        );
        await tester.pump();
        await _automaticUntil(tester, camera, () => captures == 2);
        await _automaticUntil(tester, camera, () => haptics.lightImpacts == 1);
        expect(exclusions.last, isEmpty);
        expect(session.items.single.id, 'raw-2');
        expect(tester.takeException(), isNull);
      } finally {
        if (!acknowledgement.isCompleted) acknowledgement.complete(true);
        if (find.byType(GuidedCameraScreen).evaluate().isNotEmpty) {
          await _dismissCamera(tester, camera);
        }
        restore();
      }
    },
  );
  testWidgets(
    'failed clear preserves raw ownership and the previous pause state',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final _AutomaticScene scene = _AutomaticScene()
        ..crop = _automaticCard(readable: false);
      final VoidCallback restore = scene.install();
      final _Camera camera = _Camera();
      final _ControlledSession session = _ControlledSession(
        recognizer: _UnusedRecognizer(),
        resolver: _NoLiveIdentityResolver(),
      );
      addTearDown(session.dispose);
      int captures = 0;
      int clears = 0;
      try {
        await _show(
          tester,
          camera,
          automaticCapture: true,
          session: session,
          onUnidentifiedPhotoCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excluded,
                String captureId,
                List<List<ScanPoint>> regions,
              ) async {
                captures++;
                session.items.add(
                  ScanSessionItem(
                    scene.crop,
                    id: 'retained',
                    photoId: '${captureId}_0',
                  ),
                );
                session.changed();
                return true;
              },
          onClearCaptures: () async {
            clears++;
            if (clears == 1) throw StateError('storage unavailable');
            session.items.clear();
            session.changed();
          },
        );
        await _automaticUntil(tester, camera, () => captures == 1);
        await _until(
          tester,
          () =>
              tester
                  .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                  .retainedPhotoRegions
                  .length ==
              1,
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-auto-pause')),
        );
        await tester.pump();
        expect(find.text('Paused'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-adjustments')),
        );
        await tester.pump();
        final Finder clear = find.byKey(
          const ValueKey<String>('camera-clear-captures'),
        );
        await tester.ensureVisible(clear);
        await tester.pump();
        expect(tester.getSize(clear).height, greaterThanOrEqualTo(44));
        expect(find.bySemanticsLabel('Discard remaining'), findsOneWidget);
        await tester.tap(clear);
        await _until(
          tester,
          () => clears == 1 && find.text('Clear failed').evaluate().isNotEmpty,
        );
        expect(session.items.single.id, 'retained');
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          hasLength(1),
        );
        expect(find.text('Clear failed'), findsOneWidget);
        expect(
          find.bySemanticsLabel('Resume automatic capture'),
          findsOneWidget,
        );
        await tester.ensureVisible(clear);
        await tester.pump();
        await tester.tap(clear);
        await _until(
          tester,
          () =>
              clears == 2 &&
              camera.frames.hasListener &&
              find.text('Discarding').evaluate().isEmpty,
        );
        expect(session.items, isEmpty);
        expect(find.text('Paused'), findsOneWidget);
        expect(
          tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .retainedPhotoRegions,
          isEmpty,
        );
        await _automaticPulse(tester, camera);
        expect(captures, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (find.byType(GuidedCameraScreen).evaluate().isNotEmpty) {
          await _dismissCamera(tester, camera);
        }
        restore();
        semantics.dispose();
      }
    },
  );
  for (final ThemeMode theme in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
    testWidgets(
      'camera adjustments have bounded semantic hardware actions and disable while capturing ${theme.name}',
      (WidgetTester tester) async {
        final SemanticsHandle semantics = tester.ensureSemantics();
        final _Camera camera = _Camera();
        try {
          await _show(tester, camera, theme: theme);
          await tester.tap(
            find.byKey(const ValueKey<String>('camera-adjustments')),
          );
          await tester.pumpAndSettle();
          SemanticsNode node(String label) =>
              tester.getSemantics(find.bySemanticsLabel(label));
          Future<void> adjust(String label, SemanticsAction action) async {
            final SemanticsNode current = node(label);
            current.owner!.performAction(current.id, action);
            await tester.pumpAndSettle();
          }

          expect(node('Zoom').getSemanticsData().value, '1.0×');
          expect(node('Zoom').getSemanticsData().increasedValue, '1.1×');
          expect(
            node('Zoom').getSemanticsData().hasAction(SemanticsAction.decrease),
            isFalse,
          );
          await adjust('Zoom', SemanticsAction.increase);
          expect(camera.zoomLevels.last, closeTo(1.1, .00001));
          for (int index = 0; index < 35; index++) {
            await adjust('Zoom', SemanticsAction.increase);
          }
          expect(camera.zoomLevels.last, 4);
          expect(node('Zoom').getSemanticsData().value, '4.0×');
          expect(
            node('Zoom').getSemanticsData().hasAction(SemanticsAction.increase),
            isFalse,
          );
          final int upperZoomCalls = camera.zoomLevels.length;
          await adjust('Zoom', SemanticsAction.increase);
          expect(camera.zoomLevels, hasLength(upperZoomCalls));
          for (int index = 0; index < 35; index++) {
            await adjust('Zoom', SemanticsAction.decrease);
          }
          expect(camera.zoomLevels.last, 1);
          expect(camera.zoomLevels, everyElement(inInclusiveRange(1, 4)));

          expect(node('Exposure').getSemanticsData().value, '0.0 EV');
          expect(node('Exposure').getSemanticsData().increasedValue, '0.5 EV');
          await adjust('Exposure', SemanticsAction.increase);
          expect(camera.exposureOffsets.last, .5);
          for (int index = 0; index < 4; index++) {
            await adjust('Exposure', SemanticsAction.increase);
          }
          expect(camera.exposureOffsets.last, 2);
          expect(
            node('Exposure')
                .getSemanticsData()
                .hasAction(SemanticsAction.increase),
            isFalse,
          );
          for (int index = 0; index < 9; index++) {
            await adjust('Exposure', SemanticsAction.decrease);
          }
          expect(camera.exposureOffsets.last, -2);
          expect(camera.exposureOffsets, everyElement(inInclusiveRange(-2, 2)));
          expect(
            node('Exposure')
                .getSemanticsData()
                .hasAction(SemanticsAction.decrease),
            isFalse,
          );

          camera.pendingPicture = Completer<XFile>();
          await tester.tap(find.text('Capture photo'));
          await _until(tester, () => camera.actions.contains('photo'));
          final int zoomCalls = camera.zoomLevels.length;
          final int exposureCalls = camera.exposureOffsets.length;
          for (final String label in <String>['Zoom', 'Exposure']) {
            final SemanticsNode current = node(label);
            expect(
              current.getSemanticsData().hasAction(SemanticsAction.increase),
              isFalse,
            );
            expect(
              current.getSemanticsData().hasAction(SemanticsAction.decrease),
              isFalse,
            );
            current.owner!.performAction(current.id, SemanticsAction.increase);
          }
          for (final Slider slider in tester.widgetList<Slider>(
            find.byType(Slider),
          )) {
            expect(slider.enabled, isFalse);
            expect(slider.onChanged, isNull);
            expect(slider.onChangeEnd, isNull);
          }
          await tester.pump();
          expect(camera.zoomLevels, hasLength(zoomCalls));
          expect(camera.exposureOffsets, hasLength(exposureCalls));
          camera.pendingPicture!.complete(XFile(camera.picturePath));
          await _until(tester, () => camera.frames.hasListener);
          await tester.pumpAndSettle();
          expect(
            node('Zoom').getSemanticsData().hasAction(SemanticsAction.increase),
            isTrue,
          );
          expect(
            node('Exposure')
                .getSemanticsData()
                .hasAction(SemanticsAction.increase),
            isTrue,
          );
          expect(tester.takeException(), isNull);
        } finally {
          if (camera.pendingPicture != null &&
              !camera.pendingPicture!.isCompleted) {
            camera.pendingPicture!.complete(XFile(camera.picturePath));
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await _until(tester, () => camera.actions.last == 'dispose');
          semantics.dispose();
        }
      },
    );
    for (final double scale in <double>[1, 2.35]) {
      testWidgets(
        'compact camera controls retain lens and accessible toggles ${theme.name} scale $scale',
        (WidgetTester tester) async {
          final SemanticsHandle semantics = tester.ensureSemantics();
          final _Camera camera = _Camera();
          try {
            await _show(
              tester,
              camera,
              size: scale == 1 ? const Size(320, 667) : const Size(375, 667),
              scale: scale,
              theme: theme,
            );
            final Finder lens = find.byKey(
              const ValueKey<String>('camera-lens-selector'),
            );
            final List<Finder> controls = <Finder>[
              for (final String name in <String>[
                'camera-torch',
                'camera-focus-lock',
                'camera-adjustments',
              ])
                find.byKey(ValueKey<String>(name)),
            ];
            for (final Finder control in controls) {
              expect(control.hitTestable(), findsOneWidget);
              final Size target = tester.getSize(control);
              expect(target.width, greaterThanOrEqualTo(44));
              expect(target.height, greaterThanOrEqualTo(44));
            }
            if (scale == 1) {
              final double top = tester.getRect(lens).top;
              for (final Finder control in controls) {
                expect(tester.getRect(control).top, closeTo(top, 1));
              }
              expect(
                tester.getSize(find.byType(LiveCaptureOverlay)).height,
                greaterThan(667 * .5),
              );
            }
            expect(find.bySemanticsLabel('Turn torch on'), findsOneWidget);
            await tester.tap(controls[0]);
            await tester.pumpAndSettle();
            expect(camera.actions, contains('flash torch'));
            expect(find.bySemanticsLabel('Turn torch off'), findsOneWidget);
            await tester.tap(controls[1]);
            await tester.pumpAndSettle();
            expect(camera.actions, contains('focus locked'));
            expect(find.bySemanticsLabel('Unlock focus'), findsOneWidget);
            await tester.tap(controls[2]);
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.text('Exposure 0.0 EV'));
            await tester.pumpAndSettle();
            expect(find.text('Exposure 0.0 EV').hitTestable(), findsOneWidget);
            expect(find.text('Capture photo').hitTestable(), findsOneWidget);
            await tester.ensureVisible(controls[2]);
            await tester.pumpAndSettle();
            await tester.tap(controls[2]);
            await tester.pumpAndSettle();
            await tester.ensureVisible(lens);
            await tester.pumpAndSettle();
            await tester.tap(lens);
            await tester.pump(const Duration(milliseconds: 300));
            await tester.tap(find.text('Ultra-wide').hitTestable().last);
            await _until(tester, () => camera.actions.contains('create ultra'));
            expect(camera.quality, everyElement(95));
            expect(camera.resolution, everyElement(ResolutionPreset.max));
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await _until(tester, () => camera.actions.last == 'dispose');
            semantics.dispose();
          }
        },
      );
    }
  }
  testWidgets(
    'slow photo and durable save preserve outlines and photographed markers',
    (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            NativeCardRecognizer.channel,
            (MethodCall call) async => <String, Object>{
              'width': 800,
              'height': 400,
              'rectanglesSupported': true,
              'cards': <Object>[
                for (final double x in <double>[.1, .6])
                  <String, Object>{
                    'confidence': .95,
                    'corners': <Object>[
                      <String, double>{'x': x, 'y': .1},
                      <String, double>{'x': x + .2, 'y': .1},
                      <String, double>{'x': x + .2, 'y': .7},
                      <String, double>{'x': x, 'y': .7},
                    ],
                    'lines': <Object>[
                      <String, Object>{
                        'text': 'Creature',
                        'confidence': .95,
                        'bounds': <String, double>{
                          'x': .1,
                          'y': .5,
                          'width': .7,
                          'height': .03,
                        },
                      },
                    ],
                    'warnings': <String>[],
                  },
              ],
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeCardRecognizer.channel, null),
      );
      final _Camera camera = _Camera()..pendingPicture = Completer<XFile>();
      final Completer<bool> saved = Completer<bool>();
      bool saving = false;
      await _show(
        tester,
        camera,
        onCaptured: (String _, List<List<ScanPoint>> excludedRegions) {
          saving = true;
          return saved.future;
        },
      );
      CameraImageData frame() => CameraImageData(
        format: const CameraImageFormat(
          ImageFormatGroup.bgra8888,
          raw: 1111970369,
        ),
        planes: <CameraImagePlane>[
          CameraImagePlane(
            bytes: Uint8List(16),
            bytesPerRow: 8,
            bytesPerPixel: 4,
          ),
        ],
        width: 2,
        height: 2,
      );
      camera.frames.add(frame());
      await _until(
        tester,
        () =>
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .tracks
                .length ==
            2,
      );
      final List<String> ids = tester
          .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
          .tracks
          .map((LiveScanTrack track) => track.id)
          .toList();
      await tester.tap(find.text('Capture photo'));
      await _until(tester, () => camera.actions.contains('photo'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1600)),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks
            .map((LiveScanTrack track) => track.id),
        ids,
      );
      camera.pendingPicture!.complete(XFile(camera.picturePath));
      await _until(tester, () => saving);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1600)),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks
            .map((LiveScanTrack track) => track.id),
        ids,
      );
      saved.complete(true);
      await _until(tester, () => camera.frames.hasListener);
      camera.frames.add(frame());
      await _until(
        tester,
        () =>
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .tracks
                .where((LiveScanTrack track) => track.captured)
                .length ==
            2,
      );
      final LiveCaptureOverlay overlay = tester.widget<LiveCaptureOverlay>(
        find.byType(LiveCaptureOverlay),
      );
      expect(overlay.tracks.map((LiveScanTrack track) => track.id), ids);
      expect(
        overlay.tracks
            .where((LiveScanTrack track) => track.captured)
            .map((LiveScanTrack track) => track.id)
            .toSet(),
        ids.toSet(),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _until(tester, () => camera.actions.last == 'dispose');
      debugDefaultTargetPlatformOverride = null;
    },
  );
  for (final ({Size size, double scale}) configuration
      in <({Size size, double scale})>[
        (size: const Size(320, 667), scale: 1),
        (size: const Size(375, 667), scale: 1.8),
        (size: const Size(667, 375), scale: 1.8),
      ]) {
    testWidgets(
      'capture and review remain visible with adjustments at ${configuration.size} scale ${configuration.scale}',
      (WidgetTester tester) async {
        final _Camera camera = _Camera();
        await _show(
          tester,
          camera,
          size: configuration.size,
          scale: configuration.scale,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey<String>('camera-adjustments')),
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-adjustments')),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Zoom 1.0×'));
        await tester.pumpAndSettle();
        expect(find.text('Zoom 1.0×').hitTestable(), findsOneWidget);
        await tester.ensureVisible(find.text('Exposure 0.0 EV'));
        await tester.pumpAndSettle();
        expect(find.text('Exposure 0.0 EV').hitTestable(), findsOneWidget);
        expect(find.text('Capture photo').hitTestable(), findsOneWidget);
        expect(find.text('Review batch').hitTestable(), findsOneWidget);
        expect(camera.resolution, <ResolutionPreset>[ResolutionPreset.max]);
        expect(camera.quality, <int>[95]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await _until(tester, () => camera.actions.last == 'dispose');
        expect(camera.actions.last, 'dispose');
      },
    );
  }
  testWidgets(
    'capture stops and restarts the stream, including failed captures',
    (WidgetTester tester) async {
      final _Camera camera = _Camera();
      await _show(tester, camera);
      await tester.tap(find.text('Capture photo'));
      await _until(
        tester,
        () =>
            camera.actions
                .where((String action) => action == 'stream start')
                .length ==
            2,
      );
      expect(
        camera.actions.where(
          (String action) => action.startsWith('stream') || action == 'photo',
        ),
        <String>['stream start', 'stream stop', 'photo', 'stream start'],
      );
      camera.failCapture = true;
      await tester.tap(find.text('Capture photo'));
      await _until(
        tester,
        () =>
            camera.actions
                .where((String action) => action == 'stream start')
                .length ==
            3,
      );
      expect(find.text('Capture failed'), findsOneWidget);
      expect(camera.actions.last, 'stream start');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _until(tester, () => camera.actions.last == 'dispose');
    },
  );
  testWidgets(
    'batch acknowledgement failure retries the same original without another photo',
    (WidgetTester tester) async {
      final _Camera camera = _Camera();
      final Completer<bool> acknowledgement = Completer<bool>();
      final List<String> imported = <String>[];
      await _show(
        tester,
        camera,
        size: const Size(320, 667),
        scale: 1.8,
        onCaptured: (String path, List<List<ScanPoint>> excludedRegions) {
          imported.add(path);
          return imported.length == 1
              ? acknowledgement.future
              : Future<bool>.value(true);
        },
      );
      await tester.tap(find.text('Capture photo'));
      await _until(tester, () => imported.isNotEmpty);
      expect(find.textContaining('photos ·'), findsNothing);
      acknowledgement.complete(false);
      await _until(tester, () => find.text('Retry save').evaluate().isNotEmpty);
      expect(find.text('Retry save').hitTestable(), findsOneWidget);
      final Finder review = find.ancestor(
        of: find.text('Review batch'),
        matching: find.byType(SecondaryButton),
      );
      expect(tester.widget<SecondaryButton>(review).onPressed, isNull);
      await tester.tap(find.text('Retry save'));
      await _until(
        tester,
        () => find.text('Capture photo').evaluate().isNotEmpty,
      );
      expect(
        find.byKey(const ValueKey<String>('camera-capture-count')),
        findsOneWidget,
      );
      expect(imported, <String>[
        '/tmp/synthetic-live-camera.jpg',
        '/tmp/synthetic-live-camera.jpg',
      ]);
      expect(
        camera.actions.where((String action) => action == 'photo'),
        hasLength(1),
      );
      expect(find.text('Retry save'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _until(tester, () => camera.actions.last == 'dispose');
    },
  );
  testWidgets(
    'single-shot capture stays open on failed durable save and closes only after successful retry',
    (WidgetTester tester) async {
      final _Camera camera = _Camera();
      final Completer<bool> first = Completer<bool>();
      final Completer<bool> retry = Completer<bool>();
      final List<String> imported = <String>[];
      await _show(
        tester,
        camera,
        singleShot: true,
        onCaptured: (String path, List<List<ScanPoint>> excludedRegions) {
          imported.add(path);
          return imported.length == 1 ? first.future : retry.future;
        },
      );
      await tester.tap(find.text('Capture photo'));
      await _until(tester, () => imported.isNotEmpty);
      expect(find.byType(GuidedCameraScreen), findsOneWidget);
      first.complete(false);
      await _until(tester, () => find.text('Retry save').evaluate().isNotEmpty);
      await tester.tap(find.text('Retry save'));
      await _until(tester, () => imported.length == 2);
      expect(find.byType(GuidedCameraScreen), findsOneWidget);
      retry.complete(true);
      await _until(tester, () => camera.actions.last == 'dispose');
      await tester.pumpAndSettle();
      expect(find.byType(GuidedCameraScreen), findsNothing);
      expect(find.text('Open camera').hitTestable(), findsOneWidget);
      expect(imported, <String>[camera.picturePath, camera.picturePath]);
      expect(
        camera.actions.where((String action) => action == 'photo'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'three proven cards take three focused photos and resume preview before durable acknowledgement',
    (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final List<Map<Object?, Object?>> focused = <Map<Object?, Object?>>[];
      List<Map<String, double>> corners(double x, double y) =>
          <Map<String, double>>[
            <String, double>{'x': x, 'y': y},
            <String, double>{'x': x + .18, 'y': y},
            <String, double>{'x': x + .18, 'y': y + .22},
            <String, double>{'x': x, 'y': y + .22},
          ];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, (
            MethodCall call,
          ) async {
            if (call.method == 'cameraFocusAtPoint') {
              focused.add(call.arguments as Map<Object?, Object?>);
              return true;
            }
            if (call.method == 'cameraFocusStatus') {
              return <String, Object>{
                'isAdjustingFocus': false,
                'isAdjustingExposure': false,
                'lensPosition': .5,
                'focusMode': 0,
              };
            }
            return <String, Object>{
              'width': 800,
              'height': 400,
              'rectanglesSupported': true,
              'cards': <Object>[
                for (final (double x, double y) in <(double, double)>[
                  (.1, .6),
                  (.65, .6),
                  (.65, .2),
                ])
                  <String, Object>{
                    'confidence': .95,
                    'corners': corners(x, y),
                    'lines': <Object>[
                      <String, Object>{
                        'text': 'Creature',
                        'confidence': .95,
                        'bounds': <String, double>{
                          'x': .1,
                          'y': .5,
                          'width': .7,
                          'height': .03,
                        },
                      },
                    ],
                    'warnings': <String>[],
                  },
              ],
              'focusCandidates': <Object>[
                <String, Object>{
                  'confidence': .95,
                  'corners': corners(0, 0),
                  'warnings': <String>['geometry_only'],
                },
              ],
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeCardRecognizer.channel, null),
      );
      final _Camera camera = _Camera()..pendingPicture = Completer<XFile>();
      final Completer<bool> acknowledgement = Completer<bool>();
      final List<List<String>> imported = <List<String>>[];
      await _show(
        tester,
        camera,
        onFocusStackCaptured:
            (
              List<String> paths,
              List<List<ScanPoint>> excludedRegions,
              String captureId,
              List<List<ScanPoint>>? targetRegions,
            ) {
              imported.add(List<String>.of(paths));
              return imported.length == 1
                  ? acknowledgement.future
                  : Future<bool>.value(true);
            },
      );
      camera.frames.add(
        CameraImageData(
          format: const CameraImageFormat(
            ImageFormatGroup.bgra8888,
            raw: 1111970369,
          ),
          planes: <CameraImagePlane>[
            CameraImagePlane(
              bytes: Uint8List(16),
              bytesPerRow: 8,
              bytesPerPixel: 4,
            ),
          ],
          width: 2,
          height: 2,
        ),
      );
      await _until(
        tester,
        () =>
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .tracks
                .length ==
            3,
      );
      await tester.tap(find.byKey(const ValueKey<String>('camera-shutter')));
      for (
        int index = 0;
        index < 8 && !camera.actions.contains('photo');
        index++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(find.text('Photo 1/3'), findsOneWidget);
      expect(camera.frames.hasListener, isFalse);
      camera.pendingPicture!.complete(XFile(camera.picturePath));
      for (int index = 0; index < 20 && imported.isEmpty; index++) {
        await tester.pump(const Duration(milliseconds: 250));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(imported.single, hasLength(3));
      expect(
        camera.actions.where((String action) => action == 'photo'),
        hasLength(3),
      );
      expect(focused, hasLength(3));
      final List<(double, double)> expected = <(double, double)>[
        (.19, .71),
        (.74, .71),
        (.74, .31),
      ];
      for (int index = 0; index < expected.length; index++) {
        expect(focused[index]['x'], closeTo(expected[index].$1, .00001));
        expect(focused[index]['y'], closeTo(expected[index].$2, .00001));
      }
      expect(camera.frames.hasListener, isTrue);
      expect(find.text('Saving…'), findsOneWidget);
      expect(
        tester
            .widget<PrimaryButton>(
              find.byKey(const ValueKey<String>('camera-shutter')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks
            .where((LiveScanTrack track) => track.captured),
        isEmpty,
      );
      acknowledgement.complete(false);
      await _until(tester, () => find.text('Retry save').evaluate().isNotEmpty);
      expect(
        tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks
            .where((LiveScanTrack track) => track.captured),
        isEmpty,
      );
      await tester.tap(find.text('Retry save'));
      await _until(
        tester,
        () =>
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .tracks
                .where((LiveScanTrack track) => track.captured)
                .length ==
            3,
      );
      expect(imported, <List<String>>[
        List<String>.filled(3, camera.picturePath),
        List<String>.filled(3, camera.picturePath),
      ]);
      expect(
        camera.actions.where((String action) => action == 'photo'),
        hasLength(3),
      );
      await _until(tester, () => find.text('Captured').evaluate().isNotEmpty);
      expect(find.text('Captured'), findsOneWidget);
      camera.orientations.add(
        const DeviceOrientationChangedEvent(DeviceOrientation.landscapeLeft),
      );
      await _until(
        tester,
        () => tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks
            .isEmpty,
      );
      expect(find.text('Captured'), findsOneWidget);
      expect(find.text('Clear markers'), findsOneWidget);
      expect(
        tester
            .widget<PrimaryButton>(
              find.byKey(const ValueKey<String>('camera-shutter')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Clear markers'));
      await tester.pump();
      expect(
        tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks,
        isEmpty,
      );
      expect(find.text('Capture photo'), findsOneWidget);
      expect(
        tester
            .widget<PrimaryButton>(
              find.byKey(const ValueKey<String>('camera-shutter')),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        camera.actions.where((String action) => action == 'photo'),
        hasLength(3),
      );
      expect(
        find.byKey(const ValueKey<String>('camera-capture-count')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _until(tester, () => camera.actions.last == 'dispose');
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets(
    'two current cards and a missing recent identity take only three proof-targeted photos',
    (WidgetTester tester) async {
      final TargetPlatform? previousPlatform =
          debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        bool includeRear = true;
        final List<Offset> photoFocus = <Offset>[];
        Offset? focus;
        List<Map<String, double>> corners(double x, double y) =>
            <Map<String, double>>[
              <String, double>{'x': x, 'y': y},
              <String, double>{'x': x + .18, 'y': y},
              <String, double>{'x': x + .18, 'y': y + .22},
              <String, double>{'x': x, 'y': y + .22},
            ];
        Map<String, Object> text(String value, double y) => <String, Object>{
          'text': value,
          'confidence': .95,
          'bounds': <String, double>{
            'x': .1,
            'y': y,
            'width': .7,
            'height': .03,
          },
        };
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeCardRecognizer.channel, (
              MethodCall call,
            ) async {
              if (call.method == 'cameraFocusAtPoint') {
                final Map<Object?, Object?> arguments =
                    call.arguments as Map<Object?, Object?>;
                focus = Offset(
                  arguments['x'] as double,
                  arguments['y'] as double,
                );
                return true;
              }
              if (call.method == 'cameraFocusStatus') {
                return <String, Object>{
                  'isAdjustingFocus': false,
                  'isAdjustingExposure': false,
                  'lensPosition': .5,
                  'focusMode': 0,
                };
              }
              return <String, Object>{
                'width': 800,
                'height': 400,
                'rectanglesSupported': true,
                'cards': <Object>[
                  for (final (double, double, bool) card
                      in <(double, double, bool)>[
                        (.1, .6, false),
                        (.65, .6, false),
                        if (includeRear) (.65, .2, true),
                      ])
                    <String, Object>{
                      'confidence': .95,
                      'corners': corners(card.$1, card.$2),
                      'lines': <Object>[
                        if (card.$3) text('Recent rear identity', .04),
                        text('Creature', .5),
                        if (card.$3)
                          text('Whenever you create or sacrifice a token', .6),
                      ],
                      'warnings': <String>[],
                    },
                ],
                'focusCandidates': <Object>[
                  <String, Object>{
                    'confidence': .95,
                    'corners': corners(0, 0),
                    'warnings': <String>['geometry_only'],
                  },
                ],
              };
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(NativeCardRecognizer.channel, null),
        );
        final _Camera camera = _Camera();
        camera.beforePicture = () => photoFocus.add(focus!);
        List<String>? saved;
        await _show(
          tester,
          camera,
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> excludedRegions,
                String captureId,
                List<List<ScanPoint>>? targetRegions,
              ) async {
                saved = List<String>.of(paths);
                return true;
              },
        );
        LiveCaptureOverlay overlay() =>
            tester.widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay));
        void frame() => camera.frames.add(
          CameraImageData(
            format: const CameraImageFormat(
              ImageFormatGroup.bgra8888,
              raw: 1111970369,
            ),
            planes: <CameraImagePlane>[
              CameraImagePlane(
                bytes: Uint8List(16),
                bytesPerRow: 8,
                bytesPerPixel: 4,
              ),
            ],
            width: 2,
            height: 2,
          ),
        );
        frame();
        await _until(tester, () => overlay().tracks.length == 3);
        final LiveScanTrack rear = overlay().tracks.singleWhere(
          (LiveScanTrack track) => track.crop.lines.any(
            (ScanTextLine line) => line.text == 'Recent rear identity',
          ),
        );
        rear.lastSeen = DateTime.now().subtract(const Duration(seconds: 2));
        includeRear = false;
        frame();
        await _until(tester, () => overlay().tracks.length == 2);
        expect(
          overlay().tracks.any((LiveScanTrack track) => track.id == rear.id),
          isFalse,
        );
        await tester.tap(find.byKey(const ValueKey<String>('camera-shutter')));
        for (int index = 0; index < 60 && saved == null; index++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        }
        await _until(tester, () => saved != null);
        expect(saved, hasLength(3));
        const List<Offset> expected = <Offset>[
          Offset(.19, .71),
          Offset(.74, .71),
          Offset(.74, .31),
        ];
        expect(photoFocus, hasLength(expected.length));
        for (int index = 0; index < expected.length; index++) {
          expect(photoFocus[index].dx, closeTo(expected[index].dx, .00001));
          expect(photoFocus[index].dy, closeTo(expected[index].dy, .00001));
        }
        await _until(
          tester,
          () =>
              overlay().tracks
                  .where((LiveScanTrack track) => track.captured)
                  .length ==
              2,
        );
        expect(overlay().tracks, hasLength(2));
        expect(
          overlay().tracks.any((LiveScanTrack track) => track.id == rear.id),
          isFalse,
        );
        expect(
          camera.actions.where((String action) => action == 'photo'),
          hasLength(3),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await _until(tester, () => camera.actions.last == 'dispose');
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
  );
  testWidgets(
    'focus stack includes a proven rear card before unrelated desk geometry',
    (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final List<Map<Object?, Object?>> nativeFocus = <Map<Object?, Object?>>[];
      int focusSamples = 0;
      List<Map<String, double>> corners(double x, double y) =>
          <Map<String, double>>[
            <String, double>{'x': x, 'y': y},
            <String, double>{'x': x + .15, 'y': y},
            <String, double>{'x': x + .15, 'y': y + .20},
            <String, double>{'x': x, 'y': y + .20},
          ];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, (
            MethodCall call,
          ) async {
            if (call.method == 'cameraFocusStatus') {
              focusSamples++;
              return <String, Object>{
                'isAdjustingFocus': false,
                'isAdjustingExposure': false,
                'lensPosition': .5,
                'focusMode': focusSamples <= 3 ? 1 : 0,
              };
            }
            if (call.method == 'cameraFocusAtPoint') {
              nativeFocus.add(call.arguments as Map<Object?, Object?>);
              focusSamples = 0;
              return true;
            }
            return <String, Object>{
              'width': 800,
              'height': 400,
              'rectanglesSupported': true,
              'cards': <Object>[
                <String, Object>{
                  'confidence': .95,
                  'corners': corners(.70, .25),
                  'lines': <Object>[
                    <String, Object>{
                      'text': 'Creature',
                      'confidence': .95,
                      'bounds': <String, double>{
                        'x': .1,
                        'y': .5,
                        'width': .7,
                        'height': .03,
                      },
                    },
                  ],
                  'warnings': <String>[],
                },
              ],
              'focusCandidates': <Object>[
                for (final (double x, double y) in <(double, double)>[
                  (0, 0),
                  (.8, 0),
                  (0, .75),
                  (.8, .75),
                ])
                  <String, Object>{
                    'confidence': .95,
                    'corners': corners(x, y),
                    'warnings': <String>['geometry_only'],
                  },
              ],
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeCardRecognizer.channel, null),
      );
      final _Camera camera = _Camera();
      camera.beforePicture = () =>
          expect(focusSamples, greaterThanOrEqualTo(6));
      List<String>? saved;
      await _show(
        tester,
        camera,
        onFocusStackCaptured:
            (
              List<String> paths,
              List<List<ScanPoint>> excludedRegions,
              String captureId,
              List<List<ScanPoint>>? targetRegions,
            ) async {
              saved = paths;
              return true;
            },
      );
      camera.frames.add(
        CameraImageData(
          format: const CameraImageFormat(
            ImageFormatGroup.bgra8888,
            raw: 1111970369,
          ),
          planes: <CameraImagePlane>[
            CameraImagePlane(
              bytes: Uint8List(16),
              bytesPerRow: 8,
              bytesPerPixel: 4,
            ),
          ],
          width: 2,
          height: 2,
        ),
      );
      await _until(
        tester,
        () =>
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .tracks
                .length ==
            1,
      );
      await tester.tap(find.byKey(const ValueKey<String>('camera-shutter')));
      for (int index = 0; index < 12; index++) {
        await tester.pump(const Duration(seconds: 2));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      await _until(tester, () => saved != null);
      expect(
        nativeFocus.any(
          (Map<Object?, Object?> point) =>
              ((point['x'] as double) - .775).abs() < .001 &&
              ((point['y'] as double) - .35).abs() < .001,
        ),
        isTrue,
      );
      expect(saved, hasLength(5));
      final List<Map<Object?, Object?>> captureFocus = nativeFocus
          .skip(nativeFocus.length - 5)
          .toList();
      expect(captureFocus, hasLength(5));
      expect(
        captureFocus.every(
          (Map<Object?, Object?> point) =>
              point['previewOrientation'] == 'portraitUp' &&
              point['singleShot'] == true &&
              point['adjustExposure'] == false,
        ),
        isTrue,
      );
      expect(camera.focusPoints, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await _until(tester, () => camera.actions.last == 'dispose');
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets(
    'one shutter refocuses the scene and retries the complete unsaved stack',
    (WidgetTester tester) async {
      final _Camera camera = _Camera();
      final List<List<String>> admitted = <List<String>>[];
      await _show(
        tester,
        camera,
        onFocusStackCaptured:
            (
              List<String> paths,
              List<List<ScanPoint>> excludedRegions,
              String captureId,
              List<List<ScanPoint>>? targetRegions,
            ) async {
              admitted.add(List<String>.of(paths));
              return admitted.length > 1;
            },
      );
      await tester.tap(find.text('Capture photo'));
      for (int index = 0; index < 12; index++) {
        await tester.pump(const Duration(seconds: 2));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      await _until(tester, () => admitted.isNotEmpty);
      expect(admitted.single, hasLength(5));
      expect(
        camera.actions.where((String action) => action == 'photo'),
        hasLength(5),
      );
      expect(find.text('Retry save').hitTestable(), findsOneWidget);
      expect(camera.focus, isNotNull);
      await tester.tap(find.text('Retry save'));
      await _until(tester, () => admitted.length == 2);
      await _until(tester, () => find.text('Captured').evaluate().isNotEmpty);
      expect(admitted.last, admitted.first);
      expect(
        camera.actions.where((String action) => action == 'photo'),
        hasLength(5),
      );
      expect(find.text('Captured'), findsOneWidget);
      expect(find.text('Clear markers'), findsOneWidget);
      expect(
        tester
            .widget<PrimaryButton>(
              find.byKey(const ValueKey<String>('camera-shutter')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _until(tester, () => camera.actions.last == 'dispose');
    },
  );
  testWidgets(
    'preview tap applies focus and exposure to the same mapped point',
    (WidgetTester tester) async {
      final _Camera camera = _Camera();
      await _show(tester, camera);
      final Finder preview = find.byWidgetPredicate(
        (Widget widget) =>
            widget is ColoredBox && widget.color == const Color(0xff202020),
      );
      await tester.tapAt(tester.getCenter(preview));
      await tester.pump();
      expect(camera.focus, isNotNull);
      expect(camera.exposure, camera.focus);
      expect(camera.focus!.x, closeTo(.5, .01));
      expect(camera.focus!.y, closeTo(.5, .01));
      await tester.pumpWidget(const SizedBox.shrink());
      await _until(tester, () => camera.actions.last == 'dispose');
    },
  );
  testWidgets(
    'discarding a failed batch import requires confirmation before deleting the original',
    (WidgetTester tester) async {
      final Directory directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('collector-camera-test-'),
      ))!;
      addTearDown(() => directory.delete(recursive: true));
      final File original = File('${directory.path}/photo.jpg');
      await tester.runAsync(() => original.writeAsBytes(<int>[1, 2, 3]));
      final _Camera camera = _Camera()..picturePath = original.path;
      await _show(
        tester,
        camera,
        onCaptured: (String _, List<List<ScanPoint>> excludedRegions) async =>
            false,
      );
      await tester.tap(find.text('Capture photo'));
      await _until(
        tester,
        () =>
            camera.actions
                .where((String action) => action == 'stream start')
                .length ==
            2,
      );
      await tester.ensureVisible(find.text('Discard unsaved photo'));
      await tester.tap(find.text('Discard unsaved photo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel').hitTestable());
      await tester.pumpAndSettle();
      expect(await tester.runAsync(original.exists), isTrue);
      expect(find.text('Retry save'), findsOneWidget);
      await tester.tap(find.text('Discard unsaved photo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard photo').hitTestable());
      await _until(
        tester,
        () => find.text('Capture photo').evaluate().isNotEmpty,
      );
      expect(await tester.runAsync(original.exists), isFalse);
      expect(find.textContaining('photos ·'), findsNothing);
      expect(find.text('Capture photo'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _until(tester, () => camera.actions.last == 'dispose');
    },
  );
}
