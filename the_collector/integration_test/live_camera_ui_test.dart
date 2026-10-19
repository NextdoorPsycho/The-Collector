import 'dart:async';
import 'dart:io';
import 'dart:math' show Point;
import 'dart:ui' as ui;

import 'package:arcane/arcane.dart';
import 'package:camera/camera.dart' show CameraImage;
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/scanning/guided_camera_screen.dart';
import 'package:the_collector/pages/scanning/live_capture_overlay.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/scanning/live_scan_detector.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scryfall_request_scheduler.dart';

class _SceneCamera extends CameraPlatform {
  _SceneCamera(this.scene, this.png, this.picturePath) {
    frames = StreamController<CameraImageData>.broadcast(
      onListen: () {
        actions.add('stream start');
        _pulse = Timer.periodic(const Duration(milliseconds: 200), (_) {
          delivered++;
          frames.add(scene);
        });
      },
      onCancel: () {
        actions.add('stream stop');
        _pulse?.cancel();
      },
    );
  }

  final CameraImageData scene;
  final Uint8List png;
  final String picturePath;
  final List<String> actions = <String>[];
  final List<ResolutionPreset?> presets = <ResolutionPreset?>[];
  final List<int> quality = <int>[];
  final StreamController<DeviceOrientationChangedEvent> orientations =
      StreamController<DeviceOrientationChangedEvent>.broadcast();
  late final StreamController<CameraImageData> frames;
  Timer? _pulse;
  int _nextId = 0;
  int delivered = 0;
  Point<double>? focus;
  Point<double>? exposure;

  @override
  Future<List<CameraDescription>> availableCameras() async =>
      const <CameraDescription>[
        CameraDescription(
          name: 'fixture-wide',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
          lensType: CameraLensType.wide,
        ),
        CameraDescription(
          name: 'fixture-ultra',
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
    presets.add(settings.resolutionPreset);
    actions.add('create ${camera.name}');
    return ++_nextId;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int id) =>
      Stream<CameraInitializedEvent>.value(
        CameraInitializedEvent(
          id,
          scene.height.toDouble(),
          scene.width.toDouble(),
          ExposureMode.auto,
          true,
          FocusMode.auto,
          true,
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
  }) async {
    expectSync(imageFormatGroup, ImageFormatGroup.bgra8888);
  }

  @override
  bool supportsImageStreaming() => true;
  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int id, {
    CameraImageStreamOptions? options,
  }) => frames.stream;
  @override
  Widget buildPreview(int id) =>
      Image.memory(png, fit: BoxFit.fill, gaplessPlayback: true);
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
  Future<void> setZoomLevel(int id, double zoom) async =>
      actions.add('zoom $zoom');
  @override
  Future<double> getMinExposureOffset(int id) async => -2;
  @override
  Future<double> getMaxExposureOffset(int id) async => 2;
  @override
  Future<double> getExposureOffsetStepSize(int id) async => .5;
  @override
  Future<double> setExposureOffset(int id, double value) async {
    actions.add('exposure $value');
    return value;
  }

  @override
  Future<void> setFocusMode(int id, FocusMode mode) async =>
      actions.add('focus ${mode.name}');
  @override
  Future<void> setFocusPoint(int id, Point<double>? value) async =>
      focus = value;
  @override
  Future<void> setExposurePoint(int id, Point<double>? value) async =>
      exposure = value;
  @override
  Future<XFile> takePicture(int id) async {
    expectSync(frames.hasListener, isFalse);
    actions.add('photo');
    return XFile(picturePath);
  }

  @override
  Future<void> dispose(int id) async {
    expectSync(frames.hasListener, isFalse);
    actions.add('dispose');
  }

  Future<void> close() async {
    _pulse?.cancel();
    await frames.close();
    await orientations.close();
  }
}

