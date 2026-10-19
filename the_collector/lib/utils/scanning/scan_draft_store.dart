import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:uuid/uuid.dart';

import 'scan_queue.dart';
import 'scan_accounting.dart';
import 'scan_capture_defaults.dart';
import '../auth/local_account_data.dart';
import 'scan_recognition.dart';
import 'scan_resolver.dart';

@immutable
class ScanDraftRescan {
  const ScanDraftRescan({
    required this.itemId,
    required this.requestId,
    this.photo,
    this.original,
    this.choices,
    this.complete = false,
  });
  final String itemId;
  final String requestId;
  final ScanDraftPhoto? photo;
  final ScanDraftItem? original;
  final ScanQueueApproval? choices;
  final bool complete;
  factory ScanDraftRescan.fromMap(Map<String, Object?> value) {
    final String itemId = value['itemId'] as String;
    final String requestId = value['requestId'] as String;
    if (!RegExp(r'^[A-Za-z0-9_-]{1,160}$').hasMatch(itemId) ||
        !RegExp(r'^[A-Za-z0-9_-]{1,160}$').hasMatch(requestId)) {
      throw const FormatException('Invalid replacement capture owner.');
    }
    return ScanDraftRescan(
      itemId: itemId,
      requestId: requestId,
      photo: value['photo'] == null
          ? null
          : ScanDraftPhoto.fromMap(_map(value['photo'])),
      original: value['original'] == null
          ? null
          : ScanDraftItem.fromMap(_map(value['original'])),
      choices: value['choices'] == null
          ? null
          : _readChoices(_map(value['choices'])),
      complete: value['complete'] as bool,
    );
  }
  static ScanQueueApproval _readChoices(Map<String, Object?> value) =>
      ScanQueueApproval(
        operationId: value['operationId'] as String?,
        card: MTGCardMapper.fromMap(_map(value['card'])),
        quantity: value['quantity'] as int,
        deckId: value['deckId'] as String?,
        deckSection: DeckSection.values.byName(value['deckSection'] as String),
      );
  Map<String, Object?> toMap() => <String, Object?>{
    'itemId': itemId,
    'requestId': requestId,
    'photo': photo?.toMap(),
    'original': original?.toMap(),
    'complete': complete,
    'choices': choices == null
        ? null
        : <String, Object?>{
            'operationId': choices!.operationId,
            'card': choices!.card.toMap(),
            'quantity': choices!.quantity,
            'deckId': choices!.deckId,
            'deckSection': choices!.deckSection.name,
          },
  };
}

@immutable
class ScanDraftDetail {
  const ScanDraftDetail({
    required this.photoId,
    required this.presenceComplete,
    this.failed = false,
    this.complete = false,
  });
  final String photoId;
  final bool presenceComplete;
  final bool failed;
  final bool complete;
  factory ScanDraftDetail.fromMap(Map<String, Object?> value) {
    final String id = value['photoId'] as String;
    if (!RegExp(r'^[A-Za-z0-9_-]{1,160}$').hasMatch(id)) {
      throw const FormatException('Invalid saved capture detail owner.');
    }
    return ScanDraftDetail(
      photoId: id,
      presenceComplete: value['presenceComplete'] as bool,
      failed: value['failed'] as bool,
      complete: value['complete'] as bool,
    );
  }
  Map<String, Object?> toMap() => <String, Object?>{
    'photoId': photoId,
    'presenceComplete': presenceComplete,
    'failed': failed,
    'complete': complete,
  };
}

@immutable
class ScanDraftRecovery {
  const ScanDraftRecovery({required this.itemId, required this.photoId});

  final String itemId;
  final String photoId;

  factory ScanDraftRecovery.fromMap(Map<String, Object?> map) {
    final String itemId = map['itemId'] as String;
    final String photoId = map['photoId'] as String;
    if (!RegExp(r'^[A-Za-z0-9_-]{1,180}$').hasMatch(itemId) ||
        !RegExp(r'^[A-Za-z0-9_-]{1,160}$').hasMatch(photoId)) {
      throw const FormatException('Invalid scan recovery owner.');
    }
    return ScanDraftRecovery(itemId: itemId, photoId: photoId);
  }

  Map<String, Object?> toMap({required bool pending}) => <String, Object?>{
    'itemId': itemId,
    'photoId': photoId,
    'pending': pending,
  };
}

@immutable
class ScanDraftPhoto {
  final String id;
  final String imagePath;
  final bool multipleCards;
  final bool diagnosticOnly;
  final DateTime createdAt;
  final List<List<ScanPoint>> excludedRegions;
  final List<List<ScanPoint>>? targetRegions;
  final List<String> refinementReceiptIds;
  final ScanCaptureDefaults defaults;

  const ScanDraftPhoto({
    required this.id,
    required this.imagePath,
    required this.multipleCards,
    this.diagnosticOnly = false,
    required this.createdAt,
    this.excludedRegions = const <List<ScanPoint>>[],
    this.targetRegions,
    this.refinementReceiptIds = const <String>[],
    this.defaults = const ScanCaptureDefaults(),
  });
  static List<List<ScanPoint>> freezeExcludedRegions(
    List<List<ScanPoint>> regions,
  ) {
    if (regions.length > 8 ||
        regions.any(
          (List<ScanPoint> region) =>
              region.length != 4 ||
              region.any(
                (ScanPoint point) =>
                    !point.x.isFinite ||
                    !point.y.isFinite ||
                    point.x < 0 ||
                    point.x > 1 ||
                    point.y < 0 ||
                    point.y > 1,
              ),
        )) {
      throw ArgumentError(
        'Exclusions require at most eight normalized quadrilaterals.',
      );
    }
    return List<List<ScanPoint>>.unmodifiable(
      regions.map(
        (List<ScanPoint> region) => List<ScanPoint>.unmodifiable(region),
      ),
    );
  }

  static List<List<ScanPoint>>? freezeTargetRegions(
    List<List<ScanPoint>>? regions,
  ) {
    if (regions == null) return null;
    if (regions.length > 8) {
      throw ArgumentError(
        'Capture targets require at most eight normalized convex quadrilaterals.',
      );
    }
    for (final List<ScanPoint> region in regions) {
      if (region.length != 4 ||
          region.any(
            (ScanPoint point) =>
                !point.x.isFinite ||
                !point.y.isFinite ||
                point.x < 0 ||
                point.x > 1 ||
                point.y < 0 ||
                point.y > 1,
          )) {
        throw ArgumentError(
          'Capture targets require normalized convex quadrilaterals.',
        );
      }
      double? direction;
      double twiceArea = 0;
      for (int index = 0; index < 4; index++) {
        final ScanPoint first = region[index];
        final ScanPoint second = region[(index + 1) % 4];
        final ScanPoint third = region[(index + 2) % 4];
        final double cross =
            (second.x - first.x) * (third.y - second.y) -
            (second.y - first.y) * (third.x - second.x);
        if (!cross.isFinite ||
            cross.abs() < .000001 ||
            (direction != null && cross * direction <= 0)) {
          throw ArgumentError('Capture targets require convex quadrilaterals.');
        }
        direction = cross;
        twiceArea += first.x * second.y - second.x * first.y;
      }
      if (twiceArea.abs() < .000002) {
        throw ArgumentError('Capture targets require nonempty quadrilaterals.');
      }
    }
    return List<List<ScanPoint>>.unmodifiable(
      regions.map(
        (List<ScanPoint> region) => List<ScanPoint>.unmodifiable(region),
      ),
    );
  }

  static List<String> freezeRefinementReceiptIds(List<String> ids) {
    if (ids.length > 8 ||
        ids.toSet().length != ids.length ||
        ids.any(
          (String id) => !RegExp(r'^live_[A-Za-z0-9_-]{1,155}$').hasMatch(id),
        )) {
      throw ArgumentError(
        'Refinement requires at most eight distinct live receipts.',
      );
    }
    return List<String>.unmodifiable(ids);
  }

  factory ScanDraftPhoto.fromMap(Map<String, Object?> map) => ScanDraftPhoto(
    defaults: map['defaults'] == null
        ? const ScanCaptureDefaults()
        : ScanCaptureDefaults.fromMap(_map(map['defaults'])),
    refinementReceiptIds: freezeRefinementReceiptIds(
      (map['refinementReceiptIds'] as List<Object?>? ?? const <Object>[])
          .cast<String>(),
    ),
    id: map['id'] as String,
    imagePath: map['imagePath'] as String,
    multipleCards: map['multipleCards'] as bool,
    diagnosticOnly: map['diagnosticOnly'] as bool,
    createdAt: DateTime.parse(map['createdAt'] as String),
    targetRegions: freezeTargetRegions(
      (map['targetRegions'] as List<Object?>?)
          ?.map(
            (Object? region) => (region as List<Object?>).map((Object? value) {
              final Map<String, Object?> point = _map(value);
              return ScanPoint(
                (point['x'] as num).toDouble(),
                (point['y'] as num).toDouble(),
              );
            }).toList(),
          )
          .toList(),
    ),
    excludedRegions: freezeExcludedRegions(
      (map['excludedRegions'] as List<Object?>? ?? const <Object>[])
          .map(
            (Object? region) => (region as List<Object?>).map((Object? value) {
              final Map<String, Object?> point = _map(value);
              return ScanPoint(
                (point['x'] as num).toDouble(),
                (point['y'] as num).toDouble(),
              );
            }).toList(),
          )
          .toList(),
    ),
  );
  Map<String, Object?> toMap() => <String, Object?>{
    'refinementReceiptIds': refinementReceiptIds,
    'defaults': defaults.toMap(),
    'id': id,
    'imagePath': imagePath,
    'multipleCards': multipleCards,
    'diagnosticOnly': diagnosticOnly,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'targetRegions': targetRegions
        ?.map(
          (List<ScanPoint> region) => region
              .map(
                (ScanPoint point) => <String, double>{
                  'x': point.x,
                  'y': point.y,
                },
              )
              .toList(),
        )
        .toList(),
    'excludedRegions': excludedRegions
        .map(
          (List<ScanPoint> region) => region
              .map(
                (ScanPoint point) => <String, double>{
                  'x': point.x,
                  'y': point.y,
                },
              )
              .toList(),
        )
        .toList(),
  };
}

@immutable
class ScanDraftItem {
  final String id;
  final String photoId;
  final ScanCrop crop;
  final ScanResolution? resolution;
  final ScanQueueApproval? approval;
  final bool selected;
  final String? error;
  final String? liveIdentityName;
  final String? liveCaptureReceiptId;
  final ScanCaptureDefaults defaults;

  const ScanDraftItem({
    required this.id,
    required this.photoId,
    required this.crop,
    this.resolution,
    this.approval,
    this.selected = false,
    this.error,
    this.liveIdentityName,
    this.liveCaptureReceiptId,
    this.defaults = const ScanCaptureDefaults(),
  });

  ScanDraftItem withCrop(ScanCrop value) => ScanDraftItem(
    id: id,
    photoId: photoId,
    crop: value,
    resolution: resolution,
    approval: approval,
    selected: selected,
    error: error,
    liveIdentityName: liveIdentityName,
    liveCaptureReceiptId: liveCaptureReceiptId,
    defaults: defaults,
  );

