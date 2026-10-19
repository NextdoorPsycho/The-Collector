import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:scryfall_api/scryfall_api.dart';

import 'scan_recognition.dart';

class LocalCatalogPage {
  final List<MtgCard> cards;
  final int total;
  final bool hasMore;
  const LocalCatalogPage(this.cards, this.total, this.hasMore);
}

class LocalVisualHit {
  final String illustrationId;
  final double distance;
  final List<MtgCard> cards;
  final int rotationDegrees;
  final ScanBounds? queryRegion;
  final Uint8List? referencePixels;
  const LocalVisualHit(
    this.illustrationId,
    this.distance,
    this.cards, {
    this.rotationDegrees = 0,
    this.queryRegion,
    this.referencePixels,
  });
}

class ScanCatalogPackage {
  static const String descriptorSchema = 'rgb-gradient-8x8-v1';
  static const String referenceSchema = 'gray48-bt601-cg-high-v1';
  final String version;
  final int cardCount;
  final int visualCount;
  final int illustrationCount;
  final bool visualComplete;
  final List<({String name, int bytes, String digest})> files;

  const ScanCatalogPackage({
    required this.version,
    required this.cardCount,
    required this.visualCount,
    required this.illustrationCount,
    required this.visualComplete,
    required this.files,
  });

  factory ScanCatalogPackage.parse(String value) {
    if (utf8.encode(value).length > 1024 * 1024) {
      throw const FormatException('Catalog manifest exceeds its limit.');
    }
    final Object? decoded = jsonDecode(value);
    if (decoded is! Map<String, Object?> ||
        decoded['schema'] != 2 ||
        decoded['descriptorSchema'] != descriptorSchema ||
        decoded['referenceSchema'] != referenceSchema ||
        decoded['metadataComplete'] != true ||
        decoded['version'] is! String ||
        !RegExp(r'^[a-f0-9]{24}$').hasMatch(decoded['version']! as String) ||
        decoded['cardCount'] is! int ||
        decoded['visualCount'] is! int ||
        decoded['illustrationCount'] is! int ||
        decoded['visualComplete'] is! bool ||
        decoded['files'] is! List<Object?>) {
      throw const FormatException('Unsupported catalog manifest.');
    }
    final int cards = decoded['cardCount']! as int;
    final int visuals = decoded['visualCount']! as int;
    final int illustrations = decoded['illustrationCount']! as int;
    if (cards < 1 ||
        cards > 1000000 ||
        visuals < 0 ||
        visuals > illustrations ||
        illustrations > 500000 ||
        (decoded['visualComplete'] == true && visuals != illustrations)) {
      throw const FormatException('Invalid catalog counts.');
    }
    final List<({String name, int bytes, String digest})> files =
        <({String name, int bytes, String digest})>[];
    final Set<String> names = <String>{};
    int bytes = 0;
    for (final Object? record in decoded['files']! as List<Object?>) {
      if (record is! Map<String, Object?> ||
          record['name'] is! String ||
          record['bytes'] is! int ||
          record['sha256'] is! String) {
        throw const FormatException('Invalid catalog file.');
      }
      final String name = record['name']! as String;
      final int size = record['bytes']! as int;
      final String digest = record['sha256']! as String;
      if (!RegExp(
            r'^(cards\.[0-9]{4}\.bin|catalog\.index\.json\.gz|visual\.index\.bin|visual\.ids\.json\.gz|visual\.gray\.[0-9]{4}\.bin|visual\.gray\.index\.json\.gz)$',
          ).hasMatch(name) ||
          !names.add(name) ||
          size < 1 ||
          size > 64 * 1024 * 1024 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
        throw const FormatException('Invalid catalog file bounds.');
      }
      bytes += size;
      files.add((name: name, bytes: size, digest: digest));
    }
    if (bytes > 1024 * 1024 * 1024 ||
        files.length > 512 ||
        !names.containsAll(<String>{
          'catalog.index.json.gz',
          'visual.index.bin',
          'visual.ids.json.gz',
          'visual.gray.index.json.gz',
          'visual.gray.0000.bin',
          'cards.0000.bin',
        })) {
      throw const FormatException('Incomplete catalog package.');
    }
    return ScanCatalogPackage(
      version: decoded['version']! as String,
      cardCount: cards,
      visualCount: visuals,
      illustrationCount: illustrations,
      visualComplete: decoded['visualComplete']! as bool,
      files: List<({String name, int bytes, String digest})>.unmodifiable(
        files,
      ),
    );
  }
}

class LocalScanCatalog {
  static final LocalScanCatalog shared = LocalScanCatalog();
  static const String bundledRoot = 'assets/scanner_catalog';
  final Future<Directory> Function() _directory;
  final AssetBundle _assets;
  final http.Client Function() _clientFactory;
  final Uri? updateManifest;
  Future<void>? _warming;
  Future<void> _mutationTail = Future<void>.value();
  _CatalogConnection? _worker;
  ScanCatalogPackage? package;
  bool _closed = false;

