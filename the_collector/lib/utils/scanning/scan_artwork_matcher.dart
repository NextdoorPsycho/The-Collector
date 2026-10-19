import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:scryfall_api/scryfall_api.dart';

import 'scan_recognition.dart';
import 'scan_local_catalog.dart';
import 'scan_visual_work_scheduler.dart';

abstract interface class ScanArtworkMatcher {
  Future<Map<String, double>> compare(
    ScanCrop crop,
    List<MtgCard> candidates, {
    bool reliableBodyFallback = false,
  });
}

typedef ArtworkComparator = Future<double?> Function({
  required String queryImagePath,
  required String referenceImagePath,
});

typedef ArtworkProfileComparator = Future<double?> Function({
  required String queryImagePath,
  required String referenceImagePath,
  required ScanBounds queryRegion,
  required int rotationDegrees,
});

typedef ArtworkStructureComparator = Future<double?> Function({
  required String queryImagePath,
  required Uint8List referencePixels,
  required ScanBounds queryRegion,
  required int rotationDegrees,
});

class CachedScanArtworkMatcher implements ScanArtworkMatcher {
  CachedScanArtworkMatcher({
    ArtworkComparator? comparator,
    ArtworkProfileComparator? profileComparator,
    ArtworkStructureComparator? structureComparator,
    http.Client Function()? clientFactory,
  }) : _comparator = comparator ?? NativeCardRecognizer.compareArtwork,
       _profileComparator = profileComparator ?? _nativeProfileComparator,
       _structureComparator = structureComparator ?? _nativeStructureComparator,
       _clientFactory = clientFactory ?? http.Client.new;

  static final CachedScanArtworkMatcher shared = CachedScanArtworkMatcher();
  final ArtworkComparator _comparator;
  final ArtworkProfileComparator _profileComparator;
  final ArtworkStructureComparator _structureComparator;
  final http.Client Function() _clientFactory;
  final Map<String, Future<String?>> _downloads = <String, Future<String?>>{};
  static final Map<String, int> _leases = <String, int>{};
  static Future<void> _evictions = Future<void>.value();
  Future<Box<String>>? _opening;

  Future<Box<String>> _box() =>
      _opening ??= Hive.openBox<String>('scanner_artwork_v1')
          .catchError((Object error) {
            _opening = null;
            throw error;
          });

  @override
  Future<Map<String, double>> compare(
    ScanCrop crop,
    List<MtgCard> candidates, {
    bool reliableBodyFallback = false,
  }) => _compare(crop, candidates, reliableBodyFallback: reliableBodyFallback);

