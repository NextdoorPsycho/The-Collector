import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:http/http.dart' as http;
import 'package:scryfall_api/scryfall_api.dart';

import 'collection_ingestion.dart';
import 'scanning/scryfall_request_scheduler.dart';

class MoxfieldImportException implements Exception {
  final String message;
  const MoxfieldImportException(this.message);
  @override
  String toString() => message;
}

class MoxfieldImportCancelled implements Exception {
  const MoxfieldImportCancelled();
}

enum MoxfieldImportIssueKind { source, lookup }

class MoxfieldImportIssue {
  final int line;
  final String source;
  final String message;
  final MoxfieldImportIssueKind kind;
  const MoxfieldImportIssue({
    required this.line,
    required this.source,
    required this.message,
    this.kind = MoxfieldImportIssueKind.source,
  });
}

class MoxfieldImportRow {
  final int line;
  final String source;
  final int quantity;
  final String name;
  final String? setCode;
  final String? collectorNumber;
  final String? scryfallId;
  final Finish finish;
  final String? language;
  final DeckSection section;
  final String? condition;

  const MoxfieldImportRow({
    required this.line,
    required this.source,
    required this.quantity,
    required this.name,
    this.setCode,
    this.collectorNumber,
    this.scryfallId,
    this.finish = Finish.nonfoil,
    this.language,
    this.section = DeckSection.mainboard,
    this.condition,
  });

  MoxfieldImportRow withQuantity(int value) => MoxfieldImportRow(
    line: line,
    source: source,
    quantity: value,
    name: name,
    setCode: setCode,
    collectorNumber: collectorNumber,
    scryfallId: scryfallId,
    finish: finish,
    language: language,
    section: section,
    condition: condition,
  );
}

class MoxfieldImportDocument {
  final String sourceName;
  final String sourceFormat;
  final String? sourceUrl;
  final String? deckFormat;
  final List<MoxfieldImportRow> rows;
  final List<MoxfieldImportIssue> issues;

  MoxfieldImportDocument({
    required this.sourceName,
    required this.sourceFormat,
    this.sourceUrl,
    this.deckFormat,
    required List<MoxfieldImportRow> rows,
    List<MoxfieldImportIssue> issues = const <MoxfieldImportIssue>[],
  }) : rows = List<MoxfieldImportRow>.unmodifiable(rows),
       issues = List<MoxfieldImportIssue>.unmodifiable(issues);

  int get totalQuantity =>
      rows.fold(0, (int total, MoxfieldImportRow row) => total + row.quantity);
}

class MoxfieldResolvedEntry {
  final MoxfieldImportRow row;
  final DeckEntry entry;
  final MTGCard card;
  final bool exactPrinting;
  const MoxfieldResolvedEntry({
    required this.row,
    required this.entry,
    required this.card,
    required this.exactPrinting,
  });
}

class MoxfieldImportPreview {
  final MoxfieldImportDocument document;
  final List<MoxfieldResolvedEntry> entries;
  final List<MoxfieldImportIssue> issues;
  MoxfieldImportPreview({
    required this.document,
    required List<MoxfieldResolvedEntry> entries,
    List<MoxfieldImportIssue> issues = const <MoxfieldImportIssue>[],
  }) : entries = List<MoxfieldResolvedEntry>.unmodifiable(entries),
       issues = List<MoxfieldImportIssue>.unmodifiable(issues);

  int get totalQuantity => document.totalQuantity;
  int get resolvedQuantity => entries.fold(
    0,
    (int total, MoxfieldResolvedEntry value) => total + value.entry.quantity,
  );
  bool get requiresReview =>
      entries.any((MoxfieldResolvedEntry value) => !value.exactPrinting);
  bool get canImport =>
      issues.isEmpty && entries.isNotEmpty && resolvedQuantity == totalQuantity;
}

const int _maximumBytes = 2097152;
const int _maximumRows = 10000;
const int _maximumQuantity = 1000000;
const Duration _requestTimeout = Duration(seconds: 20);
const String _exportFallback =
    'Export the deck from Moxfield as TXT or CSV, then paste or open that file here.';

