import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:scryfall_api/scryfall_api.dart';

import 'scan_recognition.dart';
import 'scryfall_request_scheduler.dart';
import 'scan_visual_work_scheduler.dart';

abstract interface class ScanSymbolMatcher {
  Future<Map<String, double>> compare(ScanCrop crop, List<MtgCard> candidates);
}

typedef SymbolComparator = Future<double?> Function({
  required String queryImagePath,
  required String referenceImagePath,
  required ScanBounds queryRegion,
});
typedef SetIconLoader = Future<Uri> Function(String setCode);

class CachedScanSymbolMatcher implements ScanSymbolMatcher {
  CachedScanSymbolMatcher({
    SymbolComparator? comparator,
    SetIconLoader? iconLoader,
    http.Client Function()? clientFactory,
  }) : _comparator = comparator ?? NativeCardRecognizer.compareSetSymbol,
       _iconLoader = iconLoader ?? _loadSetIcon,
       _clientFactory = clientFactory ?? http.Client.new;

  static final CachedScanSymbolMatcher shared = CachedScanSymbolMatcher();
  final SymbolComparator _comparator;
  final SetIconLoader _iconLoader;
  final http.Client Function() _clientFactory;
  final Map<String, Future<String?>> _downloads = <String, Future<String?>>{};
  static final Map<String, int> _leases = <String, int>{};
  static Future<void> _evictions = Future<void>.value();
  Future<Box<String>>? _opening;

  static Future<Uri> _loadSetIcon(String code) async {
    final ScryfallHttpClient client = ScryfallHttpClient();
    try {
      return (await ScryfallApiClient(httpClient: client)
              .getSetByCode(code)
              .timeout(const Duration(seconds: 10)))
          .iconSvgUri;
    } finally {
      client.close();
    }
  }

  Future<Box<String>> _box() =>
      _opening ??= Hive.openBox<String>('scanner_symbols_v1')
          .catchError((Object error) {
            _opening = null;
            throw error;
          });

