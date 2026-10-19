import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:scryfall_api/scryfall_api.dart';

import 'scan_recognition.dart';
import 'scan_resolver.dart';
import 'cloud_scan_consent.dart';
import 'cloud_card_hints_service.dart';

typedef _CropRevision = ({
  String path,
  int width,
  int height,
  int modified,
  int changed,
  int size,
  CloudScanPermission permission,
});

typedef CloudCardCropEncoder = Future<Uint8List?> Function(ScanCrop crop);
typedef CloudScanConsentCheck = Future<CloudScanPermission?> Function();

class CloudScanResolver extends ScanResolver {
  CloudScanResolver({
    super.catalog,
    super.artwork,
    super.symbols,
    this.enabled = const bool.fromEnvironment('CLOUD_CARD_HINTS_ENABLED'),
    CloudCardHintsCallable? callable,
    CloudCardHintsStatusCallable? statusCallable,
    CloudCardHintsService? cloudService,
    CloudCardCropEncoder? encoder,
    this.acquireConsent,
    this.timeout = const Duration(seconds: 20),
  }) : cloudService =
           cloudService ??
           (callable == null &&
                   statusCallable == null &&
                   enabled == cloudCardHintsEnabled
               ? CloudCardHintsService.instance
               : CloudCardHintsService(
                   enabled: enabled,
                   callable: callable,
                   statusCallable: statusCallable,
                 )),
       _encoder = encoder ?? encodeSavedCrop;

  final bool enabled;
  final CloudScanConsentCheck? acquireConsent;
  final Duration timeout;
  final CloudCardHintsService cloudService;
  final CloudCardCropEncoder _encoder;
  final LinkedHashMap<_CropRevision, _CatalogSuggestions?> _cache =
      LinkedHashMap<_CropRevision, _CatalogSuggestions?>();
  final Map<_CropRevision, Future<_CatalogSuggestions?>> _pending =
      <_CropRevision, Future<_CatalogSuggestions?>>{};

  @override
  Future<ScanResolution> resolve(
    ScanCrop crop, {
    String? name,
    String? setCode,
    String? collectorNumber,
    String? language,
    int page = 1,
  }) async {
    final ScanResolution local = await super.resolve(
      crop,
      name: name,
      setCode: setCode,
      collectorNumber: collectorNumber,
      language: language,
      page: page,
    );
    if (!enabled ||
        page != 1 ||
        name != null ||
        setCode != null ||
        collectorNumber != null ||
        language != null ||
        local.status == ScanResolutionStatus.exactPrinting ||
        !_isSavedCrop(crop)) {
      return local;
    }
    _CatalogSuggestions? suggestions;
    CloudScanPermission? permission;
    try {
      permission = await acquireConsent?.call();
      if (permission == null || !permission.isValid) return local;
      suggestions = await _suggestions(crop, permission);
    } on Object catch (error) {
      cloudService.reportError(error);
      return local;
    }
    if (!permission.isValid ||
        suggestions == null ||
        suggestions.cards.isEmpty) {
      return local;
    }
    final LinkedHashMap<String, ScanCandidate> merged =
        LinkedHashMap<String, ScanCandidate>.fromEntries(
          local.candidates.map(
            (ScanCandidate item) =>
                MapEntry<String, ScanCandidate>(item.card.id, item),
          ),
        );
    for (final MtgCard card in suggestions.cards) {
      final ScanCandidate? prior = merged[card.id];
      merged[card.id] = ScanCandidate(
        prior?.card ?? card,
        Set<ScanEvidence>.unmodifiable(<ScanEvidence>{
          ...?prior?.evidence,
          ScanEvidence.cloudSuggestion,
        }),
        artworkDistance: prior?.artworkDistance,
        symbolDistance: prior?.symbolDistance,
      );
    }
    final List<ScanCandidate> candidates = merged.values.toList();
    final Map<String, int> order = <String, int>{
      for (int index = 0; index < candidates.length; index++)
        candidates[index].card.id: index,
    };
    candidates.sort((ScanCandidate a, ScanCandidate b) {
      final int score = b.score.compareTo(a.score);
      return score == 0
          ? order[a.card.id]!.compareTo(order[b.card.id]!)
          : score;
    });
    return ScanResolution(
      candidates: List<ScanCandidate>.unmodifiable(candidates),
      hints: local.hints,
      status: ScanResolutionStatus.needsReview,
      hasMore: local.hasMore || suggestions.hasMore,
      page: local.page,
      historicalBodyIdentityProof:
          suggestions.cards.any(
            (MtgCard card) =>
                local.historicalBodyIdentityProof != null &&
                _name(card.name) !=
                    _name(local.historicalBodyIdentityProof!.name),
          )
          ? null
          : local.historicalBodyIdentityProof,
    );
  }

