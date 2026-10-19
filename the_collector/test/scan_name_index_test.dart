import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:the_collector/utils/scanning/scan_name_index.dart';

ScryfallScanNameIndex _index(List<String> names) => ScryfallScanNameIndex(
  loader: () async => names,
  readCache: () async => null,
  writeCache: (String _) async {},
);

void main() {
  test(
    'ready-only lookup never waits for a blocked loader and coalesces warming',
    () async {
      int loads = 0;
      final Completer<List<String>> loaded = Completer<List<String>>();
      final ScryfallScanNameIndex index = ScryfallScanNameIndex(
        loader: () {
          loads++;
          return loaded.future;
        },
        readCache: () async => null,
        writeCache: (String _) async {},
      );
      addTearDown(index.close);
      expect(index.matchReady('Cooperation'), isNull);
      expect(index.matchReady('Cooperarion'), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(loads, 1);
      final Future<void> warming = index.warm();
      loaded.complete(<String>['Cooperation']);
      await warming;
      expect(index.matchReady('Cooperation')?.exact, isTrue);
      expect(index.matchReady('Cooperarion')?.canonicalName, 'Cooperation');
      expect(index.matchReady('Cooperarion')?.exact, isFalse);
      expect(loads, 1);
    },
  );

  test(
    'a valid built index is usable while its optional cache write is blocked',
    () async {
      final Completer<void> writing = Completer<void>();
      final Completer<void> written = Completer<void>();
      final ScryfallScanNameIndex index = ScryfallScanNameIndex(
        loader: () async => <String>['Cooperation'],
        readCache: () async => null,
        writeCache: (String _) {
          writing.complete();
          return written.future;
        },
      );
      final Future<void> warming = index.warm();
      addTearDown(() async {
        if (!written.isCompleted) written.complete();
        await warming;
        index.close();
      });
      await writing.future.timeout(const Duration(seconds: 2));
      expect(index.matchReady('Cooperarion')?.canonicalName, 'Cooperation');
      expect(index.matchReady('Cooperarion')?.exact, isFalse);
      expect(written.isCompleted, isFalse);
      written.complete();
      await warming;
    },
  );

  test(
    'ready-only lookup withholds expired index evidence during refresh',
    () async {
      DateTime now = DateTime.utc(2026, 10, 12);
      int loads = 0;
      final Completer<List<String>> reloaded = Completer<List<String>>();
      final ScryfallScanNameIndex index = ScryfallScanNameIndex(
        clock: () => now,
        loader: () {
          loads++;
          return loads == 1
              ? Future<List<String>>.value(<String>['Cooperation'])
              : reloaded.future;
        },
        readCache: () async => null,
        writeCache: (String _) async {},
      );
      addTearDown(index.close);
      await index.warm();
      expect(index.matchReady('Cooperarion')?.canonicalName, 'Cooperation');
      now = now.add(ScryfallScanNameIndex.cacheLifetime);
      expect(index.matchReady('Cooperarion'), isNull);
      expect(index.matchReady('Cooperation'), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(loads, 2);
      final Future<void> warming = index.warm();
      reloaded.complete(<String>['Jolted Awake']);
      await warming;
      expect(index.matchReady('Cooperarion'), isNull);
      expect(index.matchReady('Jolted Awake')?.exact, isTrue);
    },
  );

  test(
    'ready-only lookup handles failed warming and preserves retry cooldown',
    () async {
      DateTime now = DateTime.utc(2026, 10, 12);
      int loads = 0;
      final ScryfallScanNameIndex index = ScryfallScanNameIndex(
        clock: () => now,
        loader: () async {
          loads++;
          if (loads == 1) throw StateError('offline');
          return <String>['Cooperation'];
        },
        readCache: () async => null,
        writeCache: (String _) async {},
      );
      addTearDown(index.close);
      expect(index.matchReady('Cooperation'), isNull);
      await index.warm();
      expect(index.matchReady('Cooperation'), isNull);
      await index.warm();
      expect(loads, 1);
      now = now.add(const Duration(minutes: 1));
      expect(index.matchReady('Cooperation'), isNull);
      await index.warm();
      expect(index.matchReady('Cooperation')?.exact, isTrue);
      index.close();
      expect(index.matchReady('Cooperation'), isNull);
    },
  );

  test(
    'canonical name lookup preserves literal punctuation and Unicode',
    () async {
      final ScryfallScanNameIndex index = _index(<String>[
        'Circle of Protection: Blue',
        'Snow-Covered Swamp',
        "Urza's Saga",
        'Lim-Dûl’s Vault',
        'Dusk // Dawn',
      ]);
      addTearDown(index.close);
      for (final (String observed, String expected) in <(String, String)>[
        ('  CIRCLE OF PROTECTION BLUE ', 'Circle of Protection: Blue'),
        ('snow covered swamp', 'Snow-Covered Swamp'),
        ('Urza’s Saga', "Urza's Saga"),
        ('Lim Dûl\'s Vault', 'Lim-Dûl’s Vault'),
        ('Dusk / Dawn', 'Dusk // Dawn'),
      ]) {
        final ScanNameMatch? result = await index.match(observed);
        expect(result?.canonicalName, expected);
        expect(result?.exact, isTrue);
      }
    },
  );

  test(
    'one damaged OCR letter proposes a name without exact classification',
    () async {
      final ScryfallScanNameIndex index = _index(<String>[
        'Cooperation',
        'Jolted Awake',
        'Circle of Protection: Blue',
      ]);
      addTearDown(index.close);
      final ScanNameMatch? result = await index.match('Cooperarion');
      expect(result?.canonicalName, 'Cooperation');
      expect(result?.exact, isFalse);
      expect(
        (await index.match('Circlc of Protection Blue'))?.canonicalName,
        'Circle of Protection: Blue',
      );
      expect((await index.match('Xooperation'))?.canonicalName, 'Cooperation');
    },
  );

  test(
    'ambiguous nearest names and normalized collisions return no match',
    () async {
      final ScryfallScanNameIndex index = _index(<String>[
        'Cooperation',
        'Cooperasion',
        'A-B Card',
        'A B Card',
      ]);
      addTearDown(index.close);
      expect(await index.match('Cooperarion'), isNull);
      expect(await index.match('A B Card'), isNull);
      expect(await index.match('AB Card'), isNull);
    },
  );

  test('long damaged title can use a unique guarded name suggestion', () async {
    final ScryfallScanNameIndex index = _index(<String>[
      'Circle of Protection: Blue',
      'Rune of Protection: Blue',
      'Circle of Protection: Black',
      'Circle of Protection: Green',
      'Circle of Protection: Red',
      'Circle of Protection: White',
    ]);
    addTearDown(index.close);
    final ScanNameMatch? result = await index.match(
      'Ctroleof Proceetion: Blue',
    );
    expect(result?.canonicalName, 'Circle of Protection: Blue');
    expect(result?.exact, isFalse);
    expect(await index.match('Crele of Proceerion: Blue'), isNull);
  });

  test(
    'two damaged letters in a medium title require a two-edit margin',
    () async {
      final ScryfallScanNameIndex index = _index(<String>[
        'Cooperation',
        'Moderation',
        'Solarion',
        'Stone Rain',
      ]);
      addTearDown(index.close);
      final ScanNameMatch? result = await index.match('Sooperarion');
      expect(result?.canonicalName, 'Cooperation');
      expect(result?.exact, isFalse);
    },
  );

  test('three-edit runner blocks a two-edit medium-title suggestion', () async {
    final ScryfallScanNameIndex index = _index(<String>[
      'Cooperation',
      // Synthetic runner lies outside acceptance but inside the margin guard.
      'Xooxerariqn',
    ]);
    addTearDown(index.close);
    expect(await index.match('Sooperarion'), isNull);
  });

  test(
    'medium title rejects equally close identities and low-information text',
    () async {
      final ScryfallScanNameIndex index = _index(<String>[
        'Cooperation',
        'Cooperasion',
        'aaaaaaaaaac',
      ]);
      addTearDown(index.close);
      expect(await index.match('Sooperarion'), isNull);
      expect(await index.match('aaaaaaaaaab'), isNull);
    },
  );

  test('guarded long title declines a one-edit runner-up outside acceptance radius', () async {
    final ScryfallScanNameIndex index = _index(<String>[
      'Circle of Protection: Blue',
      // These synthetic names put competitors at distances four and five.
      'Xtqole of Prxcxetion: Xlue',
    ]);
    addTearDown(index.close);
    expect(await index.match('Ctroleof Proceetion: Blue'), isNull);
  });

  test('long title suffix ambiguity does not select one color', () async {
    final ScryfallScanNameIndex index = _index(<String>[
      'Circle of Protection: Blue',
      'Circle of Protection: Black',
    ]);
    addTearDown(index.close);
    expect(await index.match('Circle of Protection: Bla'), isNull);
  });

  test(
    'short fuzzy titles missing words and unrelated rules do not match',
    () async {
      final ScryfallScanNameIndex index = _index(<String>[
        'Shock',
        'Jolted Awake',
        'Snow-Covered Swamp',
        'Cooperation',
      ]);
      addTearDown(index.close);
      expect(await index.match('Shoc'), isNull);
      expect(await index.match('Jolted'), isNull);
      expect(await index.match('target creature gains banding'), isNull);
      expect(await index.match('Coperarin'), isNull);
      expect((await index.match('Shock'))?.exact, isTrue);
    },
  );

  test('diacritics remain distinct rather than being erased', () async {
    final ScryfallScanNameIndex index = _index(<String>[
      'Lim-Dûl’s Vault',
      "Lim-Dul's Vault",
    ]);
    addTearDown(index.close);
    expect(
      (await index.match("Lim-Dûl's Vault"))?.canonicalName,
      'Lim-Dûl’s Vault',
    );
    expect(
      (await index.match("Lim-Dul's Vault"))?.canonicalName,
      "Lim-Dul's Vault",
    );
  });

  test(
    'concurrent crops coalesce the catalog and persist one immutable list',
    () async {
      int loads = 0;
      int writes = 0;
      String? stored;
      final Completer<List<String>> loaded = Completer<List<String>>();
      final ScryfallScanNameIndex index = ScryfallScanNameIndex(
        loader: () {
          loads++;
          return loaded.future;
        },
        readCache: () async => null,
        writeCache: (String value) async {
          writes++;
          stored = value;
        },
      );
      addTearDown(index.close);
      final List<Future<ScanNameMatch?>> pending = <Future<ScanNameMatch?>>[
        index.match('Cooperation'),
        index.match('Jolted Awake'),
        index.match('Cooperarion'),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(loads, 1);
      final List<String> names = <String>['Cooperation', 'Jolted Awake'];
      loaded.complete(names);
      expect(
        (await Future.wait(pending))
            .map((ScanNameMatch? m) => m?.canonicalName),
        <String>['Cooperation', 'Jolted Awake', 'Cooperation'],
      );
      expect(writes, 1);
      names.clear();
      expect((await index.match('Cooperation'))?.canonicalName, 'Cooperation');
      final Map<String, Object?> record =
          jsonDecode(stored!) as Map<String, Object?>;
      expect(record['names'], <String>['Cooperation', 'Jolted Awake']);
    },
  );

  test('persisted catalog TTL does not slide on memory hits', () async {
    DateTime now = DateTime.utc(2026, 10, 12);
    final DateTime at = now.subtract(const Duration(hours: 23));
    int loads = 0;
    final ScryfallScanNameIndex index = ScryfallScanNameIndex(
      clock: () => now,
      readCache: () async => jsonEncode(<String, Object?>{
        'at': at.toIso8601String(),
        'names': <String>['Cooperation'],
      }),
      loader: () async {
        loads++;
        return <String>['Jolted Awake'];
      },
      writeCache: (String _) async {},
    );
    addTearDown(index.close);
    expect((await index.match('Cooperation'))?.canonicalName, 'Cooperation');
    expect(loads, 0);
    now = now.add(const Duration(minutes: 59));
    expect((await index.match('Cooperation'))?.canonicalName, 'Cooperation');
    now = now.add(const Duration(minutes: 1));
    expect((await index.match('Jolted Awake'))?.canonicalName, 'Jolted Awake');
    expect(loads, 1);
  });

  test(
    'invalid expired or future cache records fall back to the loader',
    () async {
      final DateTime now = DateTime.utc(2026, 10, 12);
      for (final String stored in <String>[
        'broken json',
        jsonEncode(<String, Object?>{
          'at': now.toIso8601String(),
          'names': <Object?>[3],
        }),
        jsonEncode(<String, Object?>{
          'at': now.toIso8601String(),
          'names': <String>[''],
        }),
        jsonEncode(<String, Object?>{
          'at': now.subtract(const Duration(days: 1)).toIso8601String(),
          'names': <String>['Shock'],
        }),
        jsonEncode(<String, Object?>{
          'at': now.add(const Duration(seconds: 1)).toIso8601String(),
          'names': <String>['Shock'],
        }),
      ]) {
        int loads = 0;
        final ScryfallScanNameIndex index = ScryfallScanNameIndex(
          clock: () => now,
          readCache: () async => stored,
          loader: () async {
            loads++;
            return <String>['Cooperation'];
          },
          writeCache: (String _) async {},
        );
        expect(
          (await index.match('Cooperation'))?.canonicalName,
          'Cooperation',
        );
        expect(loads, 1);
        index.close();
      }
    },
  );

  test(
    'cache read and write failures leave the in-memory catalog usable',
    () async {
      final ScryfallScanNameIndex index = ScryfallScanNameIndex(
        readCache: () async => throw StateError('closed cache'),
        writeCache: (String _) async => throw StateError('full disk'),
        loader: () async => <String>['Cooperation'],
      );
      addTearDown(index.close);
      expect((await index.match('Cooperation'))?.canonicalName, 'Cooperation');
      expect((await index.match('Cooperarion'))?.exact, isFalse);
    },
  );

  test(
    'failed downloads fall back and briefly suppress repeated API attempts',
    () async {
      DateTime now = DateTime.utc(2026, 10, 12);
      int loads = 0;
      final ScryfallScanNameIndex index = ScryfallScanNameIndex(
        clock: () => now,
        readCache: () async => null,
        writeCache: (String _) async {},
        loader: () async {
          loads++;
          if (loads == 1) throw StateError('network unavailable');
          return <String>['Cooperation'];
        },
      );
      addTearDown(index.close);
      expect(await index.match('Cooperation'), isNull);
      expect(await index.match('Cooperarion'), isNull);
      expect(loads, 1);
      now = now.add(const Duration(minutes: 1));
      expect((await index.match('Cooperation'))?.canonicalName, 'Cooperation');
      expect(loads, 2);
    },
  );

  test(
    'download uses only public name catalog and required request headers',
    () async {
      final ScryfallScanNameIndex index = ScryfallScanNameIndex(
        client: MockClient((http.Request request) async {
          expect(
            request.url.toString(),
            'https://api.scryfall.com/catalog/card-names',
          );
          expect(request.headers['Accept'], 'application/json');
          expect(request.headers['User-Agent'], contains('TheCollector'));
          return http.Response(
            jsonEncode(<String, Object?>{
              'object': 'catalog',
              'total_values': 2,
              'data': <String>['Cooperation', 'Jolted Awake'],
            }),
            200,
          );
        }),
        readCache: () async => null,
        writeCache: (String _) async {},
      );
      addTearDown(index.close);
      expect((await index.match('Cooperarion'))?.canonicalName, 'Cooperation');
    },
  );

  test(
    'invalid catalog counts types lengths and control characters are rejected',
    () async {
      for (final Object? payload in <Object?>[
        <String, Object?>{
          'object': 'list',
          'total_values': 1,
          'data': <String>['Shock'],
        },
        <String, Object?>{
          'object': 'catalog',
          'total_values': 2,
          'data': <String>['Shock'],
        },
        <String, Object?>{
          'object': 'catalog',
          'total_values': 1,
          'data': <Object?>[null],
        },
        <String, Object?>{
          'object': 'catalog',
          'total_values': 1,
          'data': <String>[' bad '],
        },
        <String, Object?>{
          'object': 'catalog',
          'total_values': 1,
          'data': <String>['bad\nname'],
        },
        <String, Object?>{
          'object': 'catalog',
          'total_values': 1,
          'data': <String>['x' * 201],
        },
      ]) {
        final ScryfallScanNameIndex index = ScryfallScanNameIndex(
          client: MockClient(
            (http.Request _) async => http.Response(jsonEncode(payload), 200),
          ),
          readCache: () async => null,
          writeCache: (String _) async =>
              fail('Invalid data must not be cached.'),
        );
        expect(await index.match('Shock'), isNull);
        index.close();
      }
    },
  );

  test('maximum catalog count is enforced for injected loaders', () async {
    final ScryfallScanNameIndex index = _index(
      List<String>.filled(ScryfallScanNameIndex.maximumNames + 1, 'Shock'),
    );
    addTearDown(index.close);
    expect(await index.match('Shock'), isNull);
  });

  test(
    'dense fuzzy buckets decline rather than compare an unbounded list',
    () async {
      final ScryfallScanNameIndex index = _index(<String>[
        for (int id = 0; id < 600; id++)
          'Cooperatio${String.fromCharCode(0x4e00 + id)}',
      ]);
      addTearDown(index.close);
      expect(await index.match('Cooperatiox'), isNull);
    },
  );

  test(
    'oversized response and HTTP failures permit the resolver fallback',
    () async {
      for (final http.Response response in <http.Response>[
        http.Response(
          ' ' * (ScryfallScanNameIndex.maximumPayloadBytes + 1),
          200,
        ),
        http.Response('rate limited', 429),
      ]) {
        final ScryfallScanNameIndex index = ScryfallScanNameIndex(
          client: MockClient((http.Request _) async => response),
          readCache: () async => null,
          writeCache: (String _) async =>
              fail('Failed catalogs must not be cached.'),
        );
        expect(await index.match('Cooperation'), isNull);
        index.close();
      }
    },
  );

  test('oversized or blank observed names do not start a download', () async {
    int loads = 0;
    final ScryfallScanNameIndex index = ScryfallScanNameIndex(
      loader: () async {
        loads++;
        return <String>['Cooperation'];
      },
      readCache: () async => null,
      writeCache: (String _) async {},
    );
    addTearDown(index.close);
    expect(await index.match('x' * 201), isNull);
    expect(await index.match('  : '), isNull);
    expect(loads, 0);
  });

  test(
    'closed index ignores in-flight results and subsequent lookups',
    () async {
      final Completer<List<String>> loaded = Completer<List<String>>();
      final ScryfallScanNameIndex index = ScryfallScanNameIndex(
        loader: () => loaded.future,
        readCache: () async => null,
        writeCache: (String _) async {},
      );
      final Future<ScanNameMatch?> pending = index.match('Cooperation');
      await Future<void>.delayed(Duration.zero);
      index.close();
      loaded.complete(<String>['Cooperation']);
      expect(await pending, isNull);
      expect(await index.match('Cooperation'), isNull);
    },
  );
}