  Future<Map<String, double>> compareDiscovered(
    ScanCrop crop,
    List<MtgCard> candidates, {
    ScanBounds? queryRegion,
    int rotationDegrees = 0,
    Map<String, String>? illustrationByCard,
    required Map<String, Uint8List> referencePixelsByIllustration,
  }) async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.iOS ||
        !crop.rectified ||
        crop.width < 32 ||
        crop.height < 32 ||
        candidates.length > 160 ||
        !await File(crop.imagePath).exists()) {
      return <String, double>{};
    }
    final Map<String, double?> distances = <String, double?>{};
    final Map<String, String> illustrations = <String, String>{};
    final ScanBounds region =
        queryRegion ?? const ScanBounds(.07, .075, .86, .44);
    for (final MtgCard card in candidates) {
      if (!card.games.contains(Game.paper)) {
        continue;
      }
      final String? illustration =
          illustrationByCard?[card.id] ?? card.illustrationId;
      final Uint8List? pixels = referencePixelsByIllustration[illustration];
      if (illustration == null || pixels == null || pixels.length != 2304) {
        continue;
      }
      if (card.illustrationId != illustration &&
          !(card.cardFaces?.any(
                (CardFace face) => face.illustrationId == illustration,
              ) ??
              false)) {
        continue;
      }
      if (!distances.containsKey(illustration)) {
        if (distances.length == 20) continue;
        distances[illustration] = null;
        try {
          final double? distance = await ScanVisualWorkScheduler.compare(
            () => _structureComparator(
              queryImagePath: crop.imagePath,
              referencePixels: pixels,
              queryRegion: region,
              rotationDegrees: rotationDegrees,
            ),
          );
          if (distance != null &&
              distance.isFinite &&
              distance >= 0 &&
              distance <= .20) {
            distances[illustration] = distance;
          }
        } catch (_) {}
      }
      illustrations[card.id] = illustration;
    }
    return <String, double>{
      for (final MapEntry<String, String> entry in illustrations.entries)
        if (distances[entry.value] != null) entry.key: distances[entry.value]!,
    };
  }

  static Future<double?> _nativeProfileComparator({
    required String queryImagePath,
    required String referenceImagePath,
    required ScanBounds queryRegion,
    required int rotationDegrees,
  }) async {
    final Object? result = await NativeCardRecognizer.channel
        .invokeMethod<Object?>('compareArtwork', <String, Object>{
          'queryImagePath': queryImagePath,
          'referenceImagePath': referenceImagePath,
          'rotationDegrees': rotationDegrees,
          'queryRegion': <String, double>{
            'x': queryRegion.x,
            'y': queryRegion.y,
            'width': queryRegion.width,
            'height': queryRegion.height,
          },
        });
    return result is num && result.isFinite && result >= 0
        ? result.toDouble()
        : null;
  }

  static Future<double?> _nativeStructureComparator({
    required String queryImagePath,
    required Uint8List referencePixels,
    required ScanBounds queryRegion,
    required int rotationDegrees,
  }) async {
    final Object? result = await NativeCardRecognizer.channel
        .invokeMethod<Object?>('compareArtworkStructure', <String, Object>{
          'queryImagePath': queryImagePath,
          'referencePixels': referencePixels,
          'referenceSchema': ScanCatalogPackage.referenceSchema,
          'rotationDegrees': rotationDegrees,
          'queryRegion': <String, double>{
            'x': queryRegion.x,
            'y': queryRegion.y,
            'width': queryRegion.width,
            'height': queryRegion.height,
          },
        });
    if (result is! Map<Object?, Object?> ||
        result['schema'] != 'gray-alignment-v1' ||
        result['correlation'] is! num ||
        result['coverage'] is! num ||
        result['referenceDigest'] !=
            sha256.convert(referencePixels).toString() ||
        result['rotationDegrees'] != rotationDegrees ||
        result['region'] is! Map<Object?, Object?>) {
      return null;
    }
    final Map<Object?, Object?> observed =
        result['region']! as Map<Object?, Object?>;
    final Map<String, double> requested = <String, double>{
      'x': queryRegion.x,
      'y': queryRegion.y,
      'width': queryRegion.width,
      'height': queryRegion.height,
    };
    if (requested.entries.any(
      (MapEntry<String, double> entry) =>
          observed[entry.key] is! num ||
          !(observed[entry.key]! as num).toDouble().isFinite ||
          ((observed[entry.key]! as num).toDouble() - entry.value).abs() >
              .00001,
    )) {
      return null;
    }
    final double correlation = (result['correlation']! as num).toDouble();
    final double coverage = (result['coverage']! as num).toDouble();
    if (!correlation.isFinite ||
        correlation < -1 ||
        correlation > 1 ||
        !coverage.isFinite ||
        coverage < .35 ||
        coverage > 1) {
      return null;
    }
    return 1 - correlation;
  }

  Future<Map<String, double>> _compare(
    ScanCrop crop,
    List<MtgCard> candidates, {
    bool reliableBodyFallback = false,
    ScanBounds? queryRegion,
    int rotationDegrees = 0,
  }) async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.iOS ||
        crop.imagePath.isEmpty ||
        !crop.rectified ||
        (reliableBodyFallback
            ? !hasVerifiedSavedVisualLayout(crop) || candidates.length > 96
            : crop.warnings.isNotEmpty)) {
      return <String, double>{};
    }
    final ScanBounds? measuredRegion =
        queryRegion ??
        (crop.lines.any(
              (ScanTextLine line) =>
                  line.confidence >= .85 &&
                  line.bounds.y >= .70 &&
                  line.bounds.y < .90 &&
                  RegExp(
                    r'^basic(?:\s+snow)?\s+land\b',
                    caseSensitive: false,
                  ).hasMatch(line.text.trim()),
            )
            ? const ScanBounds(.07, .10, .86, .65)
            : null);
    final List<String> leased = <String>[];
    Future<List<String?>>? admitted;
    try {
      final List<({MtgCard card, String illustration, Uri uri})> references =
          <({MtgCard card, String illustration, Uri uri})>[];
      for (final MtgCard card in candidates) {
        if (!card.games.contains(Game.paper)) {
          continue;
        }
        final CardFace? face = card.cardFaces?.firstOrNull;
        final Uri? reference =
            card.imageUris?.artCrop ?? face?.imageUris?.artCrop;
        if (reference == null ||
            reference.scheme != 'https' ||
            reference.host != 'cards.scryfall.io') {
          continue;
        }
        references.add((
          card: card,
          illustration:
              card.illustrationId ??
              face?.illustrationId ??
              reference.toString(),
          uri: reference,
        ));
      }
      if (reliableBodyFallback &&
          references
                  .map(
                    (({MtgCard card, String illustration, Uri uri}) value) =>
                        value.illustration,
                  )
                  .toSet()
                  .length >
              32) {
        return <String, double>{};
      }
      if (!await File(crop.imagePath).exists()) {
        return <String, double>{};
      }
      final Map<String, double> distances = <String, double>{};
      final Map<String, double?> illustrations = <String, double?>{};
      final Map<String, ({MtgCard card, String illustration, Uri uri})>
      selected = <String, ({MtgCard card, String illustration, Uri uri})>{};
      for (final ({MtgCard card, String illustration, Uri uri}) reference
          in references) {
        if (selected.containsKey(reference.illustration) ||
            selected.length >= (reliableBodyFallback ? 32 : 3)) {
          continue;
        }
        selected[reference.illustration] = reference;
        final String key = sha256
            .convert(utf8.encode(reference.illustration))
            .toString();
        leased.add(key);
        _leases[key] = (_leases[key] ?? 0) + 1;
      }
      final List<({MtgCard card, String illustration, Uri uri})> unique =
          selected.values.toList();
      Future<String?> load(
        ({MtgCard card, String illustration, Uri uri}) reference,
      ) async {
        try {
          return await (_downloads[reference.illustration] ??=
              ScanVisualWorkScheduler.reference(
                () => _reference(reference.illustration, reference.uri),
              ).whenComplete(() {
                _downloads.remove(reference.illustration);
              }));
        } catch (_) {
          return null;
        }
      }

      Future<List<String?>> loadPair(int offset) =>
          Future.wait<String?>(unique.skip(offset).take(2).map(load));
      if (unique.isNotEmpty) admitted = loadPair(0);
      for (int offset = 0; offset < unique.length; offset += 2) {
        final List<({MtgCard card, String illustration, Uri uri})> pair = unique
            .skip(offset)
            .take(2)
            .toList();
        final List<String?> paths = await admitted!;
        admitted = offset + 2 < unique.length ? loadPair(offset + 2) : null;
        for (int index = 0; index < pair.length; index++) {
          final String illustration = pair[index].illustration;
          illustrations[illustration] = null;
          final String? path = paths[index];
          if (path == null) continue;
          try {
            final double? distance = await ScanVisualWorkScheduler.compare(
              () => measuredRegion != null || rotationDegrees != 0
                  ? _profileComparator(
                      queryImagePath: crop.imagePath,
                      referenceImagePath: path,
                      queryRegion:
                          measuredRegion ??
                          const ScanBounds(.08, .14, .84, .38),
                      rotationDegrees: rotationDegrees,
                    )
                  : _comparator(
                      queryImagePath: crop.imagePath,
                      referenceImagePath: path,
                    ),
            );
            if (distance != null && distance.isFinite && distance >= 0) {
              illustrations[illustration] = distance;
            }
          } catch (_) {
            // Busy or unsupported visual matching must not discard text recognition.
          }
        }
      }
      for (final ({MtgCard card, String illustration, Uri uri}) reference
          in references) {
        final String illustration = reference.illustration;
        final double? distance = illustrations[illustration];
        if (distance != null) {
          distances[reference.card.id] = distance;
        }
      }
      return distances;
    } catch (_) {
      return <String, double>{};
    } finally {
      if (admitted != null) {
        try {
          await admitted;
        } catch (_) {}
      }
      for (final String key in leased) {
        final int remaining = _leases[key]! - 1;
        if (remaining == 0) {
          _leases.remove(key);
        } else {
          _leases[key] = remaining;
        }
      }
      if (leased.isNotEmpty) {
        try {
          await _trim();
        } catch (_) {}
      }
    }
  }

  Future<void> _trim() {
    final Future<void> operation = _evictions.then((_) async {
      final Box<String> box = await _box();
      final String? path = box.path;
      if (!box.isOpen || path == null || box.length <= 256) return;
      final Directory directory = Directory(
        '${File(path).parent.path}/scanner_artwork',
      );
      final List<String> old = box.keys
          .whereType<String>()
          .where((String key) => !_leases.containsKey(key))
          .take(box.length - 256)
          .toList();
      final List<String> removed = <String>[];
      for (final String key in old) {
        final File image = File('${directory.path}/$key.jpg');
        final bool exists = await image.exists();
        if (_leases.containsKey(key)) continue;
        if (exists) await image.delete();
        removed.add(key);
      }
      await box.deleteAll(removed);
    });
    _evictions = operation.catchError((Object _) {});
    return operation;
  }

  Future<String?> _reference(String illustration, Uri uri) async {
    String? pendingPath;
    final http.Client client = _clientFactory();
    try {
      await _evictions;
      final Box<String> box = await _box();
      final String? boxPath = box.path;
      if (boxPath == null) {
        return null;
      }
      final Directory directory = Directory(
        '${File(boxPath).parent.path}/scanner_artwork',
      );
      await directory.create(recursive: true);
      final String key = sha256.convert(utf8.encode(illustration)).toString();
      final File image = File('${directory.path}/$key.jpg');
      if (box.containsKey(key) && await image.exists()) {
        return image.path;
      }
      final http.StreamedResponse response = await client
          .send(
            http.Request('GET', uri)
              ..headers.addAll(<String, String>{
                'User-Agent': 'TheCollector/1.0',
                'Accept': 'image/jpeg',
              }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > 2097152) {
        return null;
      }
      final List<int> bytes = <int>[];
      await for (final List<int> chunk in response.stream.timeout(
        const Duration(seconds: 10),
      )) {
        if (bytes.length + chunk.length > 2097152) {
          return null;
        }
        bytes.addAll(chunk);
      }
      if (bytes.isEmpty) {
        return null;
      }
      pendingPath = '${image.path}.pending';
      await File(pendingPath).writeAsBytes(bytes, flush: true);
      await File(pendingPath).rename(image.path);
      pendingPath = null;
      await box.put(key, image.path);
      await box.flush();
      await _trim();
      return image.path;
    } catch (_) {
      return null;
    } finally {
      client.close();
      if (pendingPath != null) {
        try {
          await File(pendingPath).delete();
        } on FileSystemException {
          // A stale temporary reference is harmless and can be overwritten on retry.
        }
      }
    }
  }
}