void _checkCancelled(bool Function()? isCancelled) {
  if (isCancelled?.call() ?? false) throw const MoxfieldImportCancelled();
}

String? _nonempty(String? value) {
  final String? trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _keyText(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

DeckSection? _section(String value) {
  final String key = value.trim().toLowerCase().replaceAll(
    RegExp(r'[\s:\[\]]'),
    '',
  );
  return switch (key) {
    'deck' || 'main' || 'mainboard' => DeckSection.mainboard,
    'sideboard' || 'side' => DeckSection.sideboard,
    'commander' || 'commanders' => DeckSection.commander,
    'maybeboard' || 'maybe' => DeckSection.maybeboard,
    'companion' || 'companions' => DeckSection.companion,
    _ => null,
  };
}

Finish _finish(String? value) => switch (_keyText(value ?? '')) {
  '' ||
  'false' ||
  '0' ||
  'no' ||
  'normal' ||
  'nonfoil' ||
  'non-foil' ||
  'n' => Finish.nonfoil,
  'true' || '1' || 'yes' || 'foil' || 'f' => Finish.foil,
  'etched' || 'etched foil' || 'etchedfoil' || 'e' => Finish.etched,
  _ => throw FormatException('Unsupported finish: $value.'),
};

String? _language(String? value) {
  final String? text = _nonempty(value);
  if (text == null) return null;
  final String key = _keyText(text);
  for (final Language language in Language.values) {
    if (language != Language.unknown &&
        (language.json == key ||
            language.name.toLowerCase() == key.replaceAll(' ', ''))) {
      return language.json;
    }
  }
  final String? code = <String, String>{
    'chinese, simplified': 'zhs',
    'chinese, traditional': 'zht',
    'simplified chinese': 'zhs',
    'traditional chinese': 'zht',
    'ancient greek': 'grc',
  }[key];
  if (code != null) return code;
  throw FormatException('Unsupported language: $text.');
}

MoxfieldImportRow _validatedRow({
  required int line,
  required String source,
  required String quantity,
  required String name,
  String? setCode,
  String? collectorNumber,
  String? scryfallId,
  String? finish,
  String? language,
  DeckSection section = DeckSection.mainboard,
  String? condition,
}) {
  final int? count = int.tryParse(quantity.trim());
  if (count == null || count < 1 || count > _maximumQuantity) {
    throw const FormatException('Quantity must be between 1 and 1,000,000.');
  }
  final String cardName = name.trim();
  if (cardName.isEmpty || cardName.length > 300) {
    throw const FormatException('Card name is missing or too long.');
  }
  final String? set = _nonempty(setCode)?.toLowerCase();
  final String? number = _nonempty(collectorNumber);
  final String? id = _nonempty(scryfallId)?.toLowerCase();
  if (set != null && !RegExp(r'^[a-z0-9]{2,8}$').hasMatch(set)) {
    throw const FormatException('Edition must be a set code, such as LTR.');
  }
  if (number != null &&
      (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9★†.\-]*$').hasMatch(number) ||
          number.length > 30)) {
    throw const FormatException('Collector number is invalid.');
  }
  if (number != null && set == null && id == null) {
    throw const FormatException(
      'Collector number requires an edition or Scryfall ID.',
    );
  }
  if (id != null &&
      !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          .hasMatch(id)) {
    throw const FormatException('Scryfall ID must be a UUID.');
  }
  return MoxfieldImportRow(
    line: line,
    source: source,
    quantity: count,
    name: cardName,
    setCode: set,
    collectorNumber: number,
    scryfallId: id,
    finish: _finish(finish),
    language: _language(language),
    section: section,
    condition: _nonempty(condition),
  );
}

MoxfieldImportIssue _issue(int line, String source, Object error, {
  MoxfieldImportIssueKind kind = MoxfieldImportIssueKind.source,
}) =>
    MoxfieldImportIssue(
      line: line,
      source: source,
      kind: kind,
      message: error is FormatException
          ? error.message.toString()
          : error.toString(),
    );

List<MoxfieldImportRow> _mergeRows(
  List<MoxfieldImportRow> rows,
  List<MoxfieldImportIssue> issues,
) {
  final Map<String, MoxfieldImportRow> merged = <String, MoxfieldImportRow>{};
  for (final MoxfieldImportRow row in rows) {
    final String key = jsonEncode(<Object?>[
      _keyText(row.name),
      row.setCode,
      row.collectorNumber,
      row.scryfallId,
      row.finish.name,
      row.language,
      row.section.name,
      row.condition,
    ]);
    final int count = (merged[key]?.quantity ?? 0) + row.quantity;
    if (count > _maximumQuantity) {
      issues.add(
        _issue(
          row.line,
          row.source,
          const FormatException('Merged quantity exceeds 1,000,000.'),
        ),
      );
      continue;
    }
    merged[key] = (merged[key] ?? row).withQuantity(count);
  }
  return merged.values.toList(growable: false);
}

MoxfieldImportDocument parseMoxfieldExport(String input, {String? sourceName}) {
  if (utf8.encode(input).length > _maximumBytes) {
    throw const MoxfieldImportException('Import files must be at most 2 MiB.');
  }
  final String text = input
      .replaceFirst(RegExp(r'^\uFEFF'), '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  final String firstLine = text
      .split('\n')
      .firstWhere((String line) => line.trim().isNotEmpty, orElse: () => '');
  final bool csv =
      RegExp(
        r'(^|,)\s*"?(Count|Quantity)"?\s*(,|$)',
        caseSensitive: false,
      ).hasMatch(firstLine) &&
      RegExp(
        r'(^|,)\s*"?Name"?\s*(,|$)',
        caseSensitive: false,
      ).hasMatch(firstLine);
  final List<MoxfieldImportRow> rows = <MoxfieldImportRow>[];
  final List<MoxfieldImportIssue> issues = <MoxfieldImportIssue>[];
  if (csv) {
    _parseCsv(text, rows, issues);
  } else {
    DeckSection section = DeckSection.mainboard;
    final List<String> lines = text.split('\n');
    int count = 0;
    for (int index = 0; index < lines.length; index++) {
      final String source = lines[index];
      final String value = source.trim();
      if (value.isEmpty) continue;
      final DeckSection? header = _section(value);
      if (header != null) {
        section = header;
        continue;
      }
      if (value.startsWith('//')) {
        final DeckSection? commented = _section(value.substring(2));
        if (commented != null) {
          section = commented;
        } else {
          issues.add(
            _issue(
              index + 1,
              source,
              const FormatException('Unrecognized section or comment.'),
            ),
          );
        }
        continue;
      }
      if (++count > _maximumRows) {
        throw const MoxfieldImportException(
          'Import files may contain at most 10,000 card rows.',
        );
      }
      try {
        final RegExpMatch? match = RegExp(r'^(\d+)\s*x?\s+(.+)$')
            .firstMatch(value);
        if (match == null) {
          throw const FormatException(
            'Expected quantity followed by a card name.',
          );
        }
        String name = match[2]!;
        String? finish;
        final RegExpMatch? marker = RegExp(r'\s+\*([^*]+)\*\s*$')
            .firstMatch(name);
        if (marker != null) {
          finish = marker[1];
          name = name.substring(0, marker.start).trim();
        }
        String? set;
        String? number;
        final RegExpMatch? printing = RegExp(
          r'^(.*?)\s+\(([A-Za-z0-9]{2,8})\)(?:\s+(\S+))?$',
        ).firstMatch(name);
        if (printing != null) {
          name = printing[1]!;
          set = printing[2];
          number = printing[3];
        }
        rows.add(
          _validatedRow(
            line: index + 1,
            source: source,
            quantity: match[1]!,
            name: name,
            setCode: set,
            collectorNumber: number,
            finish: finish,
            section: section,
          ),
        );
      } on FormatException catch (error) {
        issues.add(_issue(index + 1, source, error));
      }
    }
  }
  if (rows.isEmpty && issues.isEmpty) {
    issues.add(
      _issue(0, '', const FormatException('The import contains no cards.')),
    );
  }
  return MoxfieldImportDocument(
    sourceName: _nonempty(sourceName) ?? 'Moxfield import',
    sourceFormat: csv ? 'moxfield-csv' : 'moxfield-txt',
    rows: _mergeRows(rows, issues),
    issues: issues,
  );
}

class _CsvRecord {
  final int line;
  final String source;
  final List<String> fields;
  final String? error;
  const _CsvRecord(this.line, this.source, this.fields, this.error);
}

List<_CsvRecord> _csvRecords(String input) {
  final List<_CsvRecord> records = <_CsvRecord>[];
  List<String> fields = <String>[];
  StringBuffer field = StringBuffer();
  bool quoted = false;
  bool afterQuote = false;
  String? error;
  int line = 1;
  int startLine = 1;
  int start = 0;
  void finish(int end) {
    fields.add(field.toString());
    final String source = input.substring(start, end);
    if (source.trim().isNotEmpty) {
      records.add(_CsvRecord(startLine, source, fields, error));
    }
    fields = <String>[];
    field = StringBuffer();
    afterQuote = false;
    error = null;
  }

  for (int index = 0; index < input.length; index++) {
    final String character = input[index];
    if (quoted) {
      if (character == '"') {
        if (index + 1 < input.length && input[index + 1] == '"') {
          field.write('"');
          index++;
        } else {
          quoted = false;
          afterQuote = true;
        }
      } else {
        field.write(character);
        if (character == '\n') line++;
      }
      continue;
    }
    if (character == '\n') {
      finish(index);
      line++;
      startLine = line;
      start = index + 1;
      if (records.length > _maximumRows + 1) {
        throw const MoxfieldImportException(
          'Import files may contain at most 10,000 card rows.',
        );
      }
    } else if (character == ',') {
      fields.add(field.toString());
      field = StringBuffer();
      afterQuote = false;
    } else if (character == '"' && field.isEmpty && !afterQuote) {
      quoted = true;
    } else if (afterQuote && character.trim().isEmpty) {
      continue;
    } else {
      if (afterQuote || character == '"') error ??= 'Malformed CSV quoting.';
      field.write(character);
    }
  }
  if (quoted) error = 'Unterminated CSV quoted field.';
  if (start < input.length || fields.isNotEmpty || field.isNotEmpty) {
    finish(input.length);
  }
  if (records.length > _maximumRows + 1) {
    throw const MoxfieldImportException(
      'Import files may contain at most 10,000 card rows.',
    );
  }
  return records;
}

void _parseCsv(
  String text,
  List<MoxfieldImportRow> rows,
  List<MoxfieldImportIssue> issues,
) {
  final List<_CsvRecord> records = _csvRecords(text);
  if (records.isEmpty) return;
  final _CsvRecord header = records.first;
  if (header.error != null) {
    issues.add(
      _issue(header.line, header.source, FormatException(header.error!)),
    );
    return;
  }
  final Map<String, int> columns = <String, int>{};
  for (int index = 0; index < header.fields.length; index++) {
    final String key = _keyText(header.fields[index])
        .replaceAll(RegExp(r'[\s_-]'), '');
    if (columns.containsKey(key)) {
      issues.add(
        _issue(
          header.line,
          header.source,
          FormatException('Duplicate CSV column: ${header.fields[index]}.'),
        ),
      );
      return;
    }
    columns[key] = index;
  }
  String? cell(_CsvRecord record, List<String> keys) {
    for (final String key in keys) {
      final int? index = columns[key];
      if (index != null) return _nonempty(record.fields[index]);
    }
    return null;
  }

  for (final _CsvRecord record in records.skip(1)) {
    try {
      if (record.error != null) throw FormatException(record.error!);
      if (record.fields.length != header.fields.length) {
        throw const FormatException(
          'CSV row has a different number of columns from its header.',
        );
      }
      final String? sectionValue = cell(record, <String>['section', 'board']);
      final DeckSection? section = sectionValue == null
          ? DeckSection.mainboard
          : _section(sectionValue);
      if (section == null) {
        throw FormatException('Unsupported section: $sectionValue.');
      }
      rows.add(
        _validatedRow(
          line: record.line,
          source: record.source,
          quantity: cell(record, <String>['count', 'quantity']) ?? '',
          name: cell(record, <String>['name']) ?? '',
          setCode: cell(record, <String>['edition', 'set', 'setcode']),
          collectorNumber: cell(record, <String>['collectornumber']),
          scryfallId: cell(record, <String>['scryfallid']),
          finish: cell(record, <String>['finish', 'foil']),
          language: cell(record, <String>['language', 'lang']),
          section: section,
          condition: cell(record, <String>['condition']),
        ),
      );
    } on FormatException catch (error) {
      issues.add(_issue(record.line, record.source, error));
    }
  }
}

class MoxfieldImportService {
  final http.Client _client;
  final bool _ownsClient;
  final ScryfallApiClient _api;
  bool _closed = false;

  MoxfieldImportService({http.Client? client, http.Client? scryfallClient})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _api = ScryfallApiClient(
        httpClient: scryfallClient is ScryfallHttpClient
            ? scryfallClient
            : ScryfallHttpClient(
                clientFactory: () => scryfallClient ?? http.Client(),
              ),
      );

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
    _api.close();
  }

  void _check(bool Function()? isCancelled) {
    _checkCancelled(isCancelled);
    if (_closed) throw const MoxfieldImportCancelled();
  }

  Future<Uint8List> _readSourceBody(
    Stream<List<int>> stream,
    bool Function()? isCancelled,
  ) async {
    final BytesBuilder body = BytesBuilder(copy: false);
    await for (final List<int> chunk in stream.timeout(_requestTimeout)) {
      _check(isCancelled);
      if (body.length + chunk.length > _maximumBytes) {
        throw const MoxfieldImportException(
          'Import files must be at most 2 MiB.',
        );
      }
      body.add(chunk);
    }
    return body.takeBytes();
  }

  Future<MoxfieldImportPreview> prepare(
    String input, {
    String? sourceName,
    bool Function()? isCancelled,
    void Function(int resolved, int total)? onProgress,
  }) async {
    final MoxfieldImportDocument document = await loadSource(
      input,
      sourceName: sourceName,
      isCancelled: isCancelled,
    );
    return resolve(document, isCancelled: isCancelled, onProgress: onProgress);
  }

  Future<MoxfieldImportDocument> loadSource(
    String input, {
    String? sourceName,
    bool Function()? isCancelled,
  }) async {
    _check(isCancelled);
    final String value = input.trim();
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://').hasMatch(value)) {
      return parseMoxfieldExport(input, sourceName: sourceName);
    }
    final Uri? uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        !<String>{
          'moxfield.com',
          'www.moxfield.com',
        }.contains(uri.host.toLowerCase()) ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.pathSegments.length != 2 ||
        uri.pathSegments.first != 'decks' ||
        !RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(uri.pathSegments.last)) {
      throw const MoxfieldImportException(
        'Use a public HTTPS Moxfield deck URL, or paste a TXT/CSV export.',
      );
    }
    final Uri endpoint = Uri.https(
      'api2.moxfield.com',
      '/v3/decks/all/${uri.pathSegments.last}',
    );
    final Completer<void> abort = Completer<void>();
    final http.AbortableRequest request =
        http.AbortableRequest('GET', endpoint, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers.addAll(<String, String>{
            'User-Agent': 'TheCollector/1.0 (card collection app)',
            'Accept': 'application/json',
          });
    try {
      final http.StreamedResponse response = await _client
          .send(request)
          .timeout(_requestTimeout);
      _check(isCancelled);
      if (response.statusCode != 200) {
        await response.stream.listen((List<int> _) {}).cancel();
        throw MoxfieldImportException(
          'Moxfield could not provide this public deck (HTTP ${response.statusCode}). $_exportFallback',
        );
      }
      if ((response.contentLength ?? 0) > _maximumBytes) {
        await response.stream.listen((List<int> _) {}).cancel();
        throw const MoxfieldImportException(
          'Import files must be at most 2 MiB.',
        );
      }
      final Uint8List body = await _readSourceBody(
        response.stream,
        isCancelled,
      ).timeout(_requestTimeout);
      _check(isCancelled);
      final Object? decoded = jsonDecode(utf8.decode(body));
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Deck response is not a JSON object.');
      }
      return _publicDeck(
        decoded,
        sourceUrl: uri.toString(),
        sourceName: sourceName,
      );
    } on MoxfieldImportCancelled {
      rethrow;
    } on MoxfieldImportException {
      rethrow;
    } catch (_) {
      _check(isCancelled);
      throw const MoxfieldImportException(
        'Moxfield could not provide a readable public deck. $_exportFallback',
      );
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<MoxfieldImportPreview> resolve(
    MoxfieldImportDocument document, {
    bool Function()? isCancelled,
    void Function(int resolved, int total)? onProgress,
  }) async {
    _check(isCancelled);
    if (document.rows.length > _maximumRows) {
      throw const MoxfieldImportException(
        'Import files may contain at most 10,000 card rows.',
      );
    }
    final List<MoxfieldImportIssue> issues = <MoxfieldImportIssue>[
      ...document.issues,
    ];
    final List<MoxfieldResolvedEntry> entries = <MoxfieldResolvedEntry>[];
    final Map<String, List<MoxfieldImportRow>> groups =
        <String, List<MoxfieldImportRow>>{};
    for (final MoxfieldImportRow row in document.rows) {
      final String key = jsonEncode(_identifier(row).toJson());
      (groups[key] ??= <MoxfieldImportRow>[]).add(row);
    }
    final List<List<MoxfieldImportRow>> pending = groups.values.toList(
      growable: false,
    );
    int completed = 0;
    onProgress?.call(0, document.rows.length);
    for (int start = 0; start < pending.length; start += 75) {
      _check(isCancelled);
      final int end = start + 75 < pending.length ? start + 75 : pending.length;
      final List<List<MoxfieldImportRow>> batch = pending.sublist(start, end);
      CardList cards;
      try {
        cards = await _api.getCardsByIdentifiers(
          batch
              .map((List<MoxfieldImportRow> rows) => _identifier(rows.first))
              .toList(growable: false),
        );
      } catch (_) {
        _check(isCancelled);
        for (final List<MoxfieldImportRow> rows in batch) {
          for (final MoxfieldImportRow row in rows) {
            issues.add(
              _issue(
                row.line,
                row.source,
                const FormatException(
                  'Card lookup failed. Try this import again.',
                ),
                kind: MoxfieldImportIssueKind.lookup,
              ),
            );
          }
          completed += rows.length;
        }
        onProgress?.call(completed, document.rows.length);
        continue;
      }
      _check(isCancelled);
      final Map<String, MtgCard> uniqueCards = <String, MtgCard>{
        for (final MtgCard card in cards.data) card.id: card,
      };
      final Map<String, MtgCard?> languages = <String, MtgCard?>{};
      for (final List<MoxfieldImportRow> rows in batch) {
        final MoxfieldImportRow first = rows.first;
        final List<MtgCard> matches = uniqueCards.values
            .where((MtgCard card) => _matchesIdentifier(first, card))
            .toList(growable: false);
        for (final MoxfieldImportRow row in rows) {
          _check(isCancelled);
          try {
            if (matches.length != 1) {
              throw const FormatException(
                'No unique exact card match. Check the name, edition and collector number.',
              );
            }
            MtgCard card = matches.single;
            if (row.language != null &&
                row.language != card.lang.json &&
                row.scryfallId == null) {
              final String key =
                  '${card.set}/${card.collectorNumber}/${row.language}';
              if (!languages.containsKey(key)) {
                _check(isCancelled);
                try {
                  languages[key] = await _api
                      .getCardBySetCodeAndCollectorNumber(
                        card.set,
                        card.collectorNumber,
                        language: Language.values.firstWhere(
                          (Language language) => language.json == row.language,
                        ),
                      );
                } catch (_) {
                  _check(isCancelled);
                  languages[key] = null;
                }
              }
              final MtgCard? translated = languages[key];
              if (translated == null) {
                throw const FormatException(
                  'The requested language is unavailable for this printing.',
                );
              }
              card = translated;
            }
            _check(isCancelled);
            if (!_matchesSupplied(row, card)) {
              throw const FormatException(
                'The catalog printing conflicts with the exported name, edition, number, ID or language.',
              );
            }
            if (!card.finishes.contains(row.finish)) {
              throw FormatException(
                'This printing is unavailable in ${row.finish.name}. Choose a supported finish explicitly.',
              );
            }
            final MTGCard model = cardFromScryfall(card, finish: row.finish)
              ..id = row.finish == Finish.nonfoil
                  ? card.id
                  : '${card.id}__${row.finish.name}';
            entries.add(
              MoxfieldResolvedEntry(
                row: row,
                entry: DeckEntry(
                  scryfallId: card.id,
                  quantity: row.quantity,
                  section: row.section,
                  finish: row.finish,
                  language: row.language ?? card.lang.json,
                  condition: row.condition,
                ),
                card: model,
                exactPrinting:
                    row.setCode != null && row.collectorNumber != null ||
                    row.scryfallId != null,
              ),
            );
          } on FormatException catch (error) {
            issues.add(_issue(row.line, row.source, error, kind: MoxfieldImportIssueKind.lookup));
          }
          completed++;
          onProgress?.call(completed, document.rows.length);
        }
      }
    }
    _check(isCancelled);
    return MoxfieldImportPreview(
      document: document,
      entries: _mergeResolved(entries, issues),
      issues: issues,
    );
  }
}

CardIdentifier _identifier(MoxfieldImportRow row) {
  if (row.setCode != null && row.collectorNumber != null) {
    return CardIdentifierSetCollectorNumber(row.setCode!, row.collectorNumber!);
  }
  if (row.scryfallId != null) return CardIdentifierId(row.scryfallId!);
  if (row.setCode != null) return CardIdentifierSetName(row.setCode!, row.name);
  return CardIdentifierName(row.name);
}

bool _matchesName(String name, MtgCard card) => <String>[
  card.name,
  if (card.printedName != null) card.printedName!,
  ...?card.cardFaces?.map((CardFace face) => face.name),
].any((String value) => _keyText(name) == _keyText(value));

bool _matchesIdentifier(MoxfieldImportRow row, MtgCard card) {
  if (row.setCode != null && row.collectorNumber != null) {
    return row.setCode == card.set.toLowerCase() &&
        row.collectorNumber == card.collectorNumber;
  }
  if (row.scryfallId != null) return row.scryfallId == card.id;
  return _matchesName(row.name, card) &&
      (row.setCode == null || row.setCode == card.set.toLowerCase());
}

bool _matchesSupplied(MoxfieldImportRow row, MtgCard card) =>
    _matchesName(row.name, card) &&
    (row.setCode == null || row.setCode == card.set.toLowerCase()) &&
    (row.collectorNumber == null ||
        row.collectorNumber == card.collectorNumber) &&
    (row.scryfallId == null || row.scryfallId == card.id) &&
    (row.language == null || row.language == card.lang.json);

List<MoxfieldResolvedEntry> _mergeResolved(
  List<MoxfieldResolvedEntry> entries,
  List<MoxfieldImportIssue> issues,
) {
  final Map<String, MoxfieldResolvedEntry> merged =
      <String, MoxfieldResolvedEntry>{};
  for (final MoxfieldResolvedEntry value in entries) {
    final String key = jsonEncode(<Object?>[
      value.entry.scryfallId,
      value.entry.finish?.name,
      value.entry.language,
      value.entry.section.name,
      value.row.condition,
    ]);
    final MoxfieldResolvedEntry? prior = merged[key];
    if (prior == null) {
      merged[key] = value;
      continue;
    }
    final int quantity = prior.entry.quantity + value.entry.quantity;
    if (quantity > _maximumQuantity) {
      issues.add(
        _issue(
          value.row.line,
          value.row.source,
          const FormatException('Merged quantity exceeds 1,000,000.'),
        ),
      );
      continue;
    }
    merged[key] = MoxfieldResolvedEntry(
      row: prior.row.withQuantity(quantity),
      entry: DeckEntry(
        scryfallId: prior.entry.scryfallId,
        quantity: quantity,
        section: prior.entry.section,
        finish: prior.entry.finish,
        language: prior.entry.language,
        condition: prior.row.condition,
      ),
      card: prior.card,
      exactPrinting: prior.exactPrinting && value.exactPrinting,
    );
  }
  return merged.values.toList(growable: false);
}

MoxfieldImportDocument _publicDeck(
  Map<String, Object?> json, {
  required String sourceUrl,
  String? sourceName,
}) {
  if (json['visibility'] == 'private' || json['isPrivate'] == true) {
    throw const MoxfieldImportException(
      'This deck is private. $_exportFallback',
    );
  }
  final Object boardsValue = json['boards'] ?? json;
  if (boardsValue is! Map<String, Object?>) {
    throw const FormatException('Deck boards are unavailable.');
  }
  final List<MoxfieldImportRow> rows = <MoxfieldImportRow>[];
  final List<MoxfieldImportIssue> issues = <MoxfieldImportIssue>[];
  int line = 0;
  for (final MapEntry<String, Object?> board in boardsValue.entries) {
    final DeckSection? section = _section(board.key);
    if (section == null) {
      final Object? unknown = board.value is Map<String, Object?>
          ? (board.value as Map<String, Object?>)['cards'] ?? board.value
          : board.value;
      if (json['boards'] != null &&
          unknown != null &&
          !(unknown is Map<String, Object?> && unknown.isEmpty)) {
        issues.add(
          _issue(
            0,
            board.key,
            const FormatException('Unsupported nonempty deck board.'),
          ),
        );
      }
      continue;
    }
    if (board.value is! Map<String, Object?>) {
      issues.add(
        _issue(0, board.key, const FormatException('Deck board is malformed.')),
      );
      continue;
    }
    final Map<String, Object?> value = board.value as Map<String, Object?>;
    final Object cardsValue = value['cards'] ?? value;
    if (cardsValue is! Map<String, Object?>) {
      issues.add(
        _issue(
          0,
          board.key,
          const FormatException('Deck board cards are malformed.'),
        ),
      );
      continue;
    }
    for (final Object? entry in cardsValue.values) {
      if (++line > _maximumRows) {
        throw const MoxfieldImportException(
          'Import files may contain at most 10,000 card rows.',
        );
      }
      final String source = jsonEncode(entry);
      try {
        if (entry is! Map<String, Object?> ||
            entry['card'] is! Map<String, Object?>) {
          throw const FormatException('Deck card is malformed.');
        }
        final Map<String, Object?> card = entry['card'] as Map<String, Object?>;
        String? string(Object? item) {
          if (item != null && item is! String) {
            throw const FormatException('Deck card metadata is malformed.');
          }
          return item as String?;
        }

        final Object? quantity = entry['quantity'];
        rows.add(
          _validatedRow(
            line: line,
            source: source,
            quantity: quantity is int ? quantity.toString() : '',
            name: string(card['name']) ?? '',
            setCode: string(card['set']),
            collectorNumber: string(card['cn'] ?? card['collector_number']),
            scryfallId: string(card['scryfall_id'] ?? card['scryfallId']),
            language: string(card['lang'] ?? card['language']),
            finish: string(entry['finish']),
            section: section,
            condition: string(entry['condition']),
          ),
        );
      } on FormatException catch (error) {
        issues.add(_issue(line, source, error));
      }
    }
  }
  if (rows.isEmpty && issues.isEmpty) {
    throw const FormatException('Deck response has no supported card rows.');
  }
  return MoxfieldImportDocument(
    sourceName:
        _nonempty(sourceName) ??
        _nonempty(json['name'] is String ? json['name'] as String : null) ??
        'Moxfield import',
    sourceFormat: 'moxfield-url',
    sourceUrl: sourceUrl,
    deckFormat: json['format'] is String ? json['format'] as String : null,
    rows: _mergeRows(rows, issues),
    issues: issues,
  );
}