  Future<_CatalogSuggestions?> _suggestions(
    ScanCrop crop,
    CloudScanPermission permission,
  ) async {
    final FileStat stat = await File(crop.imagePath).stat();
    if (!permission.isValid) return null;
    final _CropRevision revision = (
      path: crop.imagePath,
      width: crop.width,
      height: crop.height,
      modified: stat.modified.microsecondsSinceEpoch,
      changed: stat.changed.microsecondsSinceEpoch,
      size: stat.size,
      permission: permission,
    );
    if (_cache.containsKey(revision)) {
      final _CatalogSuggestions? value = _cache.remove(revision);
      _cache[revision] = value;
      return Future<_CatalogSuggestions?>.value(value);
    }
    final Future<_CatalogSuggestions?>? existing = _pending[revision];
    if (existing != null) return existing;
    if (_pending.length >= 2) {
      return Future<_CatalogSuggestions?>.value(null);
    }
    final _SuggestionJob job = _SuggestionJob();
    final Future<_CatalogSuggestions?> request =
        _fetchSuggestions(crop, job, permission)
            .timeout(
              timeout,
              onTimeout: () {
                job.expired = true;
                throw TimeoutException('Cloud request timed out');
              },
            )
            .then((_CatalogSuggestions? value) {
              if (!permission.isValid) return null;
              if (value != null) _cache[revision] = value;
              while (_cache.length > 128) {
                _cache.remove(_cache.keys.first);
              }
              return value;
            })
            .catchError((Object error) {
              if (permission.isValid) cloudService.reportError(error);
              return null;
            })
            .whenComplete(() {
              _pending.remove(revision);
            });
    _pending[revision] = request;
    return request;
  }

