import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/live_scan_detector.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scryfall_request_scheduler.dart';

const String _name = 'Circle of Protection: Blue';
const bool _physicalCameraQa = bool.fromEnvironment('HANDHELD_CAMERA_QA');

String _letters(String text) =>
    text.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

Future<Map<String, Object>> _frame(ui.Image reference, int rotation) async {
  const int width = 960;
  const int height = 1280;
  const double cardHeight = 1100;
  final double cardWidth = cardHeight * reference.width / reference.height;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff747474), ui.BlendMode.src);
  canvas.translate(width / 2, height / 2);
  canvas.rotate(rotation * math.pi / 180);
  canvas.drawImageRect(
    reference,
    ui.Rect.fromLTWH(
      0,
      0,
      reference.width.toDouble(),
      reference.height.toDouble(),
    ),
    ui.Rect.fromLTWH(-cardWidth / 2, -cardHeight / 2, cardWidth, cardHeight),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final ui.Picture picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(width, height);
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    expect(data, isNotNull);
    final Map<String, Object> pixels =
        NativeLiveCardDetector.boundedFramePixels(
          width: width,
          height: height,
          bytes: data!.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          ),
          bytesPerRow: width * 4,
          bytesPerPixel: 4,
          bgra: true,
        );
    final Uint8List bgra = pixels['bytes'] as Uint8List;
    for (int offset = 0; offset < bgra.length; offset += 4) {
      final int red = bgra[offset];
      bgra[offset] = bgra[offset + 2];
      bgra[offset + 2] = red;
    }
    expect(pixels['width'], 720);
    expect(pixels['height'], 960);
    expect(bgra.length, 720 * 960 * 4);
    return pixels;
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