  factory ScanDraftItem.fromMap(Map<String, Object?> map) {
    final ScanCrop crop = ScanCrop.fromMap(_map(map['crop']));
    final Map<String, Object?>? resolved = map['resolution'] == null
        ? null
        : _map(map['resolution']);
    final Map<String, Object?>? approved = map['approval'] == null
        ? null
        : _map(map['approval']);
    final ScanQueueApproval? approval = approved == null
        ? null
        : ScanQueueApproval(
            operationId: approved['operationId'] as String?,
            card: MTGCardMapper.fromMap(_map(approved['card'])),
            quantity: approved['quantity'] as int,
            deckId: approved['deckId'] as String?,
            deckSection: DeckSection.values.byName(
              approved['deckSection'] as String,
            ),
          );
    return ScanDraftItem(
      id: map['id'] as String,
      photoId: map['photoId'] as String,
      defaults: map['defaults'] == null
          ? ScanCaptureDefaults(
              finish: approval?.card.finish ?? Finish.nonfoil,
              deckId: approval?.deckId,
              deckSection: approval?.deckSection ?? DeckSection.mainboard,
            )
          : ScanCaptureDefaults.fromMap(_map(map['defaults'])),
      crop: crop,
      selected: map['selected'] as bool,
      error: map['error'] as String?,
      liveIdentityName: map['liveIdentityName'] as String?,
      liveCaptureReceiptId: map['liveCaptureReceiptId'] as String?,
      resolution: resolved == null
          ? null
          : ScanResolution(
              status: ScanResolutionStatus.values.byName(
                resolved['status'] as String,
              ),
              hasMore: resolved['hasMore'] as bool,
              page: resolved['page'] as int,
              historicalBodyIdentityProof:
                  resolved['historicalBodyIdentityProof'] == null
                  ? null
                  : HistoricalBodyIdentityProof(
                      name:
                          _map(resolved['historicalBodyIdentityProof'])['name']
                              as String,
                      bodySignature:
                          _map(
                                resolved['historicalBodyIdentityProof'],
                              )['bodySignature']
                              as String,
                    ),
              hints: ScanHints(
                names: (_map(resolved['hints'])['names'] as List<Object?>)
                    .cast<String>(),
                setCode: _map(resolved['hints'])['setCode'] as String?,
                collectorNumber:
                    _map(resolved['hints'])['collectorNumber'] as String?,
                language: _map(resolved['hints'])['language'] as String?,
                rulesText:
                    (_map(resolved['hints'])['rulesText'] as List<Object?>? ??
                            const <Object?>[])
                        .cast<String>(),
                postQuoteText: ScanHints.fromCrop(crop).postQuoteText,
                typeLine: _map(resolved['hints'])['typeLine'] as String?,
              ),
              candidates: (resolved['candidates'] as List<Object?>).map((
                Object? value,
              ) {
                final Map<String, Object?> candidate = _map(value);
                return ScanCandidate(
                  MtgCard.fromJson(_map(candidate['card'])),
                  (candidate['evidence'] as List<Object?>)
                      .map(
                        (Object? name) =>
                            ScanEvidence.values.byName(name as String),
                      )
                      .toSet(),
                  artworkDistance: (candidate['artworkDistance'] as num?)
                      ?.toDouble(),
                  symbolDistance: (candidate['symbolDistance'] as num?)
                      ?.toDouble(),
                );
              }).toList(),
            ),
      approval: approval,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'photoId': photoId,
    'defaults': defaults.toMap(),
    'selected': selected,
    'error': error,
    'crop': <String, Object?>{
      'imagePath': crop.imagePath,
      'width': crop.width,
      'height': crop.height,
      'rectified': crop.rectified,
      'warnings': crop.warnings,
      'sharpness': crop.sharpness,
      'sourceCorners': crop.sourceCorners
          .map(
            (ScanPoint point) => <String, double>{'x': point.x, 'y': point.y},
          )
          .toList(),
      'lines': crop.lines
          .map(
            (ScanTextLine line) => <String, Object?>{
              'text': line.text,
              'confidence': line.confidence,
              'alternatives': line.alternatives,
              'glyphHeight': line.glyphHeight,
              'sceneFooterGuide': line.sceneFooterGuide,
              'bounds': <String, double>{
                'x': line.bounds.x,
                'y': line.bounds.y,
                'width': line.bounds.width,
                'height': line.bounds.height,
              },
            },
          )
          .toList(),
    },
    'liveIdentityName': liveIdentityName,
    'liveCaptureReceiptId': liveCaptureReceiptId,
    'resolution': resolution == null
        ? null
        : <String, Object?>{
            'status': resolution!.status.name,
            'hasMore': resolution!.hasMore,
            'page': resolution!.page,
            'historicalBodyIdentityProof':
                resolution!.historicalBodyIdentityProof == null
                ? null
                : <String, Object?>{
                    'name': resolution!.historicalBodyIdentityProof!.name,
                    'bodySignature':
                        resolution!.historicalBodyIdentityProof!.bodySignature,
                  },
            'hints': <String, Object?>{
              'names': resolution!.hints.names,
              'setCode': resolution!.hints.setCode,
              'collectorNumber': resolution!.hints.collectorNumber,
              'language': resolution!.hints.language,
              'rulesText': resolution!.hints.rulesText,
              'typeLine': resolution!.hints.typeLine,
            },
            'candidates': resolution!.candidates
                .map(
                  (ScanCandidate candidate) => <String, Object?>{
                    'card': candidate.card.toJson(),
                    'artworkDistance': candidate.artworkDistance,
                    'symbolDistance': candidate.symbolDistance,
                    'evidence': candidate.evidence
                        .map((ScanEvidence evidence) => evidence.name)
                        .toList(),
                  },
                )
                .toList(),
          },
    'approval': approval == null
        ? null
        : <String, Object?>{
            'operationId': approval!.operationId,
            'card': approval!.card.toMap(),
            'quantity': approval!.quantity,
            'deckId': approval!.deckId,
            'deckSection': approval!.deckSection.name,
          },
  };
}

Map<String, Object?> _map(Object? value) =>
    Map<String, Object?>.from(value as Map<Object?, Object?>);

int _retainedImageBytes(String directoryPath) {
  int bytes = 0;
  for (final FileSystemEntity entity in Directory(
    directoryPath,
  ).listSync(followLinks: false)) {
    if (entity is File) {
      bytes += entity.lengthSync();
    }
  }
  return bytes;
}

class ScanDraftStorageBudgetExceeded extends FileSystemException {
  static const String userMessage =
      'Scan storage full. Add reviewed cards or remove captures, then retry.';
  const ScanDraftStorageBudgetExceeded() : super(userMessage);
}

/// Share one instance between an account's session and journaled upload queue.
class ScanDraftStore {
  static const int defaultMaximumImageBytes = 512 * 1024 * 1024;
  static String focusStackCaptureId(List<String> paths) => sha256
      .convert(utf8.encode(jsonEncode(paths)))
      .toString()
      .substring(0, 40);

  ScanDraftStore({
    required this.userId,
    ScanQueueBoxOpener? openBox,
    this.maximumImageBytes = defaultMaximumImageBytes,
  }) : _openBox = openBox ?? (Hive.openBox<String>) {
    if (userId.isEmpty || userId.contains('/')) {
      throw ArgumentError.value(userId, 'userId');
    }
    if (maximumImageBytes <= 0) {
      throw ArgumentError.value(maximumImageBytes, 'maximumImageBytes');
    }
  }

  final String userId;
  final int maximumImageBytes;
  final ScanQueueBoxOpener _openBox;
  Future<Box<String>>? _opening;
  Future<void> _mutations = Future<void>.value();
  Future<void>? _cleanupTask;
  String? _nextCleanupKey;
  final ValueNotifier<int> _accountingChanges = ValueNotifier<int>(0);
  ValueListenable<int> get accountingChanges => _accountingChanges;

  ScanCaptureReceipt? _receipt(Box<String> box, String id) {
    final String? value = box.get('receipt:$id');
    if (value == null) return null;
    final ScanCaptureReceipt receipt = ScanCaptureReceipt.fromMap(
      _map(jsonDecode(value)),
    );
    if (receipt.id != id) throw const FormatException('Invalid receipt owner.');
    return receipt;
  }

  Iterable<ScanCaptureReceipt> _receipts(Box<String> box) sync* {
    for (final String key in box.keys.whereType<String>()) {
      if (key.startsWith('receipt:')) yield _receipt(box, key.substring(8))!;
    }
  }

  Future<void> _writeReceipts(
    Box<String> box,
    Iterable<ScanCaptureReceipt> receipts,
  ) async {
    final Map<String, String> changes = <String, String>{};
    for (final ScanCaptureReceipt receipt in receipts) {
      final String key = 'receipt:${receipt.id}';
      final String value = jsonEncode(receipt.toMap());
      if (box.get(key) != value) changes[key] = value;
    }
    if (changes.isEmpty) return;
    LocalAccountData.requireWritable(userId);
    await box.putAll(changes);
    await box.flush();
    _accountingChanges.value++;
  }

  ScanCaptureReceipt _draftReceipt(Box<String> box, ScanDraftItem item) {
    final ScanCaptureReceipt receipt =
        _receipt(box, item.id) ??
        ScanCaptureReceipt(id: item.id, capturedAt: DateTime.now().toUtc());
    final String? rescan = box.get('rescan:${item.id}');
    final bool replacing =
        rescan != null &&
        !ScanDraftRescan.fromMap(_map(jsonDecode(rescan))).complete;
    final ScanReceiptIdentification identification = replacing
        ? ScanReceiptIdentification.needsCheck
        : item.approval != null
        ? ScanReceiptIdentification.ready
        : item.error != null
        ? ScanReceiptIdentification.needsCheck
        : item.resolution == null
        ? ScanReceiptIdentification.processing
        : hasExactPrintingEvidence(item.crop, item.resolution)
        ? ScanReceiptIdentification.ready
        : ScanReceiptIdentification.needsCheck;
    return receipt.copyWith(identification: identification);
  }

  Future<void> _refreshDraftReceipts(Box<String> box) async {
    await _writeReceipts(box, <ScanCaptureReceipt>[
      for (final String key in box.keys.whereType<String>())
        if (key.startsWith('item:'))
          _draftReceipt(
            box,
            ScanDraftItem.fromMap(_map(jsonDecode(box.get(key)!))),
          ),
    ]);
  }

  Future<ScanAccounting> readAccounting() => _serialize(() async {
    final Box<String> box = await _box();
    await _recoverDiscardIntent(box);
    await _refreshDraftReceipts(box);
    return ScanAccounting.fromReceipts(_receipts(box));
  });

