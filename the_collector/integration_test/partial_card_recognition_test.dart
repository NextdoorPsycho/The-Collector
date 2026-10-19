import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:the_collector/utils/scanning/live_scan_detector.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

String _normalized(String text) =>
    text.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

bool _sameObservedRegion(List<ScanPoint> first, List<ScanPoint> second) {
  if (first.length != 4 || second.length != 4) {
    return false;
  }
  for (int point = 0; point < 4; point++) {
    if (!first[point].x.isFinite ||
        !first[point].y.isFinite ||
        !second[point].x.isFinite ||
        !second[point].y.isFinite ||
        (first[point].x - second[point].x).abs() > .03 ||
        (first[point].y - second[point].y).abs() > .03) {
      return false;
    }
  }
  return true;
}

Map<String, Object?> _cropReport(ScanCrop crop) {
  final ScanHints hints = ScanHints.fromCrop(crop);
  return <String, Object?>{
    'imagePath': crop.imagePath,
    'width': crop.width,
    'height': crop.height,
    'rectified': crop.rectified,
    'warnings': crop.warnings,
    'names': hints.names,
    'typeLine': hints.typeLine,
    'rulesText': hints.rulesText,
    'sourceCorners': crop.sourceCorners
        .map((ScanPoint point) => <String, double>{'x': point.x, 'y': point.y})
        .toList(),
    'lines': crop.lines
        .map(
          (ScanTextLine line) => <String, Object?>{
            'text': line.text,
            'glyphHeight': line.glyphHeight,
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
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const bool enabled = bool.fromEnvironment('PARTIAL_CARD_QA');
  const bool bodyEnabled = bool.fromEnvironment('BODY_ORIENTATION_QA');
  const bool diagnosticsEnabled = bool.fromEnvironment('PARTIAL_DIAGNOSTIC_QA');
  const bool physical4Enabled = bool.fromEnvironment('PHYSICAL4_CIRCLE_QA');
  const bool physical5Enabled = bool.fromEnvironment('PHYSICAL5_CIRCLE_QA');
  testWidgets(
    'physical originals recover a verified Circle body or observed title',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        final Directory directory = Directory(
          '${Directory.systemTemp.path}/collector_partial_qa',
        );
        final Set<String> ownedPaths = <String>{};
        final List<Map<String, Object?>> runs = <Map<String, Object?>>[];
        final String sourcePrefix = physical5Enabled
            ? 'physical5'
            : 'physical4';
        final int sourceCount = physical5Enabled ? 4 : 2;
        final Map<String, Object?> report = <String, Object?>{
          'scope': '$sourcePrefix Circle originals; native OCR only',
          'requiredSupportedPhotos': physical5Enabled ? 1 : 2,
          'passed': false,
          'runs': runs,
        };
        bool cleaning = false;
        final List<bool> supported = <bool>[];
        await directory.create(recursive: true);
        try {
          for (int index = 0; index < sourceCount; index++) {
            final File input = File(
              '${directory.path}/$sourcePrefix-circle$index.jpg',
            );
            final Map<String, Object?> run = <String, Object?>{
              'input': input.path,
              'supported': false,
            };
            runs.add(run);
            final Stopwatch elapsed = Stopwatch()..start();
            try {
              expect(await input.exists(), isTrue);
              final String digest = sha256
                  .convert(await input.readAsBytes())
                  .toString();
              run['originalDigest'] = digest;
              final ScanRecognition result = await NativeCardRecognizer.channel
                  .invokeMethod<Map<Object?, Object?>>(
                    'recognize',
                    <String, Object>{
                      'path': input.path,
                      'multipleCards': true,
                      'includePartialDiagnostics': true,
                    },
                  )
                  .then((Map<Object?, Object?>? raw) async {
                    expect(raw, isNotNull);
                    final Map<Object?, Object?> response = raw!;
                    run['orientationDiagnostics'] =
                        response['orientationDiagnostics'];
                    run['partialDiagnostics'] = response['partialDiagnostics'];
                    final ScanRecognition value = ScanRecognition.fromMap(
                      response,
                    );
                    for (final ScanCrop crop in value.crops) {
                      ownedPaths.add(crop.imagePath);
                      if (cleaning && await File(crop.imagePath).exists()) {
                        await File(crop.imagePath).delete();
                      }
                    }
                    return value;
                  })
                  .timeout(const Duration(seconds: 120));
              run['crops'] = result.crops
                  .map((ScanCrop crop) {
                    final ScanHints hints = ScanHints.fromCrop(crop);
                    final String rules = hints.rulesText
                        .join(' ')
                        .toLowerCase();
                    final bool body =
                        hasVerifiedSavedBodyLayout(crop) &&
                        hints.typeLine == 'enchantment' &&
                        rules.contains('damage') &&
                        (rules.contains('prevent') || rules.contains('source'));
                    final bool title =
                        hints.names.any(
                          (String name) =>
                              _normalized(name) == 'circleofprotectionblue',
                        ) &&
                        hints.typeLine == 'enchantment' &&
                        hints.rulesText.length >= 2;
                    if (body || title) run['supported'] = true;
                    return <String, Object?>{
                      ..._cropReport(crop),
                      'hasVerifiedSavedBodyLayout': hasVerifiedSavedBodyLayout(
                        crop,
                      ),
                      'supportedCircleBody': body,
                      'supportedCircleTitle': title,
                      'sharpness': crop.sharpness,
                      'reliableHorizontalLines': crop.lines
                          .where(
                            (ScanTextLine line) =>
                                line.confidence >= .85 &&
                                line.bounds.width > line.bounds.height &&
                                line.bounds.height > 0 &&
                                line.bounds.height < .1 &&
                                line.textHeight > 0 &&
                                line.textHeight < .07,
                          )
                          .length,
                    };
                  })
                  .toList(growable: false);
              expect(result.crops.length, lessThanOrEqualTo(8));
              expect(
                sha256.convert(await input.readAsBytes()).toString(),
                digest,
              );
              run['originalPreserved'] = true;
            } catch (error) {
              run['error'] = error.toString();
            } finally {
              elapsed.stop();
              run['milliseconds'] = elapsed.elapsedMilliseconds;
              supported.add(run['supported'] == true && run['error'] == null);
            }
          }
          report['passed'] =
              supported.length == sourceCount &&
              (physical5Enabled
                  ? supported.any((bool value) => value)
                  : supported.every((bool value) => value));
          expect(
            report['passed'],
            isTrue,
            reason: physical5Enabled
                ? 'The actual focus stack needs at least one verified Circle photo.'
                : 'Both actual Circle photos need independent native evidence.',
          );
        } finally {
          try {
            await File('${directory.path}/$sourcePrefix-circle-report.json')
                .writeAsString(
                  const JsonEncoder.withIndent('  ').convert(report),
                  flush: true,
                );
            final String marker = physical5Enabled
                ? 'PHYSICAL5_CIRCLE_QA'
                : 'PHYSICAL4_CIRCLE_QA';
            debugPrint('${marker}_REPORT ${jsonEncode(report)}');
            debugPrint('${marker}_EXPORT ${directory.path}');
            await Future<void>.delayed(const Duration(seconds: 20));
          } finally {
            cleaning = true;
            for (final String path in ownedPaths) {
              if (await File(path).exists()) await File(path).delete();
            }
          }
        }
      });
    },
    skip:
        (!physical4Enabled && !physical5Enabled) ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.iOS,
    timeout: const Timeout(Duration(minutes: 10)),
  );
  testWidgets(
    'local image reports native partial-anchor evidence without changing recognition',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        final Directory directory = Directory(
          '${Directory.systemTemp.path}/collector_partial_qa',
        );
        await directory.create(recursive: true);
        final File input = File('${directory.path}/diagnostic.jpg');
        final File reportFile = File(
          '${directory.path}/diagnostic-report.json',
        );
        final Set<String> ownedPaths = <String>{};
        bool cleaning = false;
        Map<Object?, Object?>? report;
        try {
          expect(await input.exists(), isTrue);
          final String digest = sha256
              .convert(await input.readAsBytes())
              .toString();
          report = await NativeCardRecognizer.channel
              .invokeMethod<Map<Object?, Object?>>(
                'recognize',
                <String, Object>{
                  'path': input.path,
                  'multipleCards': true,
                  'includePartialDiagnostics': true,
                },
              )
              .then((Map<Object?, Object?>? value) async {
                if (value != null) {
                  for (final ScanCrop crop in ScanRecognition.fromMap(
                    value,
                  ).crops) {
                    ownedPaths.add(crop.imagePath);
                    if (cleaning && await File(crop.imagePath).exists()) {
                      await File(crop.imagePath).delete();
                    }
                  }
                }
                return value;
              })
              .timeout(const Duration(seconds: 120));
          expect(report, isNotNull);
          expect(report!['partialDiagnostics'], isA<Map<Object?, Object?>>());
          expect(sha256.convert(await input.readAsBytes()).toString(), digest);
          const String expectedName = String.fromEnvironment(
            'PARTIAL_DIAGNOSTIC_EXPECT_NAME',
          );
          if (const bool.fromEnvironment('PARTIAL_LIVE_DIAGNOSTIC_QA')) {
            final ui.Codec codec = await ui.instantiateImageCodec(
              await input.readAsBytes(),
              targetHeight: 1920,
            );
            final ui.Image image = (await codec.getNextFrame()).image;
            final Uint8List pixels;
            final int width = image.width;
            final int height = image.height;
            try {
              expect(height, 1920);
              expect(width, lessThanOrEqualTo(1920));
              final ByteData rgba = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              final Uint8List source = rgba.buffer.asUint8List(
                rgba.offsetInBytes,
                rgba.lengthInBytes,
              );
              pixels = Uint8List(source.length);
              for (int offset = 0; offset < source.length; offset += 4) {
                pixels[offset] = source[offset + 2];
                pixels[offset + 1] = source[offset + 1];
                pixels[offset + 2] = source[offset];
                pixels[offset + 3] = source[offset + 3];
              }
            } finally {
              image.dispose();
              codec.dispose();
            }
            report['liveFrameSize'] = <String, int>{
              'width': width,
              'height': height,
            };
            final List<Map<Object?, Object?>> liveFrames =
                <Map<Object?, Object?>>[];
            report['liveFrames'] = liveFrames;
            bool supportedLive = false;
            bool trackedLiveGeometry = false;
            bool rejectedLiveGeometry = false;
            final List<List<ScanPoint>> observedPartialRegions =
                <List<ScanPoint>>[];
            for (int frame = 0; frame < 4; frame++) {
              final Map<Object?, Object?>? response = await NativeCardRecognizer
                  .channel
                  .invokeMethod<Map<Object?, Object?>>(
                    'detectFrame',
                    <String, Object>{
                      'bytes': pixels,
                      'format': 'bgra8888',
                      'width': width,
                      'height': height,
                      'bytesPerRow': width * 4,
                      'sourceWidth': width,
                      'sourceHeight': height,
                      'rotation': 0,
                      'cameraName': 'owned-live-${digest.substring(0, 12)}',
                      'includeText': true,
                      'includePartialDiagnostics': true,
                    },
                  )
                  .timeout(const Duration(seconds: 60));
              expect(response, isNotNull);
              liveFrames.add(response!);
              final LiveScanFrame observed = LiveScanFrame.fromMap(
                response,
                orientationToken: 'owned-photo:portraitUp',
              );
              trackedLiveGeometry =
                  trackedLiveGeometry ||
                  observed.focusCandidates.any((LiveCardDetection candidate) {
                    if (!candidate.warnings.contains('tracked_partial') ||
                        !candidate.warnings.contains('geometry_only') ||
                        candidate.lines.isNotEmpty ||
                        candidate.confidence < .85 ||
                        candidate.corners.length != 4) {
                      return false;
                    }
                    return observedPartialRegions.any((List<ScanPoint> region) {
                      return _sameObservedRegion(region, candidate.corners);
                    });
                  });
              final Object? diagnostics =
                  response['partialTrackingDiagnostics'];
              if (diagnostics is Map<Object?, Object?>) {
                final Object? tracking = diagnostics['tracking'];
                if (tracking is Map<Object?, Object?>) {
                  final Object? evidence = tracking['observations'];
                  if (evidence is List<Object?>) {
                    for (final Object? value in evidence) {
                      if (value is! Map<Object?, Object?> ||
                          value['rejected'] != 'confidence') {
                        continue;
                      }
                      final Object? confidence = value['confidence'];
                      final Object? rawSeed = value['seed'];
                      final Object? rawCurrent = value['current'];
                      if (confidence is! num ||
                          !confidence.isFinite ||
                          confidence < 0 ||
                          confidence >= .85 ||
                          rawSeed is! List<Object?> ||
                          rawCurrent is! List<Object?>) {
                        continue;
                      }
                      final List<ScanPoint> seed = rawSeed
                          .map(
                            (Object? point) => ScanPoint.fromMap(
                              point as Map<Object?, Object?>,
                            ),
                          )
                          .toList();
                      final List<ScanPoint> current = rawCurrent
                          .map(
                            (Object? point) => ScanPoint.fromMap(
                              point as Map<Object?, Object?>,
                            ),
                          )
                          .toList();
                      if (!_sameObservedRegion(current, current) ||
                          !observedPartialRegions.any(
                            (List<ScanPoint> region) =>
                                _sameObservedRegion(region, seed),
                          )) {
                        continue;
                      }
                      expect(
                        observed.focusCandidates.any(
                          (LiveCardDetection candidate) =>
                              candidate.warnings.contains('tracked_partial') &&
                              (_sameObservedRegion(candidate.corners, seed) ||
                                  _sameObservedRegion(
                                    candidate.corners,
                                    current,
                                  )),
                        ),
                        isFalse,
                        reason: 'a rejected low-confidence tracker must not emit focus geometry',
                      );
                      expect(
                        observed.cards.any(
                          (LiveCardDetection card) =>
                              card.warnings.contains('partial_card') &&
                              card.lines.isEmpty &&
                              (_sameObservedRegion(card.corners, seed) ||
                                  _sameObservedRegion(card.corners, current)),
                        ),
                        isFalse,
                        reason: 'a rejected tracker must not retain an unverified partial geometry card',
                      );
                      rejectedLiveGeometry = true;
                    }
                  }
                }
              }
              supportedLive =
                  supportedLive ||
                  observed.cards.any((LiveCardDetection card) {
                    final ScanHints hints = ScanHints.fromCrop(
                      ScanCrop(
                        imagePath: '',
                        width: 1000,
                        height: 1400,
                        rectified: !card.warnings.contains('partial_card'),
                        sourceCorners: card.corners,
                        lines: card.lines,
                        warnings: card.warnings,
                      ),
                    );
                    final bool supported =
                        (expectedName.isEmpty ||
                            hints.names.any(
                              (String name) =>
                                  _normalized(name) ==
                                  _normalized(expectedName),
                            )) &&
                        hints.typeLine != null &&
                        hints.rulesText.length >= 2;
                    if (supported &&
                        card.warnings.contains('partial_card') &&
                        card.corners.length == 4) {
                      observedPartialRegions.add(card.corners);
                    }
                    return supported;
                  });
              if (frame < 3) {
                await Future<void>.delayed(const Duration(milliseconds: 750));
              }
            }
            report['supportedLive'] = supportedLive;
            report['trackedLiveGeometry'] = trackedLiveGeometry;
            report['rejectedLiveGeometry'] = rejectedLiveGeometry;
            if (expectedName.isNotEmpty) {
              expect(
                supportedLive,
                isTrue,
                reason: '1920-edge live OCR must observe the fixture title, type, and two rules rows',
              );
              expect(
                trackedLiveGeometry || rejectedLiveGeometry,
                isTrue,
                reason: 'an observed partial needs verified tracked geometry or an explicit safe confidence rejection',
              );
            }
            if (const bool.fromEnvironment(
              'PARTIAL_DIAGNOSTIC_EXPECT_TRACKED',
            )) {
              expect(
                trackedLiveGeometry,
                isTrue,
                reason: 'this fixture explicitly requires high-confidence tracked geometry',
              );
            }
          }
          if (expectedName.isNotEmpty) {
            expect(
              ScanRecognition.fromMap(report).crops.any((ScanCrop crop) {
                final ScanHints hints = ScanHints.fromCrop(crop);
                return hints.names.any(
                      (String name) =>
                          _normalized(name) == _normalized(expectedName),
                    ) &&
                    hints.typeLine != null &&
                    hints.rulesText.length >= 2;
              }),
              isTrue,
              reason:
                  'the owned fixture needs a supported title, type, and body',
            );
          }
        } finally {
          try {
            await reportFile.writeAsString(
              const JsonEncoder.withIndent('  ').convert(report),
              flush: true,
            );
            debugPrint('PARTIAL_DIAGNOSTIC_QA_EXPORT ${directory.path}');
            await Future<void>.delayed(const Duration(seconds: 20));
          } finally {
            cleaning = true;
            for (final String path in ownedPaths) {
              if (await File(path).exists()) await File(path).delete();
            }
          }
        }
      });
    },
    skip:
        !diagnosticsEnabled ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.iOS,
    timeout: const Timeout(Duration(minutes: 4)),
  );
  testWidgets(
    'foreshortened physical card retains upright rules when its title is blurred',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        final Directory directory = Directory(
          '${Directory.systemTemp.path}/collector_partial_qa',
        );
        final NativeCardRecognizer recognizer = NativeCardRecognizer();
        final Set<String> ownedPaths = <String>{};
        bool cleaning = false;
        Future<ScanRecognition> recognize(String name) => recognizer
            .recognize('${directory.path}/$name', multipleCards: true)
            .then((ScanRecognition result) async {
              for (final ScanCrop crop in result.crops) {
                ownedPaths.add(crop.imagePath);
                if (cleaning && await File(crop.imagePath).exists()) {
                  await File(crop.imagePath).delete();
                }
              }
              return result;
            })
            .timeout(const Duration(seconds: 120));
        final Map<String, Object?> report = <String, Object?>{};
        await directory.create(recursive: true);
        try {
          final ScanRecognition result = await recognize('body.jpg');
          report['crops'] = result.crops.map(_cropReport).toList();
          expect(result.crops.length, lessThanOrEqualTo(8));
          final List<ScanCrop> bodies = result.crops.where((ScanCrop crop) {
            final ScanHints hints = ScanHints.fromCrop(crop);
            return hints.typeLine == 'creature' &&
                hints.rulesText.contains('sacrifice') &&
                hints.rulesText.contains('opponent');
          }).toList();
          expect(bodies, hasLength(1));
          expect(bodies.single.warnings, isNotEmpty);
          for (final ScanTextLine line in bodies.single.lines.where(
            (ScanTextLine line) =>
                line.text.contains('sacrifice') ||
                line.text.contains('opponent'),
          )) {
            expect(line.bounds.height, lessThan(.10));
            expect(line.bounds.width, greaterThan(.20));
          }
          final ScanRecognition desk = await recognize('desk.png');
          report['deskCrops'] = desk.crops.map(_cropReport).toList();
          expect(
            desk.crops.any((ScanCrop crop) {
              final ScanHints hints = ScanHints.fromCrop(crop);
              return hints.typeLine != null && hints.rulesText.isNotEmpty;
            }),
            isFalse,
          );
          report['passed'] = true;
        } finally {
          try {
            await File('${directory.path}/body-report.json').writeAsString(
              const JsonEncoder.withIndent('  ').convert(report),
              flush: true,
            );
          } finally {
            cleaning = true;
            for (final String path in ownedPaths) {
              if (await File(path).exists()) await File(path).delete();
            }
          }
        }
      });
    },
    skip: !bodyEnabled || kIsWeb || defaultTargetPlatform != TargetPlatform.iOS,
    timeout: const Timeout(Duration(minutes: 5)),
  );
  testWidgets(
    'saved physical scene recovers a review-only partial and rejects desk text',
    (WidgetTester tester) async {
      final Directory directory = Directory(
        '${Directory.systemTemp.path}/collector_partial_qa',
      );
      final File scene = File('${directory.path}/scene.jpg');
      final File desk = File('${directory.path}/desk.png');
      final File reportFile = File('${directory.path}/report.json');
      final NativeCardRecognizer recognizer = NativeCardRecognizer();
      final Set<String> cropPaths = <String>{};
      final Set<String> observedPaths = <String>{};
      bool cleaning = false;
      Future<ScanRecognition> recognize(File input) => recognizer
          .recognize(input.path, multipleCards: true)
          .then((ScanRecognition result) async {
            cropPaths.addAll(
              result.crops.map((ScanCrop crop) => crop.imagePath),
            );
            if (cleaning) {
              for (final ScanCrop crop in result.crops) {
                final File file = File(crop.imagePath);
                if (await file.exists()) await file.delete();
              }
            }
            return result;
          })
          .timeout(const Duration(seconds: 120));
      final Map<String, Object?> report = <String, Object?>{
        'scene': scene.path,
        'desk': desk.path,
        'runs': <Object?>[],
      };
      await tester.runAsync(() async {
        await directory.create(recursive: true);
        try {
          expect(
            await scene.exists(),
            isTrue,
            reason: 'Supply scene.jpg locally.',
          );
          expect(
            await desk.exists(),
            isTrue,
            reason: 'Supply desk.png locally.',
          );
          final String sceneDigest = sha256
              .convert(await scene.readAsBytes())
              .toString();
          final String deskDigest = sha256
              .convert(await desk.readAsBytes())
              .toString();
          for (int index = 0; index < 2; index++) {
            final Stopwatch elapsed = Stopwatch()..start();
            final ScanRecognition result = await recognize(scene);
            elapsed.stop();
            (report['runs']! as List<Object?>).add(<String, Object?>{
              'milliseconds': elapsed.elapsedMilliseconds,
              'crops': result.crops.map(_cropReport).toList(),
            });
            for (final ScanCrop crop in result.crops) {
              expect(observedPaths.add(crop.imagePath), isTrue);
            }
            expect(result.imagePath, scene.path);
            expect(result.crops.length, lessThanOrEqualTo(8));
            final List<ScanCrop> partials = result.crops
                .where(
                  (ScanCrop crop) => crop.warnings.contains('partial_card'),
                )
                .toList();
            expect(partials.length, lessThanOrEqualTo(3));
            final List<ScanCrop> nevermore = result.crops.where((
              ScanCrop crop,
            ) {
              return ScanHints.fromCrop(crop).names
                  .any((String name) => _normalized(name) == 'nevermore');
            }).toList();
            final List<ScanCrop> circle = result.crops.where((ScanCrop crop) {
              return ScanHints.fromCrop(crop).names.any((String name) {
                final String normalized = _normalized(name);
                return normalized.contains('circleofprotection') &&
                    normalized.contains('blue');
              });
            }).toList();
            expect(circle, hasLength(1), reason: 'Preserve the complete card.');
            expect(
              nevermore,
              hasLength(1),
              reason: 'Recover without duplicates.',
            );
            expect(nevermore.single.rectified, isFalse);
            expect(
              nevermore.single.warnings,
              containsAll(<String>[
                'partial_card',
                'incomplete_card',
                'no_card_rectangle',
              ]),
            );
            final ScanHints hints = ScanHints.fromCrop(nevermore.single);
            expect(hints.typeLine, 'enchantment');
            expect(hints.rulesText, isNotEmpty);
            expect(hints.setCode, isNull);
            expect(hints.language, isNull);
            for (final ScanCrop crop in result.crops) {
              expect(await File(crop.imagePath).exists(), isTrue);
              expect(crop.sourceCorners, hasLength(4));
              for (final ScanPoint point in crop.sourceCorners) {
                expect(point.x, inInclusiveRange(0, 1));
                expect(point.y, inInclusiveRange(0, 1));
              }
              if (crop.warnings.contains('partial_card')) {
                expect(crop.rectified, isFalse);
                expect(crop.warnings, contains('incomplete_card'));
              }
            }
          }
          final ScanRecognition negative = await recognize(desk);
          report['deskCrops'] = negative.crops.map(_cropReport).toList();
          for (final ScanCrop crop in negative.crops) {
            expect(crop.warnings, isNot(contains('partial_card')));
          }
          expect(
            sha256.convert(await scene.readAsBytes()).toString(),
            sceneDigest,
          );
          expect(
            sha256.convert(await desk.readAsBytes()).toString(),
            deskDigest,
          );
          report['originalsPreserved'] = true;
          report['passed'] = true;
        } finally {
          await reportFile.writeAsString(
            const JsonEncoder.withIndent('  ').convert(report),
            flush: true,
          );
          debugPrint('PARTIAL_CARD_QA_EXPORT ${directory.path}');
          await Future<void>.delayed(const Duration(seconds: 20));
          cleaning = true;
          for (final String path in cropPaths) {
            final File crop = File(path);
            if (await crop.exists()) await crop.delete();
          }
          if (await reportFile.exists()) await reportFile.delete();
        }
      });
    },
    skip: !enabled || kIsWeb || defaultTargetPlatform != TargetPlatform.iOS,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
