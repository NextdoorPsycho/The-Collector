import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/scan_artwork_matcher.dart';
import 'package:the_collector/utils/scanning/scan_local_catalog.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_symbol_matcher.dart';
import 'package:the_collector/utils/scanning/scan_visual_index.dart';

import 'helpers/scan_catalog_package.dart';

const String _art = 'b77b195c-509f-443a-b6d3-1a3c8416bec8';
const String _otherArt = '8d164dde-8d48-4168-ae58-1356442b305a';
const List<ScanPoint> _corners = <ScanPoint>[
  ScanPoint(0, 0),
  ScanPoint(1, 0),
  ScanPoint(1, 1),
  ScanPoint(0, 1),
];

Map<String, Object?> _card(
  int index, {
  String? name,
  String illustration = _art,
  String oracle = '7bc3f92f-68a2-4934-afc4-89f6d0e8cf98',
}) {
  final Map<String, Object?> card = jsonDecode(
    File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
  ) as Map<String, Object?>;
  card['id'] = '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
  card['collector_number'] = '$index';
  card['illustration_id'] = illustration;
  card['oracle_id'] = oracle;
  if (name != null) card['name'] = name;
  return card;
}

List<double> _vector(double value) => List<double>.filled(256, value);

Future<void> _rehash(Directory package, String name) async {
  final File manifest = File('${package.path}/manifest.json');
  final Map<String, Object?> value =
      jsonDecode(await manifest.readAsString()) as Map<String, Object?>;
  final Uint8List bytes = await File('${package.path}/$name').readAsBytes();
  for (final Object? raw in value['files']! as List<Object?>) {
    final Map<String, Object?> file = raw! as Map<String, Object?>;
    if (file['name'] == name) {
      file['bytes'] = bytes.length;
      file['sha256'] = sha256.convert(bytes).toString();
    }
  }
  await manifest.writeAsString(jsonEncode(value));
}

class _Assets extends CachingAssetBundle {
  final Map<String, Uint8List> files;
  _Assets(this.files);
  @override
  Future<ByteData> load(String key) async {
    final Uint8List? bytes = files[key];
    if (bytes == null) throw StateError('Missing fixture asset $key');
    return ByteData.sublistView(bytes);
  }
}

class _NoCatalog extends Fake implements ScanCatalog {
  @override
  Never noSuchMethod(Invocation invocation) => throw StateError(
    'Image-only discovery called text catalog: ${invocation.memberName}',
  );
}

class _Artwork implements ScanArtworkMatcher {
  int calls = 0;
  final Map<String, double> distances;
  _Artwork(this.distances);
  @override
  Future<Map<String, double>> compare(
    ScanCrop crop,
    List<MtgCard> cards, {
    bool reliableBodyFallback = false,
  }) async {
    calls++;
    return distances;
  }
}