bool _actualCircle(LiveCardDetection card, LiveScanFrame frame) {
  final bool title = card.lines.any(
    (ScanTextLine line) =>
        line.confidence >= .85 &&
        line.bounds.y < .20 &&
        line.bounds.width > line.bounds.height &&
        _letters(line.text) == _letters(_name),
  );
  final bool type = card.lines.any(
    (ScanTextLine line) =>
        line.confidence >= .85 &&
        line.bounds.y >= .35 &&
        line.bounds.y <= .70 &&
        line.bounds.width > line.bounds.height &&
        _letters(line.text) == 'enchantment',
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
  return title &&
      type &&
      hints.names.any((String name) => _letters(name) == _letters(_name)) &&
      hints.typeLine == 'enchantment' &&
      hints.collectorNumber == null;
}

Map<String, Object?> _cardReport(LiveCardDetection card) => <String, Object?>{
  'corners': card.corners
      .map((ScanPoint point) => <String, double>{'x': point.x, 'y': point.y})
      .toList(),
  'warnings': card.warnings.take(8).toList(),
  'lines': card.lines
      .take(32)
      .map(
        (ScanTextLine line) => <String, Object?>{
          'text': line.text.length > 240
              ? line.text.substring(0, 240)
              : line.text,
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
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native historical handheld fixture avoids upright retry and recovers reversed title and type',
    (WidgetTester tester) async {
      final ScryfallApiClient api = ScryfallApiClient(
        httpClient: ScryfallHttpClient(),
      );
      final http.Client images = http.Client();
      ui.Image? reference;
      final List<Map<String, Object?>> trials = <Map<String, Object?>>[];
      final Map<String, Object?> report = <String, Object?>{
        'fixture': 'public Scryfall Ice Age artwork on a plain canvas',
        'measuresPhysicalHandheldCamera': false,
        'name': _name,
        'set': 'ice',
        'collectorNumber': '13',
        'printedCollectorNumberExpected': false,
        'trials': trials,
      };
      try {
        final MtgCard printing = await api
            .getCardBySetCodeAndCollectorNumber(
              'ice',
              '13',
              language: Language.english,
            )
            .timeout(const Duration(seconds: 30));
        expect(printing.name, _name);
        expect(printing.set, 'ice');
        expect(printing.collectorNumber, '13');
        final Uri? image = printing.imageUris?.large;
        expect(image, isNotNull);
        final Uri imageUri = image!;
        expect(imageUri.scheme, 'https');
        expect(imageUri.host, 'cards.scryfall.io');
        final http.Response response = await images
            .get(imageUri)
            .timeout(const Duration(seconds: 20));
        expect(response.statusCode, 200);
        expect(response.bodyBytes.length, inInclusiveRange(1, 4 * 1024 * 1024));
        final ui.Codec codec = await ui.instantiateImageCodec(
          response.bodyBytes,
        );
        try {
          reference = (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
        for (final int orientation in <int>[0, 180]) {
          final Map<String, Object> pixels = await _frame(
            reference,
            orientation,
          );
          for (int trial = 0; trial < 2; trial++) {
            final Stopwatch elapsed = Stopwatch()..start();
            final Map<Object?, Object?>? raw = await NativeCardRecognizer
                .channel
                .invokeMethod<Map<Object?, Object?>>(
                  'detectFrame',
                  <String, Object>{
                    ...pixels,
                    'sourceWidth': 960,
                    'sourceHeight': 1280,
                    'rotation': 0,
                    'cameraName':
                        'historical-handheld-fixture-$orientation-$trial',
                    'includeText': true,
                    'includePartialDiagnostics': true,
                  },
                )
                .timeout(const Duration(seconds: 30));
            elapsed.stop();
            expect(raw, isNotNull);
            final LiveScanFrame frame = LiveScanFrame.fromMap(
              raw!,
              orientationToken: 'fixture:$orientation',
            );
            final Map<Object?, Object?> diagnostics =
                Map<Object?, Object?>.from(
                  raw['partialTrackingDiagnostics'] as Map<Object?, Object?>,
                );
            final Object? phases = diagnostics['phaseSeconds'];
            final Map<String, num> finitePhases = <String, num>{
              if (phases is Map<Object?, Object?>)
                for (final MapEntry<Object?, Object?> entry in phases.entries)
                  if (entry.key is String &&
                      entry.value is num &&
                      (entry.value as num).isFinite)
                    entry.key as String: entry.value as num,
            };
            final bool found = frame.cards.any(
              (LiveCardDetection card) => _actualCircle(card, frame),
            );
            trials.add(<String, Object?>{
              'cardRotationDegrees': orientation,
              'frameRotationDegrees': 0,
              'trial': trial,
              'elapsedMilliseconds': elapsed.elapsedMilliseconds,
              'nativeProcessingSeconds': diagnostics['processingSeconds'],
              'phaseSeconds': finitePhases,
              'textCardCount': diagnostics['textCardCount'],
              'orientationRetryCount': diagnostics['orientationRetryCount'],
              'detectedCardCount': frame.cards.length,
              'actualTitleAndTypeRecovered': found,
              'cards': frame.cards.take(8).map(_cardReport).toList(),
            });
            expect(frame.rectanglesSupported, isTrue);
            expect(diagnostics['textCardCount'], greaterThanOrEqualTo(1));
            expect(finitePhases, isNotEmpty);
            if (orientation == 0) {
              expect(diagnostics['orientationRetryCount'], 0);
            }
            expect(
              found,
              isTrue,
              reason:
                  'Actual $_name title and type must be owned by the same $orientation° card; no printed number may be inferred.',
            );
          }
        }
        report['passed'] = true;
      } catch (error) {
        report['passed'] = false;
        final String failure = error.toString();
        report['failure'] = failure.length > 1000
            ? failure.substring(0, 1000)
            : failure;
        rethrow;
      } finally {
        reference?.dispose();
        images.close();
        api.close();
        await File(
          '${Directory.systemTemp.path}/collector_handheld_native_report.json',
        ).writeAsString(jsonEncode(report), flush: true);
      }
    },
  );
  testWidgets(
    'physical rear lenses keep continuous autofocus after a native focus request',
    (WidgetTester tester) async {
      final List<Map<String, Object?>> lenses = <Map<String, Object?>>[];
      final Map<String, Object?> report = <String, Object?>{
        'measuresPhysicalCameraFocus': true,
        'lenses': lenses,
      };
      int testedWideLenses = 0;
      try {
        final List<CameraDescription> cameras =
            (await availableCameras().timeout(const Duration(seconds: 20)))
                .where(
                  (CameraDescription camera) =>
                      camera.lensDirection == CameraLensDirection.back,
                )
                .toList();
        expect(cameras, isNotEmpty);
        for (final CameraDescription camera in cameras) {
          final Map<String, Object?> lens = <String, Object?>{
            'cameraName': camera.name,
            'lensType': camera.lensType.name,
          };
          lenses.add(lens);
          final CameraController controller = CameraController(
            camera,
            ResolutionPreset.max,
            enableAudio: false,
            imageFormatGroup: ImageFormatGroup.bgra8888,
          );
          try {
            await controller.initialize().timeout(const Duration(seconds: 30));
            lens['focusPointSupported'] = controller.value.focusPointSupported;
            if (!controller.value.focusPointSupported) {
              lens['skipped'] = true;
              lens['skipReason'] = 'This lens does not support a focus point.';
              continue;
            }
            final bool? applied = await NativeCardRecognizer.channel
                .invokeMethod<bool>('cameraFocusAtPoint', <String, Object>{
                  'cameraName': camera.name,
                  'previewOrientation': 'portraitUp',
                  'x': .5,
                  'y': .5,
                  'singleShot': false,
                  'adjustExposure': false,
                })
                .timeout(const Duration(seconds: 10));
            lens['applied'] = applied;
            expect(
              applied,
              isTrue,
              reason: 'Native focus request must apply to ${camera.name}.',
            );
            final Map<Object?, Object?>? status = await NativeCardRecognizer
                .channel
                .invokeMethod<Map<Object?, Object?>>(
                  'cameraFocusStatus',
                  <String, String>{'cameraName': camera.name},
                )
                .timeout(const Duration(seconds: 10));
            lens['status'] = status == null
                ? null
                : <String, Object?>{
                    for (final MapEntry<Object?, Object?> entry
                        in status.entries)
                      if (entry.key is String) entry.key as String: entry.value,
                  };
            expect(status, isNotNull);
            expect(
              status!['focusMode'],
              2,
              reason:
                  'Handheld focus must remain continuous on ${camera.name}.',
            );
            final Object? rawPosition = status['lensPosition'];
            expect(rawPosition, isA<num>());
            final double position = (rawPosition as num).toDouble();
            expect(position.isFinite, isTrue);
            expect(position, inInclusiveRange(0, 1));
            lens['passed'] = true;
            if (camera.lensType == CameraLensType.wide) testedWideLenses++;
          } finally {
            await controller.dispose().timeout(const Duration(seconds: 15));
          }
        }
        report['testedWideLenses'] = testedWideLenses;
        expect(
          testedWideLenses,
          greaterThanOrEqualTo(1),
          reason: 'At least one physical wide lens must complete the focus assertions.',
        );
        report['passed'] = true;
      } catch (error) {
        report['passed'] = false;
        final String failure = error.toString();
        report['failure'] = failure.length > 1000
            ? failure.substring(0, 1000)
            : failure;
        rethrow;
      } finally {
        await File(
          '${Directory.systemTemp.path}/collector_handheld_focus_report.json',
        ).writeAsString(jsonEncode(report), flush: true);
      }
    },
    skip: !_physicalCameraQa,
  );
}
