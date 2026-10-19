import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:arcane/arcane.dart' as arcane;
import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/pages/scanning/guided_camera_screen.dart';
import 'package:the_collector/pages/scanning/live_capture_overlay.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/scanning/live_scan_tracker.dart';
import 'package:the_collector/utils/scanning/scan_artwork_matcher.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_symbol_matcher.dart';

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String operation, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(
    ready(),
    isTrue,
    reason: '$operation exceeded ${timeout.inSeconds} seconds',
  );
}

bool _shutterReady(WidgetTester tester) {
  final Finder preview = find.byType(CameraPreview);
  final Finder shutter = find.ancestor(
    of: find.text('Capture photo'),
    matching: find.byType(arcane.PrimaryButton),
  );
  return preview.evaluate().length == 1 &&
      shutter.evaluate().length == 1 &&
      tester
          .widget<CameraPreview>(preview)
          .controller
          .value
          .isStreamingImages &&
      tester.widget<arcane.PrimaryButton>(shutter).onPressed != null;
}

Map<String, Object?> _hints(ScanHints hints) => <String, Object?>{
  'names': hints.names,
  'body': hints.rulesText,
  'typeLine': hints.typeLine,
  'set': hints.setCode,
  'collectorNumber': hints.collectorNumber,
  'language': hints.language,
};

Map<String, Object?> _resolution(ScanResolution resolution) =>
    <String, Object?>{
      'status': resolution.status.name,
      'hints': _hints(resolution.hints),
      'hasMore': resolution.hasMore,
      'candidates': resolution.candidates.map((ScanCandidate candidate) {
        return <String, Object?>{
          'id': candidate.card.id,
          'name': candidate.card.name,
          'set': candidate.card.set,
          'collectorNumber': candidate.card.collectorNumber,
          'language': candidate.card.lang.json,
          'score': candidate.score,
          'evidence': candidate.evidence
              .map((ScanEvidence evidence) => evidence.name)
              .toList(),
          'artworkDistance': candidate.artworkDistance,
          'symbolDistance': candidate.symbolDistance,
          'hasContradiction': candidate.hasContradiction,
        };
      }).toList(),
    };