  Future<_CatalogSuggestions?> _fetchSuggestions(
    ScanCrop crop,
    _SuggestionJob job,
    CloudScanPermission permission,
  ) async {
    final Uint8List? image;
    try {
      image = await _encoder(crop);
    } catch (_) {
      throw const CloudCardHintsException(
        CloudCardHintsStatus(
          CloudCardHintsAvailability.unavailable,
          failure: CloudCardHintsFailure.invalidCrop,
        ),
      );
    }
    if (job.expired || !permission.isValid) {
      return null;
    }
    if (image == null || image.isEmpty || image.length > 2 * 1024 * 1024) {
      throw const CloudCardHintsException(
        CloudCardHintsStatus(
          CloudCardHintsAvailability.unavailable,
          failure: CloudCardHintsFailure.invalidCrop,
        ),
      );
    }
    final _CloudHints? hints = _CloudHints.parse(
      await cloudService.suggest(
        base64Encode(image),
        isAuthorized: () => !job.expired && permission.isValid,
      ),
    );
    if (job.expired || !permission.isValid) {
      return null;
    }
    if (hints == null) {
      throw const CloudCardHintsException(
        CloudCardHintsStatus(
          CloudCardHintsAvailability.unavailable,
          failure: CloudCardHintsFailure.invalidResponse,
        ),
      );
    }
    if (hints.name == null) {
      return const _CatalogSuggestions(<MtgCard>[], false);
    }
    bool matches(MtgCard card) =>
        card.games.contains(Game.paper) &&
        (_name(card.name) == _name(hints.name!) ||
            (card.printedName != null &&
                _name(card.printedName!) == _name(hints.name!))) &&
        (hints.setCode == null || card.set.toLowerCase() == hints.setCode) &&
        (hints.collectorNumber == null ||
            _number(card.collectorNumber) == _number(hints.collectorNumber!)) &&
        (hints.language == null || card.lang.json == hints.language);
    if (hints.setCode != null && hints.collectorNumber != null) {
      final MtgCard? card;
      try {
        card = await catalog.exactPrinting(
          hints.setCode!,
          hints.collectorNumber!,
          language: hints.language,
        );
      } catch (_) {
        throw const CloudCardHintsException(
          CloudCardHintsStatus(
            CloudCardHintsAvailability.unavailable,
            failure: CloudCardHintsFailure.catalogUnavailable,
          ),
        );
      }
      return !job.expired && permission.isValid && card != null && matches(card)
          ? _CatalogSuggestions(<MtgCard>[card], false)
          : const _CatalogSuggestions(<MtgCard>[], false);
    }
    final PaginableList<MtgCard> found;
    try {
      found = await catalog.printings(
        hints.name!,
        setCode: hints.setCode,
        language: hints.language,
      );
    } catch (_) {
      throw const CloudCardHintsException(
        CloudCardHintsStatus(
          CloudCardHintsAvailability.unavailable,
          failure: CloudCardHintsFailure.catalogUnavailable,
        ),
      );
    }
    if (job.expired || !permission.isValid) return null;
    final List<MtgCard> bounded = found.data.take(32).where(matches).toList();
    return _CatalogSuggestions(
      bounded,
      found.hasMore || found.data.length > 32,
    );
  }

  static bool _isSavedCrop(ScanCrop crop) {
    final String path = crop.imagePath;
    if (!path.startsWith('/') ||
        Uri.tryParse(path)?.hasScheme != false ||
        crop.width < 64 ||
        crop.height < 64 ||
        crop.width * crop.height > 32 * 1024 * 1024 ||
        crop.sourceCorners.length != 4 ||
        crop.sourceCorners.any(
          (ScanPoint point) =>
              !point.x.isFinite ||
              !point.y.isFinite ||
              point.x < 0 ||
              point.x > 1 ||
              point.y < 0 ||
              point.y > 1,
        )) {
      return false;
    }
    const List<ScanPoint> fullSource = <ScanPoint>[
      ScanPoint(0, 0),
      ScanPoint(1, 0),
      ScanPoint(1, 1),
      ScanPoint(0, 1),
    ];
    if (fullSource.every(
      (ScanPoint corner) => crop.sourceCorners.any(
        (ScanPoint point) =>
            (point.x - corner.x).abs() <= .000001 &&
            (point.y - corner.y).abs() <= .000001,
      ),
    )) {
      return false;
    }
    final String filename = path.split('/').last;
    return (path.contains('/ScanCrops/') || filename.startsWith('crop-')) &&
        RegExp(r'\.(?:jpe?g|png)$', caseSensitive: false).hasMatch(filename);
  }

