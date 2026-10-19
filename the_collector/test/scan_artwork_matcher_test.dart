import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/scan_artwork_matcher.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';

class _Card extends Fake implements MtgCard {
  _Card(this.id, this.illustrationId);
  @override
  final String id;
  @override
  final String illustrationId;
  @override
  List<Game> get games => const <Game>[Game.paper];
  @override
  List<CardFace>? get cardFaces => null;
  @override
  ImageUris get imageUris {
    final Uri uri = Uri.https(
      'cards.scryfall.io',
      '/art_crop/$illustrationId.jpg',
    );
    return ImageUris(
      small: uri,
      normal: uri,
      large: uri,
      png: uri,
      artCrop: uri,
      borderCrop: uri,
    );
  }
}

class _DigitalCard extends _Card {
  _DigitalCard(super.id, super.illustrationId);
  @override
  List<Game> get games => const <Game>[Game.arena];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String queryPath;
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    directory = await Directory.systemTemp.createTemp('collector-artwork-');
    Hive.init(directory.path);
    queryPath = (await File(
      '${directory.path}/query.jpg',
    ).writeAsBytes(<int>[1, 2, 3])).path;
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await Hive.close();
    await directory.delete(recursive: true);
  });
  ScanCrop crop({String? path, List<String> warnings = const <String>[]}) =>
      ScanCrop(
        imagePath: path ?? queryPath,
        width: 745,
        height: 1040,
        rectified: true,
        sourceCorners: const <ScanPoint>[],
        lines: const <ScanTextLine>[],
        warnings: warnings,
      );

  test(
    'digital-only artwork cannot become a physical discovery candidate',
    () async {
      final CachedScanArtworkMatcher matcher = CachedScanArtworkMatcher(
        clientFactory: () => MockClient(
          (http.Request _) async =>
              throw StateError('No reference downloads expected'),
        ),
        structureComparator: ({
          required String queryImagePath,
          required Uint8List referencePixels,
          required ScanBounds queryRegion,
          required int rotationDegrees,
        }) async => throw StateError('Digital artwork must not be compared'),
      );
      expect(
        await matcher.compareDiscovered(
          crop(),
          <MtgCard>[_DigitalCard('digital', 'digital-art')],
          referencePixelsByIllustration: <String, Uint8List>{
            'digital-art': Uint8List(2304),
          },
        ),
        isEmpty,
      );
    },
  );

  test('discovered artwork retains the measured region and rotation while bounding reference comparisons', () async {
    int networkRequests = 0;
    final List<({int rotation, ScanBounds region})> measured =
        <({int rotation, ScanBounds region})>[];
    final CachedScanArtworkMatcher matcher = CachedScanArtworkMatcher(
      clientFactory: () => MockClient((http.Request request) async {
        networkRequests++;
        throw StateError(
          'Packaged discovery must not request reference images.',
        );
      }),
      comparator:
          ({
            required String queryImagePath,
            required String referenceImagePath,
          }) async => throw StateError(
            'Default crop must not replace the selected artwork region',
          ),
      structureComparator:
          ({
            required String queryImagePath,
            required Uint8List referencePixels,
            required ScanBounds queryRegion,
            required int rotationDegrees,
          }) async {
            expect(queryImagePath, queryPath);
            expect(referencePixels.length, 2304);
            measured.add((rotation: rotationDegrees, region: queryRegion));
            return .2;
          },
    );
    final List<MtgCard> cards = <MtgCard>[
      for (int index = 0; index < 21; index++)
        _Card('card-$index', 'profile-art-$index'),
    ];
    final ScanCrop uncertain = crop(
      warnings: const <String>['capture_ownership_uncertain'],
    );
    expect(await matcher.compare(uncertain, cards), isEmpty);
    final Map<String, double> distances = await matcher.compareDiscovered(
      uncertain,
      cards,
      queryRegion: const ScanBounds(.07, .10, .86, .65),
      rotationDegrees: 180,
      referencePixelsByIllustration: <String, Uint8List>{
        for (int index = 0; index < 21; index++)
          'profile-art-$index': Uint8List(2304),
      },
    );
    expect(distances.length, 20);
    expect(measured.length, 20);
    expect(
      measured.every(
        (({int rotation, ScanBounds region}) value) =>
            value.rotation == 180 &&
            value.region.x == .07 &&
            value.region.height == .65,
      ),
      isTrue,
    );
    expect(distances.containsKey('card-20'), isFalse);
    expect(networkRequests, 0);
    expect(Hive.isBoxOpen('scanner_artwork_v1'), isFalse);
  });

  test(
    'structural discovery abstains on weak or mismatched native receipts',
    () async {
      Map<String, Object?> response = <String, Object?>{};
      const ScanBounds region = ScanBounds(.07, .075, .86, .44);
      final Uint8List pixels = Uint8List(2304);
      final Map<String, double> requested = <String, double>{
        'x': region.x,
        'y': region.y,
        'width': region.width,
        'height': region.height,
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, (
            MethodCall call,
          ) async {
            expect(call.method, 'compareArtworkStructure');
            expect(
              (call.arguments as Map<Object?, Object?>)['referencePixels'],
              pixels,
            );
            expect(
              (call.arguments as Map<Object?, Object?>).containsKey(
                'referenceImagePath',
              ),
              isFalse,
            );
            return response;
          });
      final CachedScanArtworkMatcher matcher = CachedScanArtworkMatcher(
        clientFactory: () => MockClient(
          (http.Request request) async => http.Response.bytes(<int>[1], 200),
        ),
      );
      final List<MtgCard> candidates = <MtgCard>[_Card('card', 'structure')];
      Future<Map<String, double>> compare() => matcher.compareDiscovered(
        crop(),
        candidates,
        queryRegion: region,
        rotationDegrees: 180,
        referencePixelsByIllustration: <String, Uint8List>{'structure': pixels},
      );
      final Map<String, Object?> valid = <String, Object?>{
        'schema': 'gray-alignment-v1',
        'correlation': .85,
        'coverage': .5,
        'referenceDigest': sha256.convert(pixels).toString(),
        'rotationDegrees': 180,
        'region': requested,
      };
      try {
        response = valid;
        expect((await compare())['card'], closeTo(.15, .00001));
        for (final Map<String, Object?> invalid in <Map<String, Object?>>[
          <String, Object?>{...valid, 'schema': 'other'},
          <String, Object?>{...valid, 'referenceDigest': 'different'},
          <String, Object?>{...valid, 'rotationDegrees': 0},
          <String, Object?>{
            ...valid,
            'region': <String, double>{...requested, 'y': .14},
          },
          <String, Object?>{...valid, 'correlation': double.nan},
          <String, Object?>{...valid, 'coverage': .1},
          <String, Object?>{...valid, 'correlation': .65},
        ]) {
          response = invalid;
          expect(await compare(), isEmpty);
        }
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
      }
    },
  );

  test('next artwork pair loads during comparison and remains leased through failure and completion', () async {
    final Box<String> box = await Hive.openBox<String>('scanner_artwork_v1');
    final Directory references = await Directory(
      '${directory.path}/scanner_artwork',
    ).create();
    final String nextKey = sha256.convert(utf8.encode('art-c')).toString();
    final File nextImage = File('${references.path}/$nextKey.jpg');
    await box.put(nextKey, nextImage.path);
    for (int index = 0; index < 255; index++) {
      await box.put('old-$index', 'unused');
    }
    final List<String> downloads = <String>[];
    final List<int> comparisons = <int>[];
    final Map<String, Completer<void>> gates = <String, Completer<void>>{
      for (final String art in <String>['art-a', 'art-b', 'art-c'])
        art: Completer<void>(),
    };
    final Completer<void> firstPair = Completer<void>();
    final Completer<void> third = Completer<void>();
    final Completer<void> comparing = Completer<void>();
    final Completer<void> firstComparison = Completer<void>();
    final Completer<void> failedComparison = Completer<void>();
    final Completer<void> lastComparison = Completer<void>();
    final Completer<void> finishLast = Completer<void>();
    int active = 0;
    int maximum = 0;
    final CachedScanArtworkMatcher matcher = CachedScanArtworkMatcher(
      clientFactory: () => MockClient((http.Request request) async {
        final String art = request.url.pathSegments.last.replaceAll('.jpg', '');
        downloads.add(art);
        active++;
        if (active > maximum) maximum = active;
        if (downloads.length == 2) firstPair.complete();
        if (downloads.length == 3) third.complete();
        await gates[art]!.future;
        active--;
        return http.Response.bytes(<int>[
          <String>['art-a', 'art-b', 'art-c'].indexOf(art) + 1,
        ], 200);
      }),
      comparator:
          ({
            required String queryImagePath,
            required String referenceImagePath,
          }) async {
            final int value = (await File(
              referenceImagePath,
            ).readAsBytes()).single;
            comparisons.add(value);
            if (value == 1) {
              comparing.complete();
              await firstComparison.future;
            }
            if (value == 2) {
              failedComparison.complete();
              throw StateError('native comparison failed');
            }
            if (value == 3) {
              lastComparison.complete();
              await finishLast.future;
              expect(await nextImage.exists(), isTrue);
            }
            return value / 10;
          },
    );
    final Future<Map<String, double>> result = matcher.compare(
      crop(),
      <MtgCard>[
        _Card('a', 'art-a'),
        _Card('shared-a', 'art-a'),
        _Card('b', 'art-b'),
        _Card('c', 'art-c'),
        _Card('excluded', 'art-d'),
      ],
    );
    bool completed = false;
    final Future<void> completion = result.then((_) {
      completed = true;
    });
    try {
      await firstPair.future.timeout(const Duration(seconds: 2));
      expect(downloads, unorderedEquals(<String>['art-a', 'art-b']));
      gates['art-b']!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(comparisons, isEmpty);
      gates['art-a']!.complete();
      await comparing.future.timeout(const Duration(seconds: 2));
      expect(comparisons, <int>[1]);
      await third.future.timeout(const Duration(seconds: 2));
      expect(comparisons, <int>[1]);
      expect(box.containsKey(nextKey), isTrue);
      firstComparison.complete();
      await failedComparison.future.timeout(const Duration(seconds: 2));
      expect(completed, isFalse);
      expect(box.containsKey(nextKey), isTrue);
      gates['art-c']!.complete();
      await lastComparison.future.timeout(const Duration(seconds: 2));
      final CachedScanArtworkMatcher overflow = CachedScanArtworkMatcher(
        clientFactory: () => MockClient(
          (http.Request request) async => http.Response.bytes(<int>[4], 200),
        ),
        comparator: ({
          required String queryImagePath,
          required String referenceImagePath,
        }) async => .4,
      );
      expect(
        await overflow.compare(crop(), <MtgCard>[
          _Card('overflow', 'art-overflow'),
        ]),
        <String, double>{'overflow': .4},
      );
      expect(box.length, lessThanOrEqualTo(256));
      expect(box.containsKey(nextKey), isTrue);
      expect(await nextImage.exists(), isTrue);
      finishLast.complete();
      expect(await result.timeout(const Duration(seconds: 2)), <String, double>{
        'a': .1,
        'shared-a': .1,
        'c': .3,
      });
      expect(comparisons, <int>[1, 2, 3]);
      expect(maximum, 2);
    } finally {
      for (final Completer<void> gate in gates.values) {
        if (!gate.isCompleted) gate.complete();
      }
      if (!firstComparison.isCompleted) firstComparison.complete();
      if (!finishLast.isCompleted) finishLast.complete();
      await result.timeout(const Duration(seconds: 2));
      await completion;
    }
  });

  test('cache eviction retains a shared reference until its last comparison releases it', () async {
    final String secondQueryPath = (await File(
      '${directory.path}/second-query.jpg',
    ).writeAsBytes(<int>[1, 2, 3])).path;
    final Box<String> box = await Hive.openBox<String>('scanner_artwork_v1');
    final Directory references = await Directory(
      '${directory.path}/scanner_artwork',
    ).create();
    final String key = sha256.convert(utf8.encode('held-art')).toString();
    final File heldImage = await File('${references.path}/$key.jpg')
        .writeAsBytes(<int>[1]);
    await box.put(key, heldImage.path);
    for (int index = 0; index < 255; index++) {
      await box.put('old-$index', 'unused');
    }
    final List<Completer<void>> gates = <Completer<void>>[
      Completer<void>(),
      Completer<void>(),
    ];
    final Completer<void> both = Completer<void>();
    int held = 0;
    final CachedScanArtworkMatcher matcher = CachedScanArtworkMatcher(
      clientFactory: () => MockClient(
        (http.Request request) async => http.Response.bytes(<int>[2], 200),
      ),
      comparator:
          ({
            required String queryImagePath,
            required String referenceImagePath,
          }) async {
            if (referenceImagePath == heldImage.path) {
              expect(
                queryImagePath,
                isIn(<String>[queryPath, secondQueryPath]),
              );
              final int index = queryImagePath == queryPath ? 0 : 1;
              held++;
              if (held == 2) both.complete();
              await gates[index].future;
              expect(await heldImage.exists(), isTrue);
            }
            return .2;
          },
    );
    final Future<Map<String, double>> first = matcher.compare(crop(), <MtgCard>[
      _Card('first', 'held-art'),
    ]);
    final Future<Map<String, double>> second = matcher.compare(
      crop(path: secondQueryPath),
      <MtgCard>[_Card('second', 'held-art')],
    );
    try {
      await both.future.timeout(const Duration(seconds: 2));
      gates[0].complete();
      expect((await first.timeout(const Duration(seconds: 2)))['first'], .2);
      expect(
        (await matcher.compare(crop(), <MtgCard>[
          _Card('new', 'new-art'),
        ]))['new'],
        .2,
      );
      expect(await heldImage.exists(), isTrue);
      expect(box.containsKey(key), isTrue);
      expect(box.length, lessThanOrEqualTo(256));
      gates[1].complete();
      expect((await second.timeout(const Duration(seconds: 2)))['second'], .2);
      expect(box.length, lessThanOrEqualTo(256));
    } finally {
      for (final Completer<void> gate in gates) {
        if (!gate.isCompleted) gate.complete();
      }
      await Future.wait<Map<String, double>>(<Future<Map<String, double>>>[
        first,
        second,
      ]).timeout(const Duration(seconds: 2));
    }
  });

  test('shared artwork is compared once, references survive reopen and fanout is bounded', () async {
    int downloads = 0;
    int comparisons = 0;
    CachedScanArtworkMatcher matcher() => CachedScanArtworkMatcher(
      clientFactory: () => MockClient((http.Request request) async {
        downloads++;
        return http.Response.bytes(<int>[4, 5, 6], 200);
      }),
      comparator:
          ({
            required String queryImagePath,
            required String referenceImagePath,
          }) async {
            comparisons++;
            expect(queryImagePath, queryPath);
            expect(await File(referenceImagePath).readAsBytes(), <int>[
              4,
              5,
              6,
            ]);
            return .31;
          },
    );
    final List<MtgCard> candidates = <MtgCard>[
      _Card('printing-a', 'art-a'),
      _Card('printing-b', 'art-a'),
      _Card('printing-c', 'art-b'),
      _Card('printing-d', 'art-c'),
      _Card('printing-e', 'art-d'),
    ];
    final Map<String, double> first = await matcher().compare(
      crop(),
      candidates,
    );
    expect(first, <String, double>{
      'printing-a': .31,
      'printing-b': .31,
      'printing-c': .31,
      'printing-d': .31,
    });
    expect(downloads, 3);
    expect(comparisons, 3);
    await Hive.close();
    expect(await matcher().compare(crop(), candidates), first);
    expect(downloads, 3);
    expect(comparisons, 6);
  });

  ScanCrop repaired({
    bool rectified = true,
    int width = 1917,
    List<String> warnings = const <String>[
      'incomplete_card',
      'orientation_ensemble',
      'geometry_adjusted',
    ],
    List<ScanTextLine>? lines,
    List<ScanPoint> sourceCorners = const <ScanPoint>[
      ScanPoint(.1, .1),
      ScanPoint(.4, .1),
      ScanPoint(.4, .5),
      ScanPoint(.1, .5),
    ],
  }) => ScanCrop(
    imagePath: queryPath,
    width: width,
    height: 2678,
    rectified: rectified,
    sourceCorners: sourceCorners,
    warnings: warnings,
    lines:
        lines ??
        const <ScanTextLine>[
          ScanTextLine(
            text: 'Enchantment',
            confidence: 1,
            bounds: ScanBounds(.1, .54, .3, .03),
          ),
          ScanTextLine(
            text: 'Prevent all damage against you',
            confidence: 1,
            bounds: ScanBounds(.1, .64, .7, .03),
          ),
          ScanTextLine(
            text: 'deals damage to you more than',
            confidence: 1,
            bounds: ScanBounds(.1, .72, .7, .03),
          ),
          ScanTextLine(
            text: 'each time to prevent the damage.',
            confidence: 1,
            bounds: ScanBounds(.1, .79, .7, .03),
          ),
        ],
  );

  test('verified repaired body compares every bounded candidate illustration and shares references', () async {
    int downloads = 0;
    int comparisons = 0;
    final CachedScanArtworkMatcher matcher = CachedScanArtworkMatcher(
      clientFactory: () => MockClient((http.Request request) async {
        downloads++;
        return http.Response.bytes(<int>[1, 2, 3], 200);
      }),
      comparator:
          ({
            required String queryImagePath,
            required String referenceImagePath,
          }) async {
            comparisons++;
            return .31;
          },
    );
    final List<MtgCard> cards = <MtgCard>[
      for (int index = 0; index < 30; index++)
        _Card('card-$index', index == 1 ? 'art-0' : 'art-$index'),
    ];
    expect(hasVerifiedSavedBodyLayout(repaired()), isTrue);
    expect(await matcher.compare(repaired(), cards), isEmpty);
    expect(downloads, 0);
    final Map<String, double> distances = await matcher.compare(
      repaired(),
      cards,
      reliableBodyFallback: true,
    );
    expect(
      distances.keys.toSet(),
      cards.map((MtgCard card) => card.id).toSet(),
    );
    expect(distances.length, 30);
    expect(comparisons, 29);
    expect(downloads, 29);
    expect(
      await matcher.compare(
        repaired(),
        List<MtgCard>.filled(97, cards.first),
        reliableBodyFallback: true,
      ),
      isEmpty,
    );
    expect(comparisons, 29);
    expect(downloads, 29);
  });

  test('upright repaired saved photos allow visual comparison only', () async {
    final ScanCrop upright = repaired(
      warnings: const <String>['geometry_adjusted'],
      lines: const <ScanTextLine>[
        ScanTextLine(
          text: 'Enchantment',
          confidence: 1,
          bounds: ScanBounds(.1, .54, .3, .03),
        ),
        ScanTextLine(
          text: 'Prevent all damage against you',
          confidence: 1,
          bounds: ScanBounds(.1, .63, .7, .025),
        ),
        ScanTextLine(
          text: 'from one blue source of your choice.',
          confidence: 1,
          bounds: ScanBounds(.1, .67, .7, .025),
        ),
        ScanTextLine(
          text: 'If this source deals damage to you',
          confidence: 1,
          bounds: ScanBounds(.1, .71, .7, .025),
        ),
        ScanTextLine(
          text: 'more than once this turn, you may',
          confidence: 1,
          bounds: ScanBounds(.1, .75, .7, .025),
        ),
        ScanTextLine(
          text: 'pay each time to prevent the damage.',
          confidence: 1,
          bounds: ScanBounds(.1, .79, .7, .025),
        ),
      ],
    );
    expect(hasVerifiedSavedBodyLayout(upright), isFalse);
    expect(hasVerifiedSavedVisualLayout(upright), isTrue);
    int comparisons = 0;
    final CachedScanArtworkMatcher matcher = CachedScanArtworkMatcher(
      clientFactory: () => MockClient(
        (http.Request request) async =>
            http.Response.bytes(<int>[1, 2, 3], 200),
      ),
      comparator:
          ({
            required String queryImagePath,
            required String referenceImagePath,
          }) async {
            comparisons++;
            return .2;
          },
    );
    expect(
      await matcher.compare(upright, <MtgCard>[_Card('ice', 'ice-art')]),
      isEmpty,
    );
    expect(
      await matcher.compare(upright, <MtgCard>[
        _Card('ice', 'ice-art'),
      ], reliableBodyFallback: true),
      <String, double>{'ice': .2},
    );
    expect(comparisons, 1);
    expect(hasVerifiedSavedBodyLayout(upright), isFalse);
  });

  test(
    'expanded print coverage compares all 32 artworks across 96 variants',
    () async {
      int downloads = 0;
      int comparisons = 0;
      final CachedScanArtworkMatcher matcher = CachedScanArtworkMatcher(
        clientFactory: () => MockClient((http.Request request) async {
          downloads++;
          final int index = int.parse(
            request.url.pathSegments.last
                .replaceAll('art-', '')
                .replaceAll('.jpg', ''),
          );
          return http.Response.bytes(<int>[index], 200);
        }),
        comparator:
            ({
              required String queryImagePath,
              required String referenceImagePath,
            }) async {
              comparisons++;
              return (await File(referenceImagePath).readAsBytes()).single /
                  100;
            },
      );
      final List<MtgCard> cards = <MtgCard>[
        for (int index = 0; index < 96; index++)
          _Card('print-$index', 'art-${index % 32}'),
      ];
      final ScanCrop upright = repaired(
        warnings: const <String>['geometry_adjusted'],
      );
      final Map<String, double> first = await matcher.compare(
        upright,
        cards,
        reliableBodyFallback: true,
      );
      expect(first.length, 96);
      expect(first['print-95'], .31);
      expect(first['print-31'], first['print-95']);
      expect(downloads, 32);
      expect(comparisons, 32);
      final Map<String, double> reversed = await matcher.compare(
        upright,
        cards.reversed.toList(),
        reliableBodyFallback: true,
      );
      expect(reversed, first);
      expect(downloads, 32);
      expect(comparisons, 64);
    },
  );

  test(
    'expanded artwork over budget rejects the whole batch before download',
    () async {
      int downloads = 0;
      final CachedScanArtworkMatcher matcher = CachedScanArtworkMatcher(
        clientFactory: () => MockClient((http.Request request) async {
          downloads++;
          return http.Response.bytes(<int>[1], 200);
        }),
      );
      final List<MtgCard> cards = <MtgCard>[
        for (int index = 0; index < 33; index++)
          _Card('print-$index', 'art-$index'),
      ];
      for (final List<MtgCard> order in <List<MtgCard>>[
        cards,
        cards.reversed.toList(),
      ]) {
        expect(
          await matcher.compare(repaired(), order, reliableBodyFallback: true),
          isEmpty,
        );
      }
      expect(downloads, 0);
    },
  );

  test('repaired artwork rejects weak partial wrong-shape and flavor-only artifacts', () async {
    int downloads = 0;
    final CachedScanArtworkMatcher matcher = CachedScanArtworkMatcher(
      clientFactory: () => MockClient((http.Request request) async {
        downloads++;
        return http.Response.bytes(<int>[1], 200);
      }),
    );
    final List<ScanCrop> rejected = <ScanCrop>[
      repaired(rectified: false),
      repaired(width: 390),
      repaired(width: 2500),
      repaired(warnings: const <String>['incomplete_card']),
      repaired(warnings: const <String>['orientation_ensemble']),
      repaired(sourceCorners: const <ScanPoint>[]),
      repaired(
        sourceCorners: const <ScanPoint>[
          ScanPoint(.1, .1),
          ScanPoint(.4, .5),
          ScanPoint(.4, .1),
          ScanPoint(.1, .5),
        ],
      ),
      repaired(
        warnings: const <String>[
          'incomplete_card',
          'orientation_ensemble',
          'geometry_adjusted',
          'partial_card',
        ],
      ),
      repaired(
        warnings: const <String>[
          'incomplete_card',
          'orientation_ensemble',
          'geometry_adjusted',
          'no_card_rectangle',
        ],
      ),
      repaired(lines: repaired().lines.take(2).toList()),
      repaired(
        lines: repaired().lines
            .map(
              (ScanTextLine line) => ScanTextLine(
                text: line.text,
                confidence: line.text == 'Enchantment' ? .7 : 1,
                bounds: line.bounds,
              ),
            )
            .toList(),
      ),
      repaired(
        lines: repaired().lines
            .map(
              (ScanTextLine line) => ScanTextLine(
                text: line.text,
                confidence: line.bounds.y > .6 ? .7 : 1,
                bounds: line.bounds,
              ),
            )
            .toList(),
      ),
      repaired(
        lines: <ScanTextLine>[
          repaired().lines.first,
          const ScanTextLine(
            text: '"The enemy has many spies',
            confidence: 1,
            bounds: ScanBounds(.1, .64, .7, .03),
          ),
          ...repaired().lines.skip(1),
        ],
      ),
      repaired(
        lines: <ScanTextLine>[
          repaired().lines.first,
          for (final double y in <double>[.64, .72, .79])
            ScanTextLine(
              text: 'The ocean glimmers beneath the distant moon.',
              confidence: 1,
              bounds: ScanBounds(.1, y, .7, .03),
            ),
        ],
      ),
    ];
    for (final ScanCrop artifact in rejected) {
      expect(hasVerifiedSavedVisualLayout(artifact), isFalse);
      expect(
        await matcher.compare(artifact, <MtgCard>[
          _Card('a', 'art-a'),
        ], reliableBodyFallback: true),
        isEmpty,
      );
    }
    expect(downloads, 0);
  });

  test(
    'live observations and incomplete crops never download artwork',
    () async {
      int downloads = 0;
      final CachedScanArtworkMatcher matcher = CachedScanArtworkMatcher(
        clientFactory: () => MockClient((http.Request request) async {
          downloads++;
          return http.Response('', 200);
        }),
      );
      final List<MtgCard> cards = <MtgCard>[_Card('a', 'art-a')];
      expect(await matcher.compare(crop(path: ''), cards), isEmpty);
      expect(
        await matcher.compare(
          crop(warnings: <String>['incomplete_card']),
          cards,
        ),
        isEmpty,
      );
      expect(downloads, 0);
    },
  );

  test(
    'busy native feature extraction preserves absence of visual evidence',
    () async {
      final CachedScanArtworkMatcher matcher = CachedScanArtworkMatcher(
        clientFactory: () => MockClient(
          (http.Request request) async => http.Response.bytes(<int>[1], 200),
        ),
        comparator:
            ({
              required String queryImagePath,
              required String referenceImagePath,
            }) async {
              throw PlatformException(code: 'scanner_busy');
            },
      );
      expect(
        await matcher.compare(crop(), <MtgCard>[_Card('a', 'art-a')]),
        isEmpty,
      );
    },
  );

  test('oversized artwork response creates no persisted reference', () async {
    int comparisons = 0;
    final CachedScanArtworkMatcher matcher = CachedScanArtworkMatcher(
      clientFactory: () => MockClient(
        (http.Request request) async =>
            http.Response.bytes(List<int>.filled(2097153, 0), 200),
      ),
      comparator:
          ({
            required String queryImagePath,
            required String referenceImagePath,
          }) async {
            comparisons++;
            return .1;
          },
    );
    expect(
      await matcher.compare(crop(), <MtgCard>[_Card('a', 'art-a')]),
      isEmpty,
    );
    expect(comparisons, 0);
    expect((await Hive.openBox<String>('scanner_artwork_v1')).length, 0);
    expect(
      await Directory('${directory.path}/scanner_artwork').list().toList(),
      isEmpty,
    );
  });
}