Map<String, Object?> _crop(ScanCrop crop) => <String, Object?>{
  'width': crop.width,
  'height': crop.height,
  'rectified': crop.rectified,
  'warnings': crop.warnings,
  'corners': crop.sourceCorners
      .map((ScanPoint point) => <String, double>{'x': point.x, 'y': point.y})
      .toList(),
  'hints': _hints(ScanHints.fromCrop(crop)),
  'lines': crop.lines
      .map(
        (ScanTextLine line) => <String, Object?>{
          'text': line.text,
          'confidence': line.confidence,
          'alternatives': line.alternatives,
          'glyphHeight': line.glyphHeight,
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

Map<String, Object?> _overlay(WidgetTester tester) {
  final LiveCaptureOverlay overlay = tester.widget<LiveCaptureOverlay>(
    find.byType(LiveCaptureOverlay),
  );
  return <String, Object?>{
    'captured': overlay.tracks
        .where((LiveScanTrack track) => track.captured)
        .map((LiveScanTrack track) => track.id)
        .toList(),
    'tracks': overlay.tracks
        .map(
          (LiveScanTrack track) => <String, Object?>{
            'id': track.id,
            'confidence': track.confidence,
            'stableFrames': track.stableFrames,
            'crop': _crop(track.crop),
            'resolution': track.resolution == null
                ? null
                : _resolution(track.resolution!),
            'error': track.error,
          },
        )
        .toList(),
  };
}

Future<Map<String, Object?>> _photoEvidence(
  ScanDraftPhoto photo,
  Directory directory,
) async {
  final List<int> bytes = await File(photo.imagePath).readAsBytes();
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
    Uint8List.fromList(bytes),
  );
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return <String, Object?>{
      'id': photo.id,
      'path': photo.imagePath.substring(directory.path.length + 1),
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'width': descriptor.width,
      'height': descriptor.height,
      'jpeg': bytes.length > 2 && bytes[0] == 0xff && bytes[1] == 0xd8,
    };
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const bool enabled = bool.fromEnvironment('PHYSICAL_CARD_QA');

  testWidgets(
    'physical multi-card burst retains three original photos and exports evidence',
    (WidgetTester tester) async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'collector_physical_capture_',
      );
      final Directory hiveDirectory = Directory('${directory.path}/hive');
      await hiveDirectory.create();
      Hive.init(hiveDirectory.path);
      const String userId = 'isolated-physical-capture-fixture';
      ScanDraftStore store = ScanDraftStore(userId: userId);
      final List<ScanDraftPhoto> photos = <ScanDraftPhoto>[];
      final Set<String> cameraPaths = <String>{};
      final Set<String> cropPaths = <String>{};
      final List<http.Client> clients = <http.Client>[];
      final List<Future<void>> imports = <Future<void>>[];
      final Map<String, Object?> report = <String, Object?>{
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'scope': 'Physical camera, isolated local drafts, public card lookup; no account writes',
        'captures': <Map<String, Object?>>[],
        'recognition': <Map<String, Object?>>[],
      };
      final List<Map<String, Object?>> captures =
          report['captures']! as List<Map<String, Object?>>;
      final List<Map<String, Object?>> recognitionRecords =
          report['recognition']! as List<Map<String, Object?>>;
      Object? admissionError;
      bool cleaning = false;
      bool networkDisposed = false;
      ScryfallScanCatalog? catalog;
      http.Client clientFactory() {
        final http.Client client = http.Client();
        if (networkDisposed) {
          client.close();
          return client;
        }
        clients.add(client);
        return client;
      }

      try {
        await tester.pumpWidget(
          arcane.ArcaneApp(
            theme: MyThemeData.themeData(arcane.ThemeMode.dark),
            home: GuidedCameraScreen(
              automaticCapture: false,
              multipleCards: true,
              onCaptured:
                  (String path, List<List<ScanPoint>> excludedRegions) async {
                    cameraPaths.add(path);
                    final Stopwatch timer = Stopwatch()..start();
                    final Completer<void> completed = Completer<void>();
                    imports.add(completed.future);
                    try {
                      final String sourceHash = sha256
                          .convert(await File(path).readAsBytes())
                          .toString();
                      final List<ScanDraftPhoto> admitted = await store
                          .importPhotos(
                            <String>[path],
                            multipleCards: true,
                            ownedCameraSource: true,
                          );
                      photos.addAll(admitted);
                      captures.add(<String, Object?>{
                        'admitted': admitted.length,
                        'photoId': admitted.single.id,
                        'cameraSourceSha256': sourceHash,
                        'durableHandoffMs': timer.elapsedMilliseconds,
                      });
                      return true;
                    } catch (error) {
                      admissionError = error;
                      return false;
                    } finally {
                      completed.complete();
                    }
                  },
            ),
          ),
        );
        await _waitFor(
          tester,
          () => _shutterReady(tester),
          'Initial camera preview',
        );
        expect(find.byType(LiveCaptureOverlay), findsOneWidget);
        expect(find.text('Capture photo').hitTestable(), findsOneWidget);
        final CameraController controller = tester
            .widget<CameraPreview>(find.byType(CameraPreview))
            .controller;
        report['camera'] = <String, Object?>{
          'name': controller.description.name,
          'lens': controller.description.lensDirection.name,
          'lensType': controller.description.lensType.name,
          'resolutionPreset': controller.resolutionPreset.name,
          'focusPointSupported': controller.value.focusPointSupported,
          'exposurePointSupported': controller.value.exposurePointSupported,
          'zoomMin': await controller.getMinZoomLevel(),
          'zoomMax': await controller.getMaxZoomLevel(),
          'exposureMin': await controller.getMinExposureOffset(),
          'exposureMax': await controller.getMaxExposureOffset(),
        };
        expect(controller.resolutionPreset, ResolutionPreset.max);
        final Stopwatch sceneTimer = Stopwatch()..start();
        try {
          await _waitFor(
            tester,
            () {
              report['lastObservedOverlay'] = _overlay(tester);
              final LiveCaptureOverlay overlay = tester
                  .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay));
              return overlay.tracks.any((LiveScanTrack track) {
                final ScanHints hints = ScanHints.fromCrop(track.crop);
                return track.stableFrames >= 2 &&
                    (hints.names.isNotEmpty ||
                        (hints.setCode != null &&
                            hints.collectorNumber != null));
              });
            },
            'No stable readable physical card was visible; keep cards within the camera preview with title or set and collector number readable',
            timeout: const Duration(seconds: 120),
          );
          report['readableSceneWaitMs'] = sceneTimer.elapsedMilliseconds;
          report['readableSceneConfirmed'] = true;
          final LiveCaptureOverlay overlay = tester.widget<LiveCaptureOverlay>(
            find.byType(LiveCaptureOverlay),
          );
          final LiveScanTrack readable = overlay.tracks.firstWhere((
            LiveScanTrack track,
          ) {
            final ScanHints hints = ScanHints.fromCrop(track.crop);
            return track.stableFrames >= 2 &&
                (hints.names.isNotEmpty ||
                    (hints.setCode != null && hints.collectorNumber != null));
          });
          final ui.Offset focus = ui.Offset(
            readable.corners
                    .map((ScanPoint point) => point.x)
                    .reduce((double a, double b) => a + b) /
                readable.corners.length,
            readable.corners
                    .map((ScanPoint point) => point.y)
                    .reduce((double a, double b) => a + b) /
                readable.corners.length,
          );
          await controller.setFocusMode(FocusMode.auto);
          if (controller.value.focusPointSupported) {
            await controller.setFocusPoint(focus);
          }
          if (controller.value.exposurePointSupported) {
            await controller.setExposurePoint(focus);
          }
          report['captureFocusPoint'] = <String, double>{
            'x': focus.dx,
            'y': focus.dy,
          };
          debugPrint('PHYSICAL_CARD_SCENE_READY');
          await tester.pump(const Duration(seconds: 4));
        } catch (error) {
          report['readableSceneWaitMs'] = sceneTimer.elapsedMilliseconds;
          report['readableSceneConfirmed'] = false;
          report['readableSceneError'] = error.toString();
          try {
            if (controller.value.isStreamingImages) {
              await controller.stopImageStream().timeout(
                const Duration(seconds: 10),
              );
            }
            final XFile diagnostic = await controller
                .takePicture()
                .then((XFile photo) async {
                  cameraPaths.add(photo.path);
                  if (cleaning && await File(photo.path).exists()) {
                    await File(photo.path).delete();
                  }
                  return photo;
                })
                .timeout(const Duration(seconds: 15));
            await File(diagnostic.path)
                .copy('${directory.path}/unreadable-scene.jpg');
            report['diagnosticScenePath'] = 'unreadable-scene.jpg';
          } catch (failure) {
            report['diagnosticSceneError'] = failure.toString();
          }
          rethrow;
        }

        for (int index = 0; index < 3; index++) {
          await _waitFor(
            tester,
            () => _shutterReady(tester),
            'Shutter ${index + 1}',
          );
          final Map<String, Object?> before = _overlay(tester);
          final Stopwatch timer = Stopwatch()..start();
          await tester.tap(find.text('Capture photo'));
          await _waitFor(
            tester,
            () => photos.length > index || admissionError != null,
            'Durable photo ${index + 1}',
          );
          expect(admissionError, isNull);
          await _waitFor(
            tester,
            () => _shutterReady(tester),
            'Preview restart ${index + 1}',
          );
          captures[index]['shutterAndRestartMs'] = timer.elapsedMilliseconds;
          captures[index]['before'] = before;
          captures[index]['after'] = _overlay(tester);
          expect(find.byType(LiveCaptureOverlay), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 500));
        }

        await tester.pumpWidget(const arcane.SizedBox());
        await tester.pump(const Duration(milliseconds: 500));
        await Future.wait(imports);
        expect(photos, hasLength(3));
        final List<Map<String, Object?>> originals = <Map<String, Object?>>[];
        for (final ScanDraftPhoto photo in photos) {
          final Map<String, Object?> evidence = await _photoEvidence(
            photo,
            directory,
          );
          originals.add(evidence);
          expect(
            evidence['sha256'],
            captures.singleWhere(
              (Map<String, Object?> value) => value['photoId'] == photo.id,
            )['cameraSourceSha256'],
          );
          expect(evidence['jpeg'], isTrue);
          expect(evidence['width'] as int, greaterThan(1000));
          expect(evidence['height'] as int, greaterThan(1000));
        }
        report['originals'] = originals;
        await Hive.close();
        Hive.init(hiveDirectory.path);
        store = ScanDraftStore(userId: userId);
        final List<ScanDraftPhoto> reopened = await store.readPhotos();
        expect(
          reopened.map((ScanDraftPhoto photo) => photo.id).toSet(),
          photos.map((ScanDraftPhoto photo) => photo.id).toSet(),
        );
        for (final ScanDraftPhoto photo in reopened) {
          final Map<String, Object?> evidence = await _photoEvidence(
            photo,
            directory,
          );
          expect(
            evidence['sha256'],
            originals.singleWhere(
              (Map<String, Object?> value) => value['id'] == photo.id,
            )['sha256'],
          );
        }
        report['threePhotosSurviveHiveReopen'] = true;

        final ScanDraftPhoto first = photos.first;
        final Stopwatch recognitionTimer = Stopwatch()..start();
        final List<ScanDraftItem> items = <ScanDraftItem>[];
        try {
          final Future<ScanRecognition> pending = NativeCardRecognizer()
              .recognize(first.imagePath, multipleCards: true)
              .then((ScanRecognition result) async {
                for (final ScanCrop crop in result.crops) {
                  cropPaths.add(crop.imagePath);
                  if (cleaning && await File(crop.imagePath).exists()) {
                    await File(crop.imagePath).delete();
                  }
                }
                return result;
              });
          final ScanRecognition recognized = await pending.timeout(
            const Duration(seconds: 60),
          );
          report['recognitionMs'] = recognitionTimer.elapsedMilliseconds;
          report['detectedCards'] = recognized.crops.length;
          catalog = ScryfallScanCatalog();
          final ScanResolver resolver = ScanResolver(
            catalog: catalog,
            artwork: CachedScanArtworkMatcher(clientFactory: clientFactory),
            symbols: CachedScanSymbolMatcher(clientFactory: clientFactory),
          );
          for (int index = 0; index < recognized.crops.length; index++) {
            final ScanCrop crop = recognized.crops[index];
            final Map<String, Object?> record = _crop(crop);
            recognitionRecords.add(record);
            ScanResolution? resolution;
            String? error;
            if (!networkDisposed) {
              final Stopwatch lookupTimer = Stopwatch()..start();
              try {
                resolution = await resolver
                    .resolve(crop)
                    .timeout(const Duration(seconds: 75));
                record['resolution'] = _resolution(resolution);
              } catch (failure) {
                error = failure.toString();
                record['error'] = error;
                networkDisposed = true;
                catalog.close();
                for (final http.Client client in clients) {
                  client.close();
                }
              }
              record['resolverMs'] = lookupTimer.elapsedMilliseconds;
            } else {
              error = 'Public lookup unavailable after an earlier resolver failure or timeout.';
              record['error'] = error;
              record['status'] = 'lookup_unavailable';
            }
            items.add(
              ScanDraftItem(
                id: '${first.id}_$index',
                photoId: first.id,
                crop: crop,
                resolution: resolution,
                error: error,
              ),
            );
          }
        } catch (error) {
          report['recognitionError'] = error.toString();
          report['recognitionMs'] = recognitionTimer.elapsedMilliseconds;
        }
        if (items.isNotEmpty) {
          final List<ScanDraftItem> saved = await store.completePhoto(
            first.id,
            items,
          );
          for (int index = 0; index < saved.length; index++) {
            recognitionRecords[index]['path'] = saved[index].crop.imagePath
                .substring(directory.path.length + 1);
            expect(await File(saved[index].crop.imagePath).exists(), isTrue);
            expect(saved[index].crop.width, greaterThan(0));
            expect(saved[index].crop.height, greaterThan(0));
            expect(saved[index].crop.sourceCorners, hasLength(4));
          }
        }
        for (final ScanDraftPhoto photo in photos) {
          expect(await File(photo.imagePath).exists(), isTrue);
          expect(
            sha256
                .convert(await File(photo.imagePath).readAsBytes())
                .toString(),
            originals.singleWhere(
              (Map<String, Object?> value) => value['id'] == photo.id,
            )['sha256'],
          );
        }
        report['originalsRetainedAfterRecognition'] = true;
        expect(tester.takeException(), isNull);
        report['status'] =
            'capture_storage_passed_accuracy_requires_photo_review';
      } catch (error, stack) {
        report['status'] = 'failed';
        report['error'] = error.toString();
        report['stack'] = stack.toString();
        rethrow;
      } finally {
        await tester.pumpWidget(const arcane.SizedBox());
        await tester.pump(const Duration(milliseconds: 500));
        try {
          await Future.wait(imports).timeout(const Duration(seconds: 15));
        } catch (error) {
          report['cleanupAdmissionError'] = error.toString();
        }
        networkDisposed = true;
        catalog?.close();
        for (final http.Client client in clients) {
          client.close();
        }
        try {
          await Hive.close();
        } catch (error) {
          report['closeError'] = error.toString();
        }
        for (final String path in cameraPaths) {
          final File source = File(path);
          if (await source.exists()) {
            await source.copy(
              '${directory.path}/unadmitted-${cameraPaths.toList().indexOf(path)}.jpg',
            );
          }
        }
        report['completedAt'] = DateTime.now().toUtc().toIso8601String();
        await File('${directory.path}/report.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
          flush: true,
        );
        final String exportPath = 'tmp/${directory.path.split('/').last}';
        debugPrint('PHYSICAL_CAPTURE_EXPORT:$exportPath');
        debugPrint(
          'PHYSICAL_CAPTURE_RESULT:${jsonEncode(<String, Object?>{'status': report['status'], 'photos': photos.length, 'detectedCards': report['detectedCards'], 'recognitionError': report['recognitionError']})}',
        );
        await Future<void>.delayed(const Duration(seconds: 30));
        cleaning = true;
        for (final String path in <String>{...cropPaths, ...cameraPaths}) {
          final File file = File(path);
          if (await file.exists()) {
            await file.delete();
          }
        }
        await directory.delete(recursive: true);
      }
    },
    skip: !enabled || !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