  static Future<Uint8List?> encodeSavedCrop(ScanCrop crop) async {
    if (!_isSavedCrop(crop)) return null;
    final File file = File(crop.imagePath);
    final int size = await file.length();
    if (size <= 0 || size > 32 * 1024 * 1024) return null;
    // Read at most the allowed source size even if a file changes after stat.
    final BytesBuilder bytes = BytesBuilder(copy: false);
    await for (final List<int> chunk in file.openRead(0, size + 1)) {
      bytes.add(chunk);
      if (bytes.length > 32 * 1024 * 1024) return null;
    }
    final Uint8List encoded = bytes.takeBytes();
    final bool jpeg =
        encoded.length >= 3 &&
        encoded[0] == 0xff &&
        encoded[1] == 0xd8 &&
        encoded[2] == 0xff;
    final bool png =
        encoded.length >= 8 &&
        encoded[0] == 0x89 &&
        encoded[1] == 0x50 &&
        encoded[2] == 0x4e &&
        encoded[3] == 0x47 &&
        encoded[4] == 0x0d &&
        encoded[5] == 0x0a &&
        encoded[6] == 0x1a &&
        encoded[7] == 0x0a;
    if (!jpeg && !png) return null;
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      encoded,
    );
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width < 64 ||
          descriptor.height < 64 ||
          descriptor.width * descriptor.height > 32 * 1024 * 1024 ||
          descriptor.width != crop.width ||
          descriptor.height != crop.height) {
        return null;
      }
      final double scale = math.min(
        1,
        1024 / math.max(descriptor.width, descriptor.height),
      );
      final int width = (descriptor.width * scale).round();
      final int height = (descriptor.height * scale).round();
      if (width < 64 || height < 64) return null;
      codec = await descriptor.instantiateCodec(
        targetWidth: width,
        targetHeight: height,
      );
      image = (await codec.getNextFrame()).image;
      final ByteData? output = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (output == null || output.lengthInBytes > 2 * 1024 * 1024) return null;
      return Uint8List.sublistView(output);
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  static String _name(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  static String _number(String value) =>
      value.toLowerCase().replaceFirst(RegExp(r'^0+(?=\d)'), '');
}

class _SuggestionJob {
  bool expired = false;
}

class _CatalogSuggestions {
  const _CatalogSuggestions(this.cards, this.hasMore);
  final List<MtgCard> cards;
  final bool hasMore;
}

class _CloudHints {
  const _CloudHints(
    this.name,
    this.setCode,
    this.collectorNumber,
    this.language,
  );
  final String? name;
  final String? setCode;
  final String? collectorNumber;
  final String? language;

  static _CloudHints? parse(Object? response) {
    if (response is! Map<Object?, Object?> ||
        response.length != 4 ||
        response['model'] is! String ||
        (response['model'] as String).trim().isEmpty ||
        (response['model'] as String).length > 200 ||
        response['elapsedMs'] is! num ||
        !(response['elapsedMs'] as num).isFinite ||
        (response['elapsedMs'] as num) < 0 ||
        response['confidence'] != 'uncalibrated' ||
        response['hints'] is! Map<Object?, Object?>) {
      return null;
    }
    final Map<Object?, Object?> hints =
        response['hints'] as Map<Object?, Object?>;
    const Map<String, int> limits = <String, int>{
      'name': 140,
      'setCode': 12,
      'collectorNumber': 20,
      'rulesText': 1200,
      'typeLine': 160,
      'artist': 120,
      'language': 3,
    };
    if (hints.length != limits.length) return null;
    for (final MapEntry<String, int> limit in limits.entries) {
      if (!hints.containsKey(limit.key)) return null;
      final Object? value = hints[limit.key];
      if (value != null &&
          (value is! String ||
              value.trim().isEmpty ||
              value.length > limit.value ||
              RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(value))) {
        return null;
      }
    }
    final String? name = (hints['name'] as String?)?.trim();
    final String? set = (hints['setCode'] as String?)?.trim().toLowerCase();
    final String? number = (hints['collectorNumber'] as String?)?.trim();
    final String? language = (hints['language'] as String?)
        ?.trim()
        .toLowerCase();
    if ((name != null && RegExp(r'[\r\n\t]').hasMatch(name)) ||
        (set != null && !RegExp(r'^[a-z0-9]{2,12}$').hasMatch(set)) ||
        (number != null &&
            !RegExp(r'^[0-9a-zA-Z★*.-]{1,20}$').hasMatch(number)) ||
        (language != null &&
            !Language.values.any((Language item) => item.json == language))) {
      return null;
    }
    return _CloudHints(name, set, number, language);
  }
}
