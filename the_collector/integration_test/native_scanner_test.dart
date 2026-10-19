import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:arcane/arcane.dart' as arcane;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hive/hive.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/pages/scanning/guided_camera_screen.dart';
import 'package:the_collector/pages/scanning/live_capture_overlay.dart';
import 'package:the_collector/pages/scanning/scan_correction_editor.dart';
import 'package:the_collector/pages/collection/card/card_add_dialog.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/scanning/live_scan_detector.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_symbol_matcher.dart';
import 'package:the_collector/utils/scanning/scryfall_request_scheduler.dart';

Future<File> _compose(
  ui.Image reference,
  Directory directory, {
  bool multiple = false,
  int quarterTurns = 0,
}) async {
  final int scale = multiple ? 3 : 1;
  final int rw = reference.width * scale;
  final int rh = reference.height * scale;
  final bool sideways = quarterTurns.isOdd;
  final int width = multiple ? rw * 2 + 180 : (sideways ? rh : rw) + 180;
  final int height = (sideways ? rw : rh) + 180;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xffd0d0d0), ui.BlendMode.src);
  final ui.Rect source = ui.Rect.fromLTWH(
    0,
    0,
    reference.width.toDouble(),
    reference.height.toDouble(),
  );
  if (multiple) {
    for (final double x in <double>[60, rw + 120.0]) {
      canvas.drawImageRect(
        reference,
        source,
        ui.Rect.fromLTWH(x, 90, rw.toDouble(), rh.toDouble()),
        ui.Paint(),
      );
    }
  } else {
    canvas.translate(width / 2, height / 2);
    canvas.rotate(
      quarterTurns == 0 ? math.pi / 100 : quarterTurns * math.pi / 2,
    );
    canvas.drawImageRect(
      reference,
      source,
      ui.Rect.fromLTWH(-rw / 2, -rh / 2, rw.toDouble(), rh.toDouble()),
      ui.Paint(),
    );
  }
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(width, height);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  final File file = File(
    '${directory.path}/${multiple ? 'batch' : 'rotated_$quarterTurns'}.png',
  );
  await file.writeAsBytes(data!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return file;
}

Future<ui.Size> _imageDimensions(String path) async {
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
    await File(path).readAsBytes(),
  );
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return ui.Size(descriptor.width.toDouble(), descriptor.height.toDouble());
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(
    ready(),
    isTrue,
    reason: 'Camera control did not complete within 30 seconds',
  );
  await tester.pump();
}