  LocalScanCatalog({
    Future<Directory> Function()? directory,
    AssetBundle? assets,
    http.Client Function()? clientFactory,
    this.updateManifest,
  }) : _directory = directory ?? _defaultDirectory,
       _assets = assets ?? rootBundle,
       _clientFactory = clientFactory ?? http.Client.new;

  static Future<Directory> _defaultDirectory() async {
    final Box<String> box = await Hive.openBox<String>(
      'scanner_catalog_location_v1',
    );
    final String? path = box.path;
    if (path == null) throw StateError('Catalog storage is unavailable.');
    return Directory('${File(path).parent.path}/scanner_catalog');
  }

  bool get ready => _worker != null && !_closed;

  Future<void> _mutate(Future<void> Function() operation) {
    final Future<void> result = _mutationTail.then((_) => operation());
    _mutationTail = result.catchError((Object _) {});
    return result;
  }

  Future<void> warm() =>
      _warming ??= _mutate(_load).whenComplete(() => _warming = null);

  Future<void> _load() async {
    if (_closed || ready) return;
    final Directory root = await _directory();
    await root.create(recursive: true);
    Directory? installed;
    ScanCatalogPackage? selected;
    try {
      final String version = (await File(
        '${root.path}/current',
      ).readAsString()).trim();
      if (!RegExp(r'^[a-f0-9]{24}$').hasMatch(version)) {
        throw const FormatException('Invalid catalog pointer.');
      }
      installed = Directory('${root.path}/$version');
      selected = ScanCatalogPackage.parse(
        await File('${installed.path}/manifest.json').readAsString(),
      );
      if (selected.version != version) {
        throw const FormatException('Catalog version differs.');
      }
      await _verify(installed, selected);
    } catch (_) {
      installed = null;
      selected = null;
    }
    if (selected == null) {
      final String manifest = await _assets.loadString(
        '$bundledRoot/manifest.json',
      );
      selected = ScanCatalogPackage.parse(manifest);
      installed = await _install(root, selected, manifest, (String name) async {
        final ByteData data = await _assets.load('$bundledRoot/$name');
        return Stream<List<int>>.value(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      });
    }
    final _CatalogConnection connection = await _CatalogConnection.open(
      installed!.path,
      selected.cardCount,
      selected.visualCount,
      selected.files,
    );
    await _publish(root, selected, connection);
  }

  Future<void> installDirectory(Directory source) =>
      _mutate(() => _installDirectory(source));

  Future<void> _installDirectory(Directory source) async {
    if (_closed) throw StateError('Catalog is closed.');
    final String manifest = await File('${source.path}/manifest.json')
        .readAsString();
    final ScanCatalogPackage selected = ScanCatalogPackage.parse(manifest);
    final Directory root = await _directory();
    await root.create(recursive: true);
    final Directory installed = await _install(
      root,
      selected,
      manifest,
      (String name) async => File('${source.path}/$name').openRead(),
    );
    final _CatalogConnection connection = await _CatalogConnection.open(
      installed.path,
      selected.cardCount,
      selected.visualCount,
      selected.files,
    );
    await _publish(root, selected, connection);
  }

  Future<void> update() => _mutate(_update);

  Future<void> _update() async {
    final Uri? manifestUri = updateManifest;
    if (_closed ||
        manifestUri == null ||
        manifestUri.scheme != 'https' ||
        manifestUri.userInfo.isNotEmpty ||
        manifestUri.hasFragment) {
      return;
    }
    final http.Client client = _clientFactory();
    try {
      final http.Response response = await client
          .get(manifestUri)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 ||
          response.bodyBytes.length > 1024 * 1024) {
        throw const FormatException('Catalog update unavailable.');
      }
      final String manifest = utf8.decode(response.bodyBytes);
      final ScanCatalogPackage selected = ScanCatalogPackage.parse(manifest);
      if (selected.version == package?.version) return;
      final Directory root = await _directory();
      await root.create(recursive: true);
      final Directory installed = await _install(root, selected, manifest, (
        String name,
      ) async {
        final Uri uri = manifestUri.resolve(name);
        if (uri.host != manifestUri.host || uri.scheme != 'https') {
          throw const FormatException('Catalog update changed origin.');
        }
        final http.StreamedResponse file = await client
            .send(http.Request('GET', uri))
            .timeout(const Duration(seconds: 20));
        if (file.statusCode != 200) {
          throw const FormatException('Catalog file unavailable.');
        }
        return file.stream.timeout(const Duration(seconds: 20));
      });
      final _CatalogConnection connection = await _CatalogConnection.open(
        installed.path,
        selected.cardCount,
        selected.visualCount,
        selected.files,
      );
      await _publish(root, selected, connection);
    } finally {
      client.close();
    }
  }