  Future<bool> acceptCaptures(
    List<ScanDraftItem> items, {
    bool Function()? isCurrent,
  }) => _serialize<bool>(() async {
    if (items.isEmpty ||
        items.map((ScanDraftItem item) => item.id).toSet().length !=
            items.length ||
        isCurrent?.call() == false) {
      return false;
    }
    final Box<String> box = await _box();
    await _recoverDiscardIntent(box);
    final Directory directory = await _images();
    final List<ScanCaptureReceipt> accepted = <ScanCaptureReceipt>[];
    final DateTime now = DateTime.now().toUtc();
    for (final ScanDraftItem expected in items) {
      final String? value = box.get('item:${expected.id}');
      if (value == null) return false;
      final ScanDraftItem current = ScanDraftItem.fromMap(
        _map(jsonDecode(value)),
      );
      final ScanCaptureReceipt receipt = _draftReceipt(box, current);
      final String? rescan = box.get('rescan:${current.id}');
      if ((rescan != null &&
              !ScanDraftRescan.fromMap(_map(jsonDecode(rescan))).complete) ||
          !hasVerifiedSavedCardCapturePresence(current.crop)) {
        return false;
      }
      final String path = _imagePath(
        current.crop.imagePath,
        directory,
        'crop-${current.id}',
      );
      final Map<String, Object?> currentCrop = _map(current.toMap()['crop'])
        ..['imagePath'] = path;
      if (receipt.state == ScanReceiptState.discarded ||
          current.photoId != expected.photoId ||
          current.liveCaptureReceiptId != expected.liveCaptureReceiptId ||
          jsonEncode(currentCrop) != jsonEncode(expected.toMap()['crop']) ||
          !await _isOwned(path, directory, 'crop-${current.id}') ||
          await File(path).length() == 0) {
        return false;
      }
      accepted.add(receipt.copyWith(acceptedAt: receipt.acceptedAt ?? now));
    }
    if (isCurrent?.call() == false) return false;
    await _writeReceipts(box, accepted);
    return isCurrent?.call() != false;
  });

  Future<List<ScanCaptureReceipt>> readRecentReceipts({int limit = 24}) =>
      _serialize(() async {
        if (limit < 1 || limit > 100) throw ArgumentError.value(limit, 'limit');
        final Box<String> box = await _box();
        await _recoverDiscardIntent(box);
        await _refreshDraftReceipts(box);
        final List<ScanCaptureReceipt> recent = <ScanCaptureReceipt>[];
        for (final ScanCaptureReceipt receipt in _receipts(box)) {
          if (receipt.archived) continue;
          final int index = recent.indexWhere(
            (ScanCaptureReceipt other) =>
                receipt.capturedAt.isAfter(other.capturedAt),
          );
          recent.insert(index < 0 ? recent.length : index, receipt);
          if (recent.length > limit) recent.removeLast();
        }
        return List<ScanCaptureReceipt>.unmodifiable(recent);
      });

  Future<void> recordQueueEntries(
    List<ScanQueueEntry> entries, {
    required bool completed,
  }) => _serialize(() async {
    final Box<String> box = await _box();
    final List<ScanCaptureReceipt> receipts = <ScanCaptureReceipt>[];
    for (final ScanQueueEntry entry in entries) {
      final ScanCaptureReceipt receipt =
          _receipt(box, entry.operationId) ??
          ScanCaptureReceipt(
            id: entry.operationId,
            capturedAt: entry.createdAt,
          );
      if (receipt.added && receipt.quantity != entry.quantity) {
        throw StateError(
          'Scan receipt quantity differs from its queued addition.',
        );
      }
      receipts.add(
        receipt.copyWith(
          state: completed || receipt.state == ScanReceiptState.delivered
              ? ScanReceiptState.delivered
              : ScanReceiptState.queued,
          identification: ScanReceiptIdentification.ready,
          quantity: entry.quantity,
          undoUntil: entry.undoUntil,
          removalPending: false,
        ),
      );
    }
    await _writeReceipts(box, receipts);
  });

  Future<void> beginQueueRemoval(List<String> ids) => _serialize(() async {
    final Box<String> box = await _box();
    await _writeReceipts(box, <ScanCaptureReceipt>[
      for (final String id in ids)
        if (_receipt(box, id) case final ScanCaptureReceipt receipt)
          if (receipt.state == ScanReceiptState.queued)
            receipt.copyWith(removalPending: true),
    ]);
  });

  Future<void> finishQueueRemoval(List<String> ids) => _serialize(() async {
    final Box<String> box = await _box();
    await _finishQueueRemoval(box, ids);
  });

  Future<void> _finishQueueRemoval(Box<String> box, Iterable<String> ids) =>
      _writeReceipts(box, <ScanCaptureReceipt>[
        for (final String id in ids)
          if (_receipt(box, id) case final ScanCaptureReceipt receipt)
            if (receipt.removalPending)
              receipt.copyWith(
                state: ScanReceiptState.captured,
                undone: receipt.undone + 1,
                removalPending: false,
                archived: false,
              ),
      ]);

  Future<void> reconcileQueueRemovals(Set<String> presentIds) =>
      _serialize(() async {
        final Box<String> box = await _box();
        await _finishQueueRemoval(box, <String>[
          for (final ScanCaptureReceipt receipt in _receipts(box))
            if (receipt.removalPending && !presentIds.contains(receipt.id))
              receipt.id,
        ]);
      });

  Future<List<String>> clearCompleted({DateTime? now}) => _serialize(() async {
    final Box<String> box = await _box();
    final DateTime time = now ?? DateTime.now();
    final List<ScanCaptureReceipt> completed = _receipts(box)
        .where(
          (ScanCaptureReceipt receipt) =>
              receipt.state == ScanReceiptState.delivered,
        )
        .toList();
    await _writeReceipts(
      box,
      completed.map(
        (ScanCaptureReceipt receipt) => receipt.copyWith(archived: true),
      ),
    );
    final List<String> retired = <String>[
      for (final ScanCaptureReceipt receipt in completed)
        if (box.containsKey('item:${receipt.id}') &&
            (receipt.undoUntil == null || !time.isBefore(receipt.undoUntil!)))
          receipt.id,
    ];
    await _remove(retired.map((String id) => 'item:$id').toList());
    return retired;
  });

