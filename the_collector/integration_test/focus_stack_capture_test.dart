import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:arcane/arcane.dart';
import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:scryfall_api/scryfall_api.dart'
    show ScryfallApiClient, LanguageCodeConversion;
import 'package:the_collector/pages/scanning/guided_camera_screen.dart';
import 'package:the_collector/pages/scanning/live_capture_overlay.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/live_scan_tracker.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_session.dart';
import 'package:the_collector/utils/scanning/scryfall_request_scheduler.dart';

Future<void> waitFor(
  WidgetTester tester,
  bool Function() ready,
  String name, {
  Duration timeout = const Duration(seconds: 120),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(ready(), isTrue, reason: name);
}

class RecordingCardRecognizer implements CardRecognizer {
  final Stopwatch clock;
  final List<ScanRecognition> recognitions = <ScanRecognition>[];
  final List<Map<String, Object?>> timings = <Map<String, Object?>>[];

  RecordingCardRecognizer({required this.clock});

  @override
  Future<ScanRecognition> recognize(
    String imagePath, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    final Map<String, Object?> timing = <String, Object?>{
      'imagePath': imagePath,
      'startedFromOpenMilliseconds': clock.elapsedMilliseconds,
    };
    timings.add(timing);
    try {
      final Map<Object?, Object?>? response = await NativeCardRecognizer.channel
          .invokeMethod<Map<Object?, Object?>>('recognize', <String, Object>{
            'path': imagePath,
            'multipleCards': multipleCards,
            if (targetRegions.isNotEmpty)
              'targetRegions': targetRegions
                  .map(
                    (List<ScanPoint> region) => region
                        .map(
                          (ScanPoint point) => <String, double>{
                            'x': point.x,
                            'y': point.y,
                          },
                        )
                        .toList(),
                  )
                  .toList(),
            'includePartialDiagnostics': true,
          });
      if (response == null) throw StateError('No native recognition response');
      timing['partialDiagnostics'] = response['partialDiagnostics'];
      timing['orientationDiagnostics'] = response['orientationDiagnostics'];
      final ScanRecognition recognition = ScanRecognition.fromMap(response);
      recognitions.add(recognition);
      timing['cropCount'] = recognition.crops.length;
      return recognition;
    } catch (error) {
      timing['error'] = error.toString();
      rethrow;
    } finally {
      timing['finishedFromOpenMilliseconds'] = clock.elapsedMilliseconds;
    }
  }
}

class RecordingHttpClient extends http.BaseClient {
  final http.Client client = http.Client();
  final List<Map<String, Object?>> records;

  RecordingHttpClient(this.records);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final Map<String, Object?> record = <String, Object?>{
      'method': request.method,
      'uri': request.url.toString(),
    };
    records.add(record);
    try {
      final http.StreamedResponse response = await client.send(request);
      record['status'] = response.statusCode;
      return response;
    } catch (error) {
      record['error'] = error.toString();
      rethrow;
    }
  }

  @override
  void close() => client.close();
}

class RecordingScanResolver extends ScanResolver {
  final List<String> failures;
  final Stopwatch clock;
  final List<Map<String, Object?>> timings;

  RecordingScanResolver({
    required super.catalog,
    required this.failures,
    required this.clock,
    required this.timings,
  });

  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) async {
    final Map<String, Object?> timing = <String, Object?>{
      'paths': crops.map((ScanCrop crop) => crop.imagePath).toList(),
      'startedFromOpenMilliseconds': clock.elapsedMilliseconds,
    };
    timings.add(timing);
    try {
      final List<ScanResolution> resolutions = await super.resolveBatch(crops);
      timing['statuses'] = resolutions
          .map((ScanResolution resolution) => resolution.status.name)
          .toList();
      return resolutions;
    } catch (error) {
      failures.add(error.toString());
      timing['error'] = error.toString();
      rethrow;
    } finally {
      timing['finishedFromOpenMilliseconds'] = clock.elapsedMilliseconds;
    }
  }
}

Map<String, Object?> candidateReport(ScanCandidate candidate) =>
    <String, Object?>{
      'id': candidate.card.id,
      'name': candidate.card.name,
      'set': candidate.card.set,
      'collectorNumber': candidate.card.collectorNumber,
      'language': candidate.card.lang.json,
      'hasContradiction': candidate.hasContradiction,
      'score': candidate.score,
      'artworkDistance': candidate.artworkDistance,
      'symbolDistance': candidate.symbolDistance,
      'finishes': candidate.card.finishes
          .map((Object finish) => finish.toString())
          .toList(),
      'evidence': candidate.evidence
          .map((ScanEvidence evidence) => evidence.name)
          .toList(),
    };