  Future<Directory> _install(
    Directory root,
    ScanCatalogPackage selected,
    String manifest,
    Future<Stream<List<int>>> Function(String) source,
  ) async {
    final Directory target = Directory('${root.path}/${selected.version}');
    final Directory staging = Directory(
      '${target.path}.pending-${DateTime.now().microsecondsSinceEpoch}',
    );
    await staging.create(recursive: true);
    try {
      for (final ({String name, int bytes, String digest}) entry
          in selected.files) {
        final File file = File('${staging.path}/${entry.name}');
        final IOSink sink = file.openWrite();
        int size = 0;
        try {
          await for (final List<int> block in await source(entry.name)) {
            size += block.length;
            if (size > entry.bytes) {
              throw const FormatException('Catalog file exceeds manifest.');
            }
            sink.add(block);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (size != entry.bytes) {
          throw const FormatException('Catalog file is truncated.');
        }
      }
      await File('${staging.path}/manifest.json')
          .writeAsString(manifest, flush: true);
      await _verify(staging, selected);
      if (await target.exists()) {
        await _verify(target, selected);
        await staging.delete(recursive: true);
      } else {
        await staging.rename(target.path);
      }
      return target;
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  static Future<void> _activate(Directory root, String version) async {
    final File pointer = File('${root.path}/current.pending');
    await pointer.writeAsString(version, flush: true);
    await pointer.rename('${root.path}/current');
  }

  Future<void> _publish(
    Directory root,
    ScanCatalogPackage selected,
    _CatalogConnection connection,
  ) async {
    if (_closed) {
      connection.close();
      return;
    }
    try {
      await _activate(root, selected.version);
    } catch (_) {
      connection.close();
      rethrow;
    }
    if (_closed) {
      connection.close();
      return;
    }
    final _CatalogConnection? previous = _worker;
    _worker = connection;
    package = selected;
    previous?.closeWhenIdle();
  }

  static Future<void> _verify(
    Directory directory,
    ScanCatalogPackage selected,
  ) {
    final String path = directory.path;
    final List<({String name, int bytes, String digest})> files =
        selected.files;
    return Isolate.run(() async {
      for (final ({String name, int bytes, String digest}) entry in files) {
        final File file = File('$path/${entry.name}');
        if (await file.length() != entry.bytes ||
            (await sha256.bind(file.openRead()).first).toString() !=
                entry.digest) {
          throw const FormatException('Catalog checksum differs.');
        }
      }
    });
  }

  Future<LocalCatalogPage?> printingsReady(
    String name, {
    String? setCode,
    String? language,
    int page = 1,
  }) async {
    final _CatalogConnection? worker = _worker;
    if (worker == null || _closed) {
      unawaited(warm().catchError((Object _) {}));
      return null;
    }
    final Object? value = await worker.request('name', <String, Object?>{
      'name': name,
      'set': setCode,
      'language': language,
      'page': page,
    });
    return _page(value);
  }

  Future<MtgCard?> exactReady(
    String setCode,
    String number, {
    String? language,
  }) async {
    final _CatalogConnection? worker = _worker;
    if (worker == null || _closed) {
      unawaited(warm().catchError((Object _) {}));
      return null;
    }
    final LocalCatalogPage result = _page(
      await worker.request('footer', <String, Object?>{
        'set': setCode,
        'number': number,
        'language': language ?? 'en',
      }),
    );
    return result.cards.length == 1 ? result.cards.single : null;
  }

  Future<List<String>?> cardNamesReady() async {
    final _CatalogConnection? worker = _worker;
    if (worker == null || _closed) return null;
    final Object? value = await worker.request(
      'names',
      const <String, Object?>{},
    );
    if (value is! List<Object?> ||
        value.any((Object? item) => item is! String)) {
      throw const FormatException('Invalid local card names.');
    }
    return List<String>.unmodifiable(value.cast<String>());
  }

  Future<List<LocalVisualHit>> visualSearch(
    List<List<double>> vectors, {
    int limit = 20,
    double maximumDistance = .35,
    List<int>? queryRotations,
    List<ScanBounds>? queryRegions,
  }) async {
    if (!ready) await warm().timeout(const Duration(seconds: 5));
    final _CatalogConnection? worker = _worker;
    if (worker == null || package?.visualCount == 0) {
      return const <LocalVisualHit>[];
    }
    final List<int> rotations =
        queryRotations ?? List<int>.filled(vectors.length, 0);
    if (vectors.isEmpty ||
        vectors.length > 4 ||
        rotations.length != vectors.length ||
        (queryRegions != null &&
            (queryRegions.length != vectors.length ||
                queryRegions.any(
                  (ScanBounds bounds) =>
                      !bounds.x.isFinite ||
                      !bounds.y.isFinite ||
                      !bounds.width.isFinite ||
                      !bounds.height.isFinite ||
                      bounds.x < 0 ||
                      bounds.y < 0 ||
                      bounds.width <= 0 ||
                      bounds.height <= 0 ||
                      bounds.x + bounds.width > 1 ||
                      bounds.y + bounds.height > 1,
                ))) ||
        rotations.any((int angle) => angle != 0 && angle != 180) ||
        limit < 1 ||
        limit > 40 ||
        !maximumDistance.isFinite ||
        maximumDistance < 0 ||
        maximumDistance > 1 ||
        vectors.any(
          (List<double> row) =>
              row.length != 256 ||
              row.any(
                (double value) => !value.isFinite || value < 0 || value > 1,
              ),
        )) {
      throw ArgumentError('Invalid visual search query.');
    }
    final Object? result = await worker.request('visual', <String, Object?>{
      'vectors': vectors,
      'limit': limit,
      'maximumDistance': maximumDistance,
      'primaryQueries': <int>[
        for (int index = 0; index < vectors.length; index++)
          if (queryRegions == null ||
              (queryRegions[index].x == queryRegions.first.x &&
                  queryRegions[index].y == queryRegions.first.y &&
                  queryRegions[index].width == queryRegions.first.width &&
                  queryRegions[index].height == queryRegions.first.height))
            index,
      ],
    });
    if (result is! List<Object?>) {
      throw const FormatException('Invalid visual search result.');
    }
    return List<LocalVisualHit>.unmodifiable(
      result.map((Object? raw) {
        if (raw is! Map<String, Object?> ||
            raw['illustration'] is! String ||
            raw['distance'] is! num) {
          throw const FormatException('Invalid visual candidate.');
        }
        final int query = raw['queryIndex']! as int;
        if (query < 0 || query >= rotations.length) {
          throw const FormatException('Invalid query orientation.');
        }
        return LocalVisualHit(
          raw['illustration']! as String,
          (raw['distance']! as num).toDouble(),
          _page(raw).cards,
          rotationDegrees: rotations[query],
          queryRegion: queryRegions?[query],
          referencePixels: raw['referencePixels'] is Uint8List
              ? raw['referencePixels']! as Uint8List
              : throw const FormatException('Missing reference pixels.'),
        );
      }),
    );
  }

  static LocalCatalogPage _page(Object? value) {
    if (value is! Map<String, Object?> ||
        value['cards'] is! List<Object?> ||
        value['total'] is! int) {
      throw const FormatException('Invalid local catalog response.');
    }
    final List<MtgCard> cards = (value['cards']! as List<Object?>).map((
      Object? card,
    ) {
      if (card is! Map<String, Object?>) {
        throw const FormatException('Invalid local printing.');
      }
      return MtgCard.fromJson(card);
    }).toList();
    return LocalCatalogPage(
      List<MtgCard>.unmodifiable(cards),
      value['total']! as int,
      value['hasMore'] == true,
    );
  }

  void close() {
    _closed = true;
    _worker?.closeWhenIdle();
    _worker = null;
  }
}

class _CatalogConnection {
  final Isolate isolate;
  final SendPort commands;
  final ReceivePort responses;
  final Map<int, Completer<Object?>> pending = <int, Completer<Object?>>{};
  int _next = 0;
  bool _closing = false;
  _CatalogConnection(this.isolate, this.commands, this.responses);

  static Future<_CatalogConnection> open(
    String path,
    int cards,
    int visuals,
    List<({String name, int bytes, String digest})> files,
  ) async {
    final ReceivePort responses = ReceivePort();
    final Completer<SendPort> ready = Completer<SendPort>();
    _CatalogConnection? connection;
    responses.listen((Object? message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      if (message == null || message is List<Object?>) {
        if (!ready.isCompleted) {
          ready.completeError(StateError('Catalog worker failed.'));
        }
        connection?.close();
        return;
      }
      if (message is! Map<String, Object?> || message['id'] is! int) return;
      final Completer<Object?>? result = connection?.pending.remove(
        message['id'],
      );
      if (result == null) return;
      if (message['error'] != null) {
        result.completeError(FormatException(message['error']! as String));
      } else {
        result.complete(message['value']);
      }
      if (connection?._closing == true && connection!.pending.isEmpty) {
        connection.close();
      }
    });
    final Isolate isolate = await Isolate.spawn(
      _catalogWorker,
      responses.sendPort,
      onError: responses.sendPort,
      onExit: responses.sendPort,
    );
    try {
      connection = _CatalogConnection(isolate, await ready.future, responses);
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      responses.close();
      rethrow;
    }
    try {
      await connection.request('load', <String, Object?>{
        'path': path,
        'cards': cards,
        'visuals': visuals,
        'grayFiles': <String, int>{
          for (final ({String name, int bytes, String digest}) file in files)
            if (RegExp(r'^visual\.gray\.[0-9]{4}\.bin$').hasMatch(file.name))
              file.name: file.bytes,
        },
      });
      return connection;
    } catch (_) {
      connection.close();
      rethrow;
    }
  }

  Future<Object?> request(String action, Map<String, Object?> arguments) {
    if (_closing) {
      return Future<Object?>.error(StateError('Catalog worker is closing.'));
    }
    final int id = _next++;
    final Completer<Object?> result = Completer<Object?>();
    pending[id] = result;
    commands.send(<String, Object?>{'id': id, 'action': action, ...arguments});
    return result.future;
  }

  void closeWhenIdle() {
    _closing = true;
    if (pending.isEmpty) close();
  }

  void close() {
    _closing = true;
    isolate.kill(priority: Isolate.immediate);
    responses.close();
    for (final Completer<Object?> result in pending.values) {
      result.completeError(StateError('Catalog worker closed.'));
    }
    pending.clear();
  }
}

String _catalogName(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
String _catalogNumber(String value) =>
    value.toLowerCase().replaceFirst(RegExp(r'^0+(?=\d)'), '');

void _catalogWorker(SendPort replies) {
  final ReceivePort commands = ReceivePort();
  replies.send(commands.sendPort);
  final _CatalogData data = _CatalogData();
  Future<void> tail = Future<void>.value();
  commands.listen((Object? message) {
    if (message is! Map<String, Object?> || message['id'] is! int) return;
    tail = tail.then((_) async {
      try {
        replies.send(<String, Object?>{
          'id': message['id'],
          'value': await data.handle(message),
        });
      } catch (_) {
        replies.send(<String, Object?>{
          'id': message['id'],
          'error': 'Local catalog operation failed.',
        });
      }
    });
  });
}

class _CatalogData {
  String path = '';
  List<List<Object?>> entries = <List<Object?>>[];
  final Map<String, List<int>> names = <String, List<int>>{};
  final Map<String, List<int>> footers = <String, List<int>>{};
  final Map<String, List<int>> illustrations = <String, List<int>>{};
  List<String> visualIds = <String>[];
  Uint8List vectors = Uint8List(0);
  Float32List visualStatistics = Float32List(0);
  final Map<String, List<Object?>> chunks = <String, List<Object?>>{};
  List<List<Object?>> grayRows = <List<Object?>>[];
  final Map<int, Uint8List> grayFrames = <int, Uint8List>{};
  Uint8List paperEligibility = Uint8List(0);

  Future<Object?> handle(Map<String, Object?> message) async {
    final String action = message['action']! as String;
    if (action == 'load') {
      path = message['path']! as String;
      final Object? decoded = jsonDecode(
        utf8.decode(
          gzip.decode(await File('$path/catalog.index.json.gz').readAsBytes()),
        ),
      );
      if (decoded is! Map<String, Object?> ||
          decoded['schema'] != 1 ||
          decoded['entries'] is! List<Object?>) {
        throw const FormatException('Invalid catalog index.');
      }
      entries = (decoded['entries']! as List<Object?>).map((Object? raw) {
        if (raw is! List<Object?> ||
            raw.length != 12 ||
            raw.take(6).any((Object? value) => value is! String) ||
            raw[6] is! List<Object?> ||
            raw[11] is! List<Object?> ||
            raw
                .sublist(7, 11)
                .any((Object? value) => value is! int || value < 0)) {
          throw const FormatException('Invalid catalog offset.');
        }
        return raw;
      }).toList();
      if (entries.length != message['cards']) {
        throw const FormatException('Catalog count differs.');
      }
      paperEligibility = Uint8List(entries.length);
      final Set<String> ids = <String>{};
      for (int index = 0; index < entries.length; index++) {
        final List<Object?> row = entries[index];
        if (!ids.add(row[0]! as String) ||
            (row[9]! as int) > 4 * 1024 * 1024 ||
            (row[10]! as int) > 99) {
          throw const FormatException('Invalid printing index.');
        }
        for (final String name in (row[11]! as List<Object?>).cast<String>()) {
          final String normalized = _catalogName(name);
          if (normalized.isNotEmpty) (names[normalized] ??= <int>[]).add(index);
        }
        final String footer =
            '${row[2]}/${_catalogNumber(row[3]! as String)}/${row[4]}';
        (footers[footer] ??= <int>[]).add(index);
        for (final String illustration
            in (row[6]! as List<Object?>).cast<String>()) {
          (illustrations[illustration] ??= <int>[]).add(index);
        }
      }
      final Object? decodedIds = jsonDecode(
        utf8.decode(
          gzip.decode(await File('$path/visual.ids.json.gz').readAsBytes()),
        ),
      );
      if (decodedIds is! List<Object?> ||
          decodedIds.any((Object? value) => value is! String)) {
        throw const FormatException('Invalid visual identities.');
      }
      visualIds = decodedIds.cast<String>();
      final Uint8List bytes = await File('$path/visual.index.bin')
          .readAsBytes();
      if (bytes.length < 16 ||
          utf8.decode(bytes.sublist(0, 8)) != 'SCVEC01\u0000' ||
          ByteData.sublistView(bytes).getUint32(8, Endian.little) != 256 ||
          ByteData.sublistView(bytes).getUint32(12, Endian.little) !=
              visualIds.length ||
          visualIds.length != message['visuals'] ||
          bytes.length != 16 + visualIds.length * 256 ||
          visualIds.toSet().length != visualIds.length ||
          visualIds.any((String id) => !illustrations.containsKey(id))) {
        throw const FormatException('Invalid visual vector index.');
      }
      vectors = Uint8List.sublistView(bytes, 16);
      final Object? grayIndex = jsonDecode(
        utf8.decode(
          gzip.decode(
            await File('$path/visual.gray.index.json.gz').readAsBytes(),
          ),
        ),
      );
      if (grayIndex is! Map<String, Object?> ||
          grayIndex['schema'] != ScanCatalogPackage.referenceSchema ||
          grayIndex['bytesPerReference'] != 2304 ||
          grayIndex['rows'] is! List<Object?> ||
          (grayIndex['rows']! as List<Object?>).length != visualIds.length) {
        throw const FormatException('Invalid structural reference index.');
      }
      final Map<String, int> grayFiles =
          (message['grayFiles']! as Map<Object?, Object?>).map(
            (Object? key, Object? value) =>
                MapEntry(key! as String, value! as int),
          );
      final Map<int, int> ends = <int, int>{};
      grayRows = (grayIndex['rows']! as List<Object?>).map((Object? raw) {
        if (raw is! List<Object?> ||
            raw.length != 4 ||
            raw.take(3).any((Object? value) => value is! int) ||
            raw[3] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw[3]! as String)) {
          throw const FormatException('Invalid structural reference offset.');
        }
        final int shard = raw[0]! as int;
        final int offset = raw[1]! as int;
        final int length = raw[2]! as int;
        final String name =
            'visual.gray.${shard.toString().padLeft(4, '0')}.bin';
        final int? size = grayFiles[name];
        if (shard < 0 ||
            shard > 511 ||
            size == null ||
            size > 4 * 1024 * 1024 ||
            offset != (ends[shard] ?? 8) ||
            length < 20 ||
            length > 4096 ||
            offset + length > size) {
          throw const FormatException('Invalid structural reference bounds.');
        }
        ends[shard] = offset + length;
        return raw;
      }).toList();
      for (final MapEntry<String, int> shard in grayFiles.entries) {
        final int index = int.parse(shard.key.split('.')[2]);
        if ((ends[index] ?? 8) != shard.value) {
          throw const FormatException('Structural shard length differs.');
        }
        final RandomAccessFile file = await File('$path/${shard.key}').open();
        try {
          if (await file.length() != shard.value ||
              utf8.decode(await file.read(8)) != 'SCGRSH2\u0000') {
            throw const FormatException('Invalid structural shard header.');
          }
        } finally {
          await file.close();
        }
      }
      visualStatistics = Float32List(visualIds.length * 9);
      for (int index = 0; index < visualIds.length; index++) {
        for (int channel = 0; channel < 3; channel++) {
          double sum = 0;
          double squares = 0;
          for (int cell = 0; cell < 64; cell++) {
            final int value = vectors[index * 256 + cell * 4 + channel];
            sum += value;
            squares += value * value;
          }
          final double mean = sum / 64;
          final double variance = math.max(0, squares / 64 - mean * mean);
          final double scale = 1 / (math.sqrt(variance) + 1);
          visualStatistics[index * 9 + channel] = mean;
          visualStatistics[index * 9 + 3 + channel] = scale;
          visualStatistics[index * 9 + 6 + channel] = variance * scale * scale;
        }
      }
      return true;
    }
    if (action == 'names') {
      return entries
          .expand(
            (List<Object?> row) => (row[11]! as List<Object?>).cast<String>(),
          )
          .toSet()
          .toList();
    }
    if (action == 'name') {
      List<int> indices =
          (names[_catalogName(message['name']! as String)] ?? <int>[])
              .toSet()
              .toList();
      indices = indices
          .where(
            (int index) =>
                (message['set'] == null ||
                    entries[index][2] ==
                        (message['set']! as String).toLowerCase()) &&
                (message['language'] == null ||
                    entries[index][4] ==
                        (message['language']! as String).toLowerCase()),
          )
          .toList();
      indices = await paperIndices(indices);
      final int page = message['page']! as int;
      if (page < 1 || page > 10000) {
        throw const FormatException('Invalid catalog page.');
      }
      final int start = (page - 1) * 175;
      return <String, Object?>{
        'cards': await read(indices.skip(start).take(175)),
        'total': indices.length,
        'hasMore': start + 175 < indices.length,
      };
    }
    if (action == 'footer') {
      final String key =
          '${(message['set']! as String).toLowerCase()}/${_catalogNumber(message['number']! as String)}/${(message['language']! as String).toLowerCase()}';
      final List<int> indices = await paperIndices(footers[key] ?? <int>[]);
      return <String, Object?>{
        'cards': await read(indices.take(2)),
        'total': indices.length,
        'hasMore': false,
      };
    }
    if (action == 'visual') {
      final List<List<int>> queries = (message['vectors']! as List<Object?>)
          .map(
            (Object? raw) => (raw! as List<Object?>)
                .map(
                  (Object? value) => ((value! as num).toDouble() * 255).round(),
                )
                .toList(),
          )
          .toList();
      final int limit = message['limit']! as int;
      final int mainLimit = limit >= 4 ? limit - 2 : limit;
      final double maximum = (message['maximumDistance']! as num).toDouble();
      final List<Float64List> shapes = <Float64List>[];
      final List<double> shapeVariances = <double>[];
      for (final List<int> query in queries) {
        final Float64List shape = Float64List(192);
        double shapeVariance = 0;
        for (int channel = 0; channel < 3; channel++) {
          double sum = 0;
          double squares = 0;
          for (int cell = 0; cell < 64; cell++) {
            final int value = query[cell * 4 + channel];
            sum += value;
            squares += value * value;
          }
          final double mean = sum / 64;
          final double variance = math.max(0, squares / 64 - mean * mean);
          final double scale = 1 / (math.sqrt(variance) + 1);
          shapeVariance += variance * scale * scale / 3;
          for (int cell = 0; cell < 64; cell++) {
            shape[cell * 3 + channel] =
                (query[cell * 4 + channel] - mean) * scale;
          }
        }
        shapes.add(shape);
        shapeVariances.add(shapeVariance);
      }
      final List<({int index, int squared, int query, double shape})> best =
          <({int index, int squared, int query, double shape})>[];
      for (int index = 0; index < visualIds.length; index++) {
        int squared = 256 * 255 * 255;
        int bestQuery = 0;
        double bestShape = double.infinity;
        for (int queryIndex = 0; queryIndex < queries.length; queryIndex++) {
          final List<int> query = queries[queryIndex];
          int total = 0;
          for (int component = 0; component < 256; component++) {
            final int difference =
                query[component] - vectors[index * 256 + component];
            total += difference * difference;
          }
          if (total > maximum * maximum * 256 * 255 * 255) continue;
          final Float64List queryShape = shapes[queryIndex];
          double dot = 0;
          double referenceVariance = 0;
          for (int channel = 0; channel < 3; channel++) {
            double channelDot = 0;
            for (int cell = 0; cell < 64; cell++) {
              channelDot +=
                  queryShape[cell * 3 + channel] *
                  (vectors[index * 256 + cell * 4 + channel] -
                      visualStatistics[index * 9 + channel]);
            }
            dot += channelDot * visualStatistics[index * 9 + 3 + channel];
            referenceVariance += visualStatistics[index * 9 + 6 + channel] / 3;
          }
          final double shape = math.max(
            0,
            shapeVariances[queryIndex] + referenceVariance - 2 * dot / 192,
          );
          if (shape < bestShape || (shape == bestShape && total < squared)) {
            squared = total;
            bestQuery = queryIndex;
            bestShape = shape;
          }
        }
        if (!bestShape.isFinite ||
            (best.length == mainLimit && bestShape > best.last.shape)) {
          continue;
        }
        best.add((
          index: index,
          squared: squared,
          query: bestQuery,
          shape: bestShape,
        ));
        best.sort(
          (
            ({int index, int squared, int query, double shape}) a,
            ({int index, int squared, int query, double shape}) b,
          ) => a.shape != b.shape
              ? a.shape.compareTo(b.shape)
              : a.squared != b.squared
              ? a.squared.compareTo(b.squared)
              : a.index.compareTo(b.index),
        );
        if (best.length > mainLimit) best.removeLast();
      }
      if (limit >= 4) {
        final List<int> primary = (message['primaryQueries']! as List<Object?>)
            .cast<int>();
        final List<({int index, int squared, int query, double shape})>
        patches = _patchProposals(queries, primary, maximum);
        for (final ({int index, int squared, int query, double shape}) patch
            in patches) {
          if (!best.any(
            (({int index, int squared, int query, double shape}) value) =>
                value.index == patch.index,
          )) {
            best.add(patch);
          }
        }
      }
      final List<Map<String, Object?>> found = <Map<String, Object?>>[];
      for (final ({int index, int squared, int query, double shape}) hit
          in best) {
        final String illustration = visualIds[hit.index];
        final List<int> cards = await paperIndices(
          illustrations[illustration]!,
        );
        if (cards.isEmpty) {
          continue;
        }
        final Map<String, int> identities = <String, int>{};
        for (final int card in cards) {
          identities.putIfAbsent(entries[card][5]! as String, () => card);
        }
        found.add(<String, Object?>{
          'illustration': illustration,
          'distance': math.sqrt(hit.squared / 256) / 255,
          'queryIndex': hit.query,
          'referencePixels': await readGray(hit.index),
          'cards': await read(identities.values.take(8)),
          'total': cards.length,
          'hasMore': identities.length > 8,
        });
      }
      return found;
    }
    throw const FormatException('Unsupported catalog query.');
  }

  List<({int index, int squared, int query, double shape})> _patchProposals(
    List<List<int>> queries,
    List<int> primary,
    double maximum,
  ) {
    final List<({int index, int squared, int query, double shape})> found =
        <({int index, int squared, int query, double shape})>[];
    for (final int side in <int>[0, 4]) {
      final List<({int query, Float64List shape, double variance})>
      queryShapes = <({int query, Float64List shape, double variance})>[];
      int component(int cell, int channel) =>
          ((cell ~/ 4) * 8 + cell % 4 + side) * 4 + channel;
      for (final int queryIndex in primary) {
        final List<int> query = queries[queryIndex];
        final Float64List shape = Float64List(96);
        double totalVariance = 0;
        for (int channel = 0; channel < 3; channel++) {
          double sum = 0;
          double squares = 0;
          for (int cell = 0; cell < 32; cell++) {
            final int value = query[component(cell, channel)];
            sum += value;
            squares += value * value;
          }
          final double mean = sum / 32;
          final double variance = math.max(0, squares / 32 - mean * mean);
          final double scale = 1 / (math.sqrt(variance) + 1);
          totalVariance += variance * scale * scale / 3;
          for (int cell = 0; cell < 32; cell++) {
            shape[cell * 3 + channel] =
                (query[component(cell, channel)] - mean) * scale;
          }
        }
        if (totalVariance >= .05) {
          queryShapes.add((
            query: queryIndex,
            shape: shape,
            variance: totalVariance,
          ));
        }
      }
      if (queryShapes.isEmpty) continue;
      ({int index, int squared, int query, double shape})? winner;
      final Float64List means = Float64List(3);
      final Float64List scales = Float64List(3);
      for (int index = 0; index < visualIds.length; index++) {
        double referenceVariance = 0;
        for (int channel = 0; channel < 3; channel++) {
          double sum = 0;
          double squares = 0;
          for (int cell = 0; cell < 32; cell++) {
            final int value = vectors[index * 256 + component(cell, channel)];
            sum += value;
            squares += value * value;
          }
          means[channel] = sum / 32;
          final double variance = math.max(
            0,
            squares / 32 - means[channel] * means[channel],
          );
          scales[channel] = 1 / (math.sqrt(variance) + 1);
          referenceVariance += variance * scales[channel] * scales[channel] / 3;
        }
        if (referenceVariance < .05) continue;
        for (final ({int query, Float64List shape, double variance}) query
            in queryShapes) {
          int squared = 0;
          for (int channel = 0; channel < 256; channel++) {
            final int difference =
                queries[query.query][channel] - vectors[index * 256 + channel];
            squared += difference * difference;
          }
          if (squared > maximum * maximum * 256 * 255 * 255) continue;
          double dot = 0;
          for (int channel = 0; channel < 3; channel++) {
            double channelDot = 0;
            for (int cell = 0; cell < 32; cell++) {
              channelDot +=
                  query.shape[cell * 3 + channel] *
                  (vectors[index * 256 + component(cell, channel)] -
                      means[channel]);
            }
            dot += channelDot * scales[channel];
          }
          final double score = math.max(
            0,
            query.variance + referenceVariance - 2 * dot / 96,
          );
          if (winner == null ||
              score < winner.shape ||
              (score == winner.shape && squared < winner.squared)) {
            winner = (
              index: index,
              squared: squared,
              query: query.query,
              shape: score,
            );
          }
        }
      }
      if (winner != null) found.add(winner);
    }
    return found;
  }

  Future<Uint8List> readGray(int index) async {
    final Uint8List? cached = grayFrames[index];
    if (cached != null) return cached;
    final List<Object?> row = grayRows[index];
    final String shard = (row[0]! as int).toString().padLeft(4, '0');
    final RandomAccessFile file = await File('$path/visual.gray.$shard.bin')
        .open();
    try {
      await file.setPosition(row[1]! as int);
      final Uint8List compressed = await file.read(row[2]! as int);
      if (compressed.length != row[2]) {
        throw const FormatException('Truncated structural reference.');
      }
      final Uint8List pixels = Uint8List.fromList(gzip.decode(compressed));
      if (pixels.length != 2304 ||
          sha256.convert(pixels).toString() != row[3]) {
        throw const FormatException('Invalid structural reference pixels.');
      }
      if (grayFrames.length == 40) grayFrames.remove(grayFrames.keys.first);
      grayFrames[index] = pixels;
      return pixels;
    } finally {
      await file.close();
    }
  }

  Future<List<int>> paperIndices(Iterable<int> indices) async {
    final List<int> found = <int>[];
    for (final int index in indices) {
      if (paperEligibility[index] == 0) {
        final Map<String, Object?> card = (await read(<int>[index])).single;
        final Object? games = card['games'];
        paperEligibility[index] =
            games is List<Object?> && games.contains('paper') ? 1 : 2;
      }
      if (paperEligibility[index] == 1) {
        found.add(index);
      }
    }
    return found;
  }

  Future<List<Map<String, Object?>>> read(Iterable<int> indices) async {
    final List<Map<String, Object?>> cards = <Map<String, Object?>>[];
    for (final int index in indices) {
      final List<Object?> row = entries[index];
      final String key = '${row[7]}/${row[8]}/${row[9]}';
      List<Object?>? chunk = chunks[key];
      if (chunk == null) {
        final String shard = (row[7]! as int).toString().padLeft(4, '0');
        final RandomAccessFile file = await File('$path/cards.$shard.bin')
            .open();
        try {
          await file.setPosition(row[8]! as int);
          final Uint8List compressed = await file.read(row[9]! as int);
          if (compressed.length != row[9]) {
            throw const FormatException('Truncated catalog chunk.');
          }
          final List<int> payload = gzip.decode(compressed);
          if (payload.length > 8 * 1024 * 1024) {
            throw const FormatException('Oversized catalog chunk.');
          }
          final Object? decoded = jsonDecode(utf8.decode(payload));
          if (decoded is! List<Object?> || decoded.length > 100) {
            throw const FormatException('Invalid catalog chunk.');
          }
          chunk = decoded;
          if (chunks.length == 8) chunks.remove(chunks.keys.first);
          chunks[key] = chunk;
        } finally {
          await file.close();
        }
      }
      final Object? card = chunk[row[10]! as int];
      if (card is! Map<String, Object?> ||
          card['id'] != row[0] ||
          card['name'] != row[1] ||
          card['set'] != row[2] ||
          card['collector_number'] != row[3] ||
          card['lang'] != row[4]) {
        throw const FormatException(
          'Printing metadata differs from its index.',
        );
      }
      cards.add(card);
    }
    return cards;
  }
}