class _Symbols implements ScanSymbolMatcher {
  @override
  Future<Map<String, double>> compare(
    ScanCrop crop,
    List<MtgCard> cards,
  ) async => const <String, double>{};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalScanCatalog catalog;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('collector-catalog-test-');
    catalog = LocalScanCatalog(
      directory: () async => Directory('${root.path}/installed'),
    );
  });
  tearDown(() async {
    catalog.close();
    await root.delete(recursive: true);
  });

  test('full metadata retains every printing across independently seekable chunks and pages', () async {
    final Directory package = await writeScanCatalogPackage(
      Directory('${root.path}/source'),
      <Map<String, Object?>>[
        for (int index = 0; index < 180; index++) _card(index),
      ],
      <String, List<double>>{_art: _vector(.25)},
    );
    await catalog.installDirectory(package);
    final LocalCatalogPage first = (await catalog.printingsReady(
      'Dusk // Dawn',
    ))!;
    final LocalCatalogPage second = (await catalog.printingsReady(
      'Dusk // Dawn',
      page: 2,
    ))!;
    expect(first.total, 180);
    expect(first.cards.length, 175);
    expect(first.hasMore, isTrue);
    expect(second.cards.map((MtgCard card) => card.collectorNumber), <String>[
      '175',
      '176',
      '177',
      '178',
      '179',
    ]);
    expect(second.hasMore, isFalse);
    expect((await catalog.exactReady('C19', '00179'))!.id, _card(179)['id']);
    expect(await catalog.cardNamesReady(), <String>['Dusk // Dawn']);
    expect(catalog.package!.visualComplete, isTrue);
  });

  test('one illustration preserves different oracle identities without claiming a printing', () async {
    await catalog.installDirectory(
      await writeScanCatalogPackage(
        Directory('${root.path}/source'),
        <Map<String, Object?>>[
          _card(1),
          _card(2),
          _card(
            3,
            name: 'Distinct identity',
            oracle: '10000000-0000-4000-8000-000000000003',
          ),
        ],
        <String, List<double>>{_art: _vector(.25)},
      ),
    );
    final List<LocalVisualHit> hits = await catalog.visualSearch(<List<double>>[
      _vector(.25),
    ], maximumDistance: .01);
    expect(hits.single.illustrationId, _art);
    expect(hits.single.cards.map((MtgCard card) => card.name), <String>[
      'Dusk // Dawn',
      'Distinct identity',
    ]);
    expect(hits.single.distance, lessThan(.005));
    expect(hits.single.referencePixels, hasLength(2304));
    expect(
      await catalog.visualSearch(<List<double>>[
        _vector(1),
      ], maximumDistance: .1),
      isEmpty,
    );
    await expectLater(
      catalog.visualSearch(<List<double>>[_vector(double.nan)]),
      throwsArgumentError,
    );
  });

  test(
    'seekable structural frames retain exact bytes without loading image files',
    () async {
      final Uint8List pixels = Uint8List.fromList(
        List<int>.generate(2304, (int index) => (index * 11) % 256),
      );
      await catalog.installDirectory(
        await writeScanCatalogPackage(
          Directory('${root.path}/source'),
          <Map<String, Object?>>[_card(1)],
          <String, List<double>>{_art: _vector(.25)},
          referencePixels: <String, Uint8List>{_art: pixels},
        ),
      );
      final List<LocalVisualHit> hits = await catalog.visualSearch(
        <List<double>>[_vector(.25)],
      );
      expect(hits.single.referencePixels, pixels);
      expect(await catalog.exactReady('c19', '1'), isNotNull);
    },
  );

  test('physical catalog filters games before footer uniqueness pagination and artwork representatives', () async {
    final Map<String, Object?> digital = _card(1)
      ..['games'] = <String>['arena'];
    final Map<String, Object?> paper = _card(2)
      ..['collector_number'] = '1'
      ..['games'] = <String>['paper', 'mtgo'];
    final Map<String, Object?> digitalOnly = _card(
      3,
      name: 'Digital only',
      illustration: _otherArt,
      oracle: '10000000-0000-4000-8000-000000000003',
    )..['games'] = <String>['mtgo'];
    await catalog.installDirectory(
      await writeScanCatalogPackage(
        Directory('${root.path}/source'),
        <Map<String, Object?>>[digital, paper, digitalOnly],
        <String, List<double>>{_art: _vector(.25), _otherArt: _vector(.75)},
      ),
    );
    final LocalCatalogPage page = (await catalog.printingsReady(
      'Dusk // Dawn',
    ))!;
    expect(page.total, 1);
    expect(page.cards.single.id, paper['id']);
    expect(page.cards.single.games, contains(Game.paper));
    expect((await catalog.exactReady('c19', '1'))!.id, paper['id']);
    expect(await catalog.exactReady('c19', '3'), isNull);
    expect((await catalog.printingsReady('Digital only'))!.cards, isEmpty);
    final List<LocalVisualHit> shared = await catalog.visualSearch(
      <List<double>>[_vector(.25)],
      maximumDistance: .01,
    );
    expect(shared.single.cards.map((MtgCard card) => card.id), <String>[
      paper['id']! as String,
    ]);
    expect(
      await catalog.visualSearch(<List<double>>[
        _vector(.75),
      ], maximumDistance: .01),
      isEmpty,
    );
    expect(catalog.package!.cardCount, 3);
    expect(catalog.package!.visualCount, 2);
  });

  test('checksummed invalid structural offsets cannot activate a replacement package', () async {
    await catalog.installDirectory(
      await writeScanCatalogPackage(
        Directory('${root.path}/source'),
        <Map<String, Object?>>[_card(1)],
        <String, List<double>>{_art: _vector(.25)},
      ),
    );
    final Directory broken = await writeScanCatalogPackage(
      Directory('${root.path}/broken'),
      <Map<String, Object?>>[_card(2)],
      <String, List<double>>{_art: _vector(.25)},
      version: 'abcdef0123456789abcdef01',
    );
    final File index = File('${broken.path}/visual.gray.index.json.gz');
    final Map<String, Object?> data = jsonDecode(
      utf8.decode(gzip.decode(await index.readAsBytes())),
    ) as Map<String, Object?>;
    final List<Object?> row =
        (data['rows']! as List<Object?>).single! as List<Object?>;
    for (final int offset in <int>[-1, 9, 10000000]) {
      row[1] = offset;
      await index.writeAsBytes(gzip.encode(utf8.encode(jsonEncode(data))));
      await _rehash(broken, 'visual.gray.index.json.gz');
      await expectLater(
        catalog.installDirectory(broken),
        throwsFormatException,
      );
      expect((await catalog.exactReady('c19', '1'))!.collectorNumber, '1');
    }
  });

  test('modified or truncated structural frames fail closed while metadata stays available', () async {
    await catalog.installDirectory(
      await writeScanCatalogPackage(
        Directory('${root.path}/source'),
        <Map<String, Object?>>[_card(1)],
        <String, List<double>>{_art: _vector(.25)},
      ),
    );
    final File shard = File(
      '${root.path}/installed/${catalog.package!.version}/visual.gray.0000.bin',
    );
    final Uint8List bytes = await shard.readAsBytes();
    bytes[bytes.length - 5] ^= 1;
    await shard.writeAsBytes(bytes);
    await expectLater(
      catalog.visualSearch(<List<double>>[_vector(.25)]),
      throwsFormatException,
    );
    await shard.writeAsBytes(bytes.sublist(0, bytes.length - 1));
    await expectLater(
      catalog.visualSearch(<List<double>>[_vector(.25)]),
      throwsFormatException,
    );
    expect((await catalog.exactReady('c19', '1'))!.collectorNumber, '1');
  });

  test('spatial normalization retrieves real structure across lighting shifts rather than nearest mean color', () async {
    final List<double> original = <double>[];
    final List<double> unrelated = <double>[];
    for (int cell = 0; cell < 64; cell++) {
      final double horizontal = (cell % 8) / 7;
      final double vertical = (cell ~/ 8) / 7;
      original.addAll(<double>[
        .15 + horizontal * .3,
        .2 + vertical * .15,
        .1 + horizontal * .05,
        .02,
      ]);
      unrelated.addAll(<double>[
        .33 + (1 - horizontal) * .3,
        .38 + vertical * .15,
        .28 + (1 - horizontal) * .05,
        .02,
      ]);
    }
    final List<double> query = <double>[
      for (int index = 0; index < 256; index++)
        original[index] + (index % 4 == 3 ? 0 : .18),
    ];
    await catalog.installDirectory(
      await writeScanCatalogPackage(
        Directory('${root.path}/source'),
        <Map<String, Object?>>[_card(1), _card(2, illustration: _otherArt)],
        <String, List<double>>{_art: original, _otherArt: unrelated},
      ),
    );
    final List<LocalVisualHit> result = await catalog.visualSearch(
      <List<double>>[query],
      queryRegions: const <ScanBounds>[
        IndexedScanVisualRetriever.extendedArtwork,
      ],
    );
    expect(result.first.illustrationId, _art);
    expect(result.first.queryRegion!.height, .65);
    expect(result.first.distance, greaterThan(result.last.distance));
  });

  test(
    'checksum failure leaves the active version and printing intact',
    () async {
      final Directory first = await writeScanCatalogPackage(
        Directory('${root.path}/first'),
        <Map<String, Object?>>[_card(1)],
        <String, List<double>>{_art: _vector(.25)},
      );
      await catalog.installDirectory(first);
      final Directory broken = await writeScanCatalogPackage(
        Directory('${root.path}/broken'),
        <Map<String, Object?>>[_card(2)],
        <String, List<double>>{_art: _vector(.4)},
        version: 'abcdef0123456789abcdef01',
      );
      await File('${broken.path}/visual.index.bin').writeAsBytes(<int>[1, 2]);
      await expectLater(
        catalog.installDirectory(broken),
        throwsFormatException,
      );
      expect((await catalog.exactReady('c19', '1'))!.id, _card(1)['id']);
      expect(
        await File('${root.path}/installed/current').readAsString(),
        '0123456789abcdef01234567',
      );
    },
  );

  test('checksummed but semantically invalid index never replaces the current pointer', () async {
    await catalog.installDirectory(
      await writeScanCatalogPackage(
        Directory('${root.path}/first'),
        <Map<String, Object?>>[_card(1)],
        <String, List<double>>{_art: _vector(.25)},
      ),
    );
    final Directory broken = await writeScanCatalogPackage(
      Directory('${root.path}/broken'),
      <Map<String, Object?>>[_card(2)],
      <String, List<double>>{_art: _vector(.4)},
      version: 'abcdef0123456789abcdef01',
    );
    final File index = File('${broken.path}/catalog.index.json.gz');
    final Map<String, Object?> decoded = jsonDecode(
      utf8.decode(gzip.decode(await index.readAsBytes())),
    ) as Map<String, Object?>;
    (decoded['entries']! as List<Object?>).clear();
    final List<int> bytes = gzip.encode(utf8.encode(jsonEncode(decoded)));
    await index.writeAsBytes(bytes);
    final File manifest = File('${broken.path}/manifest.json');
    final Map<String, Object?> data =
        jsonDecode(await manifest.readAsString()) as Map<String, Object?>;
    for (final Object? raw in data['files']! as List<Object?>) {
      final Map<String, Object?> file = raw! as Map<String, Object?>;
      if (file['name'] == 'catalog.index.json.gz') {
        file['bytes'] = bytes.length;
        file['sha256'] = sha256.convert(bytes).toString();
      }
    }
    await manifest.writeAsString(jsonEncode(data));
    await expectLater(catalog.installDirectory(broken), throwsFormatException);
    expect(
      await File('${root.path}/installed/current').readAsString(),
      '0123456789abcdef01234567',
    );
    expect((await catalog.exactReady('c19', '1'))!.collectorNumber, '1');
  });

  test('bundled bootstrap installs once and a new instance loads the verified offline version', () async {
    final Directory source = await writeScanCatalogPackage(
      Directory('${root.path}/source'),
      <Map<String, Object?>>[_card(1)],
      <String, List<double>>{_art: _vector(.25)},
    );
    final Map<String, Uint8List> assets = <String, Uint8List>{};
    await for (final FileSystemEntity entity in source.list()) {
      if (entity is File) {
        assets['${LocalScanCatalog.bundledRoot}/${entity.uri.pathSegments.last}'] =
            await entity.readAsBytes();
      }
    }
    catalog.close();
    catalog = LocalScanCatalog(
      directory: () async => Directory('${root.path}/installed'),
      assets: _Assets(assets),
    );
    await catalog.warm();
    expect((await catalog.exactReady('c19', '1'))!.collectorNumber, '1');
    catalog.close();
    catalog = LocalScanCatalog(
      directory: () async => Directory('${root.path}/installed'),
      assets: _Assets(<String, Uint8List>{}),
    );
    await catalog.warm();
    expect((await catalog.exactReady('c19', '1'))!.collectorNumber, '1');
  });

  test(
    'ready-only text lookup never waits for a cold blocked package loader',
    () async {
      final Completer<Directory> directory = Completer<Directory>();
      catalog.close();
      catalog = LocalScanCatalog(
        directory: () => directory.future,
        assets: _Assets(<String, Uint8List>{}),
      );
      final Future<void> warming = catalog.warm();
      final Future<void> failure = expectLater(warming, throwsStateError);
      expect(
        await catalog
            .printingsReady('Dusk // Dawn')
            .timeout(const Duration(seconds: 1)),
        isNull,
      );
      expect(
        await catalog
            .exactReady('c19', '1')
            .timeout(const Duration(seconds: 1)),
        isNull,
      );
      directory.complete(Directory('${root.path}/installed'));
      await failure;
    },
  );

  test('image-only discovery returns real candidates with no invented title or exact receipt', () async {
    await catalog.installDirectory(
      await writeScanCatalogPackage(
        Directory('${root.path}/source'),
        <Map<String, Object?>>[
          _card(1),
          _card(
            2,
            name: 'Distinct identity',
            oracle: '10000000-0000-4000-8000-000000000003',
          ),
        ],
        <String, List<double>>{_art: _vector(.25)},
      ),
    );
    final File image = await File('${root.path}/query.jpg')
        .writeAsBytes(<int>[1]);
    final ScanCrop crop = ScanCrop(
      imagePath: image.path,
      width: 700,
      height: 1000,
      rectified: true,
      sourceCorners: _corners,
      lines: const <ScanTextLine>[],
      warnings: const <String>['capture_ownership_uncertain'],
    );
    final _Artwork artwork = _Artwork(<String, double>{
      _card(1)['id']! as String: .1,
    });
    final ScanResolver resolver = ScanResolver(
      catalog: _NoCatalog(),
      artwork: artwork,
      symbols: _Symbols(),
      visualIndex: IndexedScanVisualRetriever(
        catalog: catalog,
        descriptor: (String path, int rotation, ScanBounds region) async =>
            _vector(rotation == 0 ? .25 : .8),
      ),
    );
    final ScanResolution result = await resolver.resolve(crop);
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(result.hints.names, isEmpty);
    expect(result.candidates.length, 2);
    expect(result.candidates.first.card.id, _card(1)['id']);
    expect(
      result.candidates.first.evidence,
      contains(ScanEvidence.artworkCompared),
    );
    expect(result.candidates.last.artworkDistance, isNull);
    expect(result.historicalBodyIdentityProof, isNull);
    expect(result.hasMore, isFalse);
    for (final ScanCandidate candidate in result.candidates) {
      expect(hasExactPrintingEvidence(crop, result), isFalse);
      expect(candidate.evidence, isNot(contains(ScanEvidence.nameMatch)));
    }
  });

  test('image-only retrieval offers at most three identities rather than the full search shortlist', () async {
    final List<Map<String, Object?>> cards = <Map<String, Object?>>[
      for (int index = 1; index <= 6; index++)
        _card(
          index,
          name: 'Identity $index',
          oracle:
              '10000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
        ),
    ];
    await catalog.installDirectory(
      await writeScanCatalogPackage(
        Directory('${root.path}/source'),
        cards,
        <String, List<double>>{_art: _vector(.25)},
      ),
    );
    final File image = await File('${root.path}/query.jpg')
        .writeAsBytes(<int>[1]);
    final ScanCrop crop = ScanCrop(
      imagePath: image.path,
      width: 700,
      height: 1000,
      rectified: true,
      sourceCorners: _corners,
      lines: const <ScanTextLine>[],
    );
    final ScanResolution result = await ScanResolver(
      catalog: _NoCatalog(),
      artwork: _Artwork(<String, double>{
        for (final Map<String, Object?> card in cards)
          card['id']! as String: .1,
      }),
      symbols: _Symbols(),
      visualIndex: IndexedScanVisualRetriever(
        catalog: catalog,
        descriptor: (String path, int rotation, ScanBounds region) async =>
            _vector(rotation == 0 ? .25 : .8),
      ),
    ).resolve(crop);
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(
      result.candidates
          .map((ScanCandidate value) => value.card.oracleId)
          .toSet(),
      hasLength(3),
    );
    expect(result.hints.names, isEmpty);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
  });

  test('strong literal basic-land title keeps visual fallback on that identity despite shared scenery', () async {
    final Map<String, Object?> swamp = _card(1, name: 'Snow-Covered Swamp')
      ..['type_line'] = 'Basic Snow Land — Swamp'
      ..['oracle_text'] = ''
      ..remove('card_faces');
    final Map<String, Object?> plains =
        _card(2, name: 'Plains', oracle: '10000000-0000-4000-8000-000000000002')
          ..['type_line'] = 'Basic Land — Plains'
          ..['oracle_text'] = ''
          ..remove('card_faces');
    await catalog.installDirectory(
      await writeScanCatalogPackage(
        Directory('${root.path}/source'),
        <Map<String, Object?>>[swamp, plains],
        <String, List<double>>{_art: _vector(.25)},
      ),
    );
    final File image = await File('${root.path}/query.jpg')
        .writeAsBytes(<int>[1]);
    final ScanCrop crop = ScanCrop(
      imagePath: image.path,
      width: 700,
      height: 1000,
      rectified: true,
      sourceCorners: _corners,
      warnings: const <String>[
        'border_recovered',
        'partial_card',
        'basic_land_outline',
        'unread_footer',
      ],
      lines: const <ScanTextLine>[
        ScanTextLine(
          text: 'Snow-Covered Swamp',
          confidence: 1,
          bounds: ScanBounds(.08, .05, .70, .04),
        ),
        ScanTextLine(
          text: 'Basic Snow Land — Swamp',
          confidence: 1,
          bounds: ScanBounds(.05, .82, .75, .04),
        ),
        ScanTextLine(
          text: '82//254',
          confidence: .3,
          bounds: ScanBounds(.06, .95, .30, .025),
        ),
      ],
    );
    expect(hasVerifiedSavedBasicLandCapturePresence(crop), isTrue);
    final ScanResolution result = await ScanResolver(
      catalog: _NoCatalog(),
      artwork: _Artwork(<String, double>{
        swamp['id']! as String: .05,
        plains['id']! as String: .01,
      }),
      symbols: _Symbols(),
      visualIndex: IndexedScanVisualRetriever(
        catalog: catalog,
        descriptor: (String path, int rotation, ScanBounds region) async =>
            _vector(rotation == 0 ? .25 : .8),
      ),
    ).resolve(crop);
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(
      result.candidates.map((ScanCandidate value) => value.card.name),
      everyElement('Snow-Covered Swamp'),
    );
    expect(result.candidates, isNotEmpty);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
  });

  test(
    'upside-down coarse discovery cannot apply an upright artwork comparison',
    () async {
      await catalog.installDirectory(
        await writeScanCatalogPackage(
          Directory('${root.path}/source'),
          <Map<String, Object?>>[_card(1, illustration: _otherArt)],
          <String, List<double>>{_otherArt: _vector(.25)},
        ),
      );
      final File image = await File('${root.path}/query.jpg')
          .writeAsBytes(<int>[1]);
      final ScanCrop crop = ScanCrop(
        imagePath: image.path,
        width: 700,
        height: 1000,
        rectified: true,
        sourceCorners: _corners,
        lines: const <ScanTextLine>[],
      );
      final _Artwork artwork = _Artwork(<String, double>{
        _card(1)['id']! as String: .01,
      });
      final ScanResolver resolver = ScanResolver(
        catalog: _NoCatalog(),
        artwork: artwork,
        symbols: _Symbols(),
        visualIndex: IndexedScanVisualRetriever(
          catalog: catalog,
          descriptor: (String path, int rotation, ScanBounds region) async =>
              _vector(rotation == 180 ? .25 : .8),
        ),
      );
      final ScanResolution result = await resolver.resolve(crop);
      expect(result.status, ScanResolutionStatus.noMatch);
      expect(result.candidates, isEmpty);
      expect(artwork.calls, 0);
    },
  );

  test(
    'native descriptors reject malformed schema and unsupported numeric values',
    () {
      Map<String, Object> response(List<double> values) => <String, Object>{
        'schema': ScanCatalogPackage.descriptorSchema,
        'vector': values,
      };
      expect(
        IndexedScanVisualRetriever.parseDescriptor(response(_vector(.5))),
        hasLength(256),
      );
      expect(
        IndexedScanVisualRetriever.parseDescriptor(<String, Object>{
          'schema': 'other',
          'vector': _vector(.5),
        }),
        isNull,
      );
      expect(
        IndexedScanVisualRetriever.parseDescriptor(response(<double>[.5])),
        isNull,
      );
      expect(
        IndexedScanVisualRetriever.parseDescriptor(
          response(_vector(double.nan)),
        ),
        isNull,
      );
      expect(
        IndexedScanVisualRetriever.parseDescriptor(response(_vector(1.01))),
        isNull,
      );
    },
  );

  test('image-only discovery rejects incomplete unread frames and invalid card geometry before matching', () async {
    final File image = await File('${root.path}/desk.jpg')
        .writeAsBytes(<int>[1]);
    int descriptions = 0;
    final IndexedScanVisualRetriever visual = IndexedScanVisualRetriever(
      catalog: catalog,
      descriptor: (String path, int rotation, ScanBounds region) async {
        descriptions++;
        return _vector(.25);
      },
    );
    final ScanResolver resolver = ScanResolver(
      catalog: _NoCatalog(),
      artwork: _Artwork(<String, double>{}),
      symbols: _Symbols(),
      visualIndex: visual,
    );
    final List<ScanCrop> invalid = <ScanCrop>[
      ScanCrop(
        imagePath: image.path,
        width: 700,
        height: 1000,
        rectified: true,
        sourceCorners: _corners,
        lines: const <ScanTextLine>[],
        warnings: const <String>['incomplete_card', 'no_text'],
      ),
      ScanCrop(
        imagePath: image.path,
        width: 866,
        height: 1000,
        rectified: true,
        sourceCorners: _corners,
        lines: const <ScanTextLine>[],
      ),
      ScanCrop(
        imagePath: image.path,
        width: 700,
        height: 1000,
        rectified: true,
        sourceCorners: const <ScanPoint>[
          ScanPoint(0, 0),
          ScanPoint(1, 1),
          ScanPoint(1, 0),
          ScanPoint(0, 1),
        ],
        lines: const <ScanTextLine>[],
      ),
    ];
    for (final ScanCrop crop in invalid) {
      final ScanResolution result = await resolver.resolve(crop);
      expect(result.status, ScanResolutionStatus.noMatch);
      expect(result.candidates, isEmpty);
    }
    expect(descriptions, 0);
  });

  test('unknown-layout discovery bounds profiles and keeps the winning measured source region', () async {
    await catalog.installDirectory(
      await writeScanCatalogPackage(
        Directory('${root.path}/source'),
        <Map<String, Object?>>[_card(1)],
        <String, List<double>>{_art: _vector(.25)},
      ),
    );
    final File image = await File('${root.path}/query.jpg')
        .writeAsBytes(<int>[1]);
    final List<({int rotation, ScanBounds region})> requested =
        <({int rotation, ScanBounds region})>[];
    final IndexedScanVisualRetriever retriever = IndexedScanVisualRetriever(
      catalog: catalog,
      descriptor: (String path, int rotation, ScanBounds region) async {
        expect(path, image.path);
        requested.add((rotation: rotation, region: region));
        return _vector(region.height == .65 && rotation == 180 ? .25 : .8);
      },
    );
    final List<LocalVisualHit> results = await retriever.discover(
      ScanCrop(
        imagePath: image.path,
        width: 700,
        height: 1000,
        rectified: true,
        sourceCorners: _corners,
        lines: const <ScanTextLine>[],
      ),
    );
    expect(requested.length, 4);
    expect(
      requested.map(
        (({int rotation, ScanBounds region}) value) => value.rotation,
      ),
      <int>[0, 180, 0, 180],
    );
    expect(results.single.rotationDegrees, 180);
    expect(results.single.queryRegion!.height, .65);
    expect(results.single.queryRegion!.x, .07);
  });
}