Future<_SceneCamera> _scene(Directory directory) async {
  final ScryfallHttpClient client = ScryfallHttpClient();
  final sf.ScryfallApiClient api = sf.ScryfallApiClient(httpClient: client);
  final List<ui.Image> images = <ui.Image>[];
  try {
    for (final String name in <String>['Lightning Bolt', 'Counterspell']) {
      final sf.MtgCard card = await api.getCardByName(
        name,
        set: name == 'Counterspell' ? 'mh2' : '2x2',
      );
      final http.Response response = await http.get(card.imageUris!.large);
      expect(response.statusCode, 200);
      final ui.Codec codec = await ui.instantiateImageCodec(response.bodyBytes);
      images.add((await codec.getNextFrame()).image);
      codec.dispose();
    }
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder)
      ..drawColor(const ui.Color(0xffd0d0d0), ui.BlendMode.src);
    for (int index = 0; index < images.length; index++) {
      final ui.Image card = images[index];
      final double height = 400 * card.height / card.width;
      canvas.drawImageRect(
        card,
        ui.Rect.fromLTWH(0, 0, card.width.toDouble(), card.height.toDouble()),
        ui.Rect.fromLTWH(40 + 480.0 * index, (960 - height) / 2, 400, height),
        ui.Paint(),
      );
    }
    final ui.Picture picture = recorder.endRecording();
    final ui.Image scene = await picture.toImage(960, 960);
    final Uint8List png = (await scene.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    final Uint8List bgra = (await scene.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    for (int offset = 0; offset < bgra.length; offset += 4) {
      final int red = bgra[offset];
      bgra[offset] = bgra[offset + 2];
      bgra[offset + 2] = red;
    }
    final File original = File('${directory.path}/controlled_scene.png');
    await original.writeAsBytes(png);
    scene.dispose();
    picture.dispose();
    return _SceneCamera(
      CameraImageData(
        format: const CameraImageFormat(
          ImageFormatGroup.bgra8888,
          raw: 1111970369,
        ),
        planes: <CameraImagePlane>[
          CameraImagePlane(bytes: bgra, bytesPerRow: 960 * 4, bytesPerPixel: 4),
        ],
        width: 960,
        height: 960,
      ),
      png,
      original.path,
    );
  } finally {
    for (final ui.Image image in images) {
      image.dispose();
    }
    client.close();
  }
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 75));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(ready(), isTrue);
}