Future<File> _shapeFixture(
  Directory directory, {
  required bool triangle,
  double scale = 1,
  ui.Offset offset = ui.Offset.zero,
}) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
  canvas.translate(128 + offset.dx, 128 + offset.dy);
  canvas.scale(scale);
  canvas.translate(-128, -128);
  final ui.Paint ink = ui.Paint()..color = const ui.Color(0xff000000);
  if (triangle) {
    final ui.Path path = ui.Path()
      ..moveTo(128, 25)
      ..lineTo(230, 225)
      ..lineTo(26, 225)
      ..close();
    canvas.drawPath(path, ink);
  } else {
    canvas.drawCircle(const ui.Offset(128, 128), 101, ink);
  }
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(256, 256);
  final ByteData data = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!;
  final File file = File(
    '${directory.path}/${triangle ? 'triangle' : 'circle'}_${scale}_${offset.dx}_${offset.dy}.png',
  );
  await file.writeAsBytes(data.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return file;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const bool physicalCardQa = bool.fromEnvironment('PHYSICAL_CARD_QA');

  const String realPhotoDirectory = String.fromEnvironment(
    'SCANNER_QA_PHOTO_DIRECTORY',
  );
  if (realPhotoDirectory.isNotEmpty) {
    testWidgets(
      'actual photographed upside-down and partial cards retain safe hints',
      (WidgetTester tester) async {
        final NativeCardRecognizer recognizer = NativeCardRecognizer();
        final List<String> crops = <String>[];
        try {
          final ScanRecognition inverted = await recognizer.recognize(
            '$realPhotoDirectory/upside_down.jpg',
          );
          crops.addAll(inverted.crops.map((ScanCrop crop) => crop.imagePath));
          for (final ScanCrop crop in inverted.crops) {
            debugPrint(
              'Actual inverted crop ${crop.width}x${crop.height}: ${crop.warnings}; ${ScanHints.fromCrop(crop).names}; ${crop.lines.map((ScanTextLine line) => '${line.text}@${line.bounds.y}/${line.bounds.height}').join(' | ')}',
            );
          }
          expect(
            inverted.crops.any(
              (ScanCrop crop) => ScanHints.fromCrop(crop).names.any(
                (String name) => name.toLowerCase().contains('nevermore'),
              ),
            ),
            isTrue,
          );
          final ScanRecognition partial = await recognizer.recognize(
            '$realPhotoDirectory/partial_rules.jpg',
          );
          crops.addAll(partial.crops.map((ScanCrop crop) => crop.imagePath));
          expect(
            partial.crops.every(
              (ScanCrop crop) =>
                  crop.warnings.contains('incomplete_card') &&
                  ScanHints.fromCrop(crop).names.isEmpty,
            ),
            isTrue,
          );
          final ScanRecognition readable = await recognizer.recognize(
            '$realPhotoDirectory/readable_footer.jpg',
          );
          crops.addAll(readable.crops.map((ScanCrop crop) => crop.imagePath));
          final ScanHints hints = ScanHints.fromCrop(readable.crops.first);
          expect(
            hints.names.any(
              (String name) => name.toLowerCase().contains('go for the throat'),
            ),
            isTrue,
          );
          expect(hints.setCode, 'acr');
          expect(
            hints.collectorNumber?.replaceFirst(RegExp(r'^0+(?=\d)'), ''),
            '91',
          );
        } finally {
          for (final String path in crops) {
            if (await File(path).exists()) await File(path).delete();
          }
        }
      },
    );
  }

  testWidgets(
    'rear camera supports maximum quality capture and reports actual controls',
    (WidgetTester tester) async {
      final List<CameraDescription> cameras = await availableCameras();
      final Map<CameraLensType, CameraDescription> rear =
          <CameraLensType, CameraDescription>{};
      for (final CameraDescription camera in cameras) {
        if (camera.lensDirection == CameraLensDirection.back) {
          rear.putIfAbsent(camera.lensType, () => camera);
        }
      }
      expect(rear, isNotEmpty);
      for (final CameraDescription description in rear.values) {
        final CameraController camera = CameraController(
          description,
          ResolutionPreset.max,
          enableAudio: false,
          imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
              ? ImageFormatGroup.bgra8888
              : ImageFormatGroup.yuv420,
        );
        XFile? image;
        try {
          await camera.initialize();
          await camera.setJpegImageQuality(95);
          final double minZoom = await camera.getMinZoomLevel();
          final double maxZoom = await camera.getMaxZoomLevel();
          final double minEV = await camera.getMinExposureOffset();
          final double maxEV = await camera.getMaxExposureOffset();
          final double stepEV = await camera.getExposureOffsetStepSize();
          expect(maxZoom, greaterThanOrEqualTo(minZoom));
          expect(maxEV, greaterThanOrEqualTo(minEV));
          await camera.setZoomLevel(1.0.clamp(minZoom, maxZoom));
          await camera.setExposureOffset(0.0.clamp(minEV, maxEV));
          if (camera.value.focusPointSupported) {
            await camera.setFocusPoint(const ui.Offset(.5, .5));
          }
          if (camera.value.exposurePointSupported) {
            await camera.setExposurePoint(const ui.Offset(.5, .5));
          }
          if (camera.value.focusPointSupported) {
            await camera.setFocusMode(FocusMode.locked);
            expect(camera.value.focusMode, FocusMode.locked);
            await camera.setFocusMode(FocusMode.auto);
            expect(camera.value.focusMode, FocusMode.auto);
          }
          final NativeLiveCardDetector detector = NativeLiveCardDetector();
          final Stopwatch streamTime = Stopwatch()..start();
          int frames = 0;
          int analyzed = 0;
          int sourceWidth = 0;
          int sourceHeight = 0;
          int analysisMilliseconds = 0;
          int maximumDetectedEdge = 0;
          Object? analysisError;
          bool measuring = true;
          bool analyzing = false;
          Future<void> pendingAnalysis = Future<void>.value();
          await camera.startImageStream((CameraImage frame) {
            if (!measuring) return;
            frames++;
            sourceWidth = frame.width;
            sourceHeight = frame.height;
            if (analyzing) return;
            analyzing = true;
            pendingAnalysis = (() async {
              final Stopwatch latency = Stopwatch()..start();
              try {
                final LiveScanFrame? detected = await detector.analyze(
                  frame,
                  camera: description,
                  orientation:
                      camera.value.lockedCaptureOrientation ??
                      camera.value.deviceOrientation,
                );
                if (detected != null) {
                  analyzed++;
                  analysisMilliseconds += latency.elapsedMilliseconds;
                  maximumDetectedEdge = math.max(
                    maximumDetectedEdge,
                    math.max(detected.width, detected.height),
                  );
                }
              } catch (error) {
                analysisError ??= error;
              } finally {
                analyzing = false;
              }
            })();
          });
          await tester.pump(const Duration(seconds: 4));
          measuring = false;
          await camera.stopImageStream();
          await pendingAnalysis;
          streamTime.stop();
          expect(frames, greaterThan(0));
          expect(analyzed, greaterThan(0));
          expect(analysisError, isNull);
          expect(maximumDetectedEdge, lessThanOrEqualTo(960));
          debugPrint(
            'Actual ${description.lensType.name} stream: '
            '$sourceWidth x $sourceHeight, $frames frames in '
            '${streamTime.elapsedMilliseconds}ms, $analyzed native analyses, '
            'mean ${analysisMilliseconds / analyzed}ms; no frame images saved',
          );
          detector.reset();
          image = await camera.takePicture();
          final ui.Size dimensions = await _imageDimensions(image.path);
          expect(dimensions.width, greaterThan(1000));
          expect(dimensions.height, greaterThan(1000));
          debugPrint(
            'Actual ${description.lensType.name} JPEG: '
            '${dimensions.width.toInt()}x${dimensions.height.toInt()}; '
            'preview ${camera.value.previewSize}; zoom $minZoom..$maxZoom; '
            'EV $minEV..$maxEV step $stepEV; '
            'focusPoint ${camera.value.focusPointSupported}; '
            'exposurePoint ${camera.value.exposurePointSupported}',
          );
        } finally {
          await camera.dispose();
          if (image != null && await File(image.path).exists()) {
            await File(image.path).delete();
          }
        }
      }
    },
    skip: !physicalCardQa,
  );

  testWidgets(
    'guided camera switches physical lenses and applies visible controls',
    (WidgetTester tester) async {
      final List<String> captures = <String>[];
      final List<CameraDescription> rear = (await availableCameras())
          .where(
            (CameraDescription camera) =>
                camera.lensDirection == CameraLensDirection.back,
          )
          .toList();
      expect(rear, isNotEmpty);
      try {
        await tester.pumpWidget(
          arcane.ArcaneApp(
            theme: MyThemeData.themeData(arcane.ThemeMode.dark),
            home: GuidedCameraScreen(
              automaticCapture: false,
              multipleCards: true,
              onCaptured:
                  (String path, List<List<ScanPoint>> excludedRegions) async {
                    captures.add(path);
                    return true;
                  },
            ),
          ),
        );
        await _waitFor(
          tester,
          () => find.byType(CameraPreview).evaluate().isNotEmpty,
        );
        CameraController controller = tester
            .widget<CameraPreview>(find.byType(CameraPreview))
            .controller;
        if (rear.any(
          (CameraDescription camera) => camera.lensType == CameraLensType.wide,
        )) {
          expect(controller.description.lensType, CameraLensType.wide);
        }
        expect(find.byType(LiveCaptureOverlay), findsOneWidget);
        expect(find.text('Capture photo').hitTestable(), findsOneWidget);
        expect(find.text('Review batch').hitTestable(), findsOneWidget);
        for (final CameraDescription lens in rear) {
          final String base = switch (lens.lensType) {
            CameraLensType.wide => 'Wide',
            CameraLensType.ultraWide => 'Ultra-wide',
            CameraLensType.telephoto => 'Telephoto',
            CameraLensType.unknown => 'Camera',
          };
          final int matching = rear
              .where(
                (CameraDescription camera) => camera.lensType == lens.lensType,
              )
              .length;
          final String label =
              matching > 1 || lens.lensType == CameraLensType.unknown
              ? '$base ${rear.indexOf(lens) + 1}'
              : base;
          if (rear.length > 1 && controller.description.name != lens.name) {
            final Finder selector = find.byKey(
              const ValueKey<String>('camera-lens-selector'),
            );
            await tester.ensureVisible(selector);
            await tester.tap(selector);
            await tester.pump(const Duration(milliseconds: 300));
            await tester.tap(find.text(label).hitTestable().last);
          }
          await _waitFor(tester, () {
            if (find.byType(CameraPreview).evaluate().isEmpty) return false;
            return tester
                    .widget<CameraPreview>(find.byType(CameraPreview))
                    .controller
                    .description
                    .name ==
                lens.name;
          });
          controller = tester
              .widget<CameraPreview>(find.byType(CameraPreview))
              .controller;
          expect(controller.value.isInitialized, isTrue);
          await _waitFor(tester, () {
            final Finder capture = find.ancestor(
              of: find.text('Capture photo'),
              matching: find.byType(arcane.PrimaryButton),
            );
            return capture.evaluate().isNotEmpty &&
                tester.widget<arcane.PrimaryButton>(capture).onPressed != null;
          });
          if (find.byType(arcane.Slider).evaluate().isEmpty) {
            await tester.tap(
              find.byKey(const ValueKey<String>('camera-adjustments')),
            );
            await tester.pump();
          }
          final Finder sliders = find.byType(arcane.Slider);
          final bool hasZoom = find
              .textContaining(RegExp(r'^Zoom [0-9]'))
              .evaluate()
              .isNotEmpty;
          final bool hasExposure = find
              .textContaining(RegExp(r'^Exposure [-0-9]'))
              .evaluate()
              .isNotEmpty;
          expect(
            sliders,
            findsNWidgets((hasZoom ? 1 : 0) + (hasExposure ? 1 : 0)),
          );
          double? changedZoom;
          double? changedExposure;
          if (hasZoom) {
            final arcane.Slider zoom = tester.widget<arcane.Slider>(
              sliders.at(0),
            );
            expect(zoom.max, lessThanOrEqualTo(8));
            expect(zoom.max, greaterThan(zoom.min));
            await tester.ensureVisible(sliders.at(0));
            await tester.drag(sliders.at(0), const ui.Offset(24, 0));
            await tester.pump(const Duration(milliseconds: 300));
            changedZoom = tester
                .widget<arcane.Slider>(sliders.at(0))
                .value
                .value;
            expect(changedZoom, isNot(zoom.value.value));
          }
          if (hasExposure) {
            final Finder slider = sliders.at(hasZoom ? 1 : 0);
            final double before = tester
                .widget<arcane.Slider>(slider)
                .value
                .value;
            await tester.ensureVisible(slider);
            await tester.drag(slider, const ui.Offset(24, 0));
            await tester.pump(const Duration(milliseconds: 300));
            changedExposure = tester.widget<arcane.Slider>(slider).value.value;
            expect(changedExposure, isNot(before));
          }
          if (controller.value.focusPointSupported) {
            await tester.ensureVisible(
              find.byKey(const ValueKey<String>('camera-focus-lock')),
            );
            await tester.tap(
              find.byKey(const ValueKey<String>('camera-focus-lock')),
            );
            await _waitFor(
              tester,
              () => controller.value.focusMode == FocusMode.locked,
            );
            expect(
              (tester
                          .widget<arcane.IconButton>(
                            find.byKey(
                              const ValueKey<String>('camera-focus-lock'),
                            ),
                          )
                          .icon
                      as arcane.Icon)
                  .icon,
              arcane.Icons.lock,
            );
            await tester.ensureVisible(find.byType(CameraPreview));
            await tester.tap(find.byType(CameraPreview));
            await _waitFor(
              tester,
              () => controller.value.focusMode == FocusMode.auto,
            );
            expect(
              find.byKey(const ValueKey<String>('camera-focus-lock')),
              findsOneWidget,
            );
          }
          debugPrint(
            'Guided ${lens.lensType.name}: selected ${lens.name}; '
            'zoom $changedZoom; exposure $changedExposure; '
            'focus point supported ${controller.value.focusPointSupported}',
          );
        }
        final CameraDescription? alternate = rear
            .where(
              (CameraDescription camera) =>
                  camera.name != controller.description.name,
            )
            .firstOrNull;
        if (alternate != null) {
          final arcane.IconButton torchButton = tester
              .widget<arcane.IconButton>(
                find.byKey(const ValueKey<String>('camera-torch')),
              );
          final arcane.Select<String> lensSelector = tester
              .widget<arcane.Select<String>>(
                find.byKey(const ValueKey<String>('camera-lens-selector')),
              );
          torchButton.onPressed?.call();
          lensSelector.onChanged!(alternate.name);
          await _waitFor(tester, () {
            if (find.byType(CameraPreview).evaluate().isEmpty) return false;
            return tester
                    .widget<CameraPreview>(find.byType(CameraPreview))
                    .controller
                    .description
                    .name ==
                alternate.name;
          });
          controller = tester
              .widget<CameraPreview>(find.byType(CameraPreview))
              .controller;
          expect(controller.value.flashMode, FlashMode.off);
          expect(
            (tester
                        .widget<arcane.IconButton>(
                          find.byKey(const ValueKey<String>('camera-torch')),
                        )
                        .icon
                    as arcane.Icon)
                .icon,
            arcane.Icons.lightning_slash,
          );
          debugPrint(
            'Rapid torch -> ${alternate.lensType.name}: new lens torch state remains off',
          );
        }
        await _waitFor(tester, () {
          final Finder capture = find.ancestor(
            of: find.text('Capture photo'),
            matching: find.byType(arcane.PrimaryButton),
          );
          return capture.evaluate().isNotEmpty &&
              tester.widget<arcane.PrimaryButton>(capture).onPressed != null;
        });
        await tester.ensureVisible(
          find.byKey(const ValueKey<String>('camera-torch')),
        );
        await tester.tap(find.byKey(const ValueKey<String>('camera-torch')));
        await _waitFor(
          tester,
          () =>
              controller.value.flashMode == FlashMode.torch ||
              find
                  .text('Torch is unavailable. Add light beside the card.')
                  .evaluate()
                  .isNotEmpty,
        );
        if (controller.value.flashMode == FlashMode.torch) {
          expect(
            (tester
                        .widget<arcane.IconButton>(
                          find.byKey(const ValueKey<String>('camera-torch')),
                        )
                        .icon
                    as arcane.Icon)
                .icon,
            arcane.Icons.lightning,
          );
          await tester.tap(find.byKey(const ValueKey<String>('camera-torch')));
          await _waitFor(
            tester,
            () => controller.value.flashMode == FlashMode.off,
          );
        }
        await tester.tap(find.text('Capture photo'));
        await _waitFor(tester, () => captures.isNotEmpty);
        final ui.Size dimensions = await _imageDimensions(captures.single);
        expect(dimensions.width, greaterThan(1000));
        expect(dimensions.height, greaterThan(1000));
        debugPrint(
          'Guided shutter JPEG ${dimensions.width.toInt()}x${dimensions.height.toInt()}',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const arcane.SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
        for (final String path in captures) {
          if (await File(path).exists()) await File(path).delete();
        }
      }
    },
    skip: !physicalCardQa,
  );

  testWidgets(
    'catalog review hides diagnostics while the QA viewer verifies the source photo',
    (WidgetTester tester) async {
      final ScryfallApiClient api = ScryfallApiClient(
        httpClient: ScryfallHttpClient(),
      );
      final Directory directory = await Directory.systemTemp.createTemp(
        'collector_printing_review_fixture_',
      );
      try {
        final MtgCard printing = await api.getCardByName(
          'Lightning Bolt',
          set: '2x2',
        );
        final http.Response response = await http.get(
          printing.imageUris!.large,
        );
        expect(response.statusCode, 200);
        final File source = File('${directory.path}/public_printing.jpg');
        await source.writeAsBytes(response.bodyBytes);
        final ui.Size size = await _imageDimensions(source.path);
        final ScanCrop crop = ScanCrop(
          imagePath: source.path,
          width: size.width.toInt(),
          height: size.height.toInt(),
          rectified: false,
          sourceCorners: const <ScanPoint>[],
          lines: const <ScanTextLine>[],
        );
        bool reviewReturned = false;
        PrintingSelection? reviewResult;
        await tester.pumpWidget(
          arcane.ArcaneApp(
            theme: MyThemeData.themeData(arcane.ThemeMode.dark),
            home: arcane.Builder(
              builder: (arcane.BuildContext context) => arcane.Scaffold(
                child: arcane.PrimaryButton(
                  key: const ValueKey<String>('native-open-printing-review'),
                  onPressed: () async {
                    reviewResult = await arcane.Arcane.push<PrintingSelection>(
                      context,
                      ScanCorrectionEditor(
                        crop: crop,
                        onConfirmed: (PrintingSelection selection) =>
                            arcane.Navigator.of(context).pop(selection),
                        onClose: () => arcane.Navigator.of(context).pop(),
                        initialResolution: ScanResolution(
                          candidates: <ScanCandidate>[
                            ScanCandidate(printing, const <ScanEvidence>{
                              ScanEvidence.nameMatch,
                            }),
                          ],
                          hints: ScanHints(names: <String>[printing.name]),
                          status: ScanResolutionStatus.needsReview,
                        ),
                      ),
                    );
                    reviewReturned = true;
                  },
                  child: const arcane.Text('Open review'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('native-open-printing-review')),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Original photo'), findsNothing);
        expect(find.bySemanticsLabel('Your captured card'), findsNothing);
        expect(find.byType(arcane.InteractiveViewer), findsNothing);
        final Finder artwork = find.byKey(
          ValueKey<String>('printing-artwork-${printing.id}'),
        );
        await _waitFor(tester, () => artwork.evaluate().isNotEmpty);
        await _waitFor(tester, () {
          final Finder raw = find.descendant(
            of: artwork,
            matching: find.byType(arcane.RawImage),
          );
          return raw.evaluate().isNotEmpty &&
              tester.widget<arcane.RawImage>(raw.first).image != null;
        });
        final arcane.Image displayed = tester.widget<arcane.Image>(
          find
              .descendant(of: artwork, matching: find.byType(arcane.Image))
              .first,
        );
        expect(displayed.image, isA<arcane.NetworkImage>());
        expect(
          (displayed.image as arcane.NetworkImage).url,
          printing.imageUris!.small.toString(),
        );
        expect(find.text('Photo unavailable.'), findsNothing);
        expect(find.text('No captured photo'), findsNothing);
        expect(
          find.byKey(const ValueKey<String>('printing-confirm')).hitTestable(),
          findsOneWidget,
        );
        expect(reviewReturned, isFalse);
        final Finder close = find.byKey(
          const ValueKey<String>('scan-correction-close'),
        );
        await tester.tap(close);
        await _waitFor(
          tester,
          () =>
              reviewReturned &&
              find.byType(ScanCorrectionEditor).evaluate().isEmpty,
        );
        expect(find.byType(ScanCorrectionEditor), findsNothing);
        expect(reviewResult, isNull);
        await tester.pumpWidget(
          arcane.ArcaneApp(
            theme: MyThemeData.themeData(arcane.ThemeMode.dark),
            home: arcane.Scaffold(
              child: arcane.InteractiveViewer(
                minScale: 1,
                maxScale: 8,
                child: arcane.SizedBox.expand(
                  child: arcane.Image.file(
                    source,
                    fit: arcane.BoxFit.contain,
                    semanticLabel: 'Diagnostic QA photo',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final Finder viewer = find.byType(arcane.InteractiveViewer);
        expect(viewer, findsOneWidget);
        await _waitFor(tester, () {
          final Finder raw = find.descendant(
            of: viewer,
            matching: find.byType(arcane.RawImage),
          );
          return raw.evaluate().isNotEmpty &&
              tester.widget<arcane.RawImage>(raw.first).image != null;
        });
        final arcane.Image diagnostic = tester.widget<arcane.Image>(
          find.descendant(of: viewer, matching: find.byType(arcane.Image)),
        );
        expect(diagnostic.image, isA<arcane.FileImage>());
        expect((diagnostic.image as arcane.FileImage).file.path, source.path);
        final Finder transform = find
            .descendant(of: viewer, matching: find.byType(arcane.Transform))
            .first;
        final double initialScale = tester
            .widget<arcane.Transform>(transform)
            .transform
            .getMaxScaleOnAxis();
        final ui.Offset center = tester.getCenter(viewer);
        final TestGesture left = await tester.startGesture(
          center - const ui.Offset(25, 0),
          pointer: 1,
        );
        final TestGesture right = await tester.startGesture(
          center + const ui.Offset(25, 0),
          pointer: 2,
        );
        await left.moveTo(center - const ui.Offset(90, 0));
        await right.moveTo(center + const ui.Offset(90, 0));
        await tester.pump();
        final double scale = tester
            .widget<arcane.Transform>(transform)
            .transform
            .getMaxScaleOnAxis();
        expect(scale, greaterThan(initialScale));
        expect(scale, lessThanOrEqualTo(8));
        await left.up();
        await right.up();
        debugPrint('Diagnostic QA photo pinch scale $initialScale -> $scale');
        expect(await source.readAsBytes(), response.bodyBytes);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const arcane.SizedBox.shrink());
        await tester.pump();
        await directory.delete(recursive: true);
        api.close();
      }
    },
  );

  testWidgets(
    'live native frame geometry and visual comparison use bounded public fixtures',
    (WidgetTester tester) async {
      final ScryfallApiClient api = ScryfallApiClient(
        httpClient: ScryfallHttpClient(),
      );
      final Directory directory = await Directory.systemTemp.createTemp(
        'collector_live_fixture_',
      );
      final List<String> queuedCrops = <String>[];
      ui.Image? reference;
      ui.Image? batch;
      try {
        final MtgCard printing = await api.getCardByName(
          'Lightning Bolt',
          set: '2x2',
        );
        final http.Response response = await http.get(
          printing.imageUris!.large,
        );
        expect(response.statusCode, 200);
        final File original = File('${directory.path}/printing.jpg');
        await original.writeAsBytes(response.bodyBytes);
        final ui.Codec codec = await ui.instantiateImageCodec(
          response.bodyBytes,
        );
        reference = (await codec.getNextFrame()).image;
        codec.dispose();
        final File composed = await _compose(
          reference,
          directory,
          multiple: true,
        );
        final ui.Codec batchCodec = await ui.instantiateImageCodec(
          await composed.readAsBytes(),
        );
        batch = (await batchCodec.getNextFrame()).image;
        batchCodec.dispose();
        final ByteData rgba = (await batch.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final Map<String, Object> pixels =
            NativeLiveCardDetector.boundedFramePixels(
              width: batch.width,
              height: batch.height,
              bytes: rgba.buffer.asUint8List(),
              bytesPerRow: batch.width * 4,
              bytesPerPixel: 4,
              bgra: true,
            );
        final Uint8List bgra = pixels['bytes'] as Uint8List;
        for (int index = 0; index < bgra.length; index += 4) {
          final int red = bgra[index];
          bgra[index] = bgra[index + 2];
          bgra[index + 2] = red;
        }
        final List<String> titleFailures = <String>[];
        final List<String> bodyFailures = <String>[];
        for (final int rotation in <int>[0, 90, 180, 270]) {
          final Map<Object?, Object?>? output = await NativeCardRecognizer
              .channel
              .invokeMethod<Map<Object?, Object?>>(
                'detectFrame',
                <String, Object>{
                  ...pixels,
                  'rotation': rotation,
                  'includeText': true,
                },
              );
          final LiveScanFrame frame = LiveScanFrame.fromMap(
            output!,
            orientationToken: 'fixture:$rotation',
          );
          expect(frame.rectanglesSupported, isTrue);
          expect(frame.cards.length, 2);
          expect(
            frame.width,
            rotation % 180 == 0 ? pixels['width'] : pixels['height'],
          );
          expect(
            frame.height,
            rotation % 180 == 0 ? pixels['height'] : pixels['width'],
          );
          for (final LiveCardDetection card in frame.cards) {
            expect(card.corners.length, 4);
            for (final ScanPoint corner in card.corners) {
              expect(corner.x, inInclusiveRange(0, 1));
              expect(corner.y, inInclusiveRange(0, 1));
            }
            debugPrint(
              'Live rotation $rotation OCR: ${card.lines.map((ScanTextLine line) => '${line.text}@${line.bounds.y}/${line.bounds.height}').join(' | ')}',
            );
            final ScanHints hints = ScanHints.fromCrop(
              ScanCrop(
                imagePath: '',
                width: frame.width,
                height: frame.height,
                rectified: true,
                sourceCorners: card.corners,
                lines: card.lines,
                warnings: card.warnings,
              ),
            );
            debugPrint(
              'Live rotation $rotation parsed title: ${hints.names}; footer ${hints.setCode}/${hints.collectorNumber}/${hints.language}',
            );
            if (!hints.names.any(
              (String name) => name.toLowerCase() == 'lightning bolt',
            )) {
              titleFailures.add('$rotation: ${hints.names}');
            }
            if (!card.lines.any(
              (ScanTextLine line) =>
                  line.bounds.y > .25 &&
                  line.bounds.y < .70 &&
                  line.text.toLowerCase().contains('damage'),
            )) {
              bodyFailures.add('$rotation');
            }
          }
          debugPrint(
            'Live fixture rotation $rotation: ${frame.width}x${frame.height}, '
            '${frame.cards.length} rectangles, ${frame.cards.map((LiveCardDetection card) => card.lines.length).toList()} lines',
          );
        }
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          final http.Response artwork = await http.get(
            printing.imageUris!.artCrop,
          );
          expect(artwork.statusCode, 200);
          final File art = File('${directory.path}/art_crop.jpg');
          await art.writeAsBytes(artwork.bodyBytes);
          final double? distance = await NativeCardRecognizer.compareArtwork(
            queryImagePath: original.path,
            referenceImagePath: art.path,
          );
          final MtgCard unrelatedPrinting = await api.getCardByName(
            'Black Lotus',
          );
          expect(unrelatedPrinting.name, 'Black Lotus');
          expect(
            unrelatedPrinting.imageUris!.artCrop,
            isNot(printing.imageUris!.artCrop),
          );
          final http.Response unrelatedArtwork = await http.get(
            unrelatedPrinting.imageUris!.artCrop,
          );
          expect(unrelatedArtwork.statusCode, 200);
          expect(
            listEquals(unrelatedArtwork.bodyBytes, artwork.bodyBytes),
            isFalse,
          );
          final File unrelated = File('${directory.path}/unrelated_art.jpg');
          await unrelated.writeAsBytes(unrelatedArtwork.bodyBytes);
          final double? unrelatedDistance =
              await NativeCardRecognizer.compareArtwork(
                queryImagePath: original.path,
                referenceImagePath: unrelated.path,
              );
          expect(distance, isNotNull);
          expect(distance!.isFinite, isTrue);
          expect(distance, greaterThanOrEqualTo(0));
          expect(unrelatedDistance, greaterThan(distance));
          final Future<ScanRecognition> queuedStill = NativeCardRecognizer()
              .recognize(composed.path, multipleCards: true);
          final Future<Map<Object?, Object?>?> activeLive = NativeCardRecognizer
              .channel
              .invokeMethod<Map<Object?, Object?>>(
                'detectFrame',
                <String, Object>{...pixels, 'rotation': 0, 'includeText': true},
              );
          final Future<double?> queuedArtwork =
              NativeCardRecognizer.compareArtwork(
                queryImagePath: original.path,
                referenceImagePath: art.path,
              );
          final Future<bool> droppedLive = NativeCardRecognizer.channel
              .invokeMethod<Map<Object?, Object?>>(
                'detectFrame',
                <String, Object>{
                  ...pixels,
                  'rotation': 0,
                  'includeText': false,
                },
              )
              .then(
                (Map<Object?, Object?>? _) => false,
                onError: (Object error) {
                  expect(
                    error,
                    isA<PlatformException>().having(
                      (PlatformException value) => value.code,
                      'code',
                      'scanner_busy',
                    ),
                  );
                  return true;
                },
              );
          final ScanRecognition recognized = await queuedStill;
          queuedCrops.addAll(
            recognized.crops.map((ScanCrop crop) => crop.imagePath),
          );
          final Map<Object?, Object?>? concurrentLive = await activeLive;
          expect(concurrentLive, isNotNull);
          expect(concurrentLive!['geometryOnly'], isNot(true));
          final LiveScanFrame concurrentFrame = LiveScanFrame.fromMap(
            concurrentLive,
            orientationToken: 'concurrent:0',
          );
          expect(concurrentFrame.cards.length, 2);
          expect(
            concurrentFrame.cards.every(
              (LiveCardDetection card) => card.lines.isNotEmpty,
            ),
            isTrue,
            reason: 'Saved-photo OCR must not demote live frames to geometry.',
          );
          final double? queuedDistance = await queuedArtwork;
          expect(queuedDistance, distance);
          expect(await droppedLive, isTrue);
          debugPrint(
            'Native concurrency: live text runs alongside saved-photo OCR; '
            'artwork follows the photo and extra live frames are dropped',
          );
          final File triangle = await _shapeFixture(directory, triangle: true);
          final File circle = await _shapeFixture(directory, triangle: false);
          final File transformed = await _shapeFixture(
            directory,
            triangle: true,
            scale: .60,
            offset: const ui.Offset(12, -9),
          );
          final double? matching = await NativeCardRecognizer.compareSetSymbol(
            queryImagePath: triangle.path,
            referenceImagePath: triangle.path,
            queryRegion: const ScanBounds(0, 0, 1, 1),
          );
          final double? different = await NativeCardRecognizer.compareSetSymbol(
            queryImagePath: triangle.path,
            referenceImagePath: circle.path,
            queryRegion: const ScanBounds(0, 0, 1, 1),
          );
          final double? transformedDistance =
              await NativeCardRecognizer.compareSetSymbol(
                queryImagePath: transformed.path,
                referenceImagePath: triangle.path,
                queryRegion: const ScanBounds(0, 0, 1, 1),
              );
          debugPrint(
            'Visual fixture raw distances: artwork $distance, identical shape $matching, different shape $different',
          );
          expect(matching, isNotNull);
          expect(different, greaterThan(matching!));
          expect(transformedDistance, lessThan(.10));
          expect(transformedDistance, lessThan(different!));
          final double? blankRegion =
              await NativeCardRecognizer.compareSetSymbol(
                queryImagePath: triangle.path,
                referenceImagePath: triangle.path,
                queryRegion: const ScanBounds(0, 0, .04, .04),
              );
          expect(blankRegion, isNull);
          final ScanCrop photographed = recognized.crops.first;
          final ScanBounds? symbolRegion = CachedScanSymbolMatcher.symbolRegion(
            photographed,
          );
          expect(symbolRegion, isNotNull);
          const String symbolOutput = String.fromEnvironment(
            'SCANNER_SYMBOL_QA_DIRECTORY',
          );
          final Directory? symbolArtifacts = symbolOutput.isEmpty
              ? null
              : await Directory(symbolOutput).create(recursive: true);
          if (symbolArtifacts != null) {
            await File(photographed.imagePath)
                .copy('${symbolArtifacts.path}/rectified_card.jpg');
            await File('${symbolArtifacts.path}/region.json').writeAsString(
              jsonEncode(<String, double>{
                'x': symbolRegion!.x,
                'y': symbolRegion.y,
                'width': symbolRegion.width,
                'height': symbolRegion.height,
              }),
            );
          }
          final Map<String, double?> symbolDistances = <String, double?>{};
          for (final String code in <String>[printing.set, 'm21']) {
            final MtgSet set = await api.getSetByCode(code);
            final http.Response svg = await http.get(set.iconSvgUri);
            expect(svg.statusCode, 200);
            final File raster = File('${directory.path}/set_$code.png');
            await raster.writeAsBytes(
              await CachedScanSymbolMatcher.rasterizeSymbol(svg.body),
            );
            if (symbolArtifacts != null) {
              await raster.copy('${symbolArtifacts.path}/set_$code.png');
            }
            symbolDistances[code] = await NativeCardRecognizer.compareSetSymbol(
              queryImagePath: photographed.imagePath,
              referenceImagePath: raster.path,
              queryRegion: symbolRegion!,
            );
          }
          debugPrint('Public card set glyph raw distances: $symbolDistances');
          expect(symbolDistances[printing.set], isNotNull);
          expect(
            symbolDistances['m21'],
            greaterThan(symbolDistances[printing.set]!),
          );
        }
        expect(
          titleFailures,
          isEmpty,
          reason: 'All rotations must recover the actual title band',
        );
        expect(
          bodyFailures,
          isEmpty,
          reason: 'All rotations must preserve each card body',
        );
        expect(tester.takeException(), isNull);
      } finally {
        for (final String path in queuedCrops) {
          if (await File(path).exists()) await File(path).delete();
        }
        reference?.dispose();
        batch?.dispose();
        api.close();
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets('real native OCR recognizes a public printing without Firebase access', (
    WidgetTester tester,
  ) async {
    expect(NativeCardRecognizer.supported, isTrue);
    final ScryfallApiClient api = ScryfallApiClient(
      httpClient: ScryfallHttpClient(),
    );
    final Directory directory = await Directory.systemTemp.createTemp(
      'collector_scanner_fixture_',
    );
    Hive.init('${directory.path}/hive');
    final ScryfallScanCatalog catalog = ScryfallScanCatalog();
    final ScanResolver resolver = ScanResolver(catalog: catalog);
    final List<String> crops = <String>[];
    ui.Image? decoded;
    try {
      final MtgCard reference = await api.getCardByName(
        'Lightning Bolt',
        set: '2x2',
      );
      final Uri imageUrl = reference.imageUris!.large;
      final http.Response response = await http.get(imageUrl);
      expect(response.statusCode, 200);
      final ui.Codec codec = await ui.instantiateImageCodec(response.bodyBytes);
      decoded = (await codec.getNextFrame()).image;
      codec.dispose();
      final File image = await _compose(decoded, directory);
      final NativeCardRecognizer recognizer = NativeCardRecognizer();
      final ScanRecognition result = await recognizer.recognize(image.path);
      crops.addAll(result.crops.map((ScanCrop crop) => crop.imagePath));
      expect(result.crops, isNotEmpty);
      expect(
        result.crops
            .expand((ScanCrop crop) => crop.lines)
            .any(
              (ScanTextLine line) =>
                  line.text.toLowerCase().contains('lightning bolt'),
            ),
        isTrue,
      );
      for (final ScanCrop crop in result.crops) {
        expect(await File(crop.imagePath).exists(), isTrue);
        expect(crop.width, greaterThan(100));
        expect(crop.height, greaterThan(100));
        for (final ScanTextLine line in crop.lines) {
          expect(line.bounds.x, inInclusiveRange(0.0, 1.0));
          expect(line.bounds.y, inInclusiveRange(0.0, 1.0));
          expect(line.confidence, inInclusiveRange(0.0, 1.0));
        }
      }
      if (Platform.isIOS) {
        expect(result.crops.single.rectified, isTrue);
        final File batch = await _compose(decoded, directory, multiple: true);
        final ScanRecognition segmented = await recognizer.recognize(
          batch.path,
          multipleCards: true,
        );
        crops.addAll(segmented.crops.map((ScanCrop crop) => crop.imagePath));
        expect(segmented.width, greaterThan(4096));
        expect(segmented.crops.length, 2);
        expect(
          segmented.crops.every(
            (ScanCrop crop) => crop.width > decoded!.width * 2,
          ),
          isTrue,
        );
        for (final ScanCrop crop in segmented.crops) {
          final ScanHints hints = ScanHints.fromCrop(crop);
          debugPrint(
            'Native fixture footer: ${hints.setCode}/${hints.collectorNumber}/${hints.language}',
          );
          if (hints.setCode != reference.set ||
              hints.collectorNumber != reference.collectorNumber ||
              hints.language != reference.lang.json) {
            debugPrint(
              'Native footer observations: ${crop.lines.map((ScanTextLine line) => '${line.text} confidence=${line.confidence} y=${line.bounds.y} h=${line.bounds.height} x=${line.bounds.x} w=${line.bounds.width}').join(' | ')}',
            );
          }
          final ScanHints observed = ScanHints.fromCrop(
            crop,
            minimumFooterConfidence: .30,
          );
          expect(observed.setCode, reference.set);
          expect(observed.language, reference.lang.json);
          expect(hints.setCode, anyOf(isNull, reference.set));
          expect(
            hints.collectorNumber?.replaceFirst(RegExp(r'^0+(?=\d)'), ''),
            anyOf(isNull, reference.collectorNumber),
          );
          expect(
            crop.lines.any(
              (ScanTextLine line) =>
                  line.confidence >= .30 &&
                  line.bounds.y >= .80 &&
                  line.bounds.y + line.bounds.height <= 1.02 &&
                  RegExp(
                    '^0*${RegExp.escape(reference.collectorNumber)}(?:\\s*/|\\b)',
                  ).hasMatch(line.text.trim()),
            ),
            isTrue,
          );
          expect(hints.language, anyOf(isNull, reference.lang.json));
        }
        final ScanResolution resolution = await resolver.resolve(
          segmented.crops.first,
        );
        expect(resolution.candidates, isNotEmpty);
        expect(resolution.candidates.first.card.name, reference.name);
        expect(resolution.candidates.first.card.set, reference.set);
        expect(
          resolution.candidates.first.card.collectorNumber,
          reference.collectorNumber,
        );
        final ScanHints authoritative = ScanHints.fromCrop(
          segmented.crops.first,
        );
        if (authoritative.setCode == null || authoritative.language == null) {
          expect(resolution.status, ScanResolutionStatus.needsReview);
          expect(
            hasExactPrintingEvidence(segmented.crops.first, resolution),
            isFalse,
          );
        }
        for (final int turn in <int>[1, 2, 3]) {
          final File rotated = await _compose(
            decoded,
            directory,
            quarterTurns: turn,
          );
          final ScanRecognition rotation = await recognizer.recognize(
            rotated.path,
          );
          crops.addAll(rotation.crops.map((ScanCrop crop) => crop.imagePath));
          expect(
            rotation.crops
                .expand((ScanCrop crop) => crop.lines)
                .any(
                  (ScanTextLine line) =>
                      line.bounds.y < .25 &&
                      line.text.toLowerCase().contains('lightning bolt'),
                ),
            isTrue,
            reason: '$turn quarter-turn title must be upright',
          );
          final ScanHints hints = ScanHints.fromCrop(rotation.crops.single);
          final ScanHints observed = ScanHints.fromCrop(
            rotation.crops.single,
            minimumFooterConfidence: .30,
          );
          expect(observed.setCode, reference.set);
          expect(hints.setCode, anyOf(isNull, reference.set));
          expect(
            hints.collectorNumber?.replaceFirst(RegExp(r'^0+(?=\d)'), ''),
            anyOf(isNull, reference.collectorNumber),
          );
          expect(
            rotation.crops.single.lines.any(
              (ScanTextLine line) =>
                  line.confidence >= .30 &&
                  line.bounds.y >= .80 &&
                  line.bounds.y + line.bounds.height <= 1.02 &&
                  RegExp(
                    '^0*${RegExp.escape(reference.collectorNumber)}(?:\\s*/|\\b)',
                  ).hasMatch(line.text.trim()),
            ),
            isTrue,
          );
        }
        expect(
          segmented.crops.every((ScanCrop crop) => crop.rectified),
          isTrue,
        );
      }
      await expectLater(
        recognizer.recognize('${directory.path}/missing.jpg'),
        throwsA(isA<PlatformException>()),
      );
    } finally {
      catalog.close();
      await Hive.close();
      api.close();
      decoded?.dispose();
      for (final String path in crops) {
        if (await File(path).exists()) await File(path).delete();
      }
      await directory.delete(recursive: true);
    }
  });
}
