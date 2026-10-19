import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/live_scan_detector.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scryfall_request_scheduler.dart';

const String _title = 'Circle of Protection: Blue';
const String _modernTitle = 'Mirkwood Bats';

String _letters(String value) =>
    value.toLowerCase().replaceAll(RegExp('[^a-z]'), '');

Future<Map<String, Object>> _glareFrame(ui.Image reference, double wash) async {
  const int width = 960;
  const int height = 1280;
  const double cardHeight = 1100;
  final double cardWidth = cardHeight * reference.width / reference.height;
  final ui.Rect card = ui.Rect.fromLTWH(
    (width - cardWidth) / 2,
    (height - cardHeight) / 2,
    cardWidth,
    cardHeight,
  );
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff747474), ui.BlendMode.src);
  canvas.drawImageRect(
    reference,
    ui.Rect.fromLTWH(
      0,
      0,
      reference.width.toDouble(),
      reference.height.toDouble(),
    ),
    card,
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  if (wash > 0) {
    canvas.drawRect(
      ui.Rect.fromLTWH(
        card.left + card.width * .025,
        card.top + card.height * .015,
        card.width * .95,
        card.height * .11,
      ),
      ui.Paint()..color = const ui.Color(0xffffffff).withValues(alpha: wash),
    );
  }
  final ui.Picture picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(width, height);
    final ByteData data = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    final Map<String, Object> pixels =
        NativeLiveCardDetector.boundedFramePixels(
          width: width,
          height: height,
          bytes: data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          ),
          bytesPerRow: width * 4,
          bytesPerPixel: 4,
          bgra: true,
          edge: 960,
        );
    final Uint8List bgra = pixels['bytes'] as Uint8List;
    for (int index = 0; index < bgra.length; index += 4) {
      final int red = bgra[index];
      bgra[index] = bgra[index + 2];
      bgra[index + 2] = red;
    }
    return pixels;
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native text-band lighting measures washed title without inventing clipped text',
    (WidgetTester tester) async {
      final ScryfallApiClient api = ScryfallApiClient(
        httpClient: ScryfallHttpClient(),
      );
      final http.Client images = http.Client();
      final Directory directory = await Directory.systemTemp.createTemp(
        'collector-glare-',
      );
      ui.Image? reference;
      final Map<String, Digest> savedCropHashes = <String, Digest>{};
      final List<Map<String, Object?>> trials = <Map<String, Object?>>[];
      final List<Map<String, Object?>> fixtureCards = <Map<String, Object?>>[];
      final Map<String, Object?> report = <String, Object?>{
        'fixture': 'public historical and modern artwork with deterministic title-only white overlays',
        'measuresPhysicalGlare': false,
        'claimsExactPrinting': false,
        'trials': trials,
        'fixtureCards': fixtureCards,
      };
      try {
        bool anyRecoveryDemonstrated = false;
        for (final bool historic in <bool>[true, false]) {
          final MtgCard card = historic
              ? await api
                    .getCardBySetCodeAndCollectorNumber(
                      'ice',
                      '13',
                      language: Language.english,
                    )
                    .timeout(const Duration(seconds: 30))
              : await api
                    .getCardByName(_modernTitle, set: 'ltr')
                    .timeout(const Duration(seconds: 30));
          final String title = historic ? _title : _modernTitle;
          expect(card.name, title);
          final Uri uri = card.imageUris!.large;
          expect(uri.scheme, 'https');
          expect(uri.host, 'cards.scryfall.io');
          final http.Response response = await images
              .get(uri)
              .timeout(const Duration(seconds: 20));
          expect(response.statusCode, 200);
          expect(
            response.bodyBytes.length,
            inInclusiveRange(1, 4 * 1024 * 1024),
          );
          final File original = await File(
            '${directory.path}/original-${card.id}.jpg',
          ).writeAsBytes(response.bodyBytes, flush: true);
          final Digest before = sha256.convert(await original.readAsBytes());
          final Map<Object?, Object?> saved = (await NativeCardRecognizer
              .channel
              .invokeMethod<Map<Object?, Object?>>(
                'recognize',
                <String, Object>{'path': original.path, 'multipleCards': false},
              )
              .timeout(const Duration(seconds: 30)))!;
          final List<Object?> savedCrops = saved['crops'] as List<Object?>;
          expect(savedCrops, isNotEmpty);
          for (final Object? value in savedCrops) {
            final String path =
                (value as Map<Object?, Object?>)['imagePath'] as String;
            savedCropHashes[path] = sha256.convert(
              await File(path).readAsBytes(),
            );
          }
          final ui.Codec codec = await ui.instantiateImageCodec(
            response.bodyBytes,
          );
          try {
            reference = (await codec.getNextFrame()).image;
          } finally {
            codec.dispose();
          }
          bool recoveryDemonstrated = false;
          for (final double wash in <double>[0, .85, .90, .94, 1]) {
            final Map<String, Object> pixels = await _glareFrame(
              reference,
              wash,
            );
            expect(pixels['width'], 720);
            expect(pixels['height'], 960);
            bool? baselineTitle;
            for (final bool recoveryEnabled in <bool>[false, true]) {
              final Stopwatch timer = Stopwatch()..start();
              final Map<Object?, Object?> raw = (await NativeCardRecognizer
                  .channel
                  .invokeMethod<Map<Object?, Object?>>(
                    'detectFrame',
                    <String, Object>{
                      ...pixels,
                      'sourceWidth': 960,
                      'sourceHeight': 1280,
                      'rotation': 0,
                      'cameraName':
                          'glare-fixture-${card.id}-$wash-$recoveryEnabled',
                      'includeText': true,
                      'includePartialDiagnostics': true,
                      'disableLightingRecovery': !recoveryEnabled,
                    },
                  )
                  .timeout(const Duration(seconds: 30)))!;
              timer.stop();
              final List<Object?> cards = raw['cards'] as List<Object?>;
              final Map<Object?, Object?> diagnostics =
                  raw['partialTrackingDiagnostics'] as Map<Object?, Object?>;
              final List<Map<String, Object?>> lighting =
                  <Map<String, Object?>>[
                    for (final Object? value in cards)
                      if ((value as Map<Object?, Object?>)['lighting']
                          case final Map<Object?, Object?> map)
                        <String, Object?>{
                          for (final MapEntry<Object?, Object?> entry
                              in map.entries)
                            if (entry.key is String)
                              entry.key as String: entry.value,
                        },
                  ];
              final LiveScanFrame frame = LiveScanFrame.fromMap(
                raw,
                orientationToken: 'glare:$wash',
              );
              final bool actualTitle = frame.cards.any(
                (LiveCardDetection crop) => crop.lines.any(
                  (ScanTextLine line) =>
                      line.confidence >= .85 &&
                      line.bounds.y < .10 &&
                      _letters(line.text) == _letters(title),
                ),
              );
              final bool actualType = frame.cards.any(
                (LiveCardDetection crop) => crop.lines.any(
                  (ScanTextLine line) =>
                      line.confidence >= .85 &&
                      line.bounds.y >= .35 &&
                      line.bounds.y <= .70 &&
                      _letters(line.text) == _letters(card.typeLine),
                ),
              );
              trials.add(<String, Object?>{
                'name': card.name,
                'set': card.set,
                'collectorNumber': card.collectorNumber,
                'titleWhiteOverlay': wash,
                'recoveryEnabled': recoveryEnabled,
                'frameWidth': pixels['width'],
                'frameHeight': pixels['height'],
                'elapsedMilliseconds': timer.elapsedMilliseconds,
                'lighting': lighting,
                'actualTitleRecovered': actualTitle,
                'actualTypeRecovered': actualType,
                'enhancedRetryCount': diagnostics['enhancedRetryCount'],
                'enhancedRetrySeconds': diagnostics['enhancedRetrySeconds'],
                'nativeProcessingSeconds': diagnostics['processingSeconds'],
                'phaseSeconds': diagnostics['phaseSeconds'],
                'cards': cards,
              });
              if (!recoveryEnabled) baselineTitle = actualTitle;
              if (recoveryEnabled &&
                  wash > 0 &&
                  wash < 1 &&
                  baselineTitle == false &&
                  actualTitle &&
                  (diagnostics['enhancedRetryCount'] as num) > 0) {
                recoveryDemonstrated = true;
              }
              expect(lighting, isNotEmpty);
              expect(actualType, isTrue);
              expect(
                diagnostics['enhancedRetryCount'],
                lessThanOrEqualTo(2),
                reason: 'At most one lighting ROI retry per corrected card, with two text cards per frame.',
              );
              if (wash == 0) {
                expect(actualTitle, isTrue);
                expect(diagnostics['enhancedRetryCount'], 0);
              } else {
                final List<Map<Object?, Object?>> titleBands =
                    <Map<Object?, Object?>>[
                      for (final Object? value in cards)
                        if ((value as Map<Object?, Object?>)['lightingBands']
                            case final Map<Object?, Object?> bands)
                          if (bands['title']
                              case final Map<Object?, Object?> title)
                            title,
                    ];
                expect(
                  titleBands.any(
                    (Map<Object?, Object?> value) =>
                        value['meanLuminance'] is num &&
                        value['contrast'] is num &&
                        (value['meanLuminance'] as num) >= .78 &&
                        (value['contrast'] as num) <= .20,
                  ),
                  isTrue,
                );
              }
              if (wash == 1) {
                expect(
                  actualTitle,
                  isFalse,
                  reason: 'A fully erased title contains no recoverable letter pixels.',
                );
                expect(diagnostics['enhancedRetryCount'], 0);
              }
            }
          }
          fixtureCards.add(<String, Object?>{
            'name': card.name,
            'set': card.set,
            'collectorNumber': card.collectorNumber,
            'matchedOcrRecoveryDemonstrated': recoveryDemonstrated,
          });
          anyRecoveryDemonstrated =
              anyRecoveryDemonstrated || recoveryDemonstrated;
          expect(sha256.convert(await original.readAsBytes()), before);
          reference.dispose();
          reference = null;
        }
        report['matchedOcrRecoveryDemonstrated'] = anyRecoveryDemonstrated;
        expect(
          anyRecoveryDemonstrated,
          isTrue,
          reason: 'At least one matched reversible washed title must be unread without recovery and literally recovered with it.',
        );
        for (final MapEntry<String, Digest> crop in savedCropHashes.entries) {
          expect(
            sha256.convert(await File(crop.key).readAsBytes()),
            crop.value,
          );
        }
        report['originalBytesPreserved'] = true;
        report['savedCropBytesPreserved'] = true;
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
        for (final String path in savedCropHashes.keys) {
          final File crop = File(path);
          if (await crop.exists()) await crop.delete();
        }
        await directory.delete(recursive: true);
        await File(
          '${Directory.systemTemp.path}/collector_glare_native_report.json',
        ).writeAsString(jsonEncode(report), flush: true);
      }
    },
  );
}
