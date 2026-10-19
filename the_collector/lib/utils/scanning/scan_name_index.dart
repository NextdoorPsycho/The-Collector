import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:the_collector/utils/scanning/scryfall_request_scheduler.dart';

import 'scan_local_catalog.dart';

abstract interface class ScanNameIndex {
  Future<ScanNameMatch?> match(String observed);
}

class ScanNameMatch {
  final String canonicalName;
  final bool exact;

  const ScanNameMatch({required this.canonicalName, required this.exact});
}

typedef ScanNameLoader = Future<List<String>> Function();
typedef ScanNameCacheReader = Future<String?> Function();
typedef ScanNameCacheWriter = Future<void> Function(String value);

class ScryfallScanNameIndex implements ScanNameIndex {
  static const Duration cacheLifetime = Duration(hours: 24);
  static const int maximumNames = 80000;
  static const int maximumNameLength = 200;
  static const int maximumPayloadBytes = 4194304;
  static final _NameIndexState _shared = _NameIndexState();
  static final RegExp _controlCharacters = RegExp(r'[\x00-\x1f\x7f]');

  final http.Client _client;
  final ScanNameLoader? _loader;
  final ScanNameCacheReader _readCache;
  final ScanNameCacheWriter _writeCache;
  final DateTime Function() _clock;
  final _NameIndexState _state;
  bool _closed = false;

  ScryfallScanNameIndex({
    http.Client? client,
    ScanNameLoader? loader,
    ScanNameCacheReader? readCache,
    ScanNameCacheWriter? writeCache,
    DateTime Function()? clock,
  }) : _client =
           client ??
           ScryfallHttpClient(
             headerTimeout: const Duration(seconds: 3),
             bodyTimeout: const Duration(seconds: 3),
             maximumResponseBytes: maximumPayloadBytes,
           ),
       _loader = loader,
       _readCache = readCache ?? _readHive,
       _writeCache = writeCache ?? _writeHive,
       _clock = clock ?? DateTime.now,
       _state =
           client == null &&
               loader == null &&
               readCache == null &&
               writeCache == null &&
               clock == null
           ? _shared
           : _NameIndexState();

  static Future<String?> _readHive() async =>
      (await Hive.openBox<String>('scanner_card_names_v1')).get('catalog');

  static Future<void> _writeHive(String value) async =>
      (await Hive.openBox<String>('scanner_card_names_v1'))
          .put('catalog', value);

