import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_symbol_matcher.dart';

class _Card extends Fake implements MtgCard {
  _Card(this.id, this.set);
  @override
  final String id;
  @override
  final String set;
  @override
  Layout get layout => Layout.normal;
}

ScanCrop _crop({
  String path = '',
  List<String> warnings = const <String>[],
  double confidence = .95,
}) => ScanCrop(
  imagePath: path,
  width: 1000,
  height: 1400,
  rectified: true,
  sourceCorners: const <ScanPoint>[],
  warnings: warnings,
  lines: <ScanTextLine>[
    ScanTextLine(
      text: 'Instant',
      confidence: confidence,
      bounds: const ScanBounds(.08, .54, .4, .025),
    ),
  ],
);

ScanCrop _repairedCrop({
  String path = 'saved-card.jpg',
  List<String> warnings = const <String>['geometry_adjusted'],
  bool body = true,
}) => ScanCrop(
  imagePath: path,
  width: 2879,
  height: 4021,
  rectified: true,
  sourceCorners: const <ScanPoint>[
    ScanPoint(.2, .2),
    ScanPoint(.7, .2),
    ScanPoint(.7, .8),
    ScanPoint(.2, .8),
  ],
  warnings: warnings,
  lines: <ScanTextLine>[
    const ScanTextLine(
      text: 'Enchantment',
      confidence: 1,
      bounds: ScanBounds(.054, .552, .298, .034),
    ),
    if (body) ...const <ScanTextLine>[
      ScanTextLine(
        text: '1: Prevent all damage against you',
        confidence: 1,
        bounds: ScanBounds(.113, .653, .752, .04),
      ),
      ScanTextLine(
        text: 'from one blue source. If a source',
        confidence: 1,
        bounds: ScanBounds(.111, .692, .739, .035),
      ),
      ScanTextLine(
        text: 'deals damage to you more than',
        confidence: 1,
        bounds: ScanBounds(.111, .735, .693, .035),
      ),
    ],
  ],
);

const String _svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20"><path fill="black" d="M10 1L19 19H1Z"/></svg>';

