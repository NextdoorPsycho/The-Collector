import 'dart:convert';
import 'dart:io';

import 'package:collector_models/deck/deck_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/moxfield_import.dart';

Map<String, Object?> _card({
  String name = 'Dusk // Dawn',
  String set = 'c19',
  String number = '63',
  String id = 'e9d5aee0-5963-41db-a22b-cfea40a967a3',
  String language = 'en',
  List<String> finishes = const <String>['nonfoil', 'foil', 'etched'],
}) {
  final Map<String, Object?> json = Map<String, Object?>.from(
    jsonDecode(
      File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
    ) as Map<String, Object?>,
  );
  json['id'] = id;
  json['name'] = name;
  json['set'] = set;
  json['collector_number'] = number;
  json['lang'] = language;
  json['finishes'] = finishes;
  return json;
}

http.Response _collection(List<Map<String, Object?>> cards) => http.Response(
  jsonEncode(<String, Object?>{
    'object': 'list',
    'not_found': <Object?>[],
    'data': cards,
  }),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

void main() {
  test('Arena and Moxfield TXT preserve quantities, boards, printings and finishes', () {
    final MoxfieldImportDocument document = parseMoxfieldExport(
      '\uFEFFMainboard\r\n2 Dusk // Dawn (C19) 63\r\n3 Dusk // Dawn (C19) 63\r\n'
      'Sideboard\r\n1 Dusk // Dawn (C19) 63 *F*\r\nCommander\r\n1 Sol Ring\r\n'
      'Maybeboard\r\n1 Island\r\nCompanion\r\n1 Dusk // Dawn (C19) 63 *E*\r\n',
      sourceName: 'Deck export',
    );
    expect(document.issues, isEmpty);
    expect(document.sourceName, 'Deck export');
    expect(document.sourceFormat, 'moxfield-txt');
    expect(document.rows, hasLength(5));
    expect(document.rows.first.quantity, 5);
    expect(document.rows.first.setCode, 'c19');
    expect(document.rows.first.collectorNumber, '63');
    expect(document.rows[1].finish, Finish.foil);
    expect(document.rows[1].section, DeckSection.sideboard);
    expect(document.rows[2].section, DeckSection.commander);
    expect(document.rows[3].section, DeckSection.maybeboard);
    expect(document.rows[4].section, DeckSection.companion);
    expect(document.rows[4].finish, Finish.etched);
    expect(document.totalQuantity, 9);
  });

  test('CSV decodes quoted commas, escaped quotes, multiline fields and physical row numbers', () {
    final MoxfieldImportDocument document = parseMoxfieldExport(
      '\uFEFFCount,Name,Edition,Condition,Language,Foil,Collector Number,Section\r\n'
      '2,"Borborygmos, Enraged",GTC,"Near Mint",English,false,147,Mainboard\r\n'
      '1,"Dusk // Dawn",C19,"Played\r\nwith ""marks""",French,etched,63,Maybeboard\r\n'
      '0,Island,,,,,,\r\n',
    );
    expect(document.sourceFormat, 'moxfield-csv');
    expect(document.rows, hasLength(2));
    expect(document.rows.first.name, 'Borborygmos, Enraged');
    expect(document.rows.first.language, 'en');
    expect(document.rows.first.condition, 'Near Mint');
    expect(document.rows.last.condition, 'Played\nwith "marks"');
    expect(document.rows.last.language, 'fr');
    expect(document.rows.last.finish, Finish.etched);
    expect(document.rows.last.section, DeckSection.maybeboard);
    expect(document.issues.single.line, 5);
    expect(document.issues.single.kind, MoxfieldImportIssueKind.source);
  });

  test('distinct finishes, language, condition and sections do not merge', () {
    final MoxfieldImportDocument document = parseMoxfieldExport(
      'Count,Name,Edition,Condition,Language,Foil,Collector Number,Section\n'
      '1,Dusk // Dawn,C19,Near Mint,English,false,63,Mainboard\n'
      '2,Dusk // Dawn,C19,Near Mint,English,false,63,Mainboard\n'
      '1,Dusk // Dawn,C19,Played,English,false,63,Mainboard\n'
      '1,Dusk // Dawn,C19,Near Mint,French,false,63,Mainboard\n'
      '1,Dusk // Dawn,C19,Near Mint,English,true,63,Mainboard\n'
      '1,Dusk // Dawn,C19,Near Mint,English,false,63,Sideboard\n',
    );
    expect(document.issues, isEmpty);
    expect(document.rows, hasLength(5));
    expect(document.rows.first.quantity, 3);
  });

  test(
    'invalid rows, quantities, finishes and malformed quotes produce issues',
    () {
      final MoxfieldImportDocument text = parseMoxfieldExport(
        '1 Island\n0 Sol Ring\n1000001 Island\n1 Island (M21) 265 *G*\nbroken row\n',
      );
      expect(text.rows, hasLength(1));
      expect(text.issues.map((MoxfieldImportIssue issue) => issue.line), <int>[
        2,
        3,
        4,
        5,
      ]);
      final MoxfieldImportDocument csv = parseMoxfieldExport(
        'Count,Name\n1,"Island\n',
      );
      expect(csv.rows, isEmpty);
      expect(csv.issues.single.message, contains('Unterminated'));
      expect(parseMoxfieldExport('').issues, isNotEmpty);
      expect(
        () => parseMoxfieldExport('a' * 2097153),
        throwsA(isA<MoxfieldImportException>()),
      );
      expect(
        () => parseMoxfieldExport(
          List<String>.filled(10001, '1 Island').join('\n'),
        ),
        throwsA(isA<MoxfieldImportException>()),
      );
      expect(
        () => parseMoxfieldExport(
          'Count,Name\n${List<String>.filled(10001, '1,Island').join('\n')}',
        ),
        throwsA(isA<MoxfieldImportException>()),
      );
    },
  );

  test('URL access errors use an identified request once and offer export fallback', () async {
    int calls = 0;
    final MockClient client = MockClient((http.Request request) async {
      calls++;
      expect(request.url.host, 'api2.moxfield.com');
      expect(request.url.path, '/v3/decks/all/test-deck');
      expect(request.followRedirects, isFalse);
      expect(request.headers['User-Agent'], startsWith('TheCollector/'));
      expect(request.headers.containsKey('Cookie'), isFalse);
      return http.Response('Forbidden', 403);
    });
    final MoxfieldImportService service = MoxfieldImportService(client: client);
    addTearDown(service.close);
    await expectLater(
      service.loadSource('https://moxfield.com/decks/test-deck'),
      throwsA(
        isA<MoxfieldImportException>().having(
          (MoxfieldImportException e) => e.message,
          'fallback',
          contains('TXT or CSV'),
        ),
      ),
    );
    expect(calls, 1);
    for (final String value in <String>[
      'https://evil.example/decks/test-deck',
      'http://moxfield.com/decks/test-deck',
      'https://moxfield.com@evil.example/decks/test-deck',
      'https://moxfield.com/decks/test-deck?redirect=evil',
      'https://moxfield.com/decks/a%2Fb',
    ]) {
      await expectLater(
        service.loadSource(value),
        throwsA(isA<MoxfieldImportException>()),
      );
    }
    expect(calls, 1);
  });

  test('public response preserves metadata and reports unsupported nonempty boards', () async {
    final MockClient client = MockClient(
      (http.Request request) async => http.Response(
        jsonEncode(<String, Object?>{
          'name': 'Public deck',
          'format': 'commander',
          'boards': <String, Object?>{
            'mainboard': <String, Object?>{
              'cards': <String, Object?>{
                'card': <String, Object?>{
                  'quantity': 3,
                  'finish': 'foil',
                  'card': <String, Object?>{
                    'name': 'Dusk // Dawn',
                    'set': 'c19',
                    'cn': '63',
                    'lang': 'en',
                  },
                },
              },
            },
            'maybeboard': <String, Object?>{'cards': <String, Object?>{}},
            'tokens': <String, Object?>{
              'count': 0,
              'cards': <String, Object?>{},
            },
            'unknown': <String, Object?>{
              'cards': <String, Object?>{
                'a': <String, Object?>{'quantity': 1},
              },
            },
          },
        }),
        200,
      ),
    );
    final MoxfieldImportService service = MoxfieldImportService(client: client);
    addTearDown(service.close);
    final MoxfieldImportDocument document = await service.loadSource(
      'https://www.moxfield.com/decks/public-deck',
    );
    expect(document.sourceName, 'Public deck');
    expect(document.deckFormat, 'commander');
    expect(document.sourceFormat, 'moxfield-url');
    expect(document.sourceUrl, 'https://www.moxfield.com/decks/public-deck');
    expect(document.rows.single.quantity, 3);
    expect(document.rows.single.finish, Finish.foil);
    expect(document.issues, hasLength(1));
  });

  test('catalog resolves set/collector before UUID and preserves finish, condition and language', () async {
    final MockClient client = MockClient((http.Request request) async {
      final Map<String, Object?> body =
          jsonDecode(request.body) as Map<String, Object?>;
      expect(body['identifiers'], <Object?>[
        <String, Object?>{'set': 'c19', 'collector_number': '63'},
      ]);
      expect(request.headers['User-Agent'], startsWith('TheCollector/'));
      return _collection(<Map<String, Object?>>[_card()]);
    });
    final MoxfieldImportService service = MoxfieldImportService(
      scryfallClient: client,
    );
    addTearDown(service.close);
    final MoxfieldImportPreview preview = await service.prepare(
      'Count,Name,Edition,Condition,Language,Foil,Collector Number,Scryfall ID,Section\n'
      '2,Dusk // Dawn,C19,Near Mint,English,true,63,e9d5aee0-5963-41db-a22b-cfea40a967a3,Sideboard\n',
    );
    expect(preview.canImport, isTrue);
    expect(preview.requiresReview, isFalse);
    expect(preview.entries.single.entry.quantity, 2);
    expect(preview.entries.single.entry.finish, Finish.foil);
    expect(preview.entries.single.entry.condition, 'Near Mint');
    expect(preview.entries.single.entry.language, 'en');
    expect(preview.entries.single.entry.section, DeckSection.sideboard);
    expect(
      preview.entries.single.card.printingId,
      'e9d5aee0-5963-41db-a22b-cfea40a967a3',
    );
  });

  test('name-only matches require review and merge only matching resolved variants', () async {
    final MoxfieldImportService service = MoxfieldImportService(
      scryfallClient: MockClient((http.Request request) async {
        return _collection(<Map<String, Object?>>[_card(), _card()]);
      }),
    );
    addTearDown(service.close);
    final MoxfieldImportPreview preview = await service.prepare(
      '1 Dusk // Dawn\n2 Dusk // Dawn (C19) 63\nSideboard\n1 Dusk // Dawn\n',
    );
    expect(preview.canImport, isTrue);
    expect(preview.requiresReview, isTrue);
    expect(preview.entries, hasLength(2));
    expect(preview.entries.first.entry.quantity, 3);
    expect(preview.entries.first.exactPrinting, isFalse);
    expect(preview.resolvedQuantity, 4);
  });

  test('wrong printing, unknown names and unavailable finishes block import without substitutions', () async {
    final MoxfieldImportService service = MoxfieldImportService(
      scryfallClient: MockClient((http.Request request) async {
        return _collection(<Map<String, Object?>>[
          _card(finishes: <String>['nonfoil']),
        ]);
      }),
    );
    addTearDown(service.close);
    final MoxfieldImportPreview preview = await service.prepare(
      '1 Dusk // Dawn (C19) 63 *F*\n1 Wrong Name (C19) 63\n1 Missing Card\n',
    );
    expect(preview.canImport, isFalse);
    expect(preview.entries, isEmpty);
    expect(preview.issues, hasLength(3));
    expect(
      preview.issues.every(
        (MoxfieldImportIssue issue) =>
            issue.kind == MoxfieldImportIssueKind.lookup,
      ),
      isTrue,
    );
    expect(preview.issues.first.message, contains('unavailable'));
    expect(preview.issues[1].message, contains('conflicts'));
  });

  test(
    'requested printed language uses exact set/number language lookup',
    () async {
      int calls = 0;
      final MoxfieldImportService service = MoxfieldImportService(
        scryfallClient: MockClient((http.Request request) async {
          calls++;
          if (request.method == 'POST') {
            return _collection(<Map<String, Object?>>[_card()]);
          }
          expect(request.url.path, '/cards/c19/63/fr');
          return http.Response(
            jsonEncode(
              _card(language: 'fr', id: 'b9d5aee0-5963-41db-a22b-cfea40a967a3'),
            ),
            200,
          );
        }),
      );
      addTearDown(service.close);
      final MoxfieldImportPreview preview = await service.prepare(
        'Count,Name,Edition,Language,Collector Number\n1,Dusk // Dawn,C19,French,63\n',
      );
      expect(calls, 2);
      expect(preview.canImport, isTrue);
      expect(preview.entries.single.entry.language, 'fr');
      expect(
        preview.entries.single.entry.scryfallId,
        'b9d5aee0-5963-41db-a22b-cfea40a967a3',
      );
    },
  );

  test('bulk identifiers are limited to 75 and cancellation stops subsequent batches', () async {
    int calls = 0;
    bool cancelled = false;
    final List<int> progress = <int>[];
    final MoxfieldImportService service = MoxfieldImportService(
      scryfallClient: MockClient((http.Request request) async {
        calls++;
        final Map<String, Object?> body =
            jsonDecode(request.body) as Map<String, Object?>;
        final List<Object?> identifiers = body['identifiers'] as List<Object?>;
        expect(identifiers.length, lessThanOrEqualTo(75));
        return _collection(
          identifiers
              .map((Object? identifier) {
                final Map<String, Object?> item =
                    identifier as Map<String, Object?>;
                final String number = item['collector_number'] as String;
                return _card(
                  name: 'Card $number',
                  number: number,
                  id: 'e9d5aee0-5963-41db-a22b-${int.parse(number).toString().padLeft(12, '0')}',
                );
              })
              .toList(growable: false),
        );
      }),
    );
    addTearDown(service.close);
    final String text = List<String>.generate(
      80,
      (int index) => '1 Card $index (C19) $index',
    ).join('\n');
    await expectLater(
      service.prepare(
        text,
        isCancelled: () => cancelled,
        onProgress: (int resolved, int total) {
          progress.add(resolved);
          expect(total, 80);
          if (resolved == 75) cancelled = true;
        },
      ),
      throwsA(isA<MoxfieldImportCancelled>()),
    );
    expect(calls, 1);
    expect(progress.first, 0);
    expect(progress.last, 75);
  });
}