  @override
  Future<Map<String, double>> compare(
    ScanCrop crop,
    List<MtgCard> candidates,
  ) async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.iOS ||
        crop.imagePath.isEmpty ||
        !crop.rectified ||
        candidates.length > 96 ||
        (crop.warnings.isNotEmpty && !hasVerifiedSavedVisualLayout(crop))) {
      return <String, double>{};
    }
    final ScanBounds? region = symbolRegion(crop);
    if (region == null) return <String, double>{};
    final List<String> leased = <String>[];
    Future<List<String?>>? admitted;
    try {
      if (!await File(crop.imagePath).exists()) return <String, double>{};
      final Map<String, double?> sets = <String, double?>{};
      final Map<String, double> distances = <String, double>{};
      final int maximumSets = crop.warnings.isEmpty ? 3 : 32;
      for (final MtgCard candidate in candidates) {
        if (!<Layout>{
          Layout.normal,
          Layout.transform,
          Layout.modalDfc,
        }.contains(candidate.layout)) {
          continue;
        }
        final String code = candidate.set.toLowerCase();
        if (!RegExp(r'^[a-z0-9]{2,8}$').hasMatch(code)) continue;
        if (sets.containsKey(code) || sets.length >= maximumSets) continue;
        sets[code] = null;
        leased.add(code);
        _leases[code] = (_leases[code] ?? 0) + 1;
      }
      Future<String?> load(String code) async {
        try {
          return await (_downloads[code] ??=
              ScanVisualWorkScheduler.reference(() => _reference(code))
                  .whenComplete(() {
                    _downloads.remove(code);
                  }));
        } catch (_) {
          return null;
        }
      }

      final List<String> codes = sets.keys.toList();
      Future<List<String?>> loadPair(int offset) =>
          Future.wait<String?>(codes.skip(offset).take(2).map(load));
      if (codes.isNotEmpty) admitted = loadPair(0);
      for (int offset = 0; offset < codes.length; offset += 2) {
        final List<String> pair = codes.skip(offset).take(2).toList();
        final List<String?> paths = await admitted!;
        admitted = offset + 2 < codes.length ? loadPair(offset + 2) : null;
        for (int index = 0; index < pair.length; index++) {
          final String code = pair[index];
          final String? reference = paths[index];
          if (reference == null) continue;
          try {
            final double? distance = await ScanVisualWorkScheduler.compare(
              () => _comparator(
                queryImagePath: crop.imagePath,
                referenceImagePath: reference,
                queryRegion: region,
              ),
            );
            if (distance != null && distance.isFinite && distance >= 0) {
              sets[code] = distance;
            }
          } catch (_) {
            // A missing symbol or busy native scanner leaves text matching available.
          }
        }
      }
      for (final MtgCard candidate in candidates) {
        if (!<Layout>{
          Layout.normal,
          Layout.transform,
          Layout.modalDfc,
        }.contains(candidate.layout)) {
          continue;
        }
        final double? distance = sets[candidate.set.toLowerCase()];
        if (distance != null) distances[candidate.id] = distance;
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
      for (final String code in leased) {
        final int remaining = _leases[code]! - 1;
        if (remaining == 0) {
          _leases.remove(code);
        } else {
          _leases[code] = remaining;
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
      if (!box.isOpen || path == null || box.length <= 128) return;
      final Directory directory = Directory(
        '${File(path).parent.path}/scanner_symbols',
      );
      final List<String> old = box.keys
          .whereType<String>()
          .where((String code) => !_leases.containsKey(code))
          .take(box.length - 128)
          .toList();
      final List<String> removed = <String>[];
      for (final String code in old) {
        final File image = File('${directory.path}/$code.png');
        final bool exists = await image.exists();
        if (_leases.containsKey(code)) continue;
        if (exists) await image.delete();
        removed.add(code);
      }
      await box.deleteAll(removed);
    });
    _evictions = operation.catchError((Object _) {});
    return operation;
  }

  @visibleForTesting
  static ScanBounds? symbolRegion(ScanCrop crop) {
    if (!crop.rectified ||
        (crop.warnings.isNotEmpty && !hasVerifiedSavedVisualLayout(crop))) {
      return null;
    }
    for (final ScanTextLine line in crop.lines) {
      if (line.confidence < .85 ||
          line.bounds.y < .38 ||
          line.bounds.y > .65 ||
          line.bounds.height > .045 ||
          observedCardType(line.text) == null) {
        continue;
      }
      final double left = math.max(
        .78,
        line.bounds.x + line.bounds.width + .02,
      );
      if (left > .87) continue;
      final double top = math.max(.35, line.bounds.y - .015);
      final double height = math.max(.06, line.bounds.height + .035);
      return ScanBounds(left, top, .95 - left, height);
    }
    return null;
  }

  Future<String?> _reference(String code) async {
    final http.Client client = _clientFactory();
    String? pendingPath;
    try {
      await _evictions;
      final Box<String> box = await _box();
      if (box.path == null) return null;
      final Directory directory = Directory(
        '${File(box.path!).parent.path}/scanner_symbols',
      );
      await directory.create(recursive: true);
      final File image = File('${directory.path}/$code.png');
      if (box.containsKey(code) && await image.exists()) return image.path;
      final Uri icon = await _iconLoader(code);
      if (icon.scheme != 'https' ||
          !<String>{
            'svgs.scryfall.io',
            'cards.scryfall.io',
          }.contains(icon.host)) {
        return null;
      }
      final http.StreamedResponse response = await client
          .send(
            http.Request('GET', icon)
              ..headers.addAll(<String, String>{
                'User-Agent': 'TheCollector/1.0',
                'Accept': 'image/svg+xml',
              }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > 262144) {
        return null;
      }
      final List<int> bytes = <int>[];
      await for (final List<int> chunk in response.stream.timeout(
        const Duration(seconds: 10),
      )) {
        if (bytes.length + chunk.length > 262144) return null;
        bytes.addAll(chunk);
      }
      if (bytes.isEmpty) return null;
      final Uint8List png = await rasterizeSymbol(utf8.decode(bytes));
      pendingPath = '${image.path}.pending';
      await File(pendingPath).writeAsBytes(png, flush: true);
      await File(pendingPath).rename(image.path);
      pendingPath = null;
      await box.put(code, image.path);
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
          // A failed download's scratch file can already be gone.
        }
      }
    }
  }

  @visibleForTesting
  static Future<Uint8List> rasterizeSymbol(String svg) async {
    final PictureInfo picture = await vg.loadPicture(
      SvgStringLoader(svg),
      null,
    );
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    try {
      if (picture.size.isEmpty) {
        throw const FormatException('Set icon is empty.');
      }
      canvas.drawColor(const ui.Color(0xFFFFFFFF), ui.BlendMode.src);
      final double scale =
          112 / math.max(picture.size.width, picture.size.height);
      canvas.translate(
        (128 - picture.size.width * scale) / 2,
        (128 - picture.size.height * scale) / 2,
      );
      canvas.scale(scale);
      canvas.drawPicture(picture.picture);
      final ui.Picture result = recorder.endRecording();
      try {
        final ui.Image image = await result.toImage(128, 128);
        try {
          final ByteData? bytes = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (bytes == null) {
            throw const FormatException('Set icon could not be rendered.');
          }
          return bytes.buffer.asUint8List(
            bytes.offsetInBytes,
            bytes.lengthInBytes,
          );
        } finally {
          image.dispose();
        }
      } finally {
        result.dispose();
      }
    } finally {
      if (recorder.isRecording) recorder.endRecording().dispose();
      picture.picture.dispose();
    }
  }
}