  Future<List<String>> _download() async {
    if (identical(_state, _shared)) {
      final List<String>? local = await LocalScanCatalog.shared
          .cardNamesReady();
      if (local != null && _validNames(local)) return local;
    }
    final http.Response response = await _client.get(
      Uri.https('api.scryfall.com', '/catalog/card-names'),
      headers: ScryfallRequestScheduler.headers,
    );
    if (response.statusCode != 200 ||
        response.bodyBytes.length > maximumPayloadBytes) {
      throw const FormatException('Card-name catalog unavailable.');
    }
    final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, Object?> ||
        decoded['object'] != 'catalog' ||
        decoded['data'] is! List<Object?>) {
      throw const FormatException('Invalid card-name catalog.');
    }
    final List<Object?> data = decoded['data'] as List<Object?>;
    if (decoded['total_values'] is! int ||
        decoded['total_values'] != data.length ||
        data.isEmpty ||
        data.length > maximumNames ||
        data.any((Object? value) => value is! String)) {
      throw const FormatException('Invalid card-name catalog size.');
    }
    return List<String>.unmodifiable(data.cast<String>());
  }

  Future<void> warm() async {
    if (_closed) return;
    final DateTime now = _clock();
    if (_state.index != null && (_state.expiresAt?.isAfter(now) ?? false)) {
      return;
    }
    if (_state.pending case final Future<void> pending) {
      return pending;
    }
    if (_state.retryAt?.isAfter(now) ?? false) return;
    late final Future<void> pending;
    pending = _load(now).whenComplete(() {
      if (identical(_state.pending, pending)) _state.pending = null;
    });
    _state.pending = pending;
    return pending;
  }

  Future<void> _load(DateTime now) async {
    try {
      List<String>? names;
      DateTime fetchedAt = now;
      try {
        final String? stored = await _readCache();
        if (stored != null &&
            utf8.encode(stored).length <= maximumPayloadBytes) {
          final Object? decoded = jsonDecode(stored);
          if (decoded is Map<String, Object?> &&
              decoded['at'] is String &&
              decoded['names'] is List<Object?>) {
            final DateTime? at = DateTime.tryParse(decoded['at'] as String);
            final List<Object?> data = decoded['names'] as List<Object?>;
            if (at != null &&
                !at.isAfter(now) &&
                at.add(cacheLifetime).isAfter(now) &&
                data.every((Object? name) => name is String)) {
              final List<String> cached = data.cast<String>();
              if (_validNames(cached)) {
                names = List<String>.unmodifiable(cached);
                fetchedAt = at;
              }
            }
          }
        }
      } catch (_) {
        // A cache failure must not suppress the public catalog lookup.
      }
      final bool downloaded = names == null;
      names ??= await (_loader?.call() ?? _download());
      if (!_validNames(names)) {
        throw const FormatException('Invalid card-name catalog entries.');
      }
      final List<String> immutableNames = List<String>.unmodifiable(names);
      final _BuiltNameIndex index = await _buildOffThread(immutableNames);
      if (_closed) return;
      _state.index = index;
      _state.expiresAt = fetchedAt.add(cacheLifetime);
      _state.retryAt = null;
      if (downloaded) {
        try {
          final String value = jsonEncode(<String, Object?>{
            'at': fetchedAt.toUtc().toIso8601String(),
            'names': immutableNames,
          });
          if (utf8.encode(value).length <= maximumPayloadBytes) {
            await _writeCache(value);
          }
        } catch (_) {
          // The in-memory catalog remains usable without persistent storage.
        }
      }
    } catch (_) {
      _state.index = null;
      _state.expiresAt = null;
      _state.retryAt = _clock().add(const Duration(minutes: 1));
    }
  }

  static bool _validNames(List<String> names) {
    if (names.isEmpty || names.length > maximumNames) return false;
    int bytes = 0;
    for (final String name in names) {
      if (name.trim() != name ||
          name.isEmpty ||
          name.length > maximumNameLength ||
          name.contains(_controlCharacters)) {
        return false;
      }
      bytes += utf8.encode(name).length + 4;
      if (bytes > maximumPayloadBytes) return false;
    }
    return true;
  }

  static Future<_BuiltNameIndex> _buildOffThread(List<String> names) =>
      Isolate.run<_BuiltNameIndex>(() => _BuiltNameIndex(names));

  @override
  Future<ScanNameMatch?> match(String observed) async {
    if (_closed || observed.length > maximumNameLength) return null;
    final String normalized = _BuiltNameIndex.normalize(observed);
    if (normalized.isEmpty) return null;
    await warm();
    if (_closed) return null;
    return _state.index?.match(normalized);
  }

  ScanNameMatch? matchReady(String observed) {
    if (_closed || observed.length > maximumNameLength) return null;
    final String normalized = _BuiltNameIndex.normalize(observed);
    if (normalized.isEmpty) return null;
    final _BuiltNameIndex? index = _state.index;
    if (index != null && (_state.expiresAt?.isAfter(_clock()) ?? false)) {
      return index.match(normalized);
    }
    unawaited(warm());
    return null;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }
}

class _NameIndexState {
  _BuiltNameIndex? index;
  DateTime? expiresAt;
  DateTime? retryAt;
  Future<void>? pending;
}

class _BuiltNameIndex {
  final List<String> _names;
  final List<String> _normalized;
  final List<String> _fuzzy;
  final Map<String, List<int>> _exact = <String, List<int>>{};
  final Map<int, Map<String, List<int>>> _gramsByLength =
      <int, Map<String, List<int>>>{};
  final Map<int, Map<String, List<int>>> _bigramsByLength =
      <int, Map<String, List<int>>>{};

  _BuiltNameIndex(List<String> names)
    : _names = names,
      _normalized = List<String>.unmodifiable(names.map(normalize)),
      _fuzzy = List<String>.unmodifiable(
        names.map((String name) => normalize(name).replaceAll(' ', '')),
      ) {
    for (int id = 0; id < names.length; id++) {
      (_exact[_normalized[id]] ??= <int>[]).add(id);
      final Map<String, List<int>> grams = _gramsByLength[_fuzzy[id].length] ??=
          <String, List<int>>{};
      for (final String gram in _trigrams(_fuzzy[id])) {
        (grams[gram] ??= <int>[]).add(id);
      }
      if (_fuzzy[id].length >= 7 && _fuzzy[id].length <= 22) {
        final Map<String, List<int>> bigrams =
            _bigramsByLength[_fuzzy[id].length] ??= <String, List<int>>{};
        for (final String gram in _bigrams(_fuzzy[id])) {
          (bigrams[gram] ??= <int>[]).add(id);
        }
      }
    }
  }

