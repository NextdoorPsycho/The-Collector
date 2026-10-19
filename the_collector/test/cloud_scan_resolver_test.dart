import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'helpers/live_historical_scene.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/cloud_scan_resolver.dart';
import 'package:the_collector/utils/scanning/cloud_card_hints_service.dart';
import 'package:the_collector/utils/scanning/cloud_scan_consent.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_artwork_matcher.dart';
import 'package:the_collector/utils/scanning/scan_symbol_matcher.dart';

class _Permission implements CloudScanPermission {
  @override
  bool isValid = true;
}

final _Permission _testPermission = _Permission();
Future<CloudScanPermission?> _authorize() async => _testPermission;

class _Card extends Fake implements MtgCard {
  _Card(
    this.id,
    this.name, {
    this.set = 'ltr',
    this.collectorNumber = '95',
    this.lang = Language.english,
    this.games = const <Game>[Game.paper],
  });
  @override
  final String id;
  @override
  final String name;
  @override
  final String set;
  @override
  final String collectorNumber;
  @override
  final Language lang;
  @override
  final List<Game> games;
  @override
  String? get illustrationId => null;
  @override
  String? get printedName => null;
  @override
  String get typeLine => 'Creature';
  @override
  String? get oracleText => null;
  @override
  String? get printedText => null;
  @override
  String? get flavorText => null;
  @override
  String? get artist => null;
  @override
  DateTime get releasedAt => DateTime(2023);
  @override
  List<CardFace>? get cardFaces => null;
}

class _Catalog extends Fake implements ScanCatalog {
  List<MtgCard> cards = <MtgCard>[];
  MtgCard? exact;
  bool hasMore = false;
  List<MtgCard> bodyCards = <MtgCard>[];
  final Map<String, List<MtgCard>> namedCards = <String, List<MtgCard>>{};
  final List<String> queries = <String>[];
  Completer<void>? exactStarted;
  Completer<void>? exactGate;
  @override
  Future<PaginableList<MtgCard>> printings(
    String name, {
    String? setCode,
    String? language,
    int page = 1,
  }) async {
    queries.add('$name/$setCode/$language/$page');
    return PaginableList<MtgCard>(
      data: namedCards[name] ?? cards,
      hasMore: hasMore,
    );
  }

  @override
  Future<PaginableList<MtgCard>> rulesTextPrintings(
    String phrase, {
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
    int page = 1,
  }) async => PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false);
  @override
  Future<PaginableList<MtgCard>> rulesKeywordCards(
    List<String> keywords, {
    String? phrase,
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
  }) async => PaginableList<MtgCard>(data: bodyCards, hasMore: false);
  @override
  Future<MtgCard?> fuzzyName(String name) async => null;
  @override
  Future<MtgCard?> exactPrinting(
    String setCode,
    String collectorNumber, {
    String? language,
  }) async {
    queries.add('$setCode/$collectorNumber/$language');
    exactStarted?.complete();
    await exactGate?.future;
    return exact;
  }
}

class _Artwork implements ScanArtworkMatcher {
  @override
  Future<Map<String, double>> compare(
    ScanCrop crop,
    List<MtgCard> candidates, {
    bool reliableBodyFallback = false,
  }) async => <String, double>{};
}

class _Symbols implements ScanSymbolMatcher {
  @override
  Future<Map<String, double>> compare(
    ScanCrop crop,
    List<MtgCard> candidates,
  ) async => <String, double>{};
}

