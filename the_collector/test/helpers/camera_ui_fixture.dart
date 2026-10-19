import 'dart:async';
import 'dart:math' show Point;

import 'package:arcane/arcane.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/pages/scanning/guided_camera_screen.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_session.dart';

class CameraUiPlatform extends CameraPlatform {
  CameraUiPlatform({
    this.preview = const ColoredBox(color: Color(0xff202020)),
    this.orientation = DeviceOrientation.portraitUp,
  });

  final Widget preview;
  final DeviceOrientation orientation;
  final StreamController<CameraImageData> frames =
      StreamController<CameraImageData>.broadcast();
  final List<Point<double>> focusPoints = <Point<double>>[];
  final List<String> operations = <String>[];
  int captures = 0;
  int disposals = 0;
  int _nextId = 0;

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
      Stream<DeviceOrientationChangedEvent>.value(
        DeviceOrientationChangedEvent(orientation),
      );

  @override
  Future<int> createCameraWithSettings(
    CameraDescription camera,
    MediaSettings settings,
  ) async {
    operations.add('create:${camera.name}');
    return ++_nextId;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream<CameraInitializedEvent>.value(
        CameraInitializedEvent(
          cameraId,
          800,
          400,
          ExposureMode.auto,
          true,
          FocusMode.auto,
          true,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      Stream<CameraErrorEvent>.multi(
        (MultiStreamController<CameraErrorEvent> _) {},
      );

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}

  @override
  bool supportsImageStreaming() => true;

  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) => frames.stream;

  @override
  Widget buildPreview(int cameraId) => preview;

  @override
  Future<void> setJpegImageQuality(int cameraId, int quality) async {}

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async =>
      operations.add('flash:${mode.name}');

  @override
  Future<void> setFocusMode(int cameraId, FocusMode mode) async =>
      operations.add('focus:${mode.name}');

  @override
  Future<void> setFocusPoint(int cameraId, Point<double>? point) async {
    if (point != null) focusPoints.add(point);
  }

  @override
  Future<void> setExposurePoint(int cameraId, Point<double>? point) async {}

  @override
  Future<double> getMinZoomLevel(int cameraId) async => 1;
  @override
  Future<double> getMaxZoomLevel(int cameraId) async => 4;
  @override
  Future<void> setZoomLevel(int cameraId, double zoom) async =>
      operations.add('zoom:$zoom');

  @override
  Future<double> getMinExposureOffset(int cameraId) async => -2;
  @override
  Future<double> getMaxExposureOffset(int cameraId) async => 2;
  @override
  Future<double> getExposureOffsetStepSize(int cameraId) async => .5;
  @override
  Future<double> setExposureOffset(int cameraId, double exposure) async {
    operations.add('exposure:$exposure');
    return exposure;
  }

  @override
  Future<XFile> takePicture(int cameraId) async {
    captures++;
    throw StateError('This layout fixture must never capture a photo.');
  }

  @override
  Future<void> dispose(int cameraId) async {
    disposals++;
  }

  void installNativeFocusStub() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeCardRecognizer.channel, (
          MethodCall call,
        ) async {
          if (call.method == 'cameraFocusAtPoint') {
            final Map<Object?, Object?> arguments =
                call.arguments as Map<Object?, Object?>;
            focusPoints.add(
              Point<double>(
                (arguments['x']! as num).toDouble(),
                (arguments['y']! as num).toDouble(),
              ),
            );
            return true;
          }
          throw MissingPluginException(
            'No recognition in the camera layout fixture.',
          );
        });
  }

  Future<void> close() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
    await frames.close();
  }
}

class _NoCameraRecognition implements CardRecognizer {
  @override
  Future<ScanRecognition> recognize(
    String path, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) => throw StateError('This layout fixture performs no recognition.');
}

class _NoCameraLookup extends ScanResolver {
  @override
  Future<void> warmNames() async {}
}

class CameraUiSession extends ScanSession {
  CameraUiSession({this._pendingPhotos = 3})
    : super(recognizer: _NoCameraRecognition(), resolver: _NoCameraLookup());

  int _pendingPhotos;
  @override
  int get pendingPhotoCaptures => _pendingPhotos;
  @override
  int get remainingPhotos => _pendingPhotos;

  Future<void> clearFixturePhotos() async {
    _pendingPhotos = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    (resolver.catalog as ScryfallScanCatalog).close();
    super.dispose();
  }
}

Widget cameraUiApp({
  required ThemeMode theme,
  required double scale,
  required CameraUiSession session,
  WidgetBuilder? captureDrawerBuilder,
}) => ArcaneApp(
  key: UniqueKey(),
  theme: MyThemeData.themeData(theme),
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
    child: child!,
  ),
  home: Builder(
    builder: (BuildContext context) => Scaffold(
      child: Center(
        child: PrimaryButton(
          onPressed: () => Arcane.push<void>(
            context,
            GuidedCameraScreen(
              session: session,
              captureDrawerBuilder: captureDrawerBuilder,
              multipleCards: true,
              onClearCaptures: session.clearFixturePhotos,
              onCaptured: (String _, List<List<ScanPoint>> _) async =>
                  throw StateError('The layout fixture must not save photos.'),
            ),
          ),
          child: const Text('Open layout camera'),
        ),
      ),
    ),
  ),
);

Future<void> waitForCameraUi(
  WidgetTester tester,
  CameraUiPlatform camera,
) async {
  for (
    int attempt = 0;
    attempt < 100 && !camera.frames.hasListener;
    attempt++
  ) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(
    camera.frames.hasListener,
    isTrue,
    reason: 'Production preview is ready; camera calls: ${camera.operations}.',
  );
  await tester.pumpAndSettle();
}

Future<void> disposeCameraUi(
  WidgetTester tester,
  CameraUiPlatform camera, {
  bool verify = true,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (int attempt = 0; attempt < 100 && camera.disposals == 0; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  if (verify) {
    expect(camera.disposals, greaterThan(0));
    expect(camera.frames.hasListener, isFalse);
  }
}

Future<void> waitForCameraUiClear(
  WidgetTester tester,
  CameraUiSession session,
) async {
  for (
    int attempt = 0;
    attempt < 100 && session.pendingPhotoCaptures != 0;
    attempt++
  ) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(session.pendingPhotoCaptures, 0);
  await tester.pumpAndSettle();
}