  static String normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp('[’‘`´]'), "'")
      .replaceAll(RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true), ' ')
      .trim();

  static Set<String> _trigrams(String name) => <String>{
    for (int offset = 0; offset + 3 <= name.length; offset++)
      name.substring(offset, offset + 3),
  };

  static Set<String> _bigrams(String name) => <String>{
    for (int offset = 0; offset + 2 <= name.length; offset++)
      name.substring(offset, offset + 2),
  };

  ScanNameMatch? match(String query) {
    final List<int>? exact = _exact[query];
    if (exact != null) {
      final Set<String> names = exact.map((int id) => _names[id]).toSet();
      return names.length == 1
          ? ScanNameMatch(canonicalName: names.single, exact: true)
          : null;
    }
    // OCR word spacing can break a title; this path never counts as exact.
    final String fuzzyQuery = query.replaceAll(' ', '');
    if (fuzzyQuery.length < 6) return null;
    final bool longTitle = fuzzyQuery.length >= 20;
    final bool mediumTitle = fuzzyQuery.length >= 10 && !longTitle;
    final int limit = longTitle
        ? 4
        : mediumTitle
        ? 2
        : 1;
    final int guard = longTitle ? 6 : limit;
    final Set<String> bigrams = _bigrams(fuzzyQuery);
    final Set<String> grams = mediumTitle ? bigrams : _trigrams(fuzzyQuery);
    if (longTitle &&
        (grams.length <= 3 * guard || bigrams.length <= 2 * guard)) {
      return null;
    }
    if (mediumTitle && bigrams.length <= 6) return null;
    // Four-edit names cannot violate a two-edit winner's two-edit margin.
    final int searchGuard = mediumTitle ? 3 : guard;
    final int minimumOverlap =
        (grams.length - (mediumTitle ? 2 : 3) * searchGuard).clamp(
          1,
          grams.length,
        );
    final Map<int, Map<String, List<int>>> gramIndex = mediumTitle
        ? _bigramsByLength
        : _gramsByLength;
    final Map<int, int> overlaps = <int, int>{};
    for (
      int length = fuzzyQuery.length - searchGuard;
      length <= fuzzyQuery.length + searchGuard;
      length++
    ) {
      final Map<String, List<int>>? indexed = gramIndex[length];
      if (indexed == null) continue;
      for (final String gram in grams) {
        for (final int id in indexed[gram] ?? const <int>[]) {
          overlaps[id] = (overlaps[id] ?? 0) + 1;
        }
      }
    }
    final List<int> coarse = overlaps.entries
        .where((MapEntry<int, int> entry) => entry.value >= minimumOverlap)
        .map((MapEntry<int, int> entry) => entry.key)
        .toList();
    if (coarse.length > 8192) return null;
    final int minimumBigrams = (bigrams.length - 2 * guard).clamp(
      1,
      bigrams.length,
    );
    final List<int> candidates = longTitle
        ? coarse.where((int id) {
            final Set<String> candidate = _bigrams(_fuzzy[id]);
            return bigrams.where(candidate.contains).length >= minimumBigrams;
          }).toList()
        : coarse;
    if (candidates.length > 512) return null;
    int best = searchGuard + 1;
    int runnerUp = searchGuard + 1;
    int? winner;
    bool tied = false;
    for (final int id in candidates) {
      final int distance = _distance(fuzzyQuery, _fuzzy[id], searchGuard);
      if (distance < best) {
        runnerUp = best;
        best = distance;
        winner = id;
        tied = false;
      } else if (distance == best &&
          winner != null &&
          _names[id] != _names[winner]) {
        tied = true;
        runnerUp = best;
      } else if (distance < runnerUp &&
          winner != null &&
          _names[id] != _names[winner]) {
        runnerUp = distance;
      }
    }
    if (winner == null ||
        tied ||
        best > limit ||
        best / fuzzyQuery.length > (longTitle || mediumTitle ? .20 : .12) ||
        ((longTitle || mediumTitle) && runnerUp - best < 2)) {
      return null;
    }
    return ScanNameMatch(canonicalName: _names[winner], exact: false);
  }

  static int _distance(String a, String b, int limit) {
    List<int> previous = List<int>.generate(b.length + 1, (int i) => i);
    for (int row = 1; row <= a.length; row++) {
      final List<int> current = List<int>.filled(b.length + 1, limit + 1);
      current[0] = row;
      final int first = (row - limit).clamp(1, b.length);
      final int last = (row + limit).clamp(1, b.length);
      int minimum = limit + 1;
      for (int column = first; column <= last; column++) {
        final int substitution =
            previous[column - 1] +
            (a.codeUnitAt(row - 1) == b.codeUnitAt(column - 1) ? 0 : 1);
        final int deletion = previous[column] + 1;
        final int insertion = current[column - 1] + 1;
        final int edit = substitution < deletion ? substitution : deletion;
        current[column] = insertion < edit ? insertion : edit;
        if (current[column] < minimum) minimum = current[column];
      }
      if (minimum > limit) return limit + 1;
      previous = current;
    }
    return previous[b.length];
  }
}