Map<String, Object?> footerReport(ScanHints hints) => <String, Object?>{
  'setCode': hints.setCode,
  'collectorNumber': hints.collectorNumber,
  'language': hints.language,
};

void expectRetainedCaptureCrop(
  ScanCrop crop,
  String? liveIdentityName,
  ScanResolution? resolution,
) {
  if (crop.imagePath.isNotEmpty) {
    expect(File(crop.imagePath).existsSync(), isTrue);
    return;
  }
  expect(liveIdentityName, isNotNull);
  expect(liveIdentityName, isNotEmpty);
  expect(resolution, isNotNull);
  expect(resolution!.status, isNot(ScanResolutionStatus.noMatch));
  final String? historical = verifiedLiveHistoricalBodyIdentity(
    crop,
    resolution,
  );
  final Set<String> supportedNames = historical == null
      ? resolution.candidates
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
              (ScanCandidate candidate) =>
                  candidate.card.name.trim().toLowerCase(),
            )
            .toSet()
      : <String>{historical.trim().toLowerCase()};
  expect(supportedNames, <String>{liveIdentityName!});
  expect(
    resolution.candidates.first.card.name.trim().toLowerCase(),
    liveIdentityName,
  );
}

Future<Map<String, Object?>> originalReport(ScanDraftPhoto photo) async {
  final File file = File(photo.imagePath);
  final Digest digest = await sha256.bind(file.openRead()).first;
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromFilePath(
    photo.imagePath,
  );
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    codec = await descriptor.instantiateCodec(targetWidth: 320);
    image = (await codec.getNextFrame()).image;
    final int containerOffset = photo.imagePath.indexOf('/tmp/');
    return <String, Object?>{
      'id': photo.id,
      'imagePath': photo.imagePath,
      'appRelativePath': containerOffset < 0
          ? null
          : photo.imagePath.substring(containerOffset + 1),
      'sha256': digest.toString(),
      'bytes': await file.length(),
      'width': descriptor.width,
      'height': descriptor.height,
      'decodedWidth': image.width,
      'decodedHeight': image.height,
    };
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

Map<String, Object?> cropReport(ScanCrop crop) => <String, Object?>{
  'imagePath': crop.imagePath,
  'width': crop.width,
  'height': crop.height,
  'rectified': crop.rectified,
  'warnings': crop.warnings,
  'sharpness': crop.sharpness,
  'sourceCorners': crop.sourceCorners
      .map((ScanPoint point) => <String, double>{'x': point.x, 'y': point.y})
      .toList(),
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    const bool.fromEnvironment('AUTOMATIC_CARD_QA')
        ? 'automatic capture identifies and retires three mounted cards without duplicates'
        : 'one shutter identifies all three mounted cards across depths',
    (WidgetTester tester) async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'collector_focus_stack_',
      );
      Hive.init(directory.path);
      final ScanDraftStore store = ScanDraftStore(
        userId: 'isolated-depth-stack-qa',
      );
      final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
      final ScryfallScanCatalog catalog = ScryfallScanCatalog(
        api: ScryfallApiClient(
          httpClient: ScryfallHttpClient(
            clientFactory: () => RecordingHttpClient(requests),
          ),
        ),
      );
      final Stopwatch captureTime = Stopwatch();
      final RecordingCardRecognizer recognizer = RecordingCardRecognizer(
        clock: captureTime,
      );
      final List<String> lookupFailures = <String>[];
      final List<Map<String, Object?>> resolutionTimings =
          <Map<String, Object?>>[];
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: RecordingScanResolver(
          catalog: catalog,
          failures: lookupFailures,
          clock: captureTime,
          timings: resolutionTimings,
        ),
        store: store,
      );
      const bool automatic = bool.fromEnvironment('AUTOMATIC_CARD_QA');
      int captureGroups = 0;
      final List<String> allSources = <String>[];
      final List<({String captureId, List<String> paths})> captureSources =
          <({String captureId, List<String> paths})>[];
      bool sessionDisposed = false;
      bool catalogClosed = false;
      bool handedOff = false;
      bool admitted = false;
      List<String> sources = <String>[];
      final Map<String, Object?> report = <String, Object?>{
        'passed': false,
        'scope': 'isolated camera focus-stack drafts, no account writes',
        'requests': requests,
        'lookupFailures': lookupFailures,
        'recognitionTimings': recognizer.timings,
        'resolutionTimings': resolutionTimings,
      };
      final List<Map<String, Object?>> liveSamples = <Map<String, Object?>>[];
      report['liveSamples'] = liveSamples;
      final Set<String> confirmedNames = <String>{};
      final Set<String> confirmedTracks = <String>{};
      final List<Map<String, Object?>> greenEvents = <Map<String, Object?>>[];
      report['greenEvents'] = greenEvents;
      DateTime sampledAt = DateTime.fromMillisecondsSinceEpoch(0);
      void observeLiveCapture() {
        if (!automatic) return;
        final Iterable<Element> overlays = find
            .byType(LiveCaptureOverlay)
            .evaluate();
        if (overlays.isEmpty) return;
        final List<LiveScanTrack> tracks =
            (overlays.first.widget as LiveCaptureOverlay).tracks;
        if (liveSamples.length < 90 &&
            DateTime.now().difference(sampledAt) >=
                const Duration(seconds: 1)) {
          sampledAt = DateTime.now();
          liveSamples.add(<String, Object?>{
            'at': sampledAt.toIso8601String(),
            'cards': tracks
                .map(
                  (LiveScanTrack track) => <String, Object?>{
                    'id': track.id,
                    'captured': track.captured,
                    'identified': track.capturedIdentified,
                    'name': track.resolution?.candidates.firstOrNull?.card.name,
                    'crop': cropReport(track.crop),
                  },
                )
                .toList(),
          });
        }
        for (final LiveScanTrack track in tracks) {
          final String? name =
              track.resolution?.candidates.firstOrNull?.card.name;
          if (track.capturedIdentified && name != null) {
            confirmedNames.add(name);
            if (confirmedTracks.add(track.id)) {
              final ScanResolution resolution = track.resolution!;
              greenEvents.add(<String, Object?>{
                'trackId': track.id,
                'fromOpenMilliseconds': captureTime.elapsedMilliseconds,
                'status': resolution.status.name,
                'footer': footerReport(resolution.hints),
                'printing': candidateReport(resolution.candidates.first),
                'sourceCorners': track.crop.sourceCorners
                    .map(
                      (ScanPoint point) => <String, double>{
                        'x': point.x,
                        'y': point.y,
                      },
                    )
                    .toList(),
                'hasExactPrintingEvidence': hasExactPrintingEvidence(
                  track.crop,
                  resolution,
                ),
              });
            }
          }
        }
      }

      final List<double> buildTimes = <double>[];
      final List<double> rasterTimes = <double>[];
      void recordFrames(List<ui.FrameTiming> frames) {
        observeLiveCapture();
        for (final ui.FrameTiming frame in frames) {
          if (buildTimes.length >= 5000) break;
          buildTimes.add(frame.buildDuration.inMicroseconds / 1000);
          rasterTimes.add(frame.rasterDuration.inMicroseconds / 1000);
        }
      }

      SchedulerBinding.instance.addTimingsCallback(recordFrames);
      final Set<String> liveNames = <String>{};
      final List<Map<String, Object?>> liveObservations =
          <Map<String, Object?>>[];

      try {
        await session.load();
        if (automatic) captureTime.start();
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(ThemeMode.dark),
            home: GuidedCameraScreen(
              automaticCapture: automatic,
              session: session,
              multipleCards: true,
              onFocusStackCaptured:
                  (
                    List<String> paths,
                    List<List<ScanPoint>> excludedRegions,
                    String captureId,
                    List<List<ScanPoint>>? targetRegions,
                  ) async {
                    report[automatic
                            ? 'latestPhotosReadyFromOpenMilliseconds'
                            : 'photoCaptureMilliseconds'] =
                        captureTime.elapsedMilliseconds;
                    sources = List<String>.of(paths);
                    if (automatic) {
                      report.putIfAbsent(
                        'firstPhotosReadyFromOpenMilliseconds',
                        () => captureTime.elapsedMilliseconds,
                      );
                    }
                    allSources.addAll(paths);
                    captureSources.add((
                      captureId: captureId,
                      paths: List<String>.of(paths),
                    ));
                    captureGroups++;
                    admitted = await session.addFocusStack(
                      paths,
                      ownedCameraSource: true,
                      excludedRegions: excludedRegions,
                      captureId: captureId,
                      diagnosticOnly: true,
                      targetRegions: targetRegions,
                    );
                    report[automatic
                            ? 'latestDurableHandoffFromOpenMilliseconds'
                            : 'durableHandoffMilliseconds'] =
                        captureTime.elapsedMilliseconds;
                    handedOff = true;
                    if (automatic && admitted) {
                      report.putIfAbsent(
                        'firstDurableHandoffFromOpenMilliseconds',
                        () => captureTime.elapsedMilliseconds,
                      );
                    }
                    return admitted;
                  },
            ),
          ),
        );
        await waitFor(
          tester,
          () =>
              find.byType(CameraPreview).evaluate().length == 1 &&
              tester
                  .widget<CameraPreview>(find.byType(CameraPreview))
                  .controller
                  .value
                  .isStreamingImages,
          'rear camera streaming',
        );
        if (automatic) {
          expect(
            find.byKey(const ValueKey<String>('camera-shutter')),
            findsNothing,
          );
          final DateTime deadline = DateTime.now().add(
            const Duration(minutes: 3),
          );
          while (DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 200));
            observeLiveCapture();
            if (confirmedNames.containsAll(<String>{
                  'Nevermore',
                  'Circle of Protection: Blue',
                  'Mirkwood Bats',
                }) &&
                !session.running &&
                session.remainingPhotos == 0) {
              break;
            }
          }
          report['automatic'] = true;
          report['matchingFinishedFromOpenMilliseconds'] =
              captureTime.elapsedMilliseconds;
          report['confirmedNames'] = confirmedNames.toList();
          report['captureGroups'] = captureGroups;
          report['sourceCount'] = allSources.length;
          report['items'] = session.items
              .map(
                (ScanSessionItem item) => <String, Object?>{
                  'id': item.id,
                  'photoId': item.photoId,
                  'name': item.printing?.name,
                  'status': item.resolution?.status.name,
                  'hasMore': item.resolution?.hasMore,
                  'hints': item.resolution?.hints.names,
                  'footer': item.resolution == null
                      ? null
                      : footerReport(item.resolution!.hints),
                  'printing': item.printing == null
                      ? null
                      : candidateReport(item.resolution!.candidates.first),
                  'hasExactPrintingEvidence': hasExactPrintingEvidence(
                    item.crop,
                    item.resolution,
                  ),
                  'evidence': item.resolution?.candidates.firstOrNull?.evidence
                      .map((ScanEvidence evidence) => evidence.name)
                      .toList(),
                  'candidates': item.resolution?.candidates
                      .map(candidateReport)
                      .toList(),
                  'crop': cropReport(item.crop),
                  'error': item.error,
                },
              )
              .toList();
          report['diagnosticPhotoHandoffObserved'] = handedOff;
          report['diagnosticPhotosAdmitted'] = admitted;
          expect(
            confirmedNames,
            containsAll(<String>{
              'Nevermore',
              'Circle of Protection: Blue',
              'Mirkwood Bats',
            }),
            reason:
                'every green outline requires retained, verified card identity',
          );
          expect(
            session.items,
            hasLength(3),
            reason: 'exactly three physical cards',
          );
          for (final ScanSessionItem item in session.items) {
            expectRetainedCaptureCrop(
              item.crop,
              item.liveIdentityName,
              item.resolution,
            );
          }
          debugPrint('FOCUS_STACK_IDENTIFIED_READY');
          final Finder automaticStatus = find.byKey(
            const ValueKey<String>('camera-auto-status'),
          );
          String cameraStatus() => tester.widget<Text>(automaticStatus).data!;
          final Set<String> identifiedCheckpointIds = session.items
              .map((ScanSessionItem item) => item.id)
              .toSet();
          report['greenCheckpointAutoStatus'] = cameraStatus();
          report['greenCheckpointCaptureGroups'] = captureGroups;
          report['greenCheckpointSourceCount'] = allSources.length;
          await waitFor(
            tester,
            () => cameraStatus() == 'Auto capture',
            'already admitted diagnostic capture and metadata complete',
          );
          expect(
            session.items.map((ScanSessionItem item) => item.id).toSet(),
            identifiedCheckpointIds,
            reason: 'draining an admitted diagnostic cannot add or replace a physical card',
          );
          expect(session.items, hasLength(3));
          expect(
            session.items
                .map((ScanSessionItem item) => item.printing?.name)
                .toSet(),
            <String>{
              'Nevermore',
              'Circle of Protection: Blue',
              'Mirkwood Bats',
            },
          );
          final int stableGroups = captureGroups;
          final int stablePhotos = allSources.length;
          report['stationaryBaselineAutoStatus'] = cameraStatus();
          report['stationaryBaselineCaptureGroups'] = stableGroups;
          report['stationaryBaselineSourceCount'] = stablePhotos;
          final DateTime stationaryDeadline = DateTime.now().add(
            const Duration(seconds: 20),
          );
          while (DateTime.now().isBefore(stationaryDeadline)) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          final List<LiveScanTrack> remaining = tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks;
          report['stationaryCaptureGroups'] = captureGroups;
          report['stationarySourceCount'] = allSources.length;
          report['retainedActiveTracks'] = remaining.length;
          expect(
            captureGroups,
            stableGroups,
            reason: 'stationary cards never trigger another capture',
          );
          expect(allSources.length, stablePhotos);
          expect(
            remaining,
            isEmpty,
            reason: 'green cards leave active tracking',
          );
          expect(session.items, hasLength(3));
          final Set<String?> savedNames = session.items
              .map((ScanSessionItem item) => item.printing?.name)
              .toSet();
          expect(savedNames, <String>{
            'Nevermore',
            'Circle of Protection: Blue',
            'Mirkwood Bats',
          });
          final Set<String> originalIds = <String>{
            for (final ({String captureId, List<String> paths}) capture
                in captureSources)
              for (int index = 0; index < capture.paths.length; index++)
                '${capture.captureId}_$index',
          };
          final Map<String, String> originalHashes = <String, String>{};
          final List<Map<String, Object?>> originals = <Map<String, Object?>>[];
          for (final String id in originalIds) {
            final ScanDraftPhoto? photo = await store.readSource(id);
            expect(
              photo,
              isNotNull,
              reason: 'every owned capture retains its original',
            );
            final Map<String, Object?> evidence = await originalReport(photo!);
            expect(evidence['width'] as int, greaterThan(1000));
            expect(evidence['height'] as int, greaterThan(1000));
            expect(evidence['decodedWidth'] as int, greaterThan(0));
            expect(evidence['decodedHeight'] as int, greaterThan(0));
            originalHashes[id] = evidence['sha256'] as String;
            originals.add(evidence);
          }
          report['originals'] = originals;
          final Map<String, ({String? identity, String? name})>
          retainedIdentities = <String, ({String? identity, String? name})>{
            for (final ScanSessionItem item in session.items)
              item.id: (
                identity: item.liveIdentityName,
                name: item.printing?.name,
              ),
          };
          final Set<String> draftIds = retainedIdentities.keys.toSet();
          await tester.pumpWidget(const SizedBox());
          session.dispose();
          sessionDisposed = true;
          catalog.close();
          catalogClosed = true;
          await Hive.close();
          Hive.init(directory.path);
          final ScanDraftStore reopened = ScanDraftStore(
            userId: 'isolated-depth-stack-qa',
          );
          final List<ScanDraftItem> reopenedDrafts = await reopened.readItems();
          expect(
            reopenedDrafts.map((ScanDraftItem item) => item.id).toSet(),
            draftIds,
          );
          expect(reopenedDrafts, hasLength(3));
          expect(
            reopenedDrafts
                .map(
                  (ScanDraftItem item) =>
                      item.resolution?.candidates.firstOrNull?.card.name,
                )
                .toSet(),
            savedNames,
          );
          for (final ScanDraftItem draft in reopenedDrafts) {
            expectRetainedCaptureCrop(
              draft.crop,
              draft.liveIdentityName,
              draft.resolution,
            );
            expect(
              draft.liveIdentityName,
              retainedIdentities[draft.id]!.identity,
            );
            expect(
              draft.resolution?.candidates.firstOrNull?.card.name,
              retainedIdentities[draft.id]!.name,
            );
          }
          final List<Map<String, Object?>> reopenedOriginals =
              <Map<String, Object?>>[];
          for (final String id in originalIds) {
            final ScanDraftPhoto? photo = await reopened.readSource(id);
            expect(photo, isNotNull);
            final Map<String, Object?> evidence = await originalReport(photo!);
            expect(evidence['sha256'], originalHashes[id]);
            reopenedOriginals.add(evidence);
          }
          report['reopenedOriginals'] = reopenedOriginals;
          report['originalsRetainedAfterRecognitionAndReopen'] = true;
          report['reopenedDraftCount'] = reopenedDrafts.length;
          report['passed'] = true;
          return;
        }
        await tester.pump(const Duration(seconds: 12));
        if (const bool.fromEnvironment('LIVE_CARD_QA')) {
          final DateTime deadline = DateTime.now().add(
            const Duration(seconds: 60),
          );
          DateTime sampledAt = DateTime.fromMillisecondsSinceEpoch(0);
          while (DateTime.now().isBefore(deadline) &&
              !liveNames.containsAll(<String>{
                'Nevermore',
                'Circle of Protection: Blue',
                'Mirkwood Bats',
              })) {
            await tester.pump(const Duration(milliseconds: 250));
            final Finder overlay = find.byType(LiveCaptureOverlay);
            if (overlay.evaluate().isEmpty) continue;
            final List<LiveScanTrack> tracks = tester
                .widget<LiveCaptureOverlay>(overlay)
                .tracks;
            if (DateTime.now().difference(sampledAt) >=
                const Duration(seconds: 2)) {
              sampledAt = DateTime.now();
              liveSamples.add(<String, Object?>{
                'at': sampledAt.toIso8601String(),
                'cards': tracks
                    .map(
                      (LiveScanTrack track) => <String, Object?>{
                        'id': track.id,
                        'name':
                            track.resolution?.candidates.firstOrNull?.card.name,
                        'resolving': track.resolving,
                        'error': track.error,
                        'crop': cropReport(track.crop),
                      },
                    )
                    .toList(),
              });
            }
            for (final LiveScanTrack track in tracks) {
              final ScanCandidate? candidate =
                  track.resolution?.candidates.firstOrNull;
              final String? name =
                  track.hasCatalogMatch &&
                      candidate != null &&
                      !candidate.hasContradiction
                  ? candidate.card.name
                  : null;
              if (name != null && liveNames.add(name)) {
                liveObservations.add(<String, Object?>{
                  'id': track.id,
                  'name': name,
                  'warnings': track.crop.warnings,
                  'corners': cropReport(track.crop)['sourceCorners'],
                });
              }
            }
          }
          report['liveNames'] = liveNames.toList();
          report['liveObservations'] = liveObservations;
        }
        void repaint(RenderObject object) {
          object.markNeedsPaint();
          object.visitChildren(repaint);
        }

        for (final RenderObject view in tester.binding.renderViews) {
          repaint(view);
        }
        await tester.pump();
        debugPrint('FOCUS_STACK_PREVIEW_READY');
        await tester.pump(const Duration(seconds: 3));
        final CameraController controller = tester
            .widget<CameraPreview>(find.byType(CameraPreview))
            .controller;
        final List<Map<Object?, Object?>> focusStates =
            <Map<Object?, Object?>>[];
        report['focusStates'] = focusStates;
        captureTime.start();
        await tester.tap(find.byKey(const ValueKey<String>('camera-shutter')));
        final DateTime handoffDeadline = DateTime.now().add(
          const Duration(minutes: 2),
        );
        while (!handedOff && DateTime.now().isBefore(handoffDeadline)) {
          await tester.pump(const Duration(milliseconds: 250));
          final Map<Object?, Object?>? status = await NativeCardRecognizer
              .channel
              .invokeMethod<Map<Object?, Object?>>(
                'cameraFocusStatus',
                <String, String>{'cameraName': controller.description.name},
              );
          if (status != null && focusStates.length < 120) {
            focusStates.add(status);
          }
        }
        expect(handedOff, isTrue, reason: 'durable scene handoff');
        expect(admitted, isTrue);
        await tester.pump(const Duration(milliseconds: 100));
        final List<LiveScanTrack> savedTracks = tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks;
        report['capturedTrackCount'] = savedTracks
            .where((LiveScanTrack track) => track.captured)
            .length;
        Map<String, Object?> trackReport(LiveScanTrack track) =>
            <String, Object?>{
              'id': track.id,
              'captured': track.captured,
              'identified': track.capturedIdentified,
              'name': track.resolution?.candidates.firstOrNull?.card.name,
              'crop': cropReport(track.crop),
            };
        report['acknowledgedTracks'] = savedTracks.map(trackReport).toList();
        report['captureReviewLabelVisible'] = find
            .text('Captured')
            .evaluate()
            .isNotEmpty;
        expect(sources.length, inInclusiveRange(2, 5));
        for (final RenderObject view in tester.binding.renderViews) {
          repaint(view);
        }
        await tester.pump();
        debugPrint('FOCUS_STACK_MARKERS_READY');
        await tester.pump(const Duration(seconds: 3));
        await waitFor(
          tester,
          () => !session.running && session.remainingPhotos == 0,
          'native OCR and public catalog lookup',
          timeout: const Duration(minutes: 3),
        );
        if (session.items.any((ScanSessionItem item) => item.error != null)) {
          report['retriedLookup'] = true;
          await session.retryUnresolved();
        }
        report['sourceCount'] = sources.length;
        report['storageError'] = session.storageError;
        report['items'] = session.items
            .map(
              (ScanSessionItem item) => <String, Object?>{
                'id': item.id,
                'photoId': item.photoId,
                'imagePath': item.crop.imagePath,
                'width': item.crop.width,
                'height': item.crop.height,
                'warnings': item.crop.warnings,
                'sharpness': item.crop.sharpness,
                'hints': ScanHints.fromCrop(item.crop).names,
                'lines': item.crop.lines
                    .map((ScanTextLine line) => line.text)
                    .toList(),
                'name': item.printing?.name,
                'status': item.resolution?.status.name,
                'evidence': item.resolution?.candidates.firstOrNull?.evidence
                    .map((ScanEvidence e) => e.name)
                    .toList(),
                'error': item.error,
              },
            )
            .toList();
        final Set<String> names = session.items
            .map((ScanSessionItem item) => item.printing?.name)
            .whereType<String>()
            .toSet();
        report['names'] = names.toList();
        final DateTime markerDeadline = DateTime.now().add(
          const Duration(seconds: 15),
        );
        DateTime markerSampleAt = DateTime.fromMillisecondsSinceEpoch(0);
        final List<Map<String, Object?>> markerSamples =
            <Map<String, Object?>>[];
        report['markerSamples'] = markerSamples;
        while (DateTime.now().isBefore(markerDeadline)) {
          await tester.pump(const Duration(milliseconds: 250));
          final List<LiveScanTrack> tracks = tester
              .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
              .tracks;
          if (DateTime.now().difference(markerSampleAt) >=
              const Duration(seconds: 2)) {
            markerSampleAt = DateTime.now();
            markerSamples.add(<String, Object?>{
              'at': markerSampleAt.toIso8601String(),
              'tracks': tracks.map(trackReport).toList(),
            });
          }
          if (tracks
                  .where((LiveScanTrack track) => track.capturedIdentified)
                  .length ==
              3) {
            break;
          }
        }
        final List<LiveScanTrack> identifiedTracks = tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks;
        report['finalCapturedTrackCount'] = identifiedTracks
            .where((LiveScanTrack track) => track.captured)
            .length;
        report['capturedIdentifiedCount'] = identifiedTracks
            .where((LiveScanTrack track) => track.capturedIdentified)
            .length;
        report['capturedIdentifiedNames'] = identifiedTracks
            .where((LiveScanTrack track) => track.capturedIdentified)
            .map(
              (LiveScanTrack track) =>
                  track.resolution?.candidates.firstOrNull?.card.name,
            )
            .toList();
        for (final RenderObject view in tester.binding.renderViews) {
          repaint(view);
        }
        await tester.pump();
        debugPrint('FOCUS_STACK_IDENTIFIED_READY');
        await tester.pump(const Duration(seconds: 3));
        report['retainedIdentifiedCount'] = tester
            .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
            .tracks
            .where((LiveScanTrack track) => track.capturedIdentified)
            .length;
        expect(
          names,
          containsAll(<String>[
            'Nevermore',
            'Circle of Protection: Blue',
            'Mirkwood Bats',
          ]),
        );
        expect(
          session.items,
          hasLength(3),
          reason: 'focus passes must not multiply physical cards',
        );
        if (const bool.fromEnvironment('LIVE_CARD_QA')) {
          expect(
            report['finalCapturedTrackCount'],
            3,
            reason: 'all three physical cards have capture receipts after saved recognition and fresh live geometry',
          );
          expect(
            report['capturedIdentifiedCount'],
            3,
            reason: 'saved-photo results identify all three captured markers',
          );
          expect(
            report['retainedIdentifiedCount'],
            3,
            reason:
                'fresh live frames retain all three identified card receipts',
          );
          expect(
            liveNames,
            containsAll(<String>[
              'Nevermore',
              'Circle of Protection: Blue',
              'Mirkwood Bats',
            ]),
            reason: 'automatic focus discovery identifies each card live',
          );
        }
        report['passed'] = true;
      } finally {
        SchedulerBinding.instance.removeTimingsCallback(recordFrames);
        Map<String, Object> frameSummary(List<double> timings) {
          timings.sort();
          return <String, Object>{
            'samples': timings.length,
            if (timings.isNotEmpty) ...<String, Object>{
              'p95Milliseconds': timings[((timings.length - 1) * .95).round()],
              'maximumMilliseconds': timings.last,
              'above16_67Milliseconds': timings
                  .where((double time) => time > 16.67)
                  .length,
            },
          };
        }

        report['uiFrameBuild'] = frameSummary(buildTimes);
        report['uiFrameRaster'] = frameSummary(rasterTimes);
        await tester.pumpWidget(const SizedBox());
        if (!sessionDisposed) {
          session.dispose();
          sessionDisposed = true;
        }
        if (!catalogClosed) {
          catalog.close();
          catalogClosed = true;
        }
        if (const bool.fromEnvironment('AUTOMATIC_CARD_QA') &&
            captureSources.isNotEmpty &&
            report['originalsRetainedAfterRecognitionAndReopen'] != true) {
          try {
            final Set<String> ids = <String>{
              for (final ({String captureId, List<String> paths}) capture
                  in captureSources)
                for (int index = 0; index < capture.paths.length; index++)
                  '${capture.captureId}_$index',
            };
            final List<Map<String, Object?>> originals =
                <Map<String, Object?>>[];
            for (final String id in ids) {
              final ScanDraftPhoto? photo = await store.readSource(id);
              if (photo == null) throw StateError('Missing original $id');
              originals.add(await originalReport(photo));
            }
            final Map<String, ({String? identity, String? name})>
            retainedIdentities = <String, ({String? identity, String? name})>{
              for (final ScanDraftItem draft in await store.readItems())
                draft.id: (
                  identity: draft.liveIdentityName,
                  name: draft.resolution?.candidates.firstOrNull?.card.name,
                ),
            };
            final Set<String> draftIds = retainedIdentities.keys.toSet();
            await Hive.close();
            Hive.init(directory.path);
            final ScanDraftStore reopened = ScanDraftStore(
              userId: 'isolated-depth-stack-qa',
            );
            final List<ScanDraftItem> drafts = await reopened.readItems();
            expect(
              drafts.map((ScanDraftItem item) => item.id).toSet(),
              draftIds,
            );
            final List<Map<String, Object?>> reopenedOriginals =
                <Map<String, Object?>>[];
            for (int index = 0; index < originals.length; index++) {
              final ScanDraftPhoto? photo = await reopened.readSource(
                ids.elementAt(index),
              );
              if (photo == null) throw StateError('Missing reopened original');
              final Map<String, Object?> evidence = await originalReport(photo);
              expect(evidence['sha256'], originals[index]['sha256']);
              expect(evidence['width'] as int, greaterThan(1000));
              expect(evidence['height'] as int, greaterThan(1000));
              expect(evidence['decodedWidth'] as int, greaterThan(0));
              expect(evidence['decodedHeight'] as int, greaterThan(0));
              reopenedOriginals.add(evidence);
            }
            for (final ScanDraftItem draft in drafts) {
              expectRetainedCaptureCrop(
                draft.crop,
                draft.liveIdentityName,
                draft.resolution,
              );
              expect(
                draft.liveIdentityName,
                retainedIdentities[draft.id]!.identity,
              );
              expect(
                draft.resolution?.candidates.firstOrNull?.card.name,
                retainedIdentities[draft.id]!.name,
              );
            }
            report['originals'] = originals;
            report['reopenedOriginals'] = reopenedOriginals;
            report['originalsRetainedAfterRecognitionAndReopen'] = true;
            report['reopenedDraftCount'] = drafts.length;
          } catch (error) {
            report['originalsRetainedAfterRecognitionAndReopen'] = false;
            report['photoVerificationError'] = error.toString();
            report['passed'] = false;
          }
        }
        report['recognitions'] = recognizer.recognitions
            .map(
              (ScanRecognition recognition) => <String, Object?>{
                'imagePath': recognition.imagePath,
                'width': recognition.width,
                'height': recognition.height,
                'crops': recognition.crops.map(cropReport).toList(),
              },
            )
            .toList();
        await File('${directory.path}/report.json')
            .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
        debugPrint(
          'FOCUS_STACK_EXPORT:${directory.path.substring(directory.path.indexOf('/tmp/') + 1)}',
        );
        await tester.pump(const Duration(seconds: 30));
        await Hive.close();
        if (await directory.exists()) await directory.delete(recursive: true);
        expect(report['photoVerificationError'], isNull);
      }
    },
    skip: !const bool.fromEnvironment('PHYSICAL_CARD_QA'),
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
