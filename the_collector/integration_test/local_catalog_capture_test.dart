import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/scan_artwork_matcher.dart';
import 'package:the_collector/utils/scanning/scan_local_catalog.dart';
import 'package:the_collector/utils/scanning/scan_name_index.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_symbol_matcher.dart';
import 'package:the_collector/utils/scanning/scan_visual_index.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const String manifestPath = String.fromEnvironment(
    'SCAN_CATALOG_CAPTURE_MANIFEST',
  );

  testWidgets(
    'actual native crops resolve against the complete local catalog and visual index',
    (WidgetTester tester) async {
      final File manifestFile = manifestPath.startsWith('/')
          ? File(manifestPath)
          : File.fromUri(Directory.systemTemp.uri.resolve(manifestPath));
      final Object? decoded = jsonDecode(await manifestFile.readAsString());
      if (decoded is! Map<String, Object?> ||
          decoded['schema'] != 1 ||
          decoded['fixtures'] is! List<Object?>) {
        throw const FormatException(
          'Expected an actual-capture fixture manifest.',
        );
      }
      final Directory directory = await Directory.systemTemp.createTemp(
        'collector-catalog-capture-',
      );
      Hive.init(directory.path);
      final LocalScanCatalog catalog = LocalScanCatalog(
        directory: () async => Directory('${directory.path}/catalog'),
      );
      final ScryfallScanNameIndex names = ScryfallScanNameIndex(
        loader: () async => (await catalog.cardNamesReady())!,
        readCache: () async => null,
        writeCache: (String value) async {},
      );
      final List<Map<String, Object?>> records = <Map<String, Object?>>[];
      final List<String> failures = <String>[];
      final Map<String, Object?> report = <String, Object?>{
        'fixtures': records,
      };
      try {
        final Stopwatch loading = Stopwatch()..start();
        await catalog.warm();
        expect(catalog.package!.visualComplete, isTrue);
        expect(catalog.package!.cardCount, greaterThan(100000));
        expect(catalog.package!.visualCount, greaterThan(50000));
        report['packageVersion'] = catalog.package!.version;
        report['catalogWarmMilliseconds'] = loading.elapsedMilliseconds;
        await names.warm();
        final IndexedScanVisualRetriever visual = IndexedScanVisualRetriever(
          catalog: catalog,
        );
        final ScanResolver resolver = ScanResolver(
          catalog: ScryfallScanCatalog(localCatalog: catalog),
          artwork: CachedScanArtworkMatcher(),
          symbols: CachedScanSymbolMatcher(),
          nameIndex: names,
          visualIndex: visual,
        );
        for (final Object? value in decoded['fixtures']! as List<Object?>) {
          final Map<String, Object?> record = <String, Object?>{};
          records.add(record);
          void check(bool condition, String message) {
            if (!condition) failures.add('Fixture ${records.length}: $message');
          }

          try {
            if (value is! Map<String, Object?> ||
                value['crop'] is! Map<String, Object?>) {
              throw const FormatException(
                'A fixture must contain unchanged native crop observations.',
              );
            }
            final Map<String, Object?> nativeCrop = Map<String, Object?>.from(
              value['crop']! as Map<String, Object?>,
            );
            final String imagePath = nativeCrop['imagePath']! as String;
            if (!imagePath.startsWith('/')) {
              nativeCrop['imagePath'] = manifestFile.parent.uri
                  .resolve(imagePath)
                  .toFilePath();
            }
            final ScanCrop crop = ScanCrop.fromMap(nativeCrop);
            expect(await File(crop.imagePath).exists(), isTrue);
            final bool negative = value['negative'] == true;
            final Map<String, Object?>? expected =
                value['expected'] as Map<String, Object?>?;
            MtgCard? printing;
            if (!negative) {
              expect(expected, isNotNull);
              printing = await catalog.exactReady(
                expected!['set']! as String,
                expected['number']! as String,
                language: 'en',
              );
              expect(printing, isNotNull);
              expect(printing!.name, expected['name']);
            }
            record.addAll(<String, Object?>{
              'image': crop.imagePath,
              'negative': negative,
              'expected': expected,
              'observedText': crop.lines
                  .map((ScanTextLine line) => line.text)
                  .toList(),
              'warnings': crop.warnings,
            });
            final Stopwatch shortlistTime = Stopwatch()..start();
            final List<LocalVisualHit> shortlist = await visual.discover(crop);
            record['shortlistMilliseconds'] = shortlistTime.elapsedMilliseconds;
            record['shortlist'] = shortlist
                .map(
                  (LocalVisualHit hit) => <String, Object?>{
                    'illustration': hit.illustrationId,
                    'rawDistance': hit.distance,
                    'rotation': hit.rotationDegrees,
                    'region': hit.queryRegion == null
                        ? null
                        : <String, double>{
                            'x': hit.queryRegion!.x,
                            'y': hit.queryRegion!.y,
                            'width': hit.queryRegion!.width,
                            'height': hit.queryRegion!.height,
                          },
                    'names': hit.cards
                        .map((MtgCard card) => card.name)
                        .toList(),
                  },
                )
                .toList();
            if (printing != null) {
              final Set<String> artwork = <String>{
                if (printing.illustrationId != null) printing.illustrationId!,
                ...?printing.cardFaces
                    ?.map((CardFace face) => face.illustrationId)
                    .whereType<String>(),
              };
              final bool recalled = shortlist.any(
                (LocalVisualHit hit) => artwork.contains(hit.illustrationId),
              );
              record['artworkRecalled'] = recalled;
              if (value['imageOnlyRequired'] != false) {
                check(
                  recalled,
                  'The actual artwork was absent from the bounded 20 references.',
                );
              }
            }
            final Stopwatch resolutionTime = Stopwatch()..start();
            final ScanResolution resolution = await resolver.resolve(crop);
            check(
              resolution.candidates.every(
                (ScanCandidate candidate) =>
                    candidate.card.games.contains(Game.paper),
              ),
              'Physical scanning offered a digital-only printing.',
            );
            record['resolutionMilliseconds'] =
                resolutionTime.elapsedMilliseconds;
            record['status'] = resolution.status.name;
            record['candidates'] = resolution.candidates
                .map(
                  (ScanCandidate candidate) => <String, Object?>{
                    'id': candidate.card.id,
                    'name': candidate.card.name,
                    'set': candidate.card.set,
                    'number': candidate.card.collectorNumber,
                    'artworkDistance': candidate.artworkDistance,
                    'symbolDistance': candidate.symbolDistance,
                    'evidence': candidate.evidence
                        .map((ScanEvidence item) => item.name)
                        .toList(),
                  },
                )
                .toList();
            if (!negative) {
              check(
                resolution.candidates.isNotEmpty,
                'The normal pipeline returned no candidates.',
              );
              if (resolution.candidates.isNotEmpty) {
                check(
                  resolution.candidates.first.card.id == printing!.id,
                  'The photographed identity and printing did not lead the normal pipeline.',
                );
              }
            } else {
              check(
                resolution.candidates.isEmpty,
                'Desk texture produced arbitrary card identities.',
              );
            }
            final ScanCrop imageOnly = ScanCrop(
              imagePath: crop.imagePath,
              width: crop.width,
              height: crop.height,
              rectified: crop.rectified,
              sourceCorners: crop.sourceCorners,
              warnings: crop.warnings,
              sharpness: crop.sharpness,
              lines: const <ScanTextLine>[],
            );
            final Stopwatch imageTime = Stopwatch()..start();
            final ScanResolution discovery = await resolver.resolve(imageOnly);
            record['imageOnlyMilliseconds'] = imageTime.elapsedMilliseconds;
            record['imageOnlyStatus'] = discovery.status.name;
            record['imageOnlyNames'] = discovery.candidates
                .map((ScanCandidate candidate) => candidate.card.name)
                .toList();
            record['imageOnlyCandidates'] = discovery.candidates
                .map(
                  (ScanCandidate candidate) => <String, Object?>{
                    'id': candidate.card.id,
                    'name': candidate.card.name,
                    'set': candidate.card.set,
                    'number': candidate.card.collectorNumber,
                    'artworkDistance': candidate.artworkDistance,
                  },
                )
                .toList();
            check(
              discovery.hints.names.isEmpty,
              'Image-only discovery invented observed names.',
            );
            check(
              discovery.candidates.every(
                (ScanCandidate candidate) =>
                    candidate.card.games.contains(Game.paper),
              ),
              'Artwork discovery offered a digital-only printing.',
            );
            check(
              !hasExactPrintingEvidence(imageOnly, discovery),
              'Image-only discovery granted exact printing proof.',
            );
            check(
              discovery.historicalBodyIdentityProof == null,
              'Image-only discovery invented body proof.',
            );
            if (!negative) {
              check(
                discovery.status != ScanResolutionStatus.exactPrinting,
                'Image-only discovery marked an exact printing.',
              );
              if (value['imageOnlyRequired'] != false) {
                check(
                  discovery.status == ScanResolutionStatus.needsReview &&
                      discovery.candidates.any(
                        (ScanCandidate candidate) =>
                            candidate.card.name == printing!.name,
                      ),
                  'Image-only discovery omitted the actual identity from its explicitly uncertain alternatives.',
                );
              }
            } else {
              check(
                discovery.candidates.isEmpty,
                'An image of the desk produced card suggestions.',
              );
            }
            final Stopwatch diagnosticsTime = Stopwatch()..start();
            final List<Map<String, Object?>> structural =
                <Map<String, Object?>>[];
            for (final LocalVisualHit hit in shortlist.take(20)) {
              final ScanBounds region =
                  hit.queryRegion ?? IndexedScanVisualRetriever.standardArtwork;
              final Map<String, Object?> comparison = <String, Object?>{
                'illustration': hit.illustrationId,
                'names': hit.cards.map((MtgCard card) => card.name).toList(),
              };
              try {
                comparison['result'] = await NativeCardRecognizer.channel
                    .invokeMethod<Object?>(
                      'compareArtworkStructure',
                      <String, Object?>{
                        'queryImagePath': crop.imagePath,
                        'referencePixels': hit.referencePixels,
                        'referenceSchema': ScanCatalogPackage.referenceSchema,
                        'rotationDegrees': hit.rotationDegrees,
                        'queryRegion': <String, double>{
                          'x': region.x,
                          'y': region.y,
                          'width': region.width,
                          'height': region.height,
                        },
                      },
                    );
              } catch (error) {
                comparison['error'] = error.toString();
              }
              structural.add(comparison);
            }
            record['structuralComparisons'] = structural;
            record['diagnosticsMilliseconds'] =
                diagnosticsTime.elapsedMilliseconds;
          } catch (error) {
            record['error'] = error.toString();
            failures.add('Fixture ${records.length}: $error');
          }
        }
        report['failures'] = failures;
        expect(failures, isEmpty);
        report['passed'] = true;
      } catch (error) {
        report['passed'] = false;
        report['error'] = error.toString();
        rethrow;
      } finally {
        await File(
          '${Directory.systemTemp.path}/collector_catalog_capture_report.json',
        ).writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
          flush: true,
        );
        names.close();
        catalog.close();
        await Hive.close();
        await directory.delete(recursive: true);
      }
    },
    skip: manifestPath.isEmpty,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
