import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

http.Response _printingPage(
  Map<String, Object?> fixture, {
  int count = 1,
  bool hasMore = false,
}) => http.Response(
  jsonEncode(<String, Object?>{
    'object': 'list',
    'data': <Object?>[for (int index = 0; index < count; index++) fixture],
    'has_more': hasMore,
    'next_page': hasMore
        ? 'https://api.scryfall.com/cards/search?page=2'
        : null,
    'total_cards': count,
    'warnings': <String>['Search warning'],
  }),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

void main() {
  late Directory directory;
  late Map<String, Object?> fixture;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'collector_printing_cache_',
    );
    Hive.init(directory.path);
    fixture = Map<String, Object?>.from(
      jsonDecode(
        await File('test/fixtures/scryfall_split_card.json').readAsString(),
      ) as Map<Object?, Object?>,
    );
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('physical remote searches and fuzzy fallback cannot return digital-only printings', () async {
    final Map<String, Object?> digital = <String, Object?>{
      ...fixture,
      'games': <String>['arena'],
    };
    final List<Uri> requests = <Uri>[];
    final ScryfallScanCatalog catalog = ScryfallScanCatalog(
      api: ScryfallApiClient(
        httpClient: MockClient((http.Request request) async {
          requests.add(request.url);
          if (request.url.path == '/cards/named') {
            return http.Response(
              jsonEncode(digital),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          expect(request.url.queryParameters['q'], contains('game:paper'));
          return http.Response(
            jsonEncode(<String, Object?>{
              'object': 'list',
              'data': <Object?>[digital, fixture],
              'has_more': false,
              'total_cards': 2,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    addTearDown(catalog.close);
    final PaginableList<MtgCard> prints = await catalog.printings(
      'Dusk // Dawn',
    );
    expect(prints.data, hasLength(1));
    expect(prints.totalCards, 1);
    expect(prints.data.single.games, contains(Game.paper));
    final MtgCard? fuzzy = await catalog.fuzzyName('Dsk');
    expect(fuzzy!.games, contains(Game.paper));
    expect(
      requests.where((Uri uri) => uri.path == '/cards/named'),
      hasLength(1),
    );
  });

  test('digital exact and batched footer responses cannot be cached or returned as physical cards', () async {
    final Map<String, Object?> digital = <String, Object?>{
      ...fixture,
      'games': <String>['mtgo'],
    };
    final ScryfallScanCatalog catalog = ScryfallScanCatalog(
      api: ScryfallApiClient(
        httpClient: MockClient((http.Request request) async {
          final Object payload = request.method == 'POST'
              ? <String, Object?>{
                  'object': 'list',
                  'not_found': <Object?>[],
                  'data': <Object?>[digital],
                }
              : digital;
          return http.Response(
            jsonEncode(payload),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    addTearDown(catalog.close);
    expect(await catalog.exactPrinting('c19', '1'), isNull);
    expect(
      await catalog.exactPrintings(const <ScanHints>[
        ScanHints(
          names: <String>['Dusk // Dawn'],
          setCode: 'c19',
          collectorNumber: '1',
          language: 'en',
        ),
      ]),
      isEmpty,
    );
    expect(
      (await Hive.openBox<String>('scanner_printings_v1')).values,
      isEmpty,
    );
  });

  test('printing searches coalesce concurrent calls and cache immutable paging metadata', () async {
    int requests = 0;
    final Completer<http.Response> response = Completer<http.Response>();
    final Completer<void> started = Completer<void>();
    final ScryfallScanCatalog catalog = ScryfallScanCatalog(
      api: ScryfallApiClient(
        httpClient: MockClient((http.Request request) {
          requests++;
          expect(request.url.path, '/cards/search');
          expect(
            request.url.queryParameters['q'],
            '!"Dusk // Dawn" game:paper set:c19 lang:en',
          );
          expect(request.url.queryParameters['unique'], 'prints');
          expect(request.url.queryParameters['include_multilingual'], 'true');
          expect(request.url.queryParameters['include_variations'], 'true');
          expect(request.url.queryParameters['include_extras'], 'true');
          started.complete();
          return response.future;
        }),
      ),
    );
    addTearDown(catalog.close);
    final Future<PaginableList<MtgCard>> first = catalog.printings(
      'Dusk // Dawn',
      setCode: 'c19',
      language: 'en',
    );
    final Future<PaginableList<MtgCard>> second = catalog.printings(
      'Dusk // Dawn',
      setCode: 'c19',
      language: 'en',
    );
    expect(identical(first, second), isTrue);
    await started.future;
    expect(requests, 1);
    response.complete(_printingPage(fixture, hasMore: true));
    final PaginableList<MtgCard> result = await first;
    expect(await second, same(result));
    expect(
      await catalog.printings('Dusk // Dawn', setCode: 'c19', language: 'en'),
      same(result),
    );
    expect(requests, 1);
    expect(result.data.single.name, 'Dusk // Dawn');
    expect(result.hasMore, isTrue);
    expect(
      result.nextPage,
      Uri.parse('https://api.scryfall.com/cards/search?page=2'),
    );
    expect(result.totalCards, 1);
    expect(result.warnings, <String>['Search warning']);
    expect(() => result.data.clear(), throwsUnsupportedError);
    expect(() => result.warnings!.add('Mutation'), throwsUnsupportedError);
  });

  test('printing search cache keys retain names sets languages pages and exact query escaping', () async {
    final List<Uri> requests = <Uri>[];
    final ScryfallScanCatalog catalog = ScryfallScanCatalog(
      api: ScryfallApiClient(
        httpClient: MockClient((http.Request request) async {
          requests.add(request.url);
          return _printingPage(fixture);
        }),
      ),
    );
    addTearDown(catalog.close);
    for (int repeat = 0; repeat < 2; repeat++) {
      await catalog.printings('Dusk // Dawn');
      await catalog.printings('Dusk // Dawn', setCode: 'c19');
      await catalog.printings('Dusk // Dawn', setCode: 'c19', language: 'en');
      await catalog.printings('Dusk // Dawn', setCode: 'c19', language: 'fr');
      await catalog.printings(
        'Dusk // Dawn',
        setCode: 'c19',
        language: 'en',
        page: 2,
      );
      await catalog.printings('Dawn');
      await catalog.printings(r'A "quoted" \ name');
    }
    expect(requests, hasLength(7));
    expect(requests[0].queryParameters['q'], '!"Dusk // Dawn" game:paper');
    expect(requests[0].queryParameters['include_multilingual'], 'false');
    expect(
      requests[1].queryParameters['q'],
      '!"Dusk // Dawn" game:paper set:c19',
    );
    expect(
      requests[2].queryParameters['q'],
      '!"Dusk // Dawn" game:paper set:c19 lang:en',
    );
    expect(
      requests[3].queryParameters['q'],
      '!"Dusk // Dawn" game:paper set:c19 lang:fr',
    );
    expect(requests[4].queryParameters['page'], '2');
    expect(requests[5].queryParameters['q'], '!"Dawn" game:paper');
    expect(
      requests[6].queryParameters['q'],
      r'!"A \"quoted\" \\ name" game:paper',
    );
  });

  test(
    'printing search expiry does not slide on cache hits and coalesces refresh',
    () async {
      DateTime now = DateTime.utc(2026, 10, 11);
      int requests = 0;
      final ScryfallScanCatalog catalog = ScryfallScanCatalog(
        clock: () => now,
        api: ScryfallApiClient(
          httpClient: MockClient((http.Request _) async {
            requests++;
            return _printingPage(fixture);
          }),
        ),
      );
      addTearDown(catalog.close);
      await catalog.printings('Dusk // Dawn');
      now = now.add(const Duration(minutes: 14));
      await catalog.printings('Dusk // Dawn');
      expect(requests, 1);
      now = now.add(const Duration(minutes: 1));
      await Future.wait<PaginableList<MtgCard>>(
        <Future<PaginableList<MtgCard>>>[
          catalog.printings('Dusk // Dawn'),
          catalog.printings('Dusk // Dawn'),
        ],
      );
      expect(requests, 2);
    },
  );

  test(
    'printing search LRU retains recent entries within the query limit',
    () async {
      final Map<String, int> calls = <String, int>{};
      final ScryfallScanCatalog catalog = ScryfallScanCatalog(
        api: ScryfallApiClient(
          httpClient: MockClient((http.Request request) async {
            final String query = request.url.queryParameters['q']!;
            calls[query] = (calls[query] ?? 0) + 1;
            return _printingPage(fixture, count: 0);
          }),
        ),
      );
      addTearDown(catalog.close);
      for (int index = 0; index < 64; index++) {
        await catalog.printings('Card $index');
      }
      await catalog.printings('Card 0');
      await catalog.printings('Card 64');
      await catalog.printings('Card 0');
      expect(calls['!"Card 0" game:paper'], 1);
      await catalog.printings('Card 1');
      expect(calls['!"Card 1" game:paper'], 2);
      expect(calls.length, 65);
    },
  );

  test(
    'printing search cache bounds total cards independently from query count',
    () async {
      final Map<String, int> calls = <String, int>{};
      final ScryfallScanCatalog catalog = ScryfallScanCatalog(
        api: ScryfallApiClient(
          httpClient: MockClient((http.Request request) async {
            final String query = request.url.queryParameters['q']!;
            calls[query] = (calls[query] ?? 0) + 1;
            return _printingPage(fixture, count: 64);
          }),
        ),
      );
      addTearDown(catalog.close);
      for (int index = 0; index < 33; index++) {
        await catalog.printings('Card $index');
      }
      await catalog.printings('Card 32');
      expect(calls['!"Card 32" game:paper'], 1);
      await catalog.printings('Card 0');
      expect(calls['!"Card 0" game:paper'], 2);
    },
  );

  test('printing search failures are shared but retryable and 404 empties are cached', () async {
    int requests = 0;
    final Completer<http.Response> firstResponse = Completer<http.Response>();
    final Completer<void> started = Completer<void>();
    final StateError failure = StateError('Connection failed');
    final ScryfallScanCatalog catalog = ScryfallScanCatalog(
      api: ScryfallApiClient(
        httpClient: MockClient((http.Request _) {
          requests++;
          if (requests == 1) {
            started.complete();
            return firstResponse.future;
          }
          return Future<http.Response>.value(_printingPage(fixture));
        }),
      ),
    );
    addTearDown(catalog.close);
    final Future<PaginableList<MtgCard>> first = catalog.printings(
      'Dusk // Dawn',
    );
    final Future<PaginableList<MtgCard>> second = catalog.printings(
      'Dusk // Dawn',
    );
    final Future<void> firstError = expectLater(first, throwsA(same(failure)));
    final Future<void> secondError = expectLater(
      second,
      throwsA(same(failure)),
    );
    await started.future;
    firstResponse.completeError(failure);
    await Future.wait<void>(<Future<void>>[firstError, secondError]);
    expect(requests, 1);
    expect((await catalog.printings('Dusk // Dawn')).data, hasLength(1));
    expect(requests, 2);

    int notFoundRequests = 0;
    final ScryfallScanCatalog notFound = ScryfallScanCatalog(
      api: ScryfallApiClient(
        httpClient: MockClient((http.Request _) async {
          notFoundRequests++;
          return http.Response(
            jsonEncode(<String, Object?>{
              'object': 'error',
              'status': 404,
              'code': 'not_found',
              'details': 'No cards matched.',
            }),
            404,
          );
        }),
      ),
    );
    addTearDown(notFound.close);
    expect((await notFound.printings('No card')).data, isEmpty);
    expect((await notFound.printings('No card')).hasMore, isFalse);
    expect(notFoundRequests, 1);
  });

  test('closing a printing catalog blocks cached hits and late response publication', () async {
    int requests = 0;
    final Completer<http.Response> response = Completer<http.Response>();
    final Completer<void> started = Completer<void>();
    final ScryfallScanCatalog catalog = ScryfallScanCatalog(
      api: ScryfallApiClient(
        httpClient: MockClient((http.Request request) {
          requests++;
          if (request.url.queryParameters['q'] == '!"Pending" game:paper') {
            started.complete();
            return response.future;
          }
          return Future<http.Response>.value(_printingPage(fixture));
        }),
      ),
    );
    await catalog.printings('Cached');
    final Future<PaginableList<MtgCard>> pending = catalog.printings('Pending');
    await started.future;
    catalog.close();
    response.complete(_printingPage(fixture));
    expect((await pending).data, hasLength(1));
    await expectLater(catalog.printings('Cached'), throwsStateError);
    await expectLater(catalog.printings('Pending'), throwsStateError);
    expect(requests, 2);
    catalog.close();
  });

  test(
    'printing search server errors do not become cached empty matches',
    () async {
      int requests = 0;
      final ScryfallScanCatalog catalog = ScryfallScanCatalog(
        api: ScryfallApiClient(
          httpClient: MockClient((http.Request _) async {
            requests++;
            if (requests == 1) {
              return http.Response(
                jsonEncode(<String, Object?>{
                  'object': 'error',
                  'status': 500,
                  'code': 'server_error',
                  'details': 'Try again.',
                }),
                500,
              );
            }
            return _printingPage(fixture);
          }),
        ),
      );
      addTearDown(catalog.close);
      await expectLater(
        catalog.printings('Dusk // Dawn'),
        throwsA(
          isA<ScryfallException>().having(
            (ScryfallException error) => error.status,
            'status',
            500,
          ),
        ),
      );
      expect((await catalog.printings('Dusk // Dawn')).data, hasLength(1));
      await catalog.printings('Dusk // Dawn');
      expect(requests, 2);
    },
  );

  test('exact collection batches cap at 75, preserve duplicates and cache across catalog instances', () async {
    final List<int> batchSizes = <int>[];
    final ScryfallScanCatalog catalog = ScryfallScanCatalog(
      api: ScryfallApiClient(
        httpClient: MockClient((http.Request request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/cards/collection');
          final Map<String, Object?> body = Map<String, Object?>.from(
            jsonDecode(request.body) as Map<Object?, Object?>,
          );
          final List<Object?> identifiers =
              body['identifiers'] as List<Object?>;
          batchSizes.add(identifiers.length);
          return http.Response(
            jsonEncode(<String, Object?>{
              'object': 'list',
              'not_found': <Object?>[],
              'data': identifiers
                  .map(
                    (Object? raw) => <String, Object?>{
                      ...fixture,
                      'set': 'tst',
                      'collector_number':
                          (raw as Map<String, Object?>)['collector_number'],
                    },
                  )
                  .toList(),
            }),
            200,
            headers: <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      ),
    );
    addTearDown(catalog.close);
    final List<ScanHints> hints = List<ScanHints>.generate(
      180,
      (int index) => ScanHints(
        names: const <String>['Dusk // Dawn'],
        setCode: 'tst',
        collectorNumber: '${index % 160 + 1}',
        language: 'en',
      ),
    );
    expect((await catalog.exactPrintings(hints)).length, 160);
    expect(batchSizes, <int>[75, 75, 10]);
    final ScryfallScanCatalog reopened = ScryfallScanCatalog(
      api: ScryfallApiClient(
        httpClient: MockClient(
          (http.Request _) async =>
              throw StateError('cached printing must not request network'),
        ),
      ),
    );
    addTearDown(reopened.close);
    expect((await reopened.exactPrintings(hints)).length, 160);
  });

  test('padded symbol footer retries in collection batches and caches the confirmed alias', () async {
    final List<String> numbers = <String>[];
    final ScryfallScanCatalog catalog = ScryfallScanCatalog(
      api: ScryfallApiClient(
        httpClient: MockClient((http.Request request) async {
          final Map<String, Object?> body = Map<String, Object?>.from(
            jsonDecode(request.body) as Map<Object?, Object?>,
          );
          final Map<String, Object?> identifier = Map<String, Object?>.from(
            (body['identifiers'] as List<Object?>).single
                as Map<Object?, Object?>,
          );
          final String number = identifier['collector_number'] as String;
          numbers.add(number);
          return http.Response(
            jsonEncode(<String, Object?>{
              'object': 'list',
              'not_found': number == '001★'
                  ? <Object?>[identifier]
                  : <Object?>[],
              'data': number == '001★'
                  ? <Object?>[]
                  : <Object?>[
                      <String, Object?>{
                        ...fixture,
                        'set': 'tst',
                        'collector_number': '1★',
                      },
                    ],
            }),
            200,
            headers: <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      ),
    );
    addTearDown(catalog.close);
    const List<ScanHints> hints = <ScanHints>[
      ScanHints(
        names: <String>['Dusk // Dawn'],
        setCode: 'tst',
        collectorNumber: '001★',
        language: 'en',
      ),
    ];
    final Map<String, MtgCard> result = await catalog.exactPrintings(hints);
    expect(result['tst/001★/en']?.collectorNumber, '1★');
    expect(numbers, <String>['001★', '1★']);
    await catalog.exactPrintings(hints);
    expect(numbers, hasLength(2));
  });
}