Future<void> _captureState(WidgetTester tester, String state) async {
  await tester.pump(const Duration(milliseconds: 600));
  debugPrint('SIM_CAMERA_QA_READY $state');
  await tester.pump(const Duration(seconds: 8));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Simulator controlled scene uses real native tracking and accessible capture controls',
    (WidgetTester tester) async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'collector_sim_camera_ui_',
      );
      Hive.init('${directory.path}/hive');
      final CameraPlatform previous = CameraPlatform.instance;
      final _SceneCamera camera = await _scene(directory);
      final NativeLiveCardDetector detector = NativeLiveCardDetector();
      final Stopwatch preflightTime = Stopwatch()..start();
      final LiveScanFrame? preflight = await detector.analyze(
        CameraImage.fromPlatformInterface(camera.scene),
        camera: (await camera.availableCameras()).first,
        orientation: DeviceOrientation.portraitUp,
        includeText: true,
      );
      debugPrint(
        'SIM_CAMERA_PREFLIGHT elapsedMs=${preflightTime.elapsedMilliseconds} ${preflight?.cards.map((LiveCardDetection card) => card.lines.map((line) => line.text).join(" | ")).toList()}',
      );
      detector.reset();
      expect(preflight?.cards.length, 2);
      final ValueNotifier<double> scale = ValueNotifier<double>(1);
      final List<String> captured = <String>[];
      CameraPlatform.instance = camera;
      try {
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(ThemeMode.dark),
            builder: (BuildContext context, Widget? child) =>
                ValueListenableBuilder<double>(
                  valueListenable: scale,
                  builder: (BuildContext context, double value, Widget? _) =>
                      MediaQuery(
                        data: MediaQuery.of(context).copyWith(
                          disableAnimations: true,
                          textScaler: TextScaler.linear(value),
                        ),
                        child: child!,
                      ),
                ),
            home: GuidedCameraScreen(
              automaticCapture: false,
              multipleCards: true,
              onCaptured:
                  (String path, List<List<ScanPoint>> excludedRegions) async {
                    captured.add(path);
                    return true;
                  },
            ),
          ),
        );
        LiveCaptureOverlay overlay() =>
            tester.widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay));
        DateTime? previousFrame;
        final List<String> observations = <String>[];
        bool identified() {
          if (find.byType(LiveCaptureOverlay).evaluate().isEmpty) return false;
          if (overlay().tracks.isNotEmpty) {
            final DateTime seen = overlay().tracks.first.lastSeen;
            if (seen != previousFrame) {
              final int? gap = previousFrame == null
                  ? null
                  : seen.difference(previousFrame!).inMilliseconds;
              previousFrame = seen;
              if (observations.length < 30) {
                observations.add(
                  'gapMs=$gap ${overlay().tracks.map((track) => '${track.id} stable=${track.stableFrames} resolving=${track.resolving} warnings=${track.crop.warnings}').join('; ')}',
                );
              }
            }
          }
          return overlay().tracks.length == 2 &&
              overlay().tracks.every(
                (track) => track.resolution?.candidates.isNotEmpty ?? false,
              );
        }

        await _wait(
          tester,
          () =>
              find.byType(LiveCaptureOverlay).evaluate().isNotEmpty &&
              overlay().tracks.length == 2,
        );
        await _captureState(tester, 'geometry');
        try {
          await _wait(tester, identified);
        } finally {
          debugPrint(
            'SIM_CAMERA_STREAM frames=${camera.delivered} actions=${camera.actions} tracks=${find.byType(LiveCaptureOverlay).evaluate().isEmpty ? "no overlay" : overlay().tracks.map((track) => "${track.crop.lines.map((line) => line.text)} ${track.error} ${track.resolution?.candidates.length}").toList()}',
          );
          debugPrint('SIM_CAMERA_TIMING $observations');
        }
        expect(
          overlay().tracks
              .map((track) => track.resolution!.candidates.first.card.name)
              .toSet(),
          <String>{'Lightning Bolt', 'Counterspell'},
        );
        expect(
          find.textContaining('tracked · Capture to review'),
          findsNothing,
        );
        await _captureState(tester, 'identified');
        final ui.Offset point = overlay().transform.project(
          const ui.Offset(.3, .5),
        );
        await tester.tapAt(
          tester.getTopLeft(find.byType(LiveCaptureOverlay)) + point,
        );
        await _wait(
          tester,
          () => camera.focus != null && camera.exposure == camera.focus,
        );
        expect(camera.focus!.x, closeTo(.3, .02));
        expect(camera.focus!.y, closeTo(.5, .02));
        await _captureState(tester, 'focus');
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-torch')).hitTestable(),
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-focus-lock')).hitTestable(),
        );
        await _wait(
          tester,
          () =>
              camera.actions.contains('flash torch') &&
              camera.actions.contains('focus locked'),
        );
        await tester.tap(
          find
              .byKey(const ValueKey<String>('camera-adjustments'))
              .hitTestable(),
        );
        await tester.pump();
        await tester.ensureVisible(find.text('Exposure 0.0 EV'));
        await _captureState(tester, 'adjustments');
        final Finder lens = find.byKey(
          const ValueKey<String>('camera-lens-selector'),
        );
        await tester.ensureVisible(lens);
        await tester.tap(lens);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Ultra-wide').hitTestable().last);
        await _wait(
          tester,
          () => camera.actions.contains('create fixture-ultra') && identified(),
        );
        expect(camera.presets, everyElement(ResolutionPreset.max));
        expect(camera.quality, everyElement(95));
        await tester.tap(find.text('Capture photo').hitTestable());
        await _wait(
          tester,
          () =>
              captured.length == 1 &&
              camera.actions
                      .where((String action) => action == 'stream start')
                      .length >=
                  3 &&
              identified(),
        );
        await _captureState(tester, 'photographed');
        scale.value = 2.35;
        await tester.pump();
        await tester.ensureVisible(find.text('Exposure 0.0 EV'));
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('Exposure 0.0 EV').hitTestable(), findsOneWidget);
        expect(find.text('Capture photo').hitTestable(), findsOneWidget);
        expect(find.text('Review batch').hitTestable(), findsOneWidget);
        await _captureState(tester, 'large_text');
        await tester.tap(find.text('2 cards · Details').hitTestable());
        await tester.pump(const Duration(milliseconds: 600));
        await _captureState(tester, 'tracked_cards');
        expect(find.text('Tracked cards').hitTestable(), findsOneWidget);
        final Finder details = find.byType(ArcaneDialog);
        expect(details, findsOneWidget);
        for (int index = 0; index < overlay().tracks.length; index++) {
          final String name =
              overlay().tracks[index].resolution!.candidates.first.card.name;
          final Finder label = find.descendant(
            of: details,
            matching: find.text('${index + 1} · $name'),
          );
          await tester.scrollUntilVisible(
            label.hitTestable(),
            180,
            scrollable: find.byType(Scrollable).hitTestable().first,
          );
          expect(label.hitTestable(), findsOneWidget);
        }
        await tester.scrollUntilVisible(
          find.text('Close').hitTestable(),
          180,
          scrollable: find.byType(Scrollable).hitTestable().first,
        );
        await tester.tap(find.text('Close').hitTestable());
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('Tracked cards'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _wait(tester, () => camera.actions.last == 'dispose');
        await camera.close();
        CameraPlatform.instance = previous;
        scale.dispose();
        await Hive.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
