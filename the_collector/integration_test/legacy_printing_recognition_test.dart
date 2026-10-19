import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

class _ObservedCatalog implements ScanCatalog {
  final List<MtgCard> representatives;
  final List<MtgCard> printingsByName;
  final List<String> queries = <String>[];

  _ObservedCatalog(this.representatives, this.printingsByName);

  @override
  Future<MtgCard?> exactPrinting(
    String setCode,
    String collectorNumber, {
    String? language,
  }) async => null;

  @override
  Future<MtgCard?> fuzzyName(String name) async => null;

  @override
  Future<PaginableList<MtgCard>> printings(
    String name, {
    String? setCode,
    String? language,
    int page = 1,
  }) async {
    queries.add(name);
    return PaginableList<MtgCard>(
      data: printingsByName.where((MtgCard card) => card.name == name).toList(),
      hasMore: false,
    );
  }

  @override
  Future<PaginableList<MtgCard>> rulesKeywordCards(
    List<String> keywords, {
    String? phrase,
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
  }) async => PaginableList<MtgCard>(data: representatives, hasMore: false);

  @override
  Future<PaginableList<MtgCard>> rulesTextPrintings(
    String phrase, {
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
    int page = 1,
  }) async => PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const String fixture = String.fromEnvironment('LEGACY_PRINT_QA_INPUT');
  testWidgets(
    'saved legacy card expands representative results and compares printing evidence',
    (WidgetTester tester) async {
      final Map<String, Object?> input = jsonDecode(
        await File(fixture).readAsString(),
      ) as Map<String, Object?>;
      final ScanCrop crop = ScanCrop.fromMap(
        input['crop'] as Map<String, Object?>,
      );
      final Map<String, Object?> cached =
          input['resolution'] as Map<String, Object?>;
      final List<MtgCard> representatives =
          (cached['candidates'] as List<Object?>).map((Object? item) {
            final Map<String, Object?> value = item! as Map<String, Object?>;
            return MtgCard.fromJson(value['card'] as Map<String, Object?>);
          }).toList();
      final List<MtgCard> printings =
          (input['referencePrintings'] as List<Object?>)
              .map(
                (Object? item) =>
                    MtgCard.fromJson(item! as Map<String, Object?>),
              )
              .toList();
      final _ObservedCatalog catalog = _ObservedCatalog(
        representatives,
        <MtgCard>[...printings, ...representatives],
      );
      final Directory scratch = await Directory.systemTemp.createTemp(
        'collector_legacy_print_qa_',
      );
      Hive.init(scratch.path);
      final File original = File(crop.imagePath);
      final String before = (await sha256.bind(original.openRead()).first)
          .toString();
      final Stopwatch elapsed = Stopwatch()..start();
      try {
        await tester.pumpWidget(const SizedBox());
        final ScanResolution result = await ScanResolver(catalog: catalog)
            .resolve(crop);
        elapsed.stop();
        final ScanCandidate winner = result.candidates.first;
        final Map<String, Object?> report = <String, Object?>{
          'elapsedMilliseconds': elapsed.elapsedMilliseconds,
          'queries': catalog.queries,
          'status': result.status.name,
          'hasExactPrintingEvidence': hasExactPrintingEvidence(crop, result),
          'candidates': result.candidates
              .map(
                (ScanCandidate candidate) => <String, Object?>{
                  'name': candidate.card.name,
                  'set': candidate.card.set,
                  'collectorNumber': candidate.card.collectorNumber,
                  'score': candidate.score,
                  'evidence': candidate.evidence
                      .map((ScanEvidence item) => item.name)
                      .toList(),
                  'artworkDistance': candidate.artworkDistance,
                  'symbolDistance': candidate.symbolDistance,
                },
              )
              .toList(),
        };
        debugPrint('LEGACY_PRINT_QA_REPORT ${jsonEncode(report)}');
        expect(winner.card.name, 'Circle of Protection: Blue');
        expect(winner.card.set, 'ice');
        expect(winner.card.collectorNumber, '13');
        expect(winner.artworkDistance, isNotNull);
        expect(winner.symbolDistance, isNotNull);
        expect(result.status, ScanResolutionStatus.needsReview);
        expect(hasExactPrintingEvidence(crop, result), isFalse);
        expect(
          (await sha256.bind(original.openRead()).first).toString(),
          before,
        );
      } finally {
        await Hive.close();
        await scratch.delete(recursive: true);
      }
    },
    skip: fixture.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