void main() {
  testWidgets(
    'next symbol pair loads during comparison and remains leased through a failed download',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'collector-symbol-pair-',
        );
        Hive.init(directory.path);
        final File query = await File('${directory.path}/query.jpg')
            .writeAsBytes(<int>[1]);
        final Directory references = await Directory(
          '${directory.path}/scanner_symbols',
        ).create();
        final File nextImage = File('${references.path}/lea.png');
        final Box<String> box = await Hive.openBox<String>(
          'scanner_symbols_v1',
        );
        await box.put('lea', nextImage.path);
        for (int index = 0; index < 128; index++) {
          await box.put('old$index', 'unused');
        }
        final List<String> loaded = <String>[];
        final List<String> compared = <String>[];
        final Map<String, Completer<void>> gates = <String, Completer<void>>{
          for (final String code in <String>['m11', 'm10', 'lea'])
            code: Completer<void>(),
        };
        final Completer<void> pair = Completer<void>();
        final Completer<void> last = Completer<void>();
        final Completer<void> comparing = Completer<void>();
        final Completer<void> firstComparison = Completer<void>();
        final Completer<void> lastComparison = Completer<void>();
        final Completer<void> finishLast = Completer<void>();
        int active = 0;
        int maximum = 0;
        final CachedScanSymbolMatcher matcher = CachedScanSymbolMatcher(
          iconLoader: (String code) async =>
              Uri.https('svgs.scryfall.io', '/sets/$code.svg'),
          clientFactory: () => MockClient((http.Request request) async {
            final String code = request.url.pathSegments.last.replaceAll(
              '.svg',
              '',
            );
            loaded.add(code);
            active++;
            if (active > maximum) maximum = active;
            if (loaded.length == 2) pair.complete();
            if (loaded.length == 3) last.complete();
            await gates[code]!.future;
            active--;
            return http.Response(_svg, code == 'm10' ? 500 : 200);
          }),
          comparator:
              ({
                required String queryImagePath,
                required String referenceImagePath,
                required ScanBounds queryRegion,
              }) async {
                final String code = File(referenceImagePath)
                    .uri
                    .pathSegments
                    .last
                    .replaceAll('.png', '');
                compared.add(code);
                if (code == 'm11') {
                  comparing.complete();
                  await firstComparison.future;
                }
                if (code == 'lea') {
                  lastComparison.complete();
                  await finishLast.future;
                  expect(await nextImage.exists(), isTrue);
                }
                return .2;
              },
        );
        final Future<Map<String, double>> result = matcher.compare(
          _crop(path: query.path),
          <MtgCard>[
            _Card('one', 'm11'),
            _Card('shared', 'm11'),
            _Card('failed', 'm10'),
            _Card('last', 'lea'),
            _Card('excluded', 'leb'),
          ],
        );
        try {
          await pair.future.timeout(const Duration(seconds: 2));
          expect(loaded, unorderedEquals(<String>['m11', 'm10']));
          gates['m10']!.complete();
          await Future<void>.delayed(Duration.zero);
          expect(compared, isEmpty);
          gates['m11']!.complete();
          await comparing.future.timeout(const Duration(seconds: 2));
          await last.future.timeout(const Duration(seconds: 2));
          expect(compared, <String>['m11']);
          expect(box.containsKey('lea'), isTrue);
          firstComparison.complete();
          gates['lea']!.complete();
          await lastComparison.future.timeout(const Duration(seconds: 2));
          final CachedScanSymbolMatcher overflow = CachedScanSymbolMatcher(
            iconLoader: (String code) async =>
                Uri.https('svgs.scryfall.io', '/sets/$code.svg'),
            clientFactory: () => MockClient(
              (http.Request request) async => http.Response(_svg, 200),
            ),
            comparator: ({
              required String queryImagePath,
              required String referenceImagePath,
              required ScanBounds queryRegion,
            }) async => .4,
          );
          expect(
            await overflow.compare(_crop(path: query.path), <MtgCard>[
              _Card('overflow', 'leb'),
            ]),
            <String, double>{'overflow': .4},
          );
          expect(box.length, lessThanOrEqualTo(128));
          expect(box.containsKey('lea'), isTrue);
          expect(await nextImage.exists(), isTrue);
          finishLast.complete();
          expect(
            await result.timeout(const Duration(seconds: 2)),
            <String, double>{'one': .2, 'shared': .2, 'last': .2},
          );
          expect(compared, <String>['m11', 'lea']);
          expect(maximum, 2);
        } finally {
          for (final Completer<void> gate in gates.values) {
            if (!gate.isCompleted) gate.complete();
          }
          if (!firstComparison.isCompleted) firstComparison.complete();
          if (!finishLast.isCompleted) finishLast.complete();
          await result.timeout(const Duration(seconds: 2));
          await Hive.close();
          await directory.delete(recursive: true);
        }
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'symbol cache eviction keeps a shared reference pinned until both compares finish',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'collector-symbol-leases-',
        );
        Hive.init(directory.path);
        final File query = await File('${directory.path}/query.jpg')
            .writeAsBytes(<int>[1]);
        final File secondQuery = await File(
          '${directory.path}/second-query.jpg',
        ).writeAsBytes(<int>[1]);
        final Directory references = await Directory(
          '${directory.path}/scanner_symbols',
        ).create();
        final File heldImage = await File('${references.path}/m11.png')
            .writeAsBytes(<int>[1]);
        final Box<String> box = await Hive.openBox<String>(
          'scanner_symbols_v1',
        );
        await box.put('m11', heldImage.path);
        for (int index = 0; index < 128; index++) {
          await box.put('old$index', 'unused');
        }
        final List<Completer<void>> gates = <Completer<void>>[
          Completer<void>(),
          Completer<void>(),
        ];
        final Completer<void> both = Completer<void>();
        int count = 0;
        final CachedScanSymbolMatcher matcher = CachedScanSymbolMatcher(
          comparator:
              ({
                required String queryImagePath,
                required String referenceImagePath,
                required ScanBounds queryRegion,
              }) async {
                expect(
                  queryImagePath,
                  isIn(<String>[query.path, secondQuery.path]),
                );
                final int index = queryImagePath == query.path ? 0 : 1;
                count++;
                if (count == 2) both.complete();
                await gates[index].future;
                expect(await heldImage.exists(), isTrue);
                return .2;
              },
          iconLoader: (String code) async =>
              throw StateError('cached references must not reload'),
        );
        final Future<Map<String, double>> first = matcher.compare(
          _crop(path: query.path),
          <MtgCard>[_Card('first', 'm11')],
        );
        final Future<Map<String, double>> second = matcher.compare(
          _crop(path: secondQuery.path),
          <MtgCard>[_Card('second', 'm11')],
        );
        try {
          await both.future.timeout(const Duration(seconds: 2));
          gates[0].complete();
          expect(
            (await first.timeout(const Duration(seconds: 2)))['first'],
            .2,
          );
          expect(await heldImage.exists(), isTrue);
          expect(box.containsKey('m11'), isTrue);
          expect(box.length, lessThanOrEqualTo(128));
          gates[1].complete();
          expect(
            (await second.timeout(const Duration(seconds: 2)))['second'],
            .2,
          );
          expect(box.length, lessThanOrEqualTo(128));
        } finally {
          for (final Completer<void> gate in gates) {
            if (!gate.isCompleted) gate.complete();
          }
          await Future.wait<Map<String, double>>(<Future<Map<String, double>>>[
            first,
            second,
          ]).timeout(const Duration(seconds: 2));
          await Hive.close();
          await directory.delete(recursive: true);
        }
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  test('literal legacy and narrow modern type lines locate symbols without inventing type from rules', () {
    for (final String text in <String>[
      'Enchant Creature',
      'Summon Wizard',
      'Sorcery',
    ]) {
      final ScanCrop crop = ScanCrop(
        imagePath: '',
        width: 1000,
        height: 1400,
        rectified: true,
        sourceCorners: const <ScanPoint>[],
        lines: <ScanTextLine>[
          ScanTextLine(
            text: text,
            confidence: 1,
            bounds: const ScanBounds(.0473, .5807, .1708, .0377),
          ),
        ],
      );
      expect(
        CachedScanSymbolMatcher.symbolRegion(crop),
        isNotNull,
        reason: text,
      );
    }
    final ScanCrop prose = ScanCrop(
      imagePath: '',
      width: 1000,
      height: 1400,
      rectified: true,
      sourceCorners: const <ScanPoint>[],
      lines: const <ScanTextLine>[
        ScanTextLine(
          text: 'Target creature gains banding',
          confidence: 1,
          bounds: ScanBounds(.1, .58, .7, .03),
        ),
      ],
    );
    expect(CachedScanSymbolMatcher.symbolRegion(prose), isNull);
  });
  test(
    'symbol region follows confident type-line and rejects unsafe crops',
    () {
      final ScanBounds region = CachedScanSymbolMatcher.symbolRegion(_crop())!;
      expect(region.x, greaterThan(.75));
      expect(region.y, closeTo(.525, .001));
      expect(region.x + region.width, closeTo(.95, .001));
      expect(
        CachedScanSymbolMatcher.symbolRegion(_crop(confidence: .5)),
        isNull,
      );
      expect(
        CachedScanSymbolMatcher.symbolRegion(
          _crop(warnings: <String>['incomplete_card']),
        ),
        isNull,
      );
    },
  );

  testWidgets(
    'symbol comparisons reuse references and cap each crop at three sets',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'collector-symbol-test-',
        );
        Hive.init(directory.path);
        try {
          final File query = await File('${directory.path}/query.jpg')
              .writeAsBytes(<int>[1]);
          int downloads = 0;
          int metadata = 0;
          int comparisons = 0;
          final CachedScanSymbolMatcher matcher = CachedScanSymbolMatcher(
            iconLoader: (String code) async {
              metadata++;
              return Uri.parse('https://svgs.scryfall.io/sets/$code.svg');
            },
            clientFactory: () => MockClient((http.Request request) async {
              downloads++;
              return http.Response(_svg, 200);
            }),
            comparator:
                ({
                  required String queryImagePath,
                  required String referenceImagePath,
                  required ScanBounds queryRegion,
                }) async {
                  comparisons++;
                  final List<int> png = await File(referenceImagePath)
                      .readAsBytes();
                  expect(png.take(8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
                  expect(queryImagePath, query.path);
                  return .1;
                },
          );
          final List<MtgCard> candidates = <MtgCard>[
            _Card('one', 'm11'),
            _Card('two', 'm11'),
            _Card('three', 'm10'),
            _Card('four', 'lea'),
            _Card('five', 'leb'),
          ];
          final Map<String, double> first = await matcher
              .compare(_crop(path: query.path), candidates)
              .timeout(const Duration(seconds: 5));
          expect(first.keys, <String>['one', 'two', 'three', 'four']);
          expect(downloads, 3);
          expect(metadata, 3);
          expect(comparisons, 3);
          final Map<String, double> second = await matcher.compare(
            _crop(path: query.path),
            candidates,
          );
          expect(second, first);
          expect(downloads, 3);
          expect(metadata, 3);
          expect(comparisons, 6);
          await matcher.compare(_crop(), candidates);
          expect(comparisons, 6);
        } finally {
          await Hive.close();
          await directory.delete(recursive: true);
        }
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  test(
    'repaired saved cards require verified body geometry for a symbol ROI',
    () {
      final ScanBounds region = CachedScanSymbolMatcher.symbolRegion(
        _repairedCrop(),
      )!;
      expect(region.x, .78);
      expect(region.y, closeTo(.537, .001));
      expect(region.height, closeTo(.069, .001));
      expect(region.x + region.width, closeTo(.95, .001));
      expect(
        CachedScanSymbolMatcher.symbolRegion(_repairedCrop(body: false)),
        isNull,
      );
      expect(
        CachedScanSymbolMatcher.symbolRegion(_repairedCrop(path: '')),
        isNull,
      );
      expect(
        CachedScanSymbolMatcher.symbolRegion(
          _repairedCrop(warnings: const <String>['no_card_rectangle']),
        ),
        isNull,
      );
    },
  );

  testWidgets(
    'verified repaired crops compare later print sets and cap distinct sets',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'collector-repaired-symbol-test-',
        );
        Hive.init(directory.path);
        try {
          final File query = await File('${directory.path}/query.jpg')
              .writeAsBytes(<int>[1]);
          final List<String> loaded = <String>[];
          int comparisons = 0;
          final CachedScanSymbolMatcher matcher = CachedScanSymbolMatcher(
            iconLoader: (String code) async {
              loaded.add(code);
              return Uri.parse('https://svgs.scryfall.io/sets/$code.svg');
            },
            clientFactory: () => MockClient(
              (http.Request request) async => http.Response(_svg, 200),
            ),
            comparator:
                ({
                  required String queryImagePath,
                  required String referenceImagePath,
                  required ScanBounds queryRegion,
                }) async {
                  comparisons++;
                  expect(queryImagePath, query.path);
                  expect(queryRegion.y, closeTo(.537, .001));
                  return referenceImagePath.endsWith('/ice.png') ? .01 : .5;
                },
          );
          final List<MtgCard> candidates = <MtgCard>[
            for (int index = 0; index < 8; index++)
              _Card('earlier-$index', 's${index.toString().padLeft(2, '0')}'),
            _Card('ice-print', 'ice'),
            _Card('same-ice-set', 'ice'),
            for (int index = 8; index < 34; index++)
              _Card('later-$index', 's${index.toString().padLeft(2, '0')}'),
          ];
          final Map<String, double> distances = await matcher.compare(
            _repairedCrop(path: query.path),
            candidates,
          );
          expect(distances['ice-print'], .01);
          expect(distances['same-ice-set'], .01);
          expect(loaded, contains('ice'));
          expect(loaded, hasLength(32));
          expect(comparisons, 32);
          expect(distances, hasLength(33));
          expect(distances, isNot(contains('later-31')));
          final Map<String, double> oversized = await matcher.compare(
            _repairedCrop(path: query.path),
            <MtgCard>[
              for (int index = 0; index < 97; index++) _Card('$index', 'ice'),
            ],
          );
          expect(oversized, isEmpty);
          expect(comparisons, 32);
        } finally {
          await Hive.close();
          await directory.delete(recursive: true);
        }
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