  Future<void> discardRemaining({
    Set<String> protectedIds = const <String>{},
  }) => _serialize(() async {
    final Box<String> box = await _box();
    await _recoverDiscardIntent(box);
    await _recoverRescanIntents(box);
    final List<String> itemIds = <String>[];
    for (final String key in box.keys.whereType<String>()) {
      if (!key.startsWith('item:')) continue;
      final ScanDraftItem item = ScanDraftItem.fromMap(
        _map(jsonDecode(box.get(key)!)),
      );
      if (!protectedIds.contains(item.id) &&
          !(_receipt(box, item.id)?.added ?? false)) {
        itemIds.add(item.id);
      }
    }
    await box.put(
      'discard-intent',
      jsonEncode(<String, Object?>{
        'itemIds': itemIds,
        'photoIds': box.keys
            .whereType<String>()
            .where((String key) => key.startsWith('photo:'))
            .map((String key) => key.substring(6))
            .toList(),
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    await box.flush();
    await _recoverDiscardIntent(box);
  });

  Future<void> _recoverDiscardIntent(Box<String> box) async {
    final String? value = box.get('discard-intent');
    if (value == null) return;
    final Map<String, Object?> intent = _map(jsonDecode(value));
    final List<String> itemIds = (intent['itemIds'] as List<Object?>)
        .cast<String>();
    final List<String> photoIds = (intent['photoIds'] as List<Object?>)
        .cast<String>();
    final DateTime discardedAt = DateTime.parse(intent['createdAt'] as String);
    final List<ScanDraftItem> removed = <ScanDraftItem>[];
    for (final String id in itemIds) {
      final String? record = box.get('item:$id');
      if (record == null) continue;
      final ScanDraftItem item = ScanDraftItem.fromMap(
        _map(jsonDecode(record)),
      );
      if (!(_receipt(box, id)?.added ?? false)) {
        removed.add(item);
      }
    }
    final Set<String> removedIds = removed
        .map((ScanDraftItem item) => item.id)
        .toSet();
    final Set<String> retained = <String>{
      for (final String key in box.keys.whereType<String>())
        if (key.startsWith('item:') && !removedIds.contains(key.substring(5)))
          key.substring(5),
    };
    await _writeReceipts(
      box,
      removed.map(
        (ScanDraftItem item) => _draftReceipt(
          box,
          item,
        ).copyWith(state: ScanReceiptState.discarded, discardedAt: discardedAt),
      ),
    );
    for (final ScanDraftItem item in removed) {
      await _cancelRescanRecord(box, item.id, null);
    }
    final List<String> sourcesToKeep = <String>[
      for (final String key in box.keys.whereType<String>())
        if (key.startsWith('source:') &&
            (_map(jsonDecode(box.get(key)!))['itemIds'] as List<Object?>)
                .cast<String>()
                .any(retained.contains))
          key.substring(7),
    ];
    final List<String> photoKeys = photoIds
        .map((String id) => 'photo:$id')
        .toList();
    for (final String key in photoKeys) {
      await _promoteCameraSources(box, key);
    }
    await box.deleteAll(
      photoKeys.where((String key) => sourcesToKeep.contains(key.substring(6))),
    );
    await box.deleteAll(
      box.keys
          .whereType<String>()
          .where(
            (String key) =>
                (key.startsWith('detail:') &&
                    (photoIds.contains(key.substring(7)) ||
                        removed.any(
                          (ScanDraftItem item) =>
                              item.photoId == key.substring(7),
                        ))) ||
                (key.startsWith('recovery:') &&
                    removedIds.contains(key.substring(9))),
          )
          .toList(),
    );
    await box.flush();
    await _remove(<String>[
      ...removed.map((ScanDraftItem item) => 'item:${item.id}'),
      ...photoKeys.where(
        (String key) => !sourcesToKeep.contains(key.substring(6)),
      ),
    ]);
    await box.delete('discard-intent');
    await box.flush();
  }

  Future<Box<String>> _box() {
    LocalAccountData.requireWritable(userId);
    return _opening ??= _openOwnerBox();
  }

  Future<Box<String>> _openOwnerBox() async {
    try {
      return await _openBox(
        'scanner_drafts_v1_${sha256.convert(utf8.encode(userId))}',
      );
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  Future<Directory> _images() async {
    if (kIsWeb) {
      throw UnsupportedError('Photo scan drafts require native file storage.');
    }
    final String? boxPath = (await _box()).path;
    if (boxPath == null) {
      throw UnsupportedError('Photo scan drafts require native file storage.');
    }
    final Directory directory = Directory(
      '${File(boxPath).parent.path}/scanner_images_${sha256.convert(utf8.encode(userId))}',
    );
    LocalAccountData.requireWritable(userId);
    await directory.create(recursive: true);
    return directory;
  }

  String _imagePath(String path, Directory directory, String name) {
    if (path.isEmpty) return path;
    final File file = File(path);
    final String filename = file.uri.pathSegments.last;
    final String owner = file.parent.uri.pathSegments
        .where((String segment) => segment.isNotEmpty)
        .last;
    if (owner != 'scanner_images_${sha256.convert(utf8.encode(userId))}' ||
        !RegExp('^${RegExp.escape(name)}\\.[A-Za-z0-9]{1,8}\$')
            .hasMatch(filename)) {
      throw const FormatException('Invalid owned scan image reference.');
    }
    // iOS can relocate Documents while retaining these records and image files.
    return '${directory.path}/$filename';
  }

  ScanDraftPhoto _readPhoto(Map<String, Object?> map, Directory directory) {
    final ScanDraftPhoto photo = ScanDraftPhoto.fromMap(map);
    return ScanDraftPhoto(
      id: photo.id,
      imagePath: _imagePath(photo.imagePath, directory, 'photo-${photo.id}'),
      multipleCards: photo.multipleCards,
      diagnosticOnly: photo.diagnosticOnly,
      defaults: photo.defaults,
      createdAt: photo.createdAt,
      excludedRegions: photo.excludedRegions,
      targetRegions: photo.targetRegions,
      refinementReceiptIds: photo.refinementReceiptIds,
    );
  }

  Future<List<ScanDraftPhoto>> readPhotos() =>
      _serialize<List<ScanDraftPhoto>>(() async {
        final Box<String> box = await _box();
        await _recoverDiscardIntent(box);
        if (await _attemptCleanup(box) == 64) {
          unawaited(cleanPendingImages());
        }
        bool pendingPresence(String key) {
          final String photoId = key.substring(6);
          final String? detail = box.get('detail:$photoId');
          return !box.containsKey('source:$photoId') ||
              detail == null ||
              !ScanDraftDetail.fromMap(_map(jsonDecode(detail)))
                  .presenceComplete;
        }

        final List<String> keys = box.keys
            .whereType<String>()
            .where(
              (String key) =>
                  key.startsWith('photo:') &&
                  pendingPresence(key) &&
                  (!box.containsKey('source:${key.substring(6)}') ||
                      _map(jsonDecode(box.get(key)!))['focusPhotos'] != null),
            )
            .toList();
        if (keys.isEmpty) return <ScanDraftPhoto>[];
        final Directory directory = await _images();
        return keys
            .map(
              (String key) =>
                  _readPhoto(_map(jsonDecode(box.get(key)!)), directory),
            )
            .toList();
      });

  Future<ScanDraftPhoto?> readSource(String photoId) =>
      _serialize<ScanDraftPhoto?>(() async {
        final Box<String> box = await _box();
        final String? source = box.get('source:$photoId');
        if (source != null) {
          return _readPhoto(
            _map(_map(jsonDecode(source))['photo']),
            await _images(),
          );
        }
        final String? pending = box.get('photo:$photoId');
        return pending == null
            ? null
            : _readPhoto(_map(jsonDecode(pending)), await _images());
      });

  Future<ScanDraftDetail> scheduleDetail(String photoId) =>
      _serialize<ScanDraftDetail>(() async {
        final Box<String> box = await _box();
        if (!box.containsKey('photo:$photoId') &&
            !box.containsKey('source:$photoId')) {
          throw StateError('Capture detail source is unavailable.');
        }
        final String? prior = box.get('detail:$photoId');
        if (prior != null) {
          return ScanDraftDetail.fromMap(_map(jsonDecode(prior)));
        }
        final ScanDraftDetail job = ScanDraftDetail(
          photoId: photoId,
          presenceComplete: false,
        );
        await box.put('detail:$photoId', jsonEncode(job.toMap()));
        await box.flush();
        return job;
      });

  Future<List<ScanDraftRescan>> readRescans() => _serialize(() async {
    final Box<String> box = await _box();
    await _recoverRescanIntents(box);
    final List<ScanDraftRescan> requests = <ScanDraftRescan>[];
    Directory? directory;
    for (final String key in box.keys.whereType<String>().where(
      (String key) => key.startsWith('rescan:'),
    )) {
      final ScanDraftRescan request = ScanDraftRescan.fromMap(
        _map(jsonDecode(box.get(key)!)),
      );
      if (!box.containsKey('item:${request.itemId}')) continue;
      final ScanDraftPhoto? photo = request.photo;
      if (photo != null) directory ??= await _images();
      requests.add(
        ScanDraftRescan(
          itemId: request.itemId,
          requestId: request.requestId,
          photo: photo == null ? null : _readPhoto(photo.toMap(), directory!),
          original: request.original,
          choices: request.choices,
          complete: request.complete,
        ),
      );
    }
    return requests;
  });

  Future<ScanDraftRescan> beginRescan(String itemId) => _serialize(() async {
    final Box<String> box = await _box();
    final String? record = box.get('item:$itemId');
    if (record == null) {
      throw StateError('The captured card is no longer available.');
    }
    final String? previous = box.get('rescan:$itemId');
    final ScanDraftRescan? prior = previous == null
        ? null
        : ScanDraftRescan.fromMap(_map(jsonDecode(previous)));
    if (prior != null && !prior.complete) {
      return prior;
    }
    await _promoteCameraSources(box, 'rescan:$itemId');
    final ScanDraftItem original = ScanDraftItem.fromMap(
      _map(jsonDecode(record)),
    );
    final ScanDraftRescan request = ScanDraftRescan(
      itemId: itemId,
      requestId: const Uuid().v4(),
      original: original,
      choices: original.approval ?? prior?.choices ?? prior?.original?.approval,
    );
    await box.put('rescan:$itemId', jsonEncode(request.toMap()));
    await box.flush();
    return request;
  });

  Future<void> cancelRescan(String itemId, {String? requestId}) =>
      _serialize(() async {
        final Box<String> box = await _box();
        await _recoverRescanIntents(box);
        await _cancelRescanRecord(box, itemId, requestId);
      });

  Future<void> _cancelRescanRecord(
    Box<String> box,
    String itemId,
    String? requestId,
  ) async {
    final String? record = box.get('rescan:$itemId');
    if (record == null) return;
    final ScanDraftRescan request = ScanDraftRescan.fromMap(
      _map(jsonDecode(record)),
    );
    if (requestId != null && request.requestId != requestId) return;
    await _promoteCameraSources(box, 'rescan:$itemId');
    final ScanDraftPhoto? photo = request.photo;
    if (!request.complete && photo != null) {
      await _retireRescanPhoto(box, 'rescan:$itemId', photo);
    }
    if (!request.complete && request.choices != null) {
      await box.put(
        'rescan:$itemId',
        jsonEncode(
          ScanDraftRescan(
            itemId: request.itemId,
            requestId: request.requestId,
            original: request.original,
            choices: request.choices,
            complete: true,
          ).toMap(),
        ),
      );
    } else {
      await box.delete('rescan:$itemId');
    }
    await box.flush();
    await _attemptCleanup(box);
  }

  Future<ScanDraftPhoto> importRescanPhoto(
    ScanDraftRescan request,
    String path, {
    bool ownedCameraSource = false,
  }) => _serialize(() async {
    final Box<String> box = await _box();
    final String rescanKey = 'rescan:${request.itemId}';
    final String? record = box.get(rescanKey);
    if (record == null || !box.containsKey('item:${request.itemId}')) {
      throw StateError('The replacement scan is no longer active.');
    }
    final Map<String, Object?> currentRecord = _map(jsonDecode(record));
    final ScanDraftRescan current = ScanDraftRescan.fromMap(currentRecord);
    if (current.complete || current.requestId != request.requestId) {
      throw StateError('The replacement scan is no longer active.');
    }
    final Directory directory = await _images();
    final String? cameraInputKey = ownedCameraSource
        ? sha256
              .convert(
                utf8.encode(File(path).absolute.uri.normalizePath().toString()),
              )
              .toString()
        : null;
    final ScanDraftPhoto? prior = current.photo;
    if (prior != null &&
        cameraInputKey != null &&
        _map(currentRecord['photo'])['cameraInputKey'] == cameraInputKey) {
      final ScanDraftPhoto admitted = _readPhoto(
        _map(currentRecord['photo']),
        directory,
      );
      if (!await _isOwned(
        admitted.imagePath,
        directory,
        'photo-${admitted.id}',
      )) {
        throw const FileSystemException(
          'The saved replacement photo is unavailable.',
        );
      }
      await _cleanAdmittedCameraSources(
        box,
        admitted.id,
        rescanOwner: rescanKey,
      );
      return admitted;
    }
    await _promoteCameraSources(box, rescanKey);
    if (prior != null) await _retireRescanPhoto(box, rescanKey, prior);
    final Map<String, Object?>? cameraSource = ownedCameraSource
        ? await _cameraSourceIdentity(path)
        : null;
    final String id = 'rescan_${const Uuid().v4().replaceAll('-', '')}';
    final String managed = await _copy(path, directory, 'photo-$id');
    final ScanDraftPhoto photo = ScanDraftPhoto(
      id: id,
      imagePath: managed,
      multipleCards: false,
      defaults: current.original?.defaults ?? const ScanCaptureDefaults(),
      createdAt: DateTime.now(),
    );
    final ScanDraftRescan updated = ScanDraftRescan(
      itemId: current.itemId,
      requestId: current.requestId,
      original: current.original,
      choices: current.choices,
      photo: photo,
    );
    try {
      final Map<String, Object?> savedPhoto = <String, Object?>{
        ...photo.toMap(),
        'cameraInputKey': ?cameraInputKey,
        if (cameraSource != null &&
            await _imageDigest(managed) == cameraSource['sha256'])
          'cameraSources': <Map<String, Object?>>[cameraSource],
      };
      await _saveRecord(
        box,
        rescanKey,
        jsonEncode(<String, Object?>{...updated.toMap(), 'photo': savedPhoto}),
        managed,
      );
    } catch (_) {
      if (!(box.get(rescanKey)?.contains(jsonEncode(managed)) ?? false)) {
        await _deleteFile(managed);
      }
      rethrow;
    }
    if (ownedCameraSource) {
      await _cleanAdmittedCameraSources(box, id, rescanOwner: rescanKey);
    }
    if (prior != null) {
      try {
        await _recoverCleanup(
          box,
          onlyKeys: <String>['cleanup:rescan-photo:${prior.id}'],
        );
      } catch (_) {}
    }
    return photo;
  });

  Future<void> _retireRescanPhoto(
    Box<String> box,
    String rescanKey,
    ScanDraftPhoto photo,
  ) async {
    await box.put(
      'cleanup:rescan-photo:${photo.id}',
      jsonEncode(<String, String>{
        'key': 'photo:${photo.id}',
        'path': photo.imagePath,
        'rescanOwner': rescanKey,
      }),
    );
    await box.flush();
  }

  Future<List<List<ScanPoint>>> readReplacedRegions(String photoId) =>
      _serialize(() async {
        final String? record = (await _box()).get('source:$photoId');
        if (record == null) return const <List<ScanPoint>>[];
        final Object? regions = _map(jsonDecode(record))['replacedRegions'];
        if (regions == null) return const <List<ScanPoint>>[];
        return (regions as List<Object?>)
            .map(
              (Object? region) => (region as List<Object?>)
                  .map((Object? point) => ScanPoint.fromMap(_map(point)))
                  .toList(),
            )
            .toList();
      });

  Future<ScanDraftItem> commitRescan(
    ScanDraftRescan request,
    ScanDraftItem replacement,
  ) => _serialize(() async {
    final Box<String> box = await _box();
    final String itemKey = 'item:${request.itemId}';
    final String rescanKey = 'rescan:${request.itemId}';
    final String? record = box.get(rescanKey);
    final String? oldRecord = box.get(itemKey);
    if (record == null || oldRecord == null) {
      throw StateError('The replacement scan is no longer active.');
    }
    final ScanDraftRescan current = ScanDraftRescan.fromMap(
      _map(jsonDecode(record)),
    );
    final ScanDraftPhoto? photo = current.photo;
    if (current.complete ||
        current.requestId != request.requestId ||
        photo == null ||
        replacement.id != request.itemId ||
        replacement.photoId != photo.id) {
      throw StateError('The replacement scan owner changed.');
    }
    await _promoteCameraSources(box, rescanKey);
    final Map<String, Object?> savedPhoto = _map(
      _map(jsonDecode(box.get(rescanKey)!))['photo'],
    );
    final ScanDraftItem old = ScanDraftItem.fromMap(
      _map(jsonDecode(oldRecord)),
    );
    final Directory directory = await _images();
    final String priorPath = old.crop.imagePath.isEmpty
        ? ''
        : _imagePath(old.crop.imagePath, directory, 'crop-${old.id}');
    final String extension = priorPath.endsWith('.jpeg') ? 'jpg' : 'jpeg';
    final String cropPath = await _copy(
      replacement.crop.imagePath,
      directory,
      'crop-${old.id}',
      extension: extension,
    );
    final ScanDraftItem saved = ScanDraftItem(
      id: replacement.id,
      photoId: replacement.photoId,
      defaults: old.defaults,
      resolution: replacement.resolution,
      approval: replacement.approval,
      selected: replacement.selected,
      error: replacement.error,
      liveIdentityName: replacement.liveIdentityName,
      liveCaptureReceiptId: replacement.liveCaptureReceiptId,
      crop: ScanCrop(
        imagePath: cropPath,
        width: replacement.crop.width,
        height: replacement.crop.height,
        rectified: replacement.crop.rectified,
        sourceCorners: replacement.crop.sourceCorners,
        lines: replacement.crop.lines,
        warnings: replacement.crop.warnings,
        sharpness: replacement.crop.sharpness,
      ),
    );
    final String sourceKey = 'source:${photo.id}';
    final String oldSourceKey = 'source:${old.photoId}';
    final String? oldSource = box.get(oldSourceKey);
    final Map<String, String> changes = <String, String>{
      itemKey: jsonEncode(saved.toMap()),
      sourceKey: jsonEncode(<String, Object?>{
        'photo': savedPhoto,
        'itemIds': <String>[saved.id],
      }),
    };
    bool oldSourceUnused = false;
    if (oldSource != null) {
      final Map<String, Object?> source = _map(jsonDecode(oldSource));
      final List<String> siblings = (source['itemIds'] as List<Object?>)
          .cast<String>()
          .where((String id) => id != old.id && box.containsKey('item:$id'))
          .toList();
      oldSourceUnused = siblings.isEmpty;
      source['itemIds'] = siblings;
      source['replacedRegions'] = <Object?>[
        ...(source['replacedRegions'] as List<Object?>? ?? const <Object?>[]),
        old.crop.sourceCorners
            .map(
              (ScanPoint point) => <String, double>{'x': point.x, 'y': point.y},
            )
            .toList(),
      ];
      changes[oldSourceKey] = jsonEncode(source);
    }
    changes[rescanKey] = jsonEncode(<String, Object?>{
      ...ScanDraftRescan(
        itemId: current.itemId,
        requestId: current.requestId,
        photo: photo,
        original: current.original,
        choices: current.choices,
        complete: true,
      ).toMap(),
      'photo': savedPhoto,
    });
    final Map<String, String?> before = <String, String?>{
      for (final String key in changes.keys) key: box.get(key),
    };
    try {
      await box.putAll(changes);
      await box.flush();
    } catch (_) {
      await box.putAll(<String, String>{
        for (final MapEntry<String, String?> entry in before.entries)
          if (entry.value != null) entry.key: entry.value!,
      });
      await box.deleteAll(
        before.keys.where((String key) => before[key] == null),
      );
      await box.flush();
      await _deleteFile(cropPath);
      rethrow;
    }
    final Map<String, String> cleanup = <String, String>{};
    if (priorPath.isNotEmpty && priorPath != cropPath) {
      cleanup['cleanup:rescan-crop:${old.id}:${request.requestId}'] =
          jsonEncode(<String, Object?>{
            'key': itemKey,
            'path': priorPath,
            'retired': true,
          });
    }
    if (oldSourceUnused && oldSource != null) {
      try {
        await box.delete('detail:${old.photoId}');
      } catch (_) {}
      cleanup['cleanup:source:${old.photoId}'] = jsonEncode(<String, Object?>{
        'key': oldSourceKey,
        'path': _map(_map(jsonDecode(oldSource))['photo'])['imagePath'],
      });
    }
    try {
      if (cleanup.isNotEmpty) await box.putAll(cleanup);
      await box.flush();
      await _attemptCleanup(box);
    } catch (_) {}
    return saved;
  });

  Future<void> _recoverRescanIntents(Box<String> box) async {
    for (final String key
        in box.keys
            .whereType<String>()
            .where((String key) => key.startsWith('rescan:'))
            .toList()) {
      final ScanDraftRescan request = ScanDraftRescan.fromMap(
        _map(jsonDecode(box.get(key)!)),
      );
      final ScanDraftPhoto? photo = request.photo;
      final ScanDraftItem? original = request.original;
      final String? current = box.get('item:${request.itemId}');
      if (request.complete ||
          photo == null ||
          original == null ||
          current == null) {
        continue;
      }
      final String currentPhotoId = ScanDraftItem.fromMap(
        _map(jsonDecode(current)),
      ).photoId;
      if (currentPhotoId != photo.id && currentPhotoId != original.photoId) {
        continue;
      }
      final Map<String, String> restore = <String, String>{
        if (currentPhotoId == photo.id)
          'item:${request.itemId}': jsonEncode(original.toMap()),
      };
      final String oldSourceKey = 'source:${original.photoId}';
      final String? oldSource = box.get(oldSourceKey);
      if (currentPhotoId == original.photoId &&
          !box.containsKey('source:${photo.id}') &&
          (oldSource == null ||
              (_map(jsonDecode(oldSource))['itemIds'] as List<Object?>)
                  .contains(original.id))) {
        continue;
      }
      if (oldSource != null) {
        final Map<String, Object?> source = _map(jsonDecode(oldSource));
        source['itemIds'] = <String>{
          ...(source['itemIds'] as List<Object?>).cast<String>(),
          original.id,
        }.toList();
        final List<Object?> regions =
            (source['replacedRegions'] as List<Object?>? ?? const <Object?>[])
                .toList();
        final String originalRegion = jsonEncode(
          original.crop.sourceCorners
              .map(
                (ScanPoint point) => <String, double>{
                  'x': point.x,
                  'y': point.y,
                },
              )
              .toList(),
        );
        if (regions.isNotEmpty && jsonEncode(regions.last) == originalRegion) {
          regions.removeLast();
        }
        source['replacedRegions'] = regions;
        restore[oldSourceKey] = jsonEncode(source);
      }
      await box.putAll(restore);
      await box.delete('source:${photo.id}');
      await box.flush();
    }
  }

  Future<List<ScanDraftDetail>> readDetails() =>
      _serialize<List<ScanDraftDetail>>(() async {
        final Box<String> box = await _box();
        return box.keys
            .whereType<String>()
            .where((String key) => key.startsWith('detail:'))
            .map(
              (String key) =>
                  ScanDraftDetail.fromMap(_map(jsonDecode(box.get(key)!))),
            )
            .where(
              (ScanDraftDetail job) =>
                  !job.complete &&
                  (box.containsKey('photo:${job.photoId}') ||
                      box.containsKey('source:${job.photoId}')),
            )
            .toList();
      });

  Future<void> updateDetail(ScanDraftDetail job) => _serialize<void>(() async {
    final Box<String> box = await _box();
    if (!box.containsKey('detail:${job.photoId}')) return;
    await box.put('detail:${job.photoId}', jsonEncode(job.toMap()));
    await box.flush();
  });

  Future<void> completeDetail(String photoId) => _serialize<void>(() async {
    final Box<String> box = await _box();
    if (!box.containsKey('detail:$photoId')) return;
    await box.put(
      'detail:$photoId',
      jsonEncode(
        ScanDraftDetail(
          photoId: photoId,
          presenceComplete: true,
          complete: true,
        ).toMap(),
      ),
    );
    await box.flush();
  });

  Future<ScanDraftRecovery?> scheduleRecovery(
    String itemId, {
    bool manual = false,
  }) => _serialize<ScanDraftRecovery?>(() async {
    final Box<String> box = await _box();
    final String key = 'recovery:$itemId';
    final String? previous = box.get(key);
    if (previous != null &&
        (!manual || _map(jsonDecode(previous))['pending'] == true)) {
      return null;
    }
    final String? record = box.get('item:$itemId');
    if (record == null) return null;
    final ScanDraftItem item = ScanDraftItem.fromMap(_map(jsonDecode(record)));
    if (item.approval != null || !box.containsKey('source:${item.photoId}')) {
      return null;
    }
    final String? detail = box.get('detail:${item.photoId}');
    if (!manual &&
        detail != null &&
        ScanDraftDetail.fromMap(_map(jsonDecode(detail))).complete) {
      return null;
    }
    if (!manual &&
        box.keys
            .whereType<String>()
            .where((String candidate) => candidate.startsWith('recovery:'))
            .any(
              (String candidate) =>
                  _map(jsonDecode(box.get(candidate)!))['photoId'] ==
                  item.photoId,
            )) {
      return null;
    }
    final ScanDraftRecovery job = ScanDraftRecovery.fromMap(<String, Object?>{
      'itemId': itemId,
      'photoId': item.photoId,
    });
    LocalAccountData.requireWritable(userId);
    await box.put(key, jsonEncode(job.toMap(pending: true)));
    await box.flush();
    return job;
  });

  Future<List<ScanDraftRecovery>> readRecoveries() =>
      _serialize<List<ScanDraftRecovery>>(() async {
        final Box<String> box = await _box();
        final List<ScanDraftRecovery> jobs = <ScanDraftRecovery>[];
        for (final String key in box.keys.whereType<String>().where(
          (String key) => key.startsWith('recovery:'),
        )) {
          final Map<String, Object?> record = _map(jsonDecode(box.get(key)!));
          if (record['pending'] != true) continue;
          final ScanDraftRecovery job = ScanDraftRecovery.fromMap(record);
          if (box.containsKey('item:${job.itemId}')) jobs.add(job);
        }
        return jobs;
      });

  Future<void> completeRecovery(ScanDraftRecovery job) =>
      _serialize<void>(() async {
        final Box<String> box = await _box();
        final String key = 'recovery:${job.itemId}';
        if (!box.containsKey(key)) return;
        LocalAccountData.requireWritable(userId);
        await box.put(key, jsonEncode(job.toMap(pending: false)));
        await box.flush();
      });

  Future<List<ScanDraftItem>> readItems() =>
      _serialize<List<ScanDraftItem>>(() async {
        final Box<String> box = await _box();
        await _recoverRescanIntents(box);
        await _recoverDiscardIntent(box);
        await _refreshDraftReceipts(box);
        final List<String> discarded = <String>[
          for (final ScanCaptureReceipt receipt in _receipts(box))
            if (receipt.state == ScanReceiptState.discarded &&
                box.containsKey('item:${receipt.id}'))
              'item:${receipt.id}',
        ];
        if (discarded.isNotEmpty) await _remove(discarded);
        if (await _attemptCleanup(box) == 64) {
          unawaited(cleanPendingImages());
        }
        Directory? directory;
        final List<ScanDraftItem> items = <ScanDraftItem>[];
        for (final String key in box.keys.whereType<String>().where(
          (String key) => key.startsWith('item:'),
        )) {
          final ScanDraftItem item = ScanDraftItem.fromMap(
            _map(jsonDecode(box.get(key)!)),
          );
          final ScanCrop crop = item.crop;
          if (crop.imagePath.isEmpty) {
            items.add(item);
            continue;
          }
          directory ??= await _images();
          items.add(
            item.withCrop(
              ScanCrop(
                imagePath: _imagePath(
                  crop.imagePath,
                  directory,
                  'crop-${item.id}',
                ),
                width: crop.width,
                height: crop.height,
                rectified: crop.rectified,
                sourceCorners: crop.sourceCorners,
                lines: crop.lines,
                warnings: crop.warnings,
                sharpness: crop.sharpness,
              ),
            ),
          );
        }
        return items;
      });

  Future<List<ScanDraftPhoto>> importPhotos(
    Iterable<String> paths, {
    required bool multipleCards,
    bool ownedCameraSource = false,
    List<List<ScanPoint>> excludedRegions = const <List<ScanPoint>>[],
    ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
  }) {
    final List<List<ScanPoint>> frozen = ScanDraftPhoto.freezeExcludedRegions(
      excludedRegions,
    );
    return _serialize<List<ScanDraftPhoto>>(() async {
      final Box<String> box = await _box();
      final Directory directory = await _images();
      final List<ScanDraftPhoto> photos = <ScanDraftPhoto>[];
      for (final String source in paths) {
        final Map<String, Object?>? cameraSource = ownedCameraSource
            ? await _cameraSourceIdentity(source)
            : null;
        final String id = const Uuid().v4();
        final String managed = await _copy(source, directory, 'photo-$id');
        final ScanDraftPhoto photo = ScanDraftPhoto(
          id: id,
          imagePath: managed,
          multipleCards: multipleCards,
          createdAt: DateTime.now().toUtc(),
          excludedRegions: frozen,
          defaults: defaults,
        );
        try {
          final Map<String, Object?> record = <String, Object?>{
            ...photo.toMap(),
            if (cameraSource != null &&
                await _imageDigest(managed) == cameraSource['sha256'])
              'cameraSources': <Map<String, Object?>>[cameraSource],
          };
          await _saveRecord(box, 'photo:$id', jsonEncode(record), managed);
        } catch (_) {
          if (!box.containsKey('photo:$id')) await _deleteFile(managed);
          rethrow;
        }
        photos.add(photo);
        if (ownedCameraSource) {
          await _cleanAdmittedCameraSources(box, id);
        }
      }
      return photos;
    });
  }

  Future<List<ScanDraftPhoto>> importFocusStack(
    List<String> paths, {
    bool ownedCameraSource = false,
    bool diagnosticOnly = false,
    String? captureId,
    List<String> refinementReceiptIds = const <String>[],
    List<List<ScanPoint>>? targetRegions,
    List<List<ScanPoint>> excludedRegions = const <List<ScanPoint>>[],
    ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
  }) {
    final List<List<ScanPoint>> frozen = ScanDraftPhoto.freezeExcludedRegions(
      excludedRegions,
    );
    final List<List<ScanPoint>>? targets = ScanDraftPhoto.freezeTargetRegions(
      targetRegions,
    );
    final List<String> receipts = ScanDraftPhoto.freezeRefinementReceiptIds(
      refinementReceiptIds,
    );
    return _serialize<List<ScanDraftPhoto>>(() async {
      if ((captureId != null &&
              !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(captureId)) ||
          paths.isEmpty ||
          paths.length > 5 ||
          paths.toSet().length != paths.length) {
        throw ArgumentError.value(paths, 'paths');
      }
      final Box<String> box = await _box();
      final Directory directory = await _images();
      final List<ScanDraftPhoto> photos = <ScanDraftPhoto>[];
      final String sourceKey = focusStackCaptureId(paths);
      final String admittedCaptureId = captureId ?? sourceKey;
      final String rootId = '${admittedCaptureId}_0';
      final String? admitted = box.get('photo:$rootId');
      final String? completed = box.get('source:$rootId');
      if (admitted != null || completed != null) {
        if (captureId != null &&
            _map(jsonDecode(admitted ?? completed!))['focusSourceKey'] !=
                sourceKey) {
          throw StateError(
            'This capture already owns different diagnostic photos.',
          );
        }
        if (admitted != null) {
          final List<Object?> retained =
              _map(jsonDecode(admitted))['focusPhotos'] as List<Object?>;
          photos.addAll(
            retained.map(
              (Object? record) => _readPhoto(_map(record), directory),
            ),
          );
        } else {
          final List<String> ids =
              (_map(jsonDecode(completed!))['focusPhotoIds'] as List<Object?>)
                  .cast<String>();
          photos.addAll(
            ids.map(
              (String id) => _readPhoto(
                _map(_map(jsonDecode(box.get('source:$id')!))['photo']),
                directory,
              ),
            ),
          );
        }
        if (photos.any(
          (ScanDraftPhoto photo) =>
              photo.refinementReceiptIds.length != receipts.length ||
              !photo.refinementReceiptIds.toSet().containsAll(receipts),
        )) {
          throw StateError('This photo owns different refinement receipts.');
        }
        await box.flush();
        if (ownedCameraSource) {
          await _cleanAdmittedCameraSources(box, rootId);
        }
        return photos;
      }
      final List<Map<String, Object?>> cameraSources = <Map<String, Object?>>[];
      try {
        for (int index = 0; index < paths.length; index++) {
          final String path = paths[index];
          final Map<String, Object?>? cameraSource = ownedCameraSource
              ? await _cameraSourceIdentity(path)
              : null;
          final String id = '${admittedCaptureId}_$index';
          final String managed = await _copy(path, directory, 'photo-$id');
          photos.add(
            ScanDraftPhoto(
              id: id,
              imagePath: managed,
              multipleCards: true,
              diagnosticOnly: diagnosticOnly,
              createdAt: DateTime.now().toUtc(),
              excludedRegions: frozen,
              targetRegions: targets,
              refinementReceiptIds: receipts,
              defaults: defaults,
            ),
          );
          if (cameraSource != null &&
              await _imageDigest(managed) == cameraSource['sha256']) {
            cameraSources.add(cameraSource);
          }
        }
        final String root = photos.first.id;
        LocalAccountData.requireWritable(userId);
        await _saveRecord(
          box,
          'photo:$root',
          jsonEncode(<String, Object?>{
            ...photos.first.toMap(),
            'focusSourceKey': sourceKey,
            'focusPhotos': photos
                .map((ScanDraftPhoto photo) => photo.toMap())
                .toList(),
            if (cameraSources.isNotEmpty) 'cameraSources': cameraSources,
          }),
          photos.first.imagePath,
        );
      } catch (_) {
        if (photos.isNotEmpty && !box.containsKey('photo:${photos.first.id}')) {
          for (final ScanDraftPhoto photo in photos) {
            await _deleteFile(photo.imagePath);
          }
        }
        rethrow;
      }
      if (ownedCameraSource) {
        await _cleanAdmittedCameraSources(box, rootId);
      }
      return photos;
    });
  }

  Future<List<ScanDraftPhoto>> readFocusStack(String rootPhotoId) =>
      _serialize<List<ScanDraftPhoto>>(() async {
        final Box<String> box = await _box();
        final String? pending = box.get('photo:$rootPhotoId');
        if (pending == null) return <ScanDraftPhoto>[];
        final List<Object?>? photos =
            _map(jsonDecode(pending))['focusPhotos'] as List<Object?>?;
        if (photos == null) return <ScanDraftPhoto>[];
        final Directory directory = await _images();
        return photos
            .map((Object? photo) => _readPhoto(_map(photo), directory))
            .toList();
      });

  Future<bool> focusStackComplete(String rootPhotoId) =>
      _serialize<bool>(() async {
        final Box<String> box = await _box();
        return box.containsKey('source:$rootPhotoId') &&
            !box.containsKey('photo:$rootPhotoId');
      });

  Future<List<ScanDraftItem>> completeFocusStack(
    List<ScanDraftPhoto> photos,
    List<ScanDraftItem> items,
  ) => _serialize<List<ScanDraftItem>>(() async {
    final Box<String> box = await _box();
    final String? pending = photos.isEmpty
        ? null
        : box.get('photo:${photos.first.id}');
    final String? retained = photos.isEmpty
        ? null
        : box.get('source:${photos.first.id}');
    final Map<String, Object?>? admittedPhoto = pending != null
        ? _map(jsonDecode(pending))
        : retained == null
        ? null
        : _map(_map(jsonDecode(retained))['photo']);
    final List<String> receipts = admittedPhoto == null
        ? const <String>[]
        : ScanDraftPhoto.fromMap(admittedPhoto).refinementReceiptIds;
    bool ownedRefinement(ScanDraftItem item) {
      final String? existing = box.get('item:${item.id}');
      return item.liveCaptureReceiptId != null &&
          receipts.contains(item.liveCaptureReceiptId) &&
          existing != null &&
          ScanDraftItem.fromMap(_map(jsonDecode(existing)))
                  .liveCaptureReceiptId ==
              item.liveCaptureReceiptId;
    }

    if (photos.isEmpty ||
        (items.isEmpty &&
            photos.every(
              (ScanDraftPhoto photo) =>
                  photo.excludedRegions.isEmpty && photo.targetRegions == null,
            )) ||
        items.any(
          (ScanDraftItem item) => receipts.isNotEmpty
              ? !ownedRefinement(item)
              : !photos.any((ScanDraftPhoto photo) => photo.id == item.photoId),
        )) {
      throw ArgumentError('Invalid focus-stack crops.');
    }
    await _promoteCameraSources(box, 'photo:${photos.first.id}');
    await _promoteCameraSources(box, 'source:${photos.first.id}');
    final List<ScanDraftItem> saved = await _upsertItems(items);
    final String? pendingRecord = box.get('photo:${photos.first.id}');
    final String? retainedRecord =
        pendingRecord ?? box.get('source:${photos.first.id}');
    final List<String> cameraCleanupKeys = <String>{
      ..._cameraCleanupKeys(box, 'photo:${photos.first.id}'),
      ..._cameraCleanupKeys(box, 'source:${photos.first.id}'),
    }.toList();
    final String? sourceKey = retainedRecord == null
        ? null
        : _map(jsonDecode(retainedRecord))['focusSourceKey'] as String?;
    final List<String> ids = photos
        .map((ScanDraftPhoto photo) => photo.id)
        .toList();
    final String? detailRecord = box.get('detail:${photos.first.id}');
    final ScanDraftDetail? detail = detailRecord == null
        ? null
        : ScanDraftDetail.fromMap(_map(jsonDecode(detailRecord)));
    LocalAccountData.requireWritable(userId);
    await box.putAll(<String, String>{
      for (final ScanDraftPhoto photo in photos)
        'source:${photo.id}': jsonEncode(<String, Object?>{
          'photo': <String, Object?>{
            ...photo.toMap(),
            if (photo.id == photos.first.id && cameraCleanupKeys.isNotEmpty)
              'cameraCleanupKeys': cameraCleanupKeys,
          },
          'itemIds': saved.map((ScanDraftItem item) => item.id).toList(),
          'focusPhotoIds': ids,
          'focusSourceKey': sourceKey,
        }),
      if (detail != null)
        'detail:${photos.first.id}': jsonEncode(
          ScanDraftDetail(
            photoId: detail.photoId,
            presenceComplete: true,
            failed: detail.failed,
            complete: detail.complete,
          ).toMap(),
        ),
    });
    await box.flush();
    await box.delete('photo:${photos.first.id}');
    await box.flush();
    return saved;
  });

  Future<List<ScanDraftItem>> upsertItems(List<ScanDraftItem> items) =>
      _serialize<List<ScanDraftItem>>(() => _upsertItems(items));

  Future<List<ScanDraftItem>> _upsertItems(List<ScanDraftItem> items) async {
    final Box<String> box = await _box();
    Directory? directory;
    final List<ScanDraftItem> saved = <ScanDraftItem>[];
    for (final ScanDraftItem item in items) {
      if (!RegExp(r'^[A-Za-z0-9_-]{1,160}$').hasMatch(item.id)) {
        throw ArgumentError.value(item.id, 'id');
      }
      String path = item.crop.imagePath;
      if (path.isNotEmpty) {
        directory ??= await _images();
        if (!await _isOwned(path, directory, 'crop-${item.id}')) {
          path = await _copy(path, directory, 'crop-${item.id}');
        }
      }
      final ScanCrop crop = item.crop;
      final ScanDraftItem persisted = item.withCrop(
        ScanCrop(
          imagePath: path,
          width: crop.width,
          height: crop.height,
          rectified: crop.rectified,
          sourceCorners: crop.sourceCorners,
          lines: crop.lines,
          warnings: crop.warnings,
          sharpness: crop.sharpness,
        ),
      );
      await _saveRecord(
        box,
        'item:${item.id}',
        jsonEncode(persisted.toMap()),
        path,
      );
      await _writeReceipts(box, <ScanCaptureReceipt>[
        _draftReceipt(box, persisted),
      ]);
      saved.add(persisted);
    }
    return saved;
  }

  /// Crop IDs should be derived from photo ID and crop index, so recognition replay replaces them.
  Future<List<ScanDraftItem>> completePhoto(
    String photoId,
    List<ScanDraftItem> items,
  ) => _serialize<List<ScanDraftItem>>(() async {
    final Box<String> box = await _box();
    await _promoteCameraSources(box, 'photo:$photoId');
    await _promoteCameraSources(box, 'source:$photoId');
    final String? pending = box.get('photo:$photoId');
    final String? retained = box.get('source:$photoId');
    final Map<String, Object?>? photo = pending != null
        ? _map(jsonDecode(pending))
        : retained == null
        ? null
        : _map(_map(jsonDecode(retained))['photo']);
    if (photo == null) {
      throw StateError('Source photo is unavailable.');
    }
    final List<String> receipts = ScanDraftPhoto.fromMap(photo)
        .refinementReceiptIds;
    if (items.any((ScanDraftItem item) {
      if (receipts.isEmpty) return item.photoId != photoId;
      final String? existing = box.get('item:${item.id}');
      return !receipts.contains(item.liveCaptureReceiptId) ||
          existing == null ||
          ScanDraftItem.fromMap(_map(jsonDecode(existing)))
                  .liveCaptureReceiptId !=
              item.liveCaptureReceiptId;
    })) {
      throw ArgumentError('Crop belongs to another photo.');
    }
    final List<ScanDraftItem> saved = await _upsertItems(items);
    LocalAccountData.requireWritable(userId);
    await box.put(
      'source:$photoId',
      jsonEncode(<String, Object?>{
        if (retained != null) ..._map(jsonDecode(retained)),
        'photo': photo,
        'itemIds': saved.map((ScanDraftItem item) => item.id).toList(),
      }),
    );
    await box.flush();
    await box.delete('photo:$photoId');
    await box.flush();
    if (saved.isEmpty && !box.containsKey('detail:$photoId')) {
      await _remove(<String>['source:$photoId']);
    }
    return saved;
  });

  Future<void> removePhotos(List<String> ids) => _serialize<void>(
    () => _remove(ids.map((String id) => 'photo:$id').toList()),
  );
  Future<void> removeItems(List<String> ids) => _serialize<void>(() async {
    final Box<String> box = await _box();
    await _recoverRescanIntents(box);
    await _writeReceipts(box, <ScanCaptureReceipt>[
      for (final String id in ids)
        if (box.get('item:$id') case final String value)
          if (_draftReceipt(box, ScanDraftItem.fromMap(_map(jsonDecode(value))))
              case final ScanCaptureReceipt receipt)
            if (receipt.state == ScanReceiptState.captured)
              receipt.copyWith(
                state: ScanReceiptState.discarded,
                discardedAt: DateTime.now().toUtc(),
              ),
    ]);
    for (final String id in ids) {
      await _cancelRescanRecord(box, id, null);
    }
    await _remove(ids.map((String id) => 'item:$id').toList());
    await box.deleteAll(ids.map((String id) => 'recovery:$id'));
    await box.deleteAll(ids.map((String id) => 'rescan:$id'));
    await box.flush();
  });

  Future<void> clearCaptures() => _serialize<void>(() async {
    final Box<String> box = await _box();
    for (final String key
        in box.keys
            .whereType<String>()
            .where(
              (String key) =>
                  key.startsWith('photo:') ||
                  key.startsWith('source:') ||
                  key.startsWith('rescan:'),
            )
            .toList()) {
      await _promoteCameraSources(box, key);
    }
    final Map<String, String> before = <String, String>{
      for (final String key in box.keys.whereType<String>())
        if (key.startsWith('item:') ||
            key.startsWith('photo:') ||
            key.startsWith('source:') ||
            key.startsWith('detail:') ||
            key.startsWith('rescan:') ||
            key.startsWith('recovery:') ||
            (key.startsWith('cleanup:') && !key.startsWith('cleanup:camera:')))
          key: box.get(key)!,
    };
    final Map<String, String> cleanup = <String, String>{};
    if (!kIsWeb && box.path != null) {
      try {
        final Directory directory = await _images();
        final RegExp imageName = RegExp(
          r'^(photo|crop)-([A-Za-z0-9_-]{1,160})\.[A-Za-z0-9]{1,8}$',
        );
        await for (final FileSystemEntity entity in directory.list(
          followLinks: false,
        )) {
          if (entity is! File) continue;
          final String filename = entity.uri.pathSegments.last;
          final RegExpMatch? match = imageName.firstMatch(filename);
          if (match == null) continue;
          final String key =
              '${match.group(1) == 'photo' ? 'photo' : 'item'}:${match.group(2)}';
          cleanup['cleanup:clear:$filename'] = jsonEncode(<String, String>{
            'key': key,
            'path': entity.path,
          });
        }
      } on FileSystemException {
        // Metadata removal remains available when image cleanup cannot access its directory.
      }
    }
    try {
      LocalAccountData.requireWritable(userId);
      await box.deleteAll(before.keys);
      await box.flush();
    } catch (_) {
      LocalAccountData.requireWritable(userId);
      await box.putAll(before);
      await box.flush();
      rethrow;
    }
    try {
      if (cleanup.isNotEmpty) {
        await box.putAll(cleanup);
        await box.flush();
      }
      if (await _attemptCleanup(box) == 64) {
        unawaited(cleanPendingImages());
      }
    } catch (_) {
      // Captures are cleared; an owned orphan can be reclaimed on the next clear.
    }
  });

  Future<void> _saveRecord(
    Box<String> box,
    String key,
    String value,
    String imagePath,
  ) async {
    try {
      LocalAccountData.requireWritable(userId);
      await box.put(key, value);
      await box.flush();
    } catch (_) {
      if (imagePath.isNotEmpty &&
          !(box.get(key)?.contains(jsonEncode(imagePath)) ?? false)) {
        await _deleteFile(imagePath);
      }
      rethrow;
    }
  }

  Future<void> _remove(List<String> keys) async {
    final Box<String> box = await _box();
    for (final String key in keys) {
      if (key.startsWith('photo:') || key.startsWith('source:')) {
        await _promoteCameraSources(box, key);
      }
    }
    final Map<String, String> cleanup = <String, String>{};
    final Set<String> removing = keys.toSet();
    final Set<String> sources = <String>{};
    final Map<String, List<Object?>> retiredRegions = <String, List<Object?>>{};
    for (final String key in keys) {
      final String? value = box.get(key);
      if (value == null) {
        continue;
      }
      final Map<String, Object?> record = _map(jsonDecode(value));
      if (key.startsWith('photo:')) {
        if (record['focusPhotos'] case final List<Object?> photos) {
          for (final Object? value in photos) {
            final ScanDraftPhoto photo = ScanDraftPhoto.fromMap(_map(value));
            cleanup['cleanup:photo:${photo.id}'] = jsonEncode(<String, String>{
              'key': 'photo:${photo.id}',
              'path': photo.imagePath,
            });
          }
        }
      }
      final String path = key.startsWith('source:')
          ? _map(record['photo'])['imagePath'] as String
          : key.startsWith('photo:')
          ? record['imagePath'] as String
          : _map(record['crop'])['imagePath'] as String;
      if (key.startsWith('item:')) {
        final String photoId = record['photoId'] as String;
        sources.add(photoId);
        final Object? corners = _map(record['crop'])['sourceCorners'];
        if (corners is List<Object?> && corners.length == 4) {
          (retiredRegions[photoId] ??= <Object?>[]).add(corners);
        }
      }
      if (path.isNotEmpty) {
        cleanup['cleanup:$key'] = jsonEncode(<String, String>{
          'key': key,
          'path': path,
        });
      }
    }
    final Set<String> groupSources = <String>{...sources};
    for (final String key in box.keys.whereType<String>().where(
      (String key) => key.startsWith('source:'),
    )) {
      final Map<String, Object?> source = _map(jsonDecode(box.get(key)!));
      if (!(source['itemIds'] as List<Object?>).cast<String>().any(
        (String id) => removing.contains('item:$id'),
      )) {
        continue;
      }
      final Map<String, Object?> photo = _map(source['photo']);
      if ((photo['refinementReceiptIds'] as List<Object?>?)?.isNotEmpty ??
          false) {
        groupSources.add(photo['id'] as String);
      }
    }
    for (final String photoId in sources) {
      final String? retained = box.get('source:$photoId');
      if (retained == null) continue;
      final Map<String, Object?> source = _map(jsonDecode(retained));
      if (source['focusPhotoIds'] case final List<Object?> ids) {
        groupSources.addAll(ids.cast<String>());
      }
    }
    for (final String photoId in groupSources) {
      final String key = 'source:$photoId';
      await _promoteCameraSources(box, key);
      final String? retained = box.get(key);
      if (retained == null) continue;
      final Map<String, Object?> source = _map(jsonDecode(retained));
      final List<String> itemIds = (source['itemIds'] as List<Object?>)
          .cast<String>();
      if (itemIds.any(
        (String id) =>
            !removing.contains('item:$id') && box.containsKey('item:$id'),
      )) {
        final List<Object?> regions =
            retiredRegions[photoId] ?? const <Object?>[];
        if (regions.isNotEmpty) {
          source['replacedRegions'] = <Object?>[
            ...(source['replacedRegions'] as List<Object?>? ??
                const <Object?>[]),
            ...regions,
          ];
          cleanup[key] = jsonEncode(source);
        }
        continue;
      }
      await box.delete('detail:$photoId');
      cleanup['cleanup:$key'] = jsonEncode(<String, String>{
        'key': key,
        'path': _map(source['photo'])['imagePath'] as String,
      });
    }
    if (cleanup.isNotEmpty) {
      await box.putAll(cleanup);
      await box.flush();
    }
    await box.deleteAll(keys.where((String key) => !key.startsWith('source:')));
    await box.flush();
    if (await _attemptCleanup(box) == 64) {
      unawaited(cleanPendingImages());
    }
  }

  Future<void> cleanPendingImages() =>
      _cleanupTask ??= _drainCleanup().whenComplete(() => _cleanupTask = null);

  Future<void> _drainCleanup() async {
    try {
      while (await _serialize<int>(() async => _attemptCleanup(await _box())) ==
          64) {
        await Future<void>.delayed(Duration.zero);
      }
    } on StateError {
      if (!LocalAccountData.isDeleting(userId)) rethrow;
    }
  }

  Future<int> _attemptCleanup(Box<String> box) async {
    try {
      return await _recoverCleanup(box);
    } catch (_) {
      // Cleanup can retry from durable markers without invalidating a completed approval.
      return 0;
    }
  }

  Future<int> _recoverCleanup(Box<String> box, {List<String>? onlyKeys}) async {
    if (kIsWeb) {
      return 0;
    }
    final List<String> available;
    if (onlyKeys == null) {
      final List<String> keys = box.keys.whereType<String>().toList();
      final Set<String> pending = keys
          .where((String key) => key.startsWith('cleanup:'))
          .toSet();
      int promoted = 0;
      for (final String key in keys.where(
        (String key) =>
            key.startsWith('photo:') ||
            key.startsWith('source:') ||
            key.startsWith('rescan:'),
      )) {
        try {
          final List<String> cameraKeys = await _promoteCameraSources(box, key);
          pending.addAll(cameraKeys);
          promoted += cameraKeys.length;
        } catch (_) {
          // Reclaim already journaled files even when new writes cannot fit.
          break;
        }
        if (promoted >= 64) break;
      }
      available = pending.toList();
    } else {
      available = onlyKeys;
    }
    final int next = onlyKeys == null && _nextCleanupKey != null
        ? available.indexOf(_nextCleanupKey!)
        : 0;
    final int start = next < 0 ? 0 : next;
    final List<String> cleanupKeys = <String>[
      ...available.skip(start),
      ...available.take(start),
    ].take(64).toList();
    if (cleanupKeys.isEmpty) {
      return 0;
    }
    if (onlyKeys == null) {
      _nextCleanupKey =
          available[(start + cleanupKeys.length) % available.length];
    }
    final Directory directory = await _images();
    final List<String> completed = <String>[];
    for (final String cleanupKey in cleanupKeys) {
      final Map<String, Object?> cleanup = _map(
        jsonDecode(box.get(cleanupKey)!),
      );
      if (cleanupKey.startsWith('cleanup:camera:')) {
        if (await _deleteCameraSource(cleanup)) completed.add(cleanupKey);
        continue;
      }
      final String key = cleanup['key'] as String;
      final String? rescanOwner = cleanup['rescanOwner'] as String?;
      if (rescanOwner != null) {
        if (key.startsWith('photo:') &&
            box.containsKey('source:${key.substring(6)}')) {
          completed.add(cleanupKey);
          continue;
        }
        final String? retained = box.get(rescanOwner);
        if (retained != null) {
          final Object? retainedPhoto = _map(jsonDecode(retained))['photo'];
          if (retainedPhoto != null &&
              'photo:${_map(retainedPhoto)['id']}' == key) {
            continue;
          }
        }
      }
      final bool source = key.startsWith('source:');
      if (cleanupKey.startsWith('cleanup:clear:') &&
          (box.containsKey(key) ||
              (key.startsWith('photo:') &&
                  box.containsKey('source:${key.substring(6)}')))) {
        completed.add(cleanupKey);
        continue;
      }
      if (source && box.containsKey(key)) {
        final Map<String, Object?> record = _map(jsonDecode(box.get(key)!));
        final List<String> itemIds = (record['itemIds'] as List<Object?>)
            .cast<String>();
        if (box.containsKey('detail:${key.substring(7)}')) {
          continue;
        }
        if (itemIds.any((String id) => box.containsKey('item:$id'))) {
          continue;
        }
        await box.deleteAll(<String>[key, 'photo:${key.substring(7)}']);
        await box.flush();
      } else if (box.containsKey(key) &&
          !(cleanup['retired'] == true &&
              key.startsWith('item:') &&
              File(
                    _map(_map(jsonDecode(box.get(key)!))['crop'])['imagePath']
                        as String,
                  ).uri.pathSegments.last !=
                  File(cleanup['path'] as String).uri.pathSegments.last)) {
        completed.add(cleanupKey);
        continue;
      }
      final String name =
          '${key.startsWith('photo:') || source ? 'photo' : 'crop'}-${key.substring(key.indexOf(':') + 1)}';
      final String path;
      try {
        path = _imagePath(cleanup['path'] as String, directory, name);
      } on FormatException {
        completed.add(cleanupKey);
        continue;
      }
      if (!await File(path).exists() ||
          !await _isOwned(path, directory, name)) {
        completed.add(cleanupKey);
      } else if (await _deleteFile(path)) {
        completed.add(cleanupKey);
      }
    }
    try {
      await box.deleteAll(completed);
      await box.flush();
    } catch (_) {
      // Draft removal already committed; cleanup markers can retry on the next read.
      return 0;
    }
    return completed.length;
  }

  Future<bool> _deleteFile(String path) async {
    try {
      final File file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<List<String>> _promoteCameraSources(
    Box<String> box,
    String key,
  ) async {
    final String? encoded = box.get(key);
    if (encoded == null || !encoded.contains('"cameraSources"')) {
      return const <String>[];
    }
    final Map<String, Object?> record = _map(jsonDecode(encoded));
    final bool nested = key.startsWith('source:') || key.startsWith('rescan:');
    final Map<String, Object?> photo = nested ? _map(record['photo']) : record;
    final List<Object?>? sources = photo['cameraSources'] as List<Object?>?;
    if (sources == null || sources.isEmpty) return const <String>[];
    if (sources.length > 5) {
      throw const FormatException('Invalid camera source ownership.');
    }
    final String photoId = photo['id'] as String;
    final Map<String, String> cleanup = <String, String>{
      for (final Object? source in sources)
        'cleanup:camera:$photoId:${sha256.convert(utf8.encode(jsonEncode(source)))}':
            jsonEncode(source),
    };
    await box.putAll(cleanup);
    await box.flush();
    photo.remove('cameraSources');
    photo['cameraCleanupKeys'] = cleanup.keys.toList();
    if (nested) record['photo'] = photo;
    await box.put(key, jsonEncode(record));
    await box.flush();
    return cleanup.keys.toList();
  }

  List<String> _cameraCleanupKeys(Box<String> box, String key) {
    final String? encoded = box.get(key);
    if (encoded == null || !encoded.contains('"cameraCleanupKeys"')) {
      return const <String>[];
    }
    final Map<String, Object?> record = _map(jsonDecode(encoded));
    final Map<String, Object?> photo =
        key.startsWith('source:') || key.startsWith('rescan:')
        ? _map(record['photo'])
        : record;
    return (photo['cameraCleanupKeys'] as List<Object?>? ?? const <Object?>[])
        .cast<String>();
  }

  Future<void> _cleanAdmittedCameraSources(
    Box<String> box,
    String photoId, {
    String? rescanOwner,
  }) async {
    try {
      final List<String> owners = <String>[
        if (rescanOwner != null)
          rescanOwner
        else ...<String>['photo:$photoId', 'source:$photoId'],
      ];
      for (final String owner in owners) {
        await _promoteCameraSources(box, owner);
      }
      final Set<String> keys = <String>{
        for (final String owner in owners) ..._cameraCleanupKeys(box, owner),
      };
      await _recoverCleanup(
        box,
        onlyKeys: keys.where(box.containsKey).toList(),
      );
    } catch (_) {
      // Admission is durable; embedded ownership or its journal can retry cleanup.
    }
  }

  bool _managedImagePath(String path) =>
      File(path).absolute.uri.pathSegments
          .any((String segment) => segment.startsWith('scanner_images_'));

  Future<String> _imageDigest(String path) async =>
      (await sha256.bind(File(path).openRead()).first).toString();

  Future<Map<String, Object?>?> _cameraSourceIdentity(String path) async {
    if (_managedImagePath(path) ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
      return null;
    }
    final File file = File(path);
    final String canonical = await file.resolveSymbolicLinks();
    if (_managedImagePath(canonical)) return null;
    final FileStat before = await file.stat();
    final String digest = await _imageDigest(path);
    final FileStat after = await file.stat();
    if (before.type != FileSystemEntityType.file ||
        after.type != FileSystemEntityType.file ||
        before.size != after.size ||
        before.modified != after.modified ||
        before.changed != after.changed ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.resolveSymbolicLinks() != canonical) {
      return null;
    }
    return <String, Object?>{
      'path': canonical,
      'size': after.size,
      'modified': after.modified.microsecondsSinceEpoch,
      'changed': after.changed.microsecondsSinceEpoch,
      'sha256': digest,
    };
  }

  Future<bool> _deleteCameraSource(Map<String, Object?> identity) async {
    try {
      final String path = identity['path'] as String;
      final Map<String, Object?>? current = await _cameraSourceIdentity(path);
      if (current == null ||
          current['path'] != path ||
          current['size'] != identity['size'] ||
          current['modified'] != identity['modified'] ||
          current['changed'] != identity['changed'] ||
          current['sha256'] != identity['sha256']) {
        return true;
      }
      return await _deleteFile(path);
    } on FileSystemException {
      return false;
    }
  }

  Future<bool> _isOwned(String path, Directory directory, String name) async =>
      path.split('/').last.startsWith('$name.') &&
      await _isManaged(path, directory);

  Future<bool> _isManaged(String path, Directory directory) async {
    final File file = File(path);
    if (!await file.exists()) {
      return false;
    }
    return (await file.resolveSymbolicLinks()).startsWith(
      '${await directory.resolveSymbolicLinks()}/',
    );
  }

  Future<String> _copy(
    String source,
    Directory directory,
    String name, {
    String? extension,
  }) async {
    // Native recognition writes crops here, so count the directory fresh for each admission.
    final int retainedBytes = await compute(
      _retainedImageBytes,
      directory.path,
    );
    final int incomingBytes = await File(source).length();
    if (retainedBytes + incomingBytes > maximumImageBytes) {
      throw const ScanDraftStorageBudgetExceeded();
    }
    final String suffix = source.split('.').last;
    final String fileExtension =
        extension ??
        (RegExp(r'^[A-Za-z0-9]{1,8}$').hasMatch(suffix) ? suffix : 'jpg');
    final String destination = '${directory.path}/$name.$fileExtension';
    final String temporary = '$destination.pending';
    try {
      final File staged = await File(source).copy(temporary);
      final RandomAccessFile handle = await staged.open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
      await staged.rename(destination);
    } catch (_) {
      await _deleteFile(temporary);
      rethrow;
    }
    return destination;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final Future<T> next = _mutations.then(
      (_) => LocalAccountData.mutate(userId, action),
    );
    _mutations = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}