ScanCrop _crop({
  String path = '/local/crop-test.jpg',
  int width = 745,
  int height = 1040,
  List<ScanTextLine> lines = const <ScanTextLine>[],
}) => ScanCrop(
  imagePath: path,
  width: width,
  height: height,
  rectified: true,
  sourceCorners: const <ScanPoint>[
    ScanPoint(.1, .1),
    ScanPoint(.4, .1),
    ScanPoint(.4, .6),
    ScanPoint(.1, .6),
  ],
  lines: lines,
);
Map<String, Object?> _response({
  String? name = 'Mirkwood Bats',
  String? set,
  String? number,
  String? language,
}) => <String, Object?>{
  'model': 'configured-model',
  'elapsedMs': 300,
  'confidence': 'uncalibrated',
  'hints': <String, Object?>{
    'name': name,
    'setCode': set,
    'collectorNumber': number,
    'rulesText': null,
    'typeLine': null,
    'artist': null,
    'language': language,
  },
};
CloudScanResolver _resolver(
  _Catalog catalog,
  CloudCardHintsCallable callable, {
  bool enabled = true,
  CloudCardCropEncoder? encoder,
  Duration timeout = const Duration(seconds: 20),
  CloudScanConsentCheck? acquireConsent = _authorize,
}) => CloudScanResolver(
  catalog: catalog,
  artwork: _Artwork(),
  symbols: _Symbols(),
  callable: callable,
  statusCallable: () async => <String, Object?>{
    'configured': true,
    'mode': 'text-transcription',
    'model': 'fixture-model',
  },
  encoder:
      encoder ?? (ScanCrop crop) async => Uint8List.fromList(<int>[1, 2, 3]),
  enabled: enabled,
  timeout: timeout,
  acquireConsent: acquireConsent,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('batch publication waits for final cloud outcome and honors revocation without delaying a local sibling', () async {
    for (final bool revoke in <bool>[false, true]) {
      final _Permission permission = _Permission();
      final Completer<Object?> reply = Completer<Object?>();
      final Completer<void> started = Completer<void>();
      final _Catalog catalog = _Catalog()
        ..cards = <MtgCard>[_Card('bats', 'Mirkwood Bats')];
      final CloudScanResolver resolver = _resolver(catalog, (String _) {
        started.complete();
        return reply.future;
      }, acquireConsent: () async => permission);
      final Map<int, ScanResolveOutcome> published =
          <int, ScanResolveOutcome>{};
      final List<int> order = <int>[];
      final Future<List<ScanResolveOutcome>> results = resolver
          .resolveBatchOutcomes(
            <ScanCrop>[_crop(), _crop(path: '')],
            onOutcome: (int index, ScanResolveOutcome outcome) async {
              order.add(index);
              published[index] = outcome;
            },
          );
      await started.future;
      expect(order, <int>[1]);
      expect(published[1]!.resolution!.status, ScanResolutionStatus.noMatch);
      permission.isValid = !revoke;
      reply.complete(_response());
      final List<ScanResolveOutcome> completed = await results;
      expect(order, <int>[1, 0]);
      expect(completed[0], same(published[0]));
      final ScanResolution cloud = published[0]!.resolution!;
      expect(
        cloud.status,
        revoke
            ? ScanResolutionStatus.noMatch
            : ScanResolutionStatus.needsReview,
      );
      expect(hasExactPrintingEvidence(_crop(), cloud), isFalse);
      if (revoke) {
        expect(catalog.queries, isEmpty);
      } else {
        expect(
          cloud.candidates.single.evidence,
          contains(ScanEvidence.cloudSuggestion),
        );
      }
    }
  });
  test(
    'cloud hints cannot suggest a digital-only printing for a physical scan',
    () async {
      final _Catalog catalog = _Catalog()
        ..cards = <MtgCard>[
          _Card(
            'digital-bats',
            'Mirkwood Bats',
            games: const <Game>[Game.arena],
          ),
          _Card('paper-bats', 'Mirkwood Bats'),
        ];
      final CloudScanResolver resolver = _resolver(
        catalog,
        (String _) async => _response(),
      );
      final ScanResolution result = await resolver.resolve(_crop());
      expect(
        result.candidates.map((ScanCandidate candidate) => candidate.card.id),
        <String>['paper-bats'],
      );
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(hasExactPrintingEvidence(_crop(), result), isFalse);
    },
  );
  test('disabled server configuration is observable, uploads nothing, and a checked rollout can retry the same crop', () async {
    bool configured = false;
    int uploads = 0;
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[_Card('bats', 'Mirkwood Bats')];
    final CloudCardHintsService service = CloudCardHintsService(
      enabled: true,
      statusCallable: () async => <String, Object?>{
        'configured': configured,
        'mode': 'text-transcription',
        'model': configured ? 'fixture-model' : null,
      },
      callable: (String _) async {
        uploads++;
        return _response();
      },
    );
    addTearDown(service.dispose);
    final CloudScanResolver resolver = CloudScanResolver(
      enabled: true,
      cloudService: service,
      catalog: catalog,
      artwork: _Artwork(),
      symbols: _Symbols(),
      acquireConsent: _authorize,
      encoder: (ScanCrop _) async => Uint8List.fromList(<int>[1]),
    );
    expect(
      (await resolver.resolve(_crop())).status,
      ScanResolutionStatus.noMatch,
    );
    expect(
      service.status.value.availability,
      CloudCardHintsAvailability.notConfigured,
    );
    expect(uploads, 0);
    configured = true;
    await service.checkAvailability(force: true);
    final ScanResolution result = await resolver.resolve(_crop());
    expect(uploads, 1);
    expect(result.candidates.single.card.id, 'bats');
    expect(result.candidates.single.evidence, <ScanEvidence>{
      ScanEvidence.cloudSuggestion,
    });
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(_crop(), result), isFalse);
  });

  test('a transient cloud request failure stays visible and is not cached as a successful empty crop', () async {
    int uploads = 0;
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[_Card('bats', 'Mirkwood Bats')];
    final CloudScanResolver resolver = _resolver(catalog, (String _) async {
      uploads++;
      if (uploads == 1) throw StateError('Transient failure');
      return _response();
    });
    expect(
      (await resolver.resolve(_crop())).status,
      ScanResolutionStatus.noMatch,
    );
    expect(
      resolver.cloudService.status.value.failure,
      CloudCardHintsFailure.requestFailed,
    );
    final ScanResolution second = await resolver.resolve(_crop());
    expect(uploads, 2);
    expect(second.candidates.single.card.id, 'bats');
    expect(resolver.cloudService.status.value.canEnable, isTrue);
    expect(second.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(_crop(), second), isFalse);
  });
  test(
    'missing, denied, loading-failed, and revoked consent never upload',
    () async {
      for (final CloudScanConsentCheck? consent in <CloudScanConsentCheck?>[
        null,
        () async => null,
        () async => throw StateError('Consent storage unavailable'),
        () async => _Permission()..isValid = false,
      ]) {
        int calls = 0;
        int encodes = 0;
        final CloudScanResolver resolver = _resolver(
          _Catalog(),
          (String _) async {
            calls++;
            return _response();
          },
          acquireConsent: consent,
          encoder: (ScanCrop _) async {
            encodes++;
            return Uint8List.fromList(<int>[1]);
          },
        );
        expect(
          (await resolver.resolve(_crop())).status,
          ScanResolutionStatus.noMatch,
        );
        expect(calls, 0);
        expect(encodes, 0);
      }
    },
  );

  test('revoking consent during encoding prevents the upload', () async {
    final _Permission permission = _Permission();
    final Completer<Uint8List?> encoding = Completer<Uint8List?>();
    final Completer<void> started = Completer<void>();
    int calls = 0;
    final CloudScanResolver resolver = _resolver(
      _Catalog(),
      (String _) async {
        calls++;
        return _response();
      },
      acquireConsent: () async => permission,
      encoder: (ScanCrop _) {
        started.complete();
        return encoding.future;
      },
    );
    final Future<ScanResolution> result = resolver.resolve(_crop());
    await started.future;
    permission.isValid = false;
    encoding.complete(Uint8List.fromList(<int>[1, 2, 3]));
    expect((await result).status, ScanResolutionStatus.noMatch);
    expect(calls, 0);
  });

  test('revoking consent while cloud responds ignores suggestions and catalog lookups', () async {
    final _Permission permission = _Permission();
    final _Catalog catalog = _Catalog()..exact = _Card('card', 'Mirkwood Bats');
    final Completer<Object?> reply = Completer<Object?>();
    final Completer<void> started = Completer<void>();
    final CloudScanResolver resolver = _resolver(catalog, (String _) {
      started.complete();
      return reply.future;
    }, acquireConsent: () async => permission);
    final Future<ScanResolution> result = resolver.resolve(_crop());
    await started.future;
    permission.isValid = false;
    reply.complete(_response());
    expect((await result).status, ScanResolutionStatus.noMatch);
    expect(catalog.queries, isEmpty);
  });

  test('revoking consent during catalog verification discards the pending cloud result', () async {
    final _Permission permission = _Permission();
    final _Catalog catalog = _Catalog()
      ..exact = _Card('card', 'Mirkwood Bats')
      ..exactStarted = Completer<void>()
      ..exactGate = Completer<void>();
    final CloudScanResolver resolver = _resolver(
      catalog,
      (String _) async => _response(set: 'ltr', number: '95'),
      acquireConsent: () async => permission,
    );
    final Future<ScanResolution> result = resolver.resolve(_crop());
    await catalog.exactStarted!.future;
    expect(catalog.queries, <String>['ltr/95/null']);
    permission.isValid = false;
    catalog.exactGate!.complete();
    expect((await result).status, ScanResolutionStatus.noMatch);
    expect((await result).candidates, isEmpty);
  });

  test(
    'new consent cannot reuse suggestions cached under a retired permission',
    () async {
      _Permission permission = _Permission();
      int calls = 0;
      final _Catalog catalog = _Catalog()
        ..exact = _Card('card', 'Mirkwood Bats');
      final CloudScanResolver resolver = _resolver(catalog, (String _) async {
        calls++;
        return _response(set: 'ltr', number: '95');
      }, acquireConsent: () async => permission);
      expect((await resolver.resolve(_crop())).candidates, hasLength(1));
      expect((await resolver.resolve(_crop())).candidates, hasLength(1));
      expect(calls, 1);
      expect(catalog.queries, <String>['ltr/95/null']);
      permission.isValid = false;
      permission = _Permission();
      expect((await resolver.resolve(_crop())).candidates, hasLength(1));
      expect(calls, 2);
      expect(catalog.queries, <String>['ltr/95/null', 'ltr/95/null']);
    },
  );

  test('disabled resolver uses only local recognition without Firebase initialization', () async {
    int calls = 0;
    final CloudScanResolver resolver = _resolver(_Catalog(), (
      String image,
    ) async {
      calls++;
      return _response();
    }, enabled: false);
    final ScanResolution result = await resolver.resolve(_crop());
    expect(result.status, ScanResolutionStatus.noMatch);
    expect(calls, 0);
  });

  test('model identity becomes zero-weight catalog suggestion without OCR or green evidence', () async {
    final _Card bats = _Card('bats', 'Mirkwood Bats');
    final _Catalog catalog = _Catalog()..cards = <MtgCard>[bats];
    String? sent;
    final ScanResolution result = await _resolver(catalog, (
      String image,
    ) async {
      sent = image;
      return _response();
    }).resolve(_crop());
    expect(sent, base64Encode(<int>[1, 2, 3]));
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(result.hints.names, isEmpty);
    expect(result.hints.rulesText, isEmpty);
    expect(result.hints.setCode, isNull);
    expect(result.historicalBodyIdentityProof, isNull);
    expect(result.candidates.single.card.id, 'bats');
    expect(result.candidates.single.evidence, <ScanEvidence>{
      ScanEvidence.cloudSuggestion,
    });
    expect(result.candidates.single.score, 0);
  });

  test('verified catalog footer remains suggestion rather than exact printing evidence', () async {
    final _Catalog catalog = _Catalog()..exact = _Card('bats', 'Mirkwood Bats');
    final ScanResolution result = await _resolver(
      catalog,
      (String image) async =>
          _response(set: 'LTR', number: '095', language: 'en'),
    ).resolve(_crop());
    expect(catalog.queries, <String>['ltr/095/en']);
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(result.candidates.single.evidence, <ScanEvidence>{
      ScanEvidence.cloudSuggestion,
    });
  });

  test(
    'same local printing preserves actual evidence and confidence',
    () async {
      final _Catalog catalog = _Catalog()
        ..cards = <MtgCard>[_Card('bats', 'Mirkwood Bats')];
      final ScanCrop crop = _crop(
        lines: const <ScanTextLine>[
          ScanTextLine(
            text: 'Mirkwood Bats',
            confidence: .99,
            bounds: ScanBounds(.1, .05, .7, .03),
          ),
        ],
      );
      final ScanResolution local = await ScanResolver(
        catalog: catalog,
        artwork: _Artwork(),
        symbols: _Symbols(),
      ).resolve(crop);
      final ScanResolution result = await _resolver(
        catalog,
        (String image) async => _response(),
      ).resolve(crop);
      expect(result.candidates.length, 1);
      expect(result.hints.names, local.hints.names);
      expect(result.candidates.single.score, local.candidates.single.score);
      expect(result.candidates.single.evidence, <ScanEvidence>{
        ...local.candidates.single.evidence,
        ScanEvidence.cloudSuggestion,
      });
      expect(result.status, ScanResolutionStatus.needsReview);
    },
  );

  test(
    'native whole-source fallback cannot upload under a crop filename',
    () async {
      int calls = 0;
      int encodings = 0;
      final CloudScanResolver resolver = _resolver(
        _Catalog(),
        (String image) async {
          calls++;
          return _response();
        },
        encoder: (ScanCrop crop) async {
          encodings++;
          return Uint8List.fromList(<int>[1, 2, 3]);
        },
      );
      for (final List<String> warnings in <List<String>>[
        <String>['no_card_rectangle', 'no_text', 'incomplete_card'],
        <String>['no_text'],
        <String>[],
      ]) {
        final ScanCrop fullSource = ScanCrop(
          imagePath: '/local/ScanCrops/whole-${warnings.length}.jpg',
          width: 745,
          height: 1040,
          rectified: !warnings.contains('no_card_rectangle'),
          sourceCorners: const <ScanPoint>[
            ScanPoint(0, 0),
            ScanPoint(1, 0),
            ScanPoint(1, 1),
            ScanPoint(0, 1),
          ],
          lines: const <ScanTextLine>[],
          warnings: warnings,
        );
        expect(
          (await resolver.resolve(fullSource)).status,
          ScanResolutionStatus.noMatch,
        );
        expect(await CloudScanResolver.encodeSavedCrop(fullSource), isNull);
      }
      expect(calls, 0);
      expect(encodings, 0);
      await resolver.resolve(_crop(path: '/local/ScanCrops/real-card.jpg'));
      expect(calls, 1);
      expect(encodings, 1);
      final ScanCrop bounded = ScanCrop(
        imagePath: '/local/crop-tightly-framed.jpg',
        width: 745,
        height: 1040,
        rectified: true,
        sourceCorners: const <ScanPoint>[
          ScanPoint(.01, .01),
          ScanPoint(.99, .01),
          ScanPoint(.99, .99),
          ScanPoint(.01, .99),
        ],
        lines: const <ScanTextLine>[],
        warnings: const <String>['no_text'],
      );
      await resolver.resolve(bounded);
      expect(calls, 2);
      expect(encodings, 2);
    },
  );

  test('live streams, source photos, remote URLs, overrides, and later pages never upload', () async {
    int calls = 0;
    final CloudScanResolver resolver = _resolver(_Catalog(), (
      String image,
    ) async {
      calls++;
      return _response();
    });
    for (final String path in <String>[
      '',
      '/local/photo-source.jpg',
      'https://example.com/crop.jpg',
      'file:///local/crop-test.jpg',
    ]) {
      await resolver.resolve(_crop(path: path));
    }
    await resolver.resolve(_crop(), name: 'User selection');
    await resolver.resolve(_crop(), setCode: 'ltr');
    await resolver.resolve(_crop(), collectorNumber: '95');
    await resolver.resolve(_crop(), language: 'en');
    await resolver.resolve(_crop(), page: 2);
    expect(calls, 0);
  });

  test('exact local footer never requests cloud hints', () async {
    int calls = 0;
    final _Catalog catalog = _Catalog()..exact = _Card('bats', 'Mirkwood Bats');
    final ScanCrop crop = _crop(
      lines: const <ScanTextLine>[
        ScanTextLine(
          text: 'Mirkwood Bats',
          confidence: .99,
          bounds: ScanBounds(.1, .05, .7, .03),
        ),
        ScanTextLine(
          text: '095',
          confidence: .99,
          bounds: ScanBounds(.1, .88, .2, .025),
        ),
        ScanTextLine(
          text: 'LTR EN',
          confidence: .99,
          bounds: ScanBounds(.1, .94, .3, .025),
        ),
      ],
    );
    final ScanResolution result = await _resolver(catalog, (
      String image,
    ) async {
      calls++;
      return _response();
    }).resolve(crop);
    expect(result.status, ScanResolutionStatus.exactPrinting);
    expect(calls, 0);
  });

  test(
    'missing and failed source encoding or callable retain local results',
    () async {
      for (final CloudCardCropEncoder encoder in <CloudCardCropEncoder>[
        (ScanCrop crop) async => null,
        (ScanCrop crop) async => Uint8List(2 * 1024 * 1024 + 1),
        (ScanCrop crop) async =>
            throw const FileSystemException('missing diagnostic crop'),
      ]) {
        int calls = 0;
        final ScanResolution result = await _resolver(_Catalog(), (
          String image,
        ) async {
          calls++;
          return _response();
        }, encoder: encoder).resolve(_crop());
        expect(result.status, ScanResolutionStatus.noMatch);
        expect(calls, 0);
      }
      final ScanResolution failed = await _resolver(
        _Catalog(),
        (String image) async => throw StateError('unavailable'),
      ).resolve(_crop());
      expect(failed.status, ScanResolutionStatus.noMatch);
    },
  );

  test('catalog lookup checks literal name, set, number and language returned by cloud', () async {
    final List<MtgCard> wrong = <MtgCard>[
      _Card('wrong-name', 'Nevermore'),
      _Card('wrong-set', 'Mirkwood Bats', set: 'mom'),
      _Card('wrong-number', 'Mirkwood Bats', collectorNumber: '96'),
      _Card('wrong-language', 'Mirkwood Bats', lang: Language.german),
    ];
    for (final MtgCard card in wrong) {
      final _Catalog catalog = _Catalog()..exact = card;
      final ScanResolution result = await _resolver(
        catalog,
        (String image) async =>
            _response(set: 'ltr', number: '95', language: 'en'),
      ).resolve(_crop());
      expect(result.candidates, isEmpty, reason: card.id);
      expect(result.status, ScanResolutionStatus.noMatch);
    }
  });

  test('malformed or injected hints cannot query the catalog', () async {
    final List<Object?> malformed = <Object?>[
      null,
      'wrong',
      <String, Object?>{..._response(), 'confidence': 'certain'},
      <String, Object?>{..._response(), 'id': 'invented'},
      <String, Object?>{..._response(), 'elapsedMs': double.nan},
      _response(set: 'ltr or set:mom'),
      _response(number: '95 or name:x'),
      _response(language: 'xxx'),
      _response(name: 'Card\nquery'),
      <String, Object?>{
        ..._response(),
        'hints': <String, Object?>{'name': 'Mirkwood Bats'},
      },
      <String, Object?>{
        ..._response(),
        'hints': <String, Object?>{
          ...(_response()['hints'] as Map<String, Object?>),
          'confidence': 1,
        },
      },
    ];
    for (int index = 0; index < malformed.length; index++) {
      final _Catalog catalog = _Catalog();
      final ScanResolution result = await _resolver(
        catalog,
        (String image) async => malformed[index],
      ).resolve(_crop());
      expect(result.status, ScanResolutionStatus.noMatch, reason: '$index');
      expect(catalog.queries, isEmpty, reason: '$index');
    }
  });

  test('failed suggestions remain retryable and replacing an owned crop invalidates successful cached suggestions', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'collector-cloud-revision-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final String path = '${directory.path}/crop-existing.jpg';
    await File(path).writeAsBytes(<int>[1]);
    int calls = 0;
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[_Card('bats', 'Mirkwood Bats')];
    final CloudScanResolver resolver = _resolver(catalog, (String image) async {
      calls++;
      return base64Decode(image).length == 1 ? null : _response();
    }, encoder: (ScanCrop crop) => File(crop.imagePath).readAsBytes());
    final ScanCrop crop = _crop(path: path);
    expect((await resolver.resolve(crop)).status, ScanResolutionStatus.noMatch);
    expect((await resolver.resolve(crop)).status, ScanResolutionStatus.noMatch);
    expect(calls, 2);
    final File replacement = File('${directory.path}/replacement.jpg');
    await replacement.writeAsBytes(<int>[1, 2, 3]);
    await replacement.rename(path);
    final ScanResolution refined = await resolver.resolve(crop);
    expect(refined.candidates.single.card.id, 'bats');
    expect(refined.candidates.single.evidence, <ScanEvidence>{
      ScanEvidence.cloudSuggestion,
    });
    expect(calls, 3);
    await resolver.resolve(crop);
    expect(calls, 3);
  });

  test(
    'a refined crop does not join an earlier in-flight image revision',
    () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'collector-cloud-pending-revision-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final String path = '${directory.path}/crop-existing.jpg';
      await File(path).writeAsBytes(<int>[1]);
      final Completer<void> started = Completer<void>();
      final Completer<Object?> original = Completer<Object?>();
      int calls = 0;
      final _Catalog catalog = _Catalog()
        ..cards = <MtgCard>[_Card('bats', 'Mirkwood Bats')];
      final CloudScanResolver resolver = _resolver(catalog, (String image) {
        calls++;
        if (base64Decode(image).length == 1) {
          started.complete();
          return original.future;
        }
        return Future<Object?>.value(_response());
      }, encoder: (ScanCrop crop) => File(crop.imagePath).readAsBytes());
      final ScanCrop crop = _crop(path: path);
      final Future<ScanResolution> old = resolver.resolve(crop);
      await started.future.timeout(const Duration(seconds: 2));
      final File replacement = File('${directory.path}/replacement.jpg');
      await replacement.writeAsBytes(<int>[1, 2, 3]);
      await replacement.rename(path);
      expect((await resolver.resolve(crop)).candidates.single.card.id, 'bats');
      expect(calls, 2);
      original.complete(null);
      expect((await old).status, ScanResolutionStatus.noMatch);
      expect((await resolver.resolve(crop)).candidates.single.card.id, 'bats');
      expect(calls, 2);
    },
  );

  test(
    'name printing query caps comparisons and preserves incomplete pagination',
    () async {
      final _Catalog catalog = _Catalog()
        ..cards = List<MtgCard>.generate(
          40,
          (int index) => _Card('bats-$index', 'Mirkwood Bats'),
        );
      final ScanResolution result = await _resolver(
        catalog,
        (String image) async => _response(),
      ).resolve(_crop());
      expect(result.candidates.length, 32);
      expect(result.hasMore, isTrue);
      expect(
        result.candidates.every(
          (ScanCandidate candidate) => candidate.evidence.length == 1,
        ),
        isTrue,
      );
    },
  );

  test('at most two pending requests with identical-path coalescing and bounded cache', () async {
    final List<Completer<Object?>> pending = <Completer<Object?>>[];
    int calls = 0;
    final Completer<void> started = Completer<void>();
    final CloudScanResolver resolver = _resolver(_Catalog(), (String image) {
      calls++;
      if (calls == 2) started.complete();
      final Completer<Object?> future = Completer<Object?>();
      pending.add(future);
      return future.future;
    });
    final Future<ScanResolution> first = resolver.resolve(
      _crop(path: '/local/crop-a.jpg'),
    );
    final Future<ScanResolution> same = resolver.resolve(
      _crop(path: '/local/crop-a.jpg'),
    );
    final Future<ScanResolution> second = resolver.resolve(
      _crop(path: '/local/crop-b.jpg'),
    );
    await started.future.timeout(const Duration(seconds: 2));
    expect(calls, 2);
    expect(
      (await resolver.resolve(_crop(path: '/local/crop-c.jpg'))).status,
      ScanResolutionStatus.noMatch,
    );
    expect(calls, 2);
    for (final Completer<Object?> future in pending) {
      future.complete(_response());
    }
    await Future.wait(<Future<ScanResolution>>[first, same, second]);
    await resolver.resolve(_crop(path: '/local/crop-a.jpg'));
    expect(calls, 2);

    int cachedCalls = 0;
    final CloudScanResolver cached = _resolver(_Catalog(), (
      String image,
    ) async {
      cachedCalls++;
      return _response();
    });
    for (int index = 0; index < 129; index++) {
      await cached.resolve(_crop(path: '/local/crop-$index.jpg'));
    }
    await cached.resolve(_crop(path: '/local/crop-128.jpg'));
    expect(cachedCalls, 129);
    await cached.resolve(_crop(path: '/local/crop-0.jpg'));
    expect(cachedCalls, 130);
  });

  test(
    'timeout releases bounded admission and preserves local result',
    () async {
      final List<Completer<Object?>> pending = <Completer<Object?>>[];
      final CloudScanResolver resolver = _resolver(_Catalog(), (String image) {
        final Completer<Object?> future = Completer<Object?>();
        pending.add(future);
        return future.future;
      }, timeout: const Duration(milliseconds: 5));
      await Future.wait(<Future<ScanResolution>>[
        resolver.resolve(_crop(path: '/local/crop-a.jpg')),
        resolver.resolve(_crop(path: '/local/crop-b.jpg')),
      ]);
      await resolver.resolve(_crop(path: '/local/crop-c.jpg'));
      expect(pending.length, 3);
      for (final Completer<Object?> future in pending) {
        future.complete(null);
      }
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('timed-out encoding cannot launch a stale paid request after admission releases', () async {
    final Completer<Uint8List?> delayedEncoding = Completer<Uint8List?>();
    int calls = 0;
    final CloudScanResolver resolver = _resolver(
      _Catalog(),
      (String image) async {
        calls++;
        return _response();
      },
      encoder: (ScanCrop crop) => delayedEncoding.future,
      timeout: const Duration(milliseconds: 5),
    );
    final ScanResolution result = await resolver.resolve(_crop());
    expect(result.status, ScanResolutionStatus.noMatch);
    expect(calls, 0);
    delayedEncoding.complete(Uint8List.fromList(<int>[1, 2, 3]));
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);
    await resolver.resolve(_crop());
    expect(calls, 1);
    expect(
      resolver.cloudService.status.value.failure,
      isNot(CloudCardHintsFailure.timedOut),
    );
  });

  test(
    'multiline model rules do not invalidate a validated catalog suggestion',
    () async {
      final _Catalog catalog = _Catalog()
        ..cards = <MtgCard>[_Card('bats', 'Mirkwood Bats')];
      final Map<String, Object?> response = _response();
      (response['hints'] as Map<String, Object?>)['rulesText'] =
          'Whenever a token enters,\nEach opponent loses life.\tAnother row.';
      final ScanResolution result = await _resolver(
        catalog,
        (String image) async => response,
      ).resolve(_crop());
      expect(result.candidates.single.evidence, <ScanEvidence>{
        ScanEvidence.cloudSuggestion,
      });
      expect(result.hints.rulesText, isEmpty);
    },
  );

  test('conflicting cloud identity cannot inherit a complete historical body proof', () async {
    final MtgCard circle = HistoricalSceneCard();
    final _Catalog catalog = _Catalog()
      ..bodyCards = <MtgCard>[circle]
      ..namedCards['Circle of Protection: Blue'] = <MtgCard>[circle]
      ..namedCards['Mirkwood Bats'] = <MtgCard>[_Card('bats', 'Mirkwood Bats')];
    final ScanCrop actual = liveHistoricalScene();
    final ScanCrop saved = ScanCrop(
      imagePath: '/local/crop-historical.jpg',
      width: actual.width,
      height: actual.height,
      rectified: true,
      sourceCorners: actual.sourceCorners,
      lines: actual.lines,
      warnings: actual.warnings,
    );
    final ScanResolution local = await ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
      symbols: _Symbols(),
    ).resolve(saved);
    expect(local.historicalBodyIdentityProof, isNotNull);
    final ScanResolution conflicted = await _resolver(
      catalog,
      (String image) async => _response(),
    ).resolve(saved);
    expect(conflicted.historicalBodyIdentityProof, isNull);
    final ScanCandidate retained = conflicted.candidates.firstWhere(
      (ScanCandidate candidate) => candidate.card.id == circle.id,
    );
    expect(retained.evidence, local.candidates.single.evidence);
    final ScanCandidate cloud = conflicted.candidates.firstWhere(
      (ScanCandidate candidate) => candidate.card.id == 'bats',
    );
    expect(cloud.evidence, <ScanEvidence>{ScanEvidence.cloudSuggestion});
    final ScanResolution same = await _resolver(
      catalog,
      (String image) async => _response(name: circle.name),
    ).resolve(saved);
    expect(
      same.historicalBodyIdentityProof?.name,
      local.historicalBodyIdentityProof!.name,
    );
  });

  for (final String relativePath in <String>[
    'crop-test.png',
    'ScanCrops/c27f8839-7f14-42f5-8259-7e01e6b8ba86.png',
    'ScanCrops/ec186f14-cafc-443a-8827-deb8e915aac1/c27f8839-7f14-42f5-8259-7e01e6b8ba86.png',
  ]) {
    test(
      'saved crop $relativePath encoding bounds image to 1024 preserving aspect and rejects mismatched source',
      () async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'collector-cloud-crop-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final ui.PictureRecorder recorder = ui.PictureRecorder();
        final ui.Canvas canvas = ui.Canvas(recorder);
        canvas.drawColor(const ui.Color(0xffabcdef), ui.BlendMode.src);
        final ui.Picture picture = recorder.endRecording();
        final ui.Image source = await picture.toImage(1500, 2100);
        final ByteData sourceBytes = (await source.toByteData(
          format: ui.ImageByteFormat.png,
        ))!;
        source.dispose();
        picture.dispose();
        final String path = '${directory.path}/$relativePath';
        await File(path).parent.create(recursive: true);
        await File(path).writeAsBytes(Uint8List.sublistView(sourceBytes));
        final Uint8List? encoded = await CloudScanResolver.encodeSavedCrop(
          _crop(path: path, width: 1500, height: 2100),
        );
        expect(encoded, isNotNull);
        final ui.Codec codec = await ui.instantiateImageCodec(encoded!);
        final ui.Image image = (await codec.getNextFrame()).image;
        expect(image.width, 731);
        expect(image.height, 1024);
        image.dispose();
        codec.dispose();
        expect(
          await CloudScanResolver.encodeSavedCrop(_crop(path: path)),
          isNull,
        );
        final String fullFrame = '${directory.path}/photo-test.png';
        await File(path).copy(fullFrame);
        expect(
          await CloudScanResolver.encodeSavedCrop(
            _crop(path: fullFrame, width: 1500, height: 2100),
          ),
          isNull,
        );
        await File(path).writeAsString('not an image');
        expect(
          await CloudScanResolver.encodeSavedCrop(_crop(path: path)),
          isNull,
        );
      },
    );
  }
}
