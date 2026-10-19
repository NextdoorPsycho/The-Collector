import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:uuid/uuid.dart';

import 'scan_draft_store.dart';
import 'scan_capture_defaults.dart';
import 'live_scan_tracker.dart';
import 'scan_focus_stack.dart';
import 'scan_queue.dart';
import 'scan_recognition.dart';
import 'scan_resolver.dart';

enum ScanItemPhase {
  processing,
  retrying,
  needsReview,
  noIdentity,
  lookupFailed,
  ready,
}

class ScanSessionItem {
  final String id;
  final String photoId;
  final ScanCaptureDefaults defaults;
  ScanCrop crop;
  ScanResolution? resolution;
  ScanQueueApproval? approval;
  bool selected = false;
  bool manuallyReviewed = false;
  String? error;
  String? liveIdentityName;
  String? liveCaptureReceiptId;
  bool _retrying = false;
  bool _detailsPending = false;
  bool _reviewSaveFailed = false;
  bool _rescanPending = false;
  ScanQueueApproval? _replacementChoices;
  bool get rescanPending => _rescanPending;
  int get replacementQuantity => _replacementChoices?.quantity ?? 1;
  ScanQueueApproval? get replacementChoices => _replacementChoices;

  ScanSessionItem(
    this.crop, {
    String? id,
    this.photoId = '',
    this.defaults = const ScanCaptureDefaults(),
  }) : id = id ?? const Uuid().v4();

  factory ScanSessionItem.fromDraft(ScanDraftItem draft) =>
      ScanSessionItem(
          draft.crop,
          id: draft.id,
          photoId: draft.photoId,
          defaults: draft.defaults,
        )
        ..resolution = draft.resolution
        ..approval = draft.approval
        ..selected = draft.selected
        ..manuallyReviewed = draft.approval != null
        ..error = draft.error
        ..liveIdentityName = draft.liveIdentityName
        ..liveCaptureReceiptId = draft.liveCaptureReceiptId;

  ScanDraftItem get draft => ScanDraftItem(
    id: id,
    photoId: photoId,
    crop: crop,
    resolution: resolution,
    approval: approval,
    selected: selected,
    error: error,
    liveIdentityName: liveIdentityName,
    liveCaptureReceiptId: liveCaptureReceiptId,
    defaults: defaults,
  );

  MtgCard? get printing => resolution?.candidates.firstOrNull?.card;

  bool get exactMatch =>
      !_rescanPending && hasExactPrintingEvidence(crop, resolution);

  ScanItemPhase get phase {
    if (_rescanPending) return ScanItemPhase.needsReview;
    if (approval != null && !_reviewSaveFailed) return ScanItemPhase.ready;
    if (_retrying) return ScanItemPhase.retrying;
    if (_detailsPending) return ScanItemPhase.processing;
    if (_reviewSaveFailed) return ScanItemPhase.needsReview;
    if (error != null) return ScanItemPhase.lookupFailed;
    if (resolution == null) return ScanItemPhase.processing;
    if (resolution!.candidates.isEmpty) return ScanItemPhase.noIdentity;
    return exactMatch ? ScanItemPhase.ready : ScanItemPhase.needsReview;
  }
}

class ScanSession extends ChangeNotifier {
  final CardRecognizer recognizer;
  final ScanResolver resolver;
  final ScanDraftStore? store;
  final Queue<ScanDraftPhoto> _photos = Queue<ScanDraftPhoto>();
  final Queue<ScanDraftRecovery> _recoveries = Queue<ScanDraftRecovery>();
  final Set<String> _recoveryIds = <String>{};
  ScanDraftRecovery? _activeRecovery;
  final Queue<ScanDraftDetail> _details = Queue<ScanDraftDetail>();
  final Map<String, ScanDraftDetail> _detailJobs = <String, ScanDraftDetail>{};
  final Map<String, ScanDraftPhoto> _detailSources = <String, ScanDraftPhoto>{};
  final Set<String> _detailedPhotoIds = <String>{};
  bool _detailReaderRunning = false;
  int? _detailEpoch;
  ScanDraftDetail? _activeDetail;
  Completer<void>? _detailIdle;
  Completer<void>? _readerIdle;
  final Map<String, ScanDraftRescan> _rescans = <String, ScanDraftRescan>{};
  final Map<String, String> _rescanFailures = <String, String>{};
  final Set<String> _activeReplacements = <String>{};
  int _replacementReaders = 0;
  Future<void> _replacementTurns = Future<void>.value();
  bool _readerUsesPresence = false;
  final List<ScanDraftPhoto> _failed = <ScanDraftPhoto>[];
  final List<ScanSessionItem> items = <ScanSessionItem>[];
  final Set<String> _removing = <String>{};
  final Map<String, ScanSessionItem> _byId = <String, ScanSessionItem>{};
  final Map<String, List<ScanDraftPhoto>> _focusStacks =
      <String, List<ScanDraftPhoto>>{};
  final Map<String, String> _captureReadsByPhotoId = <String, String>{};
  final LinkedHashSet<String> _readCaptures = LinkedHashSet<String>();
  final Map<String, List<List<ScanPoint>>> _rawCaptureRegions =
      <String, List<List<ScanPoint>>>{};
  final Map<String, List<SavedTargetAppearance>> _savedTargetAppearances =
      <String, List<SavedTargetAppearance>>{};
  ({String path, String id})? _lastCameraPhoto;
  String? _activePhotoId;
  ScanDraftPhoto? _activePhoto;
  int _captureEpoch = 0;
  bool _clearingCaptures = false;
  Future<void>? _clearCaptures;
  final Set<Future<void>> _captureAdmissions = <Future<void>>{};
  bool loaded = false;
  Future<void>? _loading;
  final List<ScanSessionItem> _unresolved = <ScanSessionItem>[];
  final Set<String> _resolvingIds = <String>{};
  final Map<String, ({int epoch, ScanSessionItem item, Completer<void> done})>
  _itemRetries =
      <String, ({int epoch, ScanSessionItem item, Completer<void> done})>{};
  Future<void> _itemUpdates = Future<void>.value();
  final Map<String, ScanCrop> _photoRefinements = <String, ScanCrop>{};
  final Set<String> _removedLiveIds = <String>{};
  final Map<String, List<List<ScanPoint>>> _removedPhotoRegions =
      <String, List<List<ScanPoint>>>{};
  final Map<String, String> _liveReceiptIds = <String, String>{};
  final LinkedHashMap<String, Set<String>> _photoRefinementReceipts =
      LinkedHashMap<String, Set<String>>();
  final Set<String> _pendingRefinementPhotoIds = <String>{};

  bool _registerRefinementReceipts(String photoId, Iterable<String> receipts) {
    if (!_photoRefinementReceipts.containsKey(photoId)) {
      while (_photoRefinementReceipts.length >= 32) {
        final String? expired = _photoRefinementReceipts.keys
            .where(
              (String id) =>
                  !_pendingRefinementPhotoIds.contains(id) &&
                  _activePhotoId != id &&
                  !_photos.any((ScanDraftPhoto photo) => photo.id == id) &&
                  !_failed.any((ScanDraftPhoto photo) => photo.id == id),
            )
            .firstOrNull;
        if (expired == null) return false;
        _photoRefinementReceipts.remove(expired);
      }
    }
    _photoRefinementReceipts.remove(photoId);
    _photoRefinementReceipts[photoId] = receipts.toSet();
    return true;
  }

  final LinkedHashMap<String, String> _explicitCapturesByPaths =
      LinkedHashMap<String, String>();
  final LinkedHashMap<String, String> _diagnosticSources =
      LinkedHashMap<String, String>();
  final LinkedHashMap<String, Set<String>> _capturePhotoIds =
      LinkedHashMap<String, Set<String>>();
  Completer<void>? _idle;
  bool _readerRunning = false;
  int? _readerEpoch;
  int _resolverWorkers = 0;
  final Map<int, int> _resolverWorkersByEpoch = <int, int>{};
  static const int _maximumResolverWorkers = 2;
  static const int _maximumResolverBatch = 8;
  static const int _maximumPendingRecognitionCards = 225;
  bool paused = false;
  int _pauseRevision = 0;
  bool running = false;
  bool _disposed = false;
  int photosRead = 0;
  int photosQueued = 0;
  String? _storageError;
  String? get storageError =>
      _storageError ?? (_failedReviewIds.isEmpty ? null : _reviewStorageError);
  set storageError(String? value) => _storageError = value;
  static const String _liveStorageError =
      'Could not save the captured cards. Free storage and retry.';
  static const String _acceptanceStorageError =
      'Could not save capture confirmation. Retry.';
  static const String _reviewStorageError =
      'Could not save the latest review results. Free storage and retry before closing.';
  final Set<String> _failedLiveReceiptIds = <String>{};
  final Set<String> _failedCaptureAcceptanceIds = <String>{};
  final Set<String> _failedReviewIds = <String>{};
  bool get liveStorageFailed => _failedLiveReceiptIds.isNotEmpty;
  bool get clearingCaptures => _clearingCaptures;

  bool _currentCapture(int epoch) =>
      !_disposed && !_clearingCaptures && epoch == _captureEpoch;

  bool _forgetReviewFailures(Iterable<String> ids) {
    final String? previousError = storageError;
    for (final String id in ids) {
      _failedReviewIds.remove(id);
      _byId[id]?._reviewSaveFailed = false;
    }
    if (_failedReviewIds.isEmpty && _storageError == _reviewStorageError) {
      _storageError = null;
    }
    return storageError != previousError;
  }

  Future<T> _trackCaptureAdmission<T>(Future<T> Function() operation) async {
    final Completer<void> done = Completer<void>();
    _captureAdmissions.add(done.future);
    try {
      return await operation();
    } finally {
      _captureAdmissions.remove(done.future);
      done.complete();
    }
  }

  Future<void> clearCaptures() => _clearCaptureState(preserveApproved: false);

  Future<void> discardRemaining({
    Set<String> protectedIds = const <String>{},
  }) => _clearCaptureState(preserveApproved: true, protectedIds: protectedIds);

  Future<void> clearCompleted({DateTime? now}) =>
      _serializeItemUpdates<void>(() async {
        final ScanDraftStore? drafts = store;
        if (_disposed || drafts == null) return;
        final Set<String> retired = (await drafts.clearCompleted(now: now))
            .toSet();
        if (_disposed) return;
        _forgetItems(
          items
              .where((ScanSessionItem item) => retired.contains(item.id))
              .toList(),
        );
      });

  Future<bool> acceptCaptures(
    List<ScanSessionItem> captures, {
    bool Function()? isCurrent,
  }) {
    final ScanDraftStore? drafts = store;
    final int epoch = _captureEpoch;
    final List<ScanSessionItem> snapshot = List<ScanSessionItem>.of(captures);
    final Map<String, ScanCrop> crops = <String, ScanCrop>{
      for (final ScanSessionItem item in snapshot) item.id: item.crop,
    };
    bool current() =>
        _currentCapture(epoch) &&
        isCurrent?.call() != false &&
        snapshot.isNotEmpty &&
        crops.length == snapshot.length &&
        snapshot.every(
          (ScanSessionItem item) =>
              identical(_byId[item.id], item) &&
              identical(item.crop, crops[item.id]) &&
              !item.rescanPending &&
              !_removing.contains(item.id),
        );
    if (drafts == null || !current()) return Future<bool>.value(false);
    return _trackCaptureAdmission<bool>(
      () => _serializeItemUpdates<bool>(() async {
        if (!current()) return false;
        try {
          final bool accepted = await drafts.acceptCaptures(
            snapshot.map((ScanSessionItem item) => item.draft).toList(),
            isCurrent: current,
          );
          if (!accepted || !current()) return false;
          _failedCaptureAcceptanceIds.removeAll(crops.keys);
          if (_failedCaptureAcceptanceIds.isEmpty &&
              storageError == _acceptanceStorageError) {
            storageError = null;
            _notify();
          }
          return true;
        } catch (_) {
          if (current()) {
            _failedCaptureAcceptanceIds.addAll(crops.keys);
            storageError = _acceptanceStorageError;
            _notify();
          }
          return false;
        }
      }),
    );
  }

  Future<void> _clearCaptureState({
    required bool preserveApproved,
    Set<String> protectedIds = const <String>{},
  }) {
    if (_disposed) {
      return Future<void>.error(StateError('This scan session is closed.'));
    }
    if (_clearCaptures case final Future<void> pending) return pending;
    final bool wasPaused = paused;
    final int pauseRevision = _pauseRevision;
    final ScanDraftPhoto? active = _activePhoto;
    final ScanDraftRecovery? activeRecovery = _activeRecovery;
    final ScanDraftDetail? activeDetail = _activeDetail;
    _captureEpoch++;
    _clearingCaptures = true;
    paused = true;
    late final Future<void> pending;
    pending =
        _serializeItemUpdates<void>(() async {
          try {
            await Future.wait<void>(_captureAdmissions.toList());
            final Set<String> retained = <String>{};
            if (preserveApproved) {
              await store?.discardRemaining(protectedIds: protectedIds);
              retained.addAll(
                store == null
                    ? items
                          .where(
                            (ScanSessionItem item) =>
                                protectedIds.contains(item.id),
                          )
                          .map((ScanSessionItem item) => item.id)
                    : (await store!.readItems()).map(
                        (ScanDraftItem item) => item.id,
                      ),
              );
            } else {
              await store?.clearCaptures();
            }
            if (_disposed) return;
            for (final ScanSessionItem item in items) {
              if (!retained.contains(item.id)) {
                _releaseTemporary(item.crop.imagePath);
              }
            }
            _photos.clear();
            _recoveries.clear();
            _recoveryIds.clear();
            _details.clear();
            _detailJobs.clear();
            _detailSources.clear();
            _detailedPhotoIds.clear();
            _rescans.clear();
            _rescanFailures.clear();
            _failed.clear();
            items.removeWhere(
              (ScanSessionItem item) => !retained.contains(item.id),
            );
            _byId.removeWhere(
              (String id, ScanSessionItem _) => !retained.contains(id),
            );
            _unresolved.clear();
            _resolvingIds.clear();
            _removing.clear();
            _focusStacks.clear();
            _captureReadsByPhotoId.clear();
            _readCaptures.clear();
            _rawCaptureRegions.clear();
            _photoRefinements.clear();
            _removedLiveIds.clear();
            _removedPhotoRegions.clear();
            _liveReceiptIds.clear();
            _photoRefinementReceipts.clear();
            _pendingRefinementPhotoIds.clear();
            _explicitCapturesByPaths.clear();
            _diagnosticSources.clear();
            _capturePhotoIds.clear();
            _savedTargetAppearances.clear();
            _failedCaptureAcceptanceIds.clear();
            _failedLiveReceiptIds.clear();
            _failedReviewIds.retainAll(retained);
            _lastCameraPhoto = null;
            photosRead = 0;
            photosQueued = 0;
            storageError = _failedReviewIds.isEmpty
                ? null
                : _reviewStorageError;
            loaded = true;
          } catch (_) {
            if (!_disposed) {
              _clearingCaptures = false;
              _resolvingIds.clear();
              if (active != null &&
                  !_photos.any(
                    (ScanDraftPhoto photo) => photo.id == active.id,
                  ) &&
                  !_failed.any(
                    (ScanDraftPhoto photo) => photo.id == active.id,
                  )) {
                _photos.addFirst(active);
              }
              if (activeRecovery != null &&
                  !_recoveries.any(
                    (ScanDraftRecovery job) =>
                        job.itemId == activeRecovery.itemId,
                  )) {
                _recoveries.addFirst(activeRecovery);
              }
              if (activeDetail != null &&
                  !_details.any(
                    (ScanDraftDetail job) =>
                        job.photoId == activeDetail.photoId,
                  )) {
                _details.addFirst(activeDetail);
              }
              _pendingRefinementPhotoIds.clear();
              try {
                await _restoreItems(restoreImagePaths: true);
                await _restoreRescans(_captureEpoch);
                final Set<String> pendingIds = <String>{
                  ..._photos.map((ScanDraftPhoto photo) => photo.id),
                  ..._failed.map((ScanDraftPhoto photo) => photo.id),
                };
                for (final ScanDraftPhoto photo
                    in await store?.readPhotos() ?? <ScanDraftPhoto>[]) {
                  if (pendingIds.add(photo.id)) _photos.add(photo);
                  if (photo.refinementReceiptIds.isNotEmpty) {
                    _registerRefinementReceipts(
                      photo.id,
                      photo.refinementReceiptIds,
                    );
                  }
                }
              } catch (_) {}
              for (final ScanSessionItem item in items) {
                if (_canResolve(item) &&
                    !_unresolved.contains(item) &&
                    (item.resolution == null || item.error != null)) {
                  _unresolved.add(item);
                }
              }
              storageError = 'Could not clear the captured cards. Retry when storage is available.';
            }
            rethrow;
          } finally {
            _clearingCaptures = false;
            if (_pauseRevision == pauseRevision) paused = wasPaused;
            _notify();
            _pumpWorkers();
          }
        }).whenComplete(() {
          if (identical(_clearCaptures, pending)) _clearCaptures = null;
        });
    _clearCaptures = pending;
    _notify();
    return pending;
  }

  ScanSession({required this.recognizer, required this.resolver, this.store});

  int get remainingPhotos => _photos.length;
  int get pendingPhotoCaptures =>
      _photos.length +
      _failed.length +
      _recoveries.length +
      (_readerEpoch == _captureEpoch &&
              (_activePhotoId != null || _activeRecovery != null)
          ? 1
          : 0);
  int get pendingDetailSources => _detailJobs.values
      .where((ScanDraftDetail job) => job.presenceComplete)
      .length;
  bool get detailBackpressure => _detailJobs.length >= 16;
  int get failedPhotos =>
      _failed.length +
      _detailJobs.values.where((ScanDraftDetail job) => job.failed).length;
  int get pendingRecognitionCards => _unresolved.length + _resolvingIds.length;
  bool get recognitionBackpressure =>
      pendingRecognitionCards >= _maximumPendingRecognitionCards;

  bool captureReadComplete(List<String> paths) {
    if (_disposed ||
        paths.isEmpty ||
        paths.length > 5 ||
        paths.toSet().length != paths.length) {
      return false;
    }
    final String key = ScanDraftStore.focusStackCaptureId(paths);
    return _readCaptures.contains(key) &&
        !_captureReadsByPhotoId.values.contains(key);
  }

  bool captureDetailsPending(List<String> paths) {
    if (_disposed ||
        paths.isEmpty ||
        paths.length > 5 ||
        paths.toSet().length != paths.length) {
      return false;
    }
    final String key = ScanDraftStore.focusStackCaptureId(paths);
    final Set<String> photoIds = _capturePhotoIds[key] ?? const <String>{};
    return photoIds.any((String photoId) {
      final ScanDraftDetail? job = _detailJobs[photoId];
      return job != null && !job.failed;
    });
  }

  bool captureDetailsFailed(List<String> paths) {
    if (_disposed ||
        paths.isEmpty ||
        paths.length > 5 ||
        paths.toSet().length != paths.length) {
      return false;
    }
    final String key = ScanDraftStore.focusStackCaptureId(paths);
    return (_capturePhotoIds[key] ?? const <String>{}).any(
      (String photoId) => _detailJobs[photoId]?.failed == true,
    );
  }

  List<List<ScanPoint>> capturedRawRegions(List<String> paths) =>
      captureReadComplete(paths)
      ? _rawCaptureRegions[ScanDraftStore.focusStackCaptureId(paths)] ??
            const <List<ScanPoint>>[]
      : const <List<ScanPoint>>[];

  List<SavedTargetAppearance> captureTargetAppearances(List<String> paths) {
    if (_disposed || _clearingCaptures) return const <SavedTargetAppearance>[];
    final String key = ScanDraftStore.focusStackCaptureId(paths);
    return List<SavedTargetAppearance>.unmodifiable(
      (_capturePhotoIds[key] ?? const <String>{}).expand(
        (String photoId) =>
            _savedTargetAppearances[photoId] ?? const <SavedTargetAppearance>[],
      ),
    );
  }

  void _recordTargetAppearances(ScanDraftPhoto photo, ScanRecognition result) {
    if (result.imagePath != photo.imagePath ||
        !_capturePhotoIds.values.any(
          (Set<String> ids) => ids.contains(photo.id),
        )) {
      return;
    }
    final List<List<ScanPoint>> targets =
        photo.targetRegions ?? const <List<ScanPoint>>[];
    bool same(List<ScanPoint> a, List<ScanPoint> b) =>
        a.length == 4 &&
        b.length == 4 &&
        List<int>.generate(4, (int index) => index).every(
          (int index) =>
              (a[index].x - b[index].x).abs() <= .0001 &&
              (a[index].y - b[index].y).abs() <= .0001,
        );
    final List<SavedTargetAppearance> retained = List<SavedTargetAppearance>.of(
      _savedTargetAppearances[photo.id] ?? const <SavedTargetAppearance>[],
    );
    for (final List<ScanPoint> target in targets.take(8)) {
      if (!_validQuad(target) ||
          retained.any(
            (SavedTargetAppearance sample) => same(sample.corners, target),
          )) {
        continue;
      }
      final List<SavedTargetAppearance> matches = result.targetAppearances
          .where(
            (SavedTargetAppearance sample) =>
                sample.isValid && same(sample.corners, target),
          )
          .toList();
      if (matches.length != 1) continue;
      retained.add(
        SavedTargetAppearance(
          corners: List<ScanPoint>.unmodifiable(target),
          values: List<double>.unmodifiable(matches.single.values),
          present: true,
        ),
      );
    }
    if (retained.isNotEmpty) {
      _savedTargetAppearances[photo.id] =
          List<SavedTargetAppearance>.unmodifiable(retained);
    }
  }

  void _recordRawRegions(String photoId, Iterable<ScanCrop> crops) {
    final String? key = _captureReadsByPhotoId[photoId];
    if (_disposed || key == null) {
      return;
    }
    _rawCaptureRegions[key] = List<List<ScanPoint>>.unmodifiable(
      crops
          .map((ScanCrop crop) => crop.sourceCorners)
          .where(_validQuad)
          .take(40)
          .map(List<ScanPoint>.unmodifiable),
    );
  }

  void _registerCaptureRead(String photoId, List<String> paths) {
    final String key = ScanDraftStore.focusStackCaptureId(paths);
    _readCaptures.remove(key);
    _rawCaptureRegions.remove(key);
    _captureReadsByPhotoId[photoId] = key;
    _savedTargetAppearances.remove(photoId);
    final Set<String> registered = _capturePhotoIds.remove(key) ?? <String>{};
    registered.add(photoId);
    _capturePhotoIds[key] = registered;
    _pruneCapturePhotoIds();
  }

  void _pruneCapturePhotoIds() {
    final List<String> completed = _capturePhotoIds.entries
        .where(
          (MapEntry<String, Set<String>> entry) => !entry.value.any(
            (String photoId) =>
                _detailJobs.containsKey(photoId) ||
                _captureReadsByPhotoId.containsKey(photoId),
          ),
        )
        .map((MapEntry<String, Set<String>> entry) => entry.key)
        .toList();
    for (final String key in completed.take(
      completed.length > 32 ? completed.length - 32 : 0,
    )) {
      _capturePhotoIds.remove(key);
    }
    final Set<String> retained = _capturePhotoIds.values
        .expand((Set<String> ids) => ids)
        .toSet();
    _savedTargetAppearances.removeWhere(
      (String photoId, List<SavedTargetAppearance> _) =>
          !retained.contains(photoId),
    );
  }

  void _completeCaptureRead(String photoId) {
    final String? key = _captureReadsByPhotoId.remove(photoId);
    if (_disposed || key == null) return;
    _readCaptures.remove(key);
    _readCaptures.add(key);
    if (_readCaptures.length > 32) {
      final String oldest = _readCaptures.first;
      _readCaptures.remove(oldest);
      _rawCaptureRegions.remove(oldest);
    }
    _pruneCapturePhotoIds();
  }

  Iterable<ScanSessionItem> capturedItems(List<String> paths) {
    if (_disposed) return const <ScanSessionItem>[];
    final String captureId = ScanDraftStore.focusStackCaptureId(paths);
    final Set<String> photoIds = <String>{
      for (int index = 0; index < paths.length; index++) '${captureId}_$index',
      if (_explicitCapturesByPaths[captureId] != null)
        for (int index = 0; index < paths.length; index++)
          '${_explicitCapturesByPaths[captureId]}_$index',
      if (paths.length == 1 && _lastCameraPhoto?.path == paths.single)
        _lastCameraPhoto!.id,
    };
    final Set<String> receipts = <String>{
      for (final String photoId in photoIds)
        ...?_photoRefinementReceipts[photoId],
    };
    return items.where(
      (ScanSessionItem item) =>
          photoIds.contains(item.photoId) ||
          receipts.contains(item.liveCaptureReceiptId),
    );
  }

  Iterable<ScanSessionItem> _capturedItemsForLiveAdoption(List<String> paths) {
    final String captureId = ScanDraftStore.focusStackCaptureId(paths);
    final Set<String> admittedPhotoIds =
        _capturePhotoIds[captureId] ?? const <String>{};
    final Set<String> currentIds = capturedItems(paths)
        .map((ScanSessionItem item) => item.id)
        .toSet();
    return items.where(
      (ScanSessionItem item) =>
          currentIds.contains(item.id) ||
          admittedPhotoIds.contains(item.photoId),
    );
  }

  Future<T> _serializeItemUpdates<T>(Future<T> Function() operation) {
    final Future<T> next = _itemUpdates.then((_) => operation());
    _itemUpdates = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<bool> adoptLiveIdentities(
    List<String> paths,
    List<({String id, ScanCrop crop, ScanResolution resolution})> identities, {
    ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
  }) {
    final int epoch = _captureEpoch;
    if (!_currentCapture(epoch)) return Future<bool>.value(false);
    if (paths.isEmpty ||
        paths.length > 5 ||
        paths.any((String path) => path.isEmpty) ||
        paths.toSet().length != paths.length) {
      return Future<bool>.value(false);
    }
    return _serializeItemUpdates<bool>(
      () => _adoptLiveCapture(
        ScanDraftStore.focusStackCaptureId(paths),
        identities,
        paths: paths,
        defaults: defaults,
        epoch: epoch,
      ),
    );
  }

  Future<bool> adoptLiveCapture(
    String captureId,
    List<({String id, ScanCrop crop, ScanResolution resolution})> identities, {
    ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
  }) {
    final int epoch = _captureEpoch;
    if (!_currentCapture(epoch)) return Future<bool>.value(false);
    return _serializeItemUpdates<bool>(
      () => _adoptLiveCapture(
        captureId,
        identities,
        epoch: epoch,
        defaults: defaults,
      ),
    );
  }

  void releaseLivePhotoReservation(LiveCaptureSnapshot capture) {
    if (_disposed || _clearingCaptures) return;
    if (capture.retainedObservations.any(
      (LiveCaptureObservation observation) =>
          observation.isRefinement &&
          observation.photoCaptureId == capture.captureId,
    )) {
      _pendingRefinementPhotoIds.remove('${capture.captureId}_0');
    }
  }

  Future<bool> adoptLiveObservations(
    List<LiveCaptureObservation> observations, {
    ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
  }) {
    final int epoch = _captureEpoch;
    if (!_currentCapture(epoch)) return Future<bool>.value(false);
    return _serializeItemUpdates<bool>(() async {
      if (!_currentCapture(epoch) ||
          observations.isEmpty ||
          observations.length > 8) {
        return false;
      }
      final String captureId = observations.first.captureId;
      final String photoCaptureId = observations.first.photoCaptureId;
      if (observations.any(
            (LiveCaptureObservation observation) =>
                observation.captureId != captureId ||
                observation.photoCaptureId != photoCaptureId ||
                !_validQuad(observation.crop.sourceCorners),
          ) ||
          observations
                  .map((LiveCaptureObservation value) => value.id)
                  .toSet()
                  .length !=
              observations.length) {
        return false;
      }
      final Set<String> photoIds = <String>{
        for (int index = 0; index < 5; index++) '${captureId}_$index',
      };
      final List<({ScanSessionItem item, ScanSessionItem? prior})> adopted =
          <({ScanSessionItem item, ScanSessionItem? prior})>[];
      final Set<String> receiptIds = <String>{};
      final Set<String> itemIds = <String>{};
      for (final LiveCaptureObservation observation in observations) {
        final String receiptId = observation.receiptId;
        if (_removedLiveIds.contains(receiptId)) return false;
        final List<ScanSessionItem> matches = items
            .where(
              (ScanSessionItem item) =>
                  photoIds.contains(item.photoId) &&
                  _sameCapturedRegion(observation.crop, item.crop),
            )
            .toList();
        if (matches.length > 1) return false;
        final ScanSessionItem? prior =
            _byId[receiptId] ??
            (observation.isRefinement
                ? items
                      .where(
                        (ScanSessionItem item) =>
                            item.liveCaptureReceiptId == receiptId,
                      )
                      .firstOrNull
                : matches.firstOrNull);
        if (observation.isRefinement && prior == null) return false;
        final String id = prior?.id ?? receiptId;
        if (_removing.contains(id) || !itemIds.add(id)) return false;
        receiptIds.add(receiptId);
        final ScanSessionItem item = prior == null
            ? ScanSessionItem(
                _cropWithImage(observation.crop, ''),
                id: receiptId,
                photoId: '${captureId}_0',
                defaults: defaults,
              )
            : ScanSessionItem.fromDraft(prior.draft);
        item.liveCaptureReceiptId = receiptId;
        adopted.add((item: item, prior: prior));
      }
      final String refinementPhotoId = '${photoCaptureId}_0';
      if (photoCaptureId != captureId) {
        if (!_registerRefinementReceipts(refinementPhotoId, receiptIds)) {
          return false;
        }
        _pendingRefinementPhotoIds.add(refinementPhotoId);
      }
      try {
        final List<ScanDraftItem>? saved = await store?.upsertItems(
          adopted.map((entry) => entry.item.draft).toList(),
        );
        if (!_currentCapture(epoch)) return false;
        for (int index = 0; index < adopted.length; index++) {
          final ScanSessionItem item = adopted[index].item;
          final ScanSessionItem? prior = adopted[index].prior;
          if (saved != null) item.crop = saved[index].crop;
          if (_removedLiveIds.contains(item.liveCaptureReceiptId) ||
              _removing.contains(item.id)) {
            await store?.removeItems(<String>[item.id]);
            _pendingRefinementPhotoIds.remove(refinementPhotoId);
            return false;
          }
          if (prior != null) {
            prior.liveCaptureReceiptId = item.liveCaptureReceiptId;
            if (prior.approval != null || prior.manuallyReviewed) {
              await store?.upsertItems(<ScanDraftItem>[prior.draft]);
            }
          } else {
            add(item);
          }
          _liveReceiptIds[item.id] = item.liveCaptureReceiptId!;
          final ScanSessionItem target = prior ?? item;
          if (target.resolution == null &&
              _canResolve(target) &&
              !_unresolved.contains(target) &&
              !_resolvingIds.contains(target.id)) {
            _unresolved.add(target);
          }
        }
        _failedLiveReceiptIds.removeAll(receiptIds);
        if (_failedLiveReceiptIds.isEmpty &&
            storageError == _liveStorageError) {
          storageError = null;
        }
        _notify();
        unawaited(_run());
        return true;
      } catch (_) {
        if (!_currentCapture(epoch)) return false;
        _pendingRefinementPhotoIds.remove(refinementPhotoId);
        _failedLiveReceiptIds.addAll(receiptIds);
        storageError ??= _liveStorageError;
        _notify();
        return false;
      }
    });
  }

  Future<bool> _adoptLiveCapture(
    String captureId,
    List<({String id, ScanCrop crop, ScanResolution resolution})> identities, {
    List<String>? paths,
    required int epoch,
    required ScanCaptureDefaults defaults,
  }) async {
    if (!_currentCapture(epoch) ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(captureId) ||
        identities.isEmpty ||
        identities.length > 8 ||
        identities.map((identity) => identity.id).toSet().length !=
            identities.length) {
      return false;
    }
    for (final ({String id, ScanCrop crop, ScanResolution resolution}) identity
        in identities) {
      if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(identity.id) ||
          !_validQuad(identity.crop.sourceCorners) ||
          _liveIdentityName(identity.resolution, identity.crop) == null) {
        return false;
      }
    }
    for (final ({String id, ScanCrop crop, ScanResolution resolution}) identity
        in identities) {
      if (!_currentCapture(epoch)) return false;
      String receiptId = 'live_${captureId}_${identity.id}';
      if (_removedLiveIds.contains(receiptId)) return false;
      final Iterable<ScanSessionItem> captureItems = paths == null
          ? items.where(
              (ScanSessionItem item) =>
                  <String>{
                    for (int index = 0; index < 5; index++)
                      '${captureId}_$index',
                  }.contains(item.photoId) ||
                  (_photoRefinementReceipts['${captureId}_0']?.contains(
                        item.liveCaptureReceiptId,
                      ) ??
                      false),
            )
          : _capturedItemsForLiveAdoption(paths);
      final List<ScanSessionItem> matches = captureItems
          .where(
            (ScanSessionItem item) =>
                _sameCapturedRegion(identity.crop, item.crop),
          )
          .toList();
      if (matches.length > 1) return false;
      final ScanSessionItem? prior = _byId[receiptId] ?? matches.firstOrNull;
      final Set<String>? refinementReceipts =
          _photoRefinementReceipts['${captureId}_0'];
      if (refinementReceipts != null &&
          (prior == null ||
              !refinementReceipts.contains(prior.liveCaptureReceiptId))) {
        return false;
      }
      receiptId = prior?.liveCaptureReceiptId ?? receiptId;
      if (_removedLiveIds.contains(receiptId)) return false;
      final String id = prior?.id ?? receiptId;
      if (prior != null && (prior.approval != null || prior.manuallyReviewed)) {
        continue;
      }
      final ScanSessionItem adopted =
          ScanSessionItem(
              _cropWithImage(
                identity.crop,
                prior?.crop.imagePath ?? identity.crop.imagePath,
              ),
              id: id,
              defaults: prior?.defaults ?? defaults,
              photoId:
                  prior?.photoId ??
                  _capturePhotoIds[captureId]?.firstOrNull ??
                  '${captureId}_0',
            )
            ..resolution = _sessionResolution(
              ScanResolution(
                candidates: identity.resolution.candidates,
                hints: identity.resolution.hints,
                status: ScanResolutionStatus.needsReview,
                hasMore: identity.resolution.hasMore,
                page: identity.resolution.page,
                historicalBodyIdentityProof:
                    identity.resolution.historicalBodyIdentityProof,
              ),
            )
            ..selected = prior?.selected ?? false
            ..liveCaptureReceiptId = receiptId
            ..liveIdentityName = _liveIdentityName(
              identity.resolution,
              identity.crop,
            );
      try {
        final List<ScanDraftItem>? saved = await store?.upsertItems(
          <ScanDraftItem>[adopted.draft],
        );
        if (saved != null) adopted.crop = saved.single.crop;
        if (!_currentCapture(epoch)) return false;
        if (prior != null &&
            (prior.approval != null || prior.manuallyReviewed)) {
          await store?.upsertItems(<ScanDraftItem>[prior.draft]);
          continue;
        }
        if (prior != null) {
          prior.crop = adopted.crop;
          prior.resolution = adopted.resolution;
          prior.liveIdentityName = adopted.liveIdentityName;
          prior.liveCaptureReceiptId = adopted.liveCaptureReceiptId;
          prior.error = null;
        } else {
          add(adopted);
        }
        _liveReceiptIds[id] = receiptId;
        _failedLiveReceiptIds.remove(receiptId);
        if (_failedLiveReceiptIds.isEmpty &&
            storageError == _liveStorageError) {
          storageError = null;
        }
      } catch (_) {
        if (!_currentCapture(epoch)) return false;
        _failedLiveReceiptIds.add(receiptId);
        storageError ??= _liveStorageError;
        _notify();
        return false;
      }
    }
    _notify();
    return _currentCapture(epoch);
  }

  List<ScanSessionItem> _liveItemsForPhoto(String photoId) {
    final String? key = _captureReadsByPhotoId[photoId];
    return items
        .where(
          (ScanSessionItem item) =>
              (item.liveIdentityName != null ||
                  item.liveCaptureReceiptId != null) &&
              (item.photoId == photoId ||
                  (_photoRefinementReceipts[photoId]?.contains(
                        item.liveCaptureReceiptId,
                      ) ??
                      false) ||
                  (key != null &&
                      (item.photoId == '${key}_0' ||
                          _capturePhotoIds[key]?.contains(item.photoId) ==
                              true))) &&
              !_removing.contains(item.id),
        )
        .toList();
  }

  Future<List<ScanSessionItem>> _commitRecognized(
    List<ScanCrop> crops,
    List<String> photoIds,
    ScanDraftPhoto root, {
    List<ScanDraftPhoto>? focusPhotos,
    List<int>? cropIndexes,
    required int epoch,
  }) => _serializeItemUpdates<List<ScanSessionItem>>(() async {
    if (!_currentCapture(epoch)) return const <ScanSessionItem>[];
    final List<ScanSessionItem> recognized = <ScanSessionItem>[];
    if (root.refinementReceiptIds.isNotEmpty) {
      _registerRefinementReceipts(root.id, root.refinementReceiptIds);
    }
    final Map<String, ScanSessionItem> owned = <String, ScanSessionItem>{
      for (final ScanSessionItem item in _liveItemsForPhoto(root.id))
        item.id: item,
      for (final ScanSessionItem item in items)
        if (root.refinementReceiptIds.contains(item.liveCaptureReceiptId) &&
            !_removing.contains(item.id))
          item.id: item,
    };
    final List<ScanSessionItem> live = owned.values.toList();
    final Set<String> matched = <String>{};
    for (int index = 0; index < crops.length; index++) {
      final ScanCrop observed = crops[index];
      final ScanCrop crop = ScanCrop(
        imagePath: observed.imagePath,
        width: observed.width,
        height: observed.height,
        rectified: observed.rectified,
        sourceCorners: observed.sourceCorners,
        warnings: observed.warnings,
        sharpness: observed.sharpness,
        lines: observed.lines
            .where(
              (ScanTextLine line) =>
                  line.confidence.isFinite &&
                  line.confidence >= .30 &&
                  line.confidence <= 1,
            )
            .take(64)
            .toList(),
      );
      final List<ScanSessionItem> matches = live
          .where((ScanSessionItem item) => _sameCapturedRegion(item.crop, crop))
          .toList();
      // A broad or ambiguous crop cannot create another quantity for an owned region.
      if (matches.isNotEmpty ||
          live.any(
            (ScanSessionItem item) => _capturedRegionsOverlap(item.crop, crop),
          )) {
        if (matches.length == 1 && matched.add(matches.single.id)) {
          final ScanSessionItem item = matches.single;
          if (item.approval == null && !item.manuallyReviewed) {
            _photoRefinements[item.id] = crop;
            item.crop = _cropWithImage(item.crop, crop.imagePath);
          }
          recognized.add(item);
        } else {
          _releaseTemporary(crop.imagePath);
        }
        continue;
      }
      if (root.refinementReceiptIds.isNotEmpty) {
        _releaseTemporary(crop.imagePath);
        continue;
      }
      final String id = '${root.id}_${cropIndexes?[index] ?? index}';
      final ScanSessionItem? existing = _byId[id];
      if (existing != null) {
        recognized.add(existing);
        _releaseTemporary(crop.imagePath);
      } else {
        recognized.add(
          ScanSessionItem(
            crop,
            id: id,
            photoId: photoIds[index],
            defaults: root.defaults,
          ).._detailsPending = _detailJobs.containsKey(root.id),
        );
      }
    }
    if (store != null) {
      final List<ScanDraftItem> saved = focusPhotos == null
          ? await store!.completePhoto(
              root.id,
              recognized.map((ScanSessionItem item) => item.draft).toList(),
            )
          : await store!.completeFocusStack(
              focusPhotos,
              recognized.map((ScanSessionItem item) => item.draft).toList(),
            );
      for (int index = 0; index < recognized.length; index++) {
        final ScanSessionItem item = recognized[index];
        _releaseTemporary(item.crop.imagePath);
        item.crop = saved[index].crop;
        final ScanCrop? refinement = _photoRefinements[item.id];
        if (refinement != null) {
          _photoRefinements[item.id] = _cropWithImage(
            refinement,
            item.crop.imagePath,
          );
        }
      }
    }
    if (!_currentCapture(epoch)) return const <ScanSessionItem>[];
    for (final ScanSessionItem item in recognized) {
      if (!_byId.containsKey(item.id)) {
        add(item);
        _unresolved.add(item);
      } else if (_photoRefinements.containsKey(item.id) &&
          _canResolve(item) &&
          !_unresolved.contains(item) &&
          !_resolvingIds.contains(item.id)) {
        _unresolved.add(item);
      }
    }
    return recognized;
  });

  Future<void> load() {
    if (_clearingCaptures) return _clearCaptures!.then((_) => load());
    if (loaded) return Future<void>.value();
    return _loading ??= _load(_captureEpoch)
        .whenComplete(() => _loading = null);
  }

  Future<void> _restoreItems({bool restoreImagePaths = false}) async {
    final int epoch = _captureEpoch;
    final List<ScanDraftItem> restored =
        await store?.readItems() ?? <ScanDraftItem>[];
    if (!_currentCapture(epoch)) return;
    for (final ScanDraftItem draft in restored) {
      final ScanSessionItem? existing = _byId[draft.id];
      if (existing != null) {
        if (existing.photoId != draft.photoId) {
          final ScanSessionItem replacement = ScanSessionItem.fromDraft(draft);
          final int index = items.indexOf(existing);
          if (index >= 0) items[index] = replacement;
          _byId[draft.id] = replacement;
          _unresolved.remove(existing);
          _photoRefinements.remove(draft.id);
          _liveReceiptIds.remove(draft.id);
          if (replacement.resolution == null && replacement.approval == null) {
            _unresolved.add(replacement);
          }
        } else if (restoreImagePaths) {
          existing.crop = draft.crop;
        }
        continue;
      }
      final ScanSessionItem item = ScanSessionItem.fromDraft(draft);
      add(item);
      if (item.liveCaptureReceiptId != null) {
        _liveReceiptIds[item.id] = item.liveCaptureReceiptId!;
      }
      if (item.resolution == null && item.approval == null) {
        _unresolved.add(item);
      }
    }
  }

  Future<void> _restoreRescans(int epoch) async {
    final List<ScanDraftRescan> requests =
        await store?.readRescans() ?? const <ScanDraftRescan>[];
    if (!_currentCapture(epoch)) return;
    _rescans.clear();
    for (final ScanSessionItem item in items) {
      item._rescanPending = false;
      item._replacementChoices = null;
    }
    for (final ScanDraftRescan request in requests) {
      final ScanSessionItem? item = _byId[request.itemId];
      if (item == null) continue;
      item._replacementChoices = request.choices ?? request.original?.approval;
      if (!request.complete) {
        item._rescanPending = true;
        _rescans[item.id] = request;
        _unresolved.remove(item);
      }
    }
  }

  Future<void> _load(int epoch) async {
    try {
      await _restoreItems();
      if (!_currentCapture(epoch)) return;
      await _restoreRescans(epoch);
      if (!_currentCapture(epoch)) return;
      final Set<String> pending = <String>{
        ..._photos.map((ScanDraftPhoto photo) => photo.id),
        ..._failed.map((ScanDraftPhoto photo) => photo.id),
      };
      final List<ScanDraftPhoto> restoredPhotos =
          await store?.readPhotos() ?? <ScanDraftPhoto>[];
      if (!_currentCapture(epoch)) return;
      for (final ScanDraftPhoto photo in restoredPhotos) {
        if (photo.refinementReceiptIds.isNotEmpty) {
          _registerRefinementReceipts(photo.id, photo.refinementReceiptIds);
        }
        if (pending.add(photo.id)) _photos.add(photo);
      }
      for (final ScanDraftRecovery job
          in await store?.readRecoveries() ?? <ScanDraftRecovery>[]) {
        final ScanSessionItem? item = _byId[job.itemId];
        if (item != null && _canResolve(item) && _recoveryIds.add(job.itemId)) {
          item._retrying = true;
          _recoveries.add(job);
          _unresolved.remove(item);
        }
      }
      for (final ScanDraftDetail job
          in await store?.readDetails() ?? <ScanDraftDetail>[]) {
        _detailJobs[job.photoId] = job;
        for (final ScanSessionItem item in items.where(
          (ScanSessionItem item) => item.photoId == job.photoId,
        )) {
          item._detailsPending = true;
        }
        final ScanDraftPhoto? source = await store?.readSource(job.photoId);
        if (!_currentCapture(epoch)) return;
        if (source != null) _detailSources[job.photoId] = source;
        if (job.presenceComplete && !job.failed) _details.add(job);
      }
      photosQueued = _photos.length;
      loaded = true;
      _notify();
      unawaited(_run());
    } catch (_) {
      if (_currentCapture(epoch)) rethrow;
    }
  }

  void add(ScanSessionItem item) {
    if (_disposed || _clearingCaptures || _byId.containsKey(item.id)) return;
    _byId[item.id] = item;
    items.add(item);
  }

  Future<bool> addPhotos(
    Iterable<String> paths, {
    required bool multipleCards,
    bool ownedCameraSource = false,
    List<List<ScanPoint>> excludedRegions = const <List<ScanPoint>>[],
    ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
  }) => _trackCaptureAdmission<bool>(
    () => _addPhotos(
      paths,
      multipleCards: multipleCards,
      ownedCameraSource: ownedCameraSource,
      excludedRegions: excludedRegions,
      defaults: defaults,
      epoch: _captureEpoch,
    ),
  );

  Future<bool> _addPhotos(
    Iterable<String> paths, {
    required bool multipleCards,
    required bool ownedCameraSource,
    required List<List<ScanPoint>> excludedRegions,
    required ScanCaptureDefaults defaults,
    required int epoch,
  }) async {
    if (!_currentCapture(epoch)) return false;
    try {
      final List<List<ScanPoint>> frozen = ScanDraftPhoto.freezeExcludedRegions(
        excludedRegions,
      );
      // Import one photo at a time so earlier photos can be recognized while a large gallery import continues.
      for (final String path in paths) {
        if (!_currentCapture(epoch)) return false;
        final ScanDraftPhoto photo = store == null
            ? ScanDraftPhoto(
                id: const Uuid().v4(),
                imagePath: path,
                multipleCards: multipleCards,
                createdAt: DateTime.now(),
                excludedRegions: frozen,
                defaults: defaults,
              )
            : (await store!.importPhotos(
                <String>[path],
                multipleCards: multipleCards,
                ownedCameraSource: ownedCameraSource,
                excludedRegions: frozen,
                defaults: defaults,
              )).single;
        if (epoch != _captureEpoch || _clearingCaptures) return false;
        if (storageError == ScanDraftStorageBudgetExceeded.userMessage) {
          storageError = null;
        }
        // An admitted import is durable even if its screen closed while copying.
        if (!_disposed) {
          _lastCameraPhoto = ownedCameraSource
              ? (path: path, id: photo.id)
              : null;
          _registerCaptureRead(photo.id, <String>[path]);
          _photos.add(photo);
          photosQueued++;
          _notify();
          unawaited(_run());
        }
      }
      return true;
    } catch (error) {
      if (!_currentCapture(epoch)) return false;
      storageError = error is ScanDraftStorageBudgetExceeded
          ? ScanDraftStorageBudgetExceeded.userMessage
          : 'Could not save every photo on this device. Free storage, then select the remaining photos again.';
      _notify();
      return false;
    }
  }

  Future<bool> addFocusStack(
    List<String> paths, {
    bool ownedCameraSource = false,
    String? captureId,
    bool diagnosticOnly = false,
    bool preferFastPresence = false,
    List<List<ScanPoint>>? targetRegions,
    List<List<ScanPoint>> excludedRegions = const <List<ScanPoint>>[],
    ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
  }) => _trackCaptureAdmission<bool>(
    () => _addFocusStack(
      paths,
      ownedCameraSource: ownedCameraSource,
      captureId: captureId,
      diagnosticOnly: diagnosticOnly,
      preferFastPresence: preferFastPresence,
      targetRegions: targetRegions,
      excludedRegions: excludedRegions,
      defaults: defaults,
      epoch: _captureEpoch,
    ),
  );

  Future<bool> _addFocusStack(
    List<String> paths, {
    required bool ownedCameraSource,
    required String? captureId,
    required bool diagnosticOnly,
    required bool preferFastPresence,
    required List<List<ScanPoint>>? targetRegions,
    required List<List<ScanPoint>> excludedRegions,
    required ScanCaptureDefaults defaults,
    required int epoch,
  }) async {
    if (!_currentCapture(epoch)) return false;
    if ((captureId != null &&
            !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(captureId)) ||
        paths.isEmpty ||
        paths.length > 5 ||
        paths.toSet().length != paths.length) {
      throw ArgumentError.value(paths, 'paths');
    }
    final List<List<ScanPoint>>? targets = ScanDraftPhoto.freezeTargetRegions(
      targetRegions,
    );
    try {
      final String sourceKey = ScanDraftStore.focusStackCaptureId(paths);
      if (captureId != null) {
        final String? retained = _diagnosticSources[captureId];
        if (retained != null && retained != sourceKey) return false;
        if (retained == sourceKey && _readCaptures.contains(sourceKey)) {
          return true;
        }
      }
      final List<List<ScanPoint>> frozen = ScanDraftPhoto.freezeExcludedRegions(
        excludedRegions,
      );
      final List<String> refinementReceipts = captureId == null
          ? const <String>[]
          : (_photoRefinementReceipts['${captureId}_0'] ?? const <String>{})
                .toList();
      final List<ScanDraftPhoto> photos = store == null
          ? paths.indexed
                .map(
                  ((int, String) entry) => ScanDraftPhoto(
                    id: captureId == null
                        ? const Uuid().v4()
                        : '${captureId}_${entry.$1}',
                    imagePath: entry.$2,
                    multipleCards: true,
                    diagnosticOnly: diagnosticOnly,
                    createdAt: DateTime.now(),
                    excludedRegions: frozen,
                    targetRegions: targets,
                    refinementReceiptIds: refinementReceipts,
                    defaults: defaults,
                  ),
                )
                .toList()
          : await store!.importFocusStack(
              paths,
              ownedCameraSource: ownedCameraSource,
              diagnosticOnly: diagnosticOnly,
              captureId: captureId,
              refinementReceiptIds: refinementReceipts,
              excludedRegions: frozen,
              targetRegions: targets,
              defaults: defaults,
            );
      if (epoch != _captureEpoch || _clearingCaptures) return false;
      if (storageError == ScanDraftStorageBudgetExceeded.userMessage) {
        storageError = null;
      }
      if (!_disposed) {
        if (captureId != null) {
          _diagnosticSources.remove(captureId);
          _diagnosticSources[captureId] = sourceKey;
          _explicitCapturesByPaths.remove(sourceKey);
          _explicitCapturesByPaths[sourceKey] = captureId;
          if (_diagnosticSources.length > 32) {
            _diagnosticSources.remove(_diagnosticSources.keys.first);
          }
          if (_explicitCapturesByPaths.length > 32) {
            _explicitCapturesByPaths.remove(
              _explicitCapturesByPaths.keys.first,
            );
          }
        }
        _lastCameraPhoto = null;
        _registerCaptureRead(photos.first.id, paths);
        if (_activePhotoId == photos.first.id ||
            _focusStacks.containsKey(photos.first.id) ||
            _photos.any(
              (ScanDraftPhoto photo) => photo.id == photos.first.id,
            ) ||
            _failed.any(
              (ScanDraftPhoto photo) => photo.id == photos.first.id,
            )) {
          return true;
        }
        if (await store?.focusStackComplete(photos.first.id) == true) {
          if (!_currentCapture(epoch)) return false;
          _completeCaptureRead(photos.first.id);
          if (!_disposed) await _restoreItems();
          return true;
        }
        if (epoch != _captureEpoch || _clearingCaptures) return false;
        if (_disposed) return true;
        final bool staged =
            preferFastPresence &&
            paths.length == 1 &&
            !diagnosticOnly &&
            targets?.isNotEmpty == true &&
            recognizer is CapturePresenceRecognizer &&
            (recognizer as CapturePresenceRecognizer).supportsCapturePresence;
        if (staged) {
          if (_detailJobs.length >= 16 &&
              !_detailJobs.containsKey(photos.first.id)) {
            throw StateError('Saved capture detail queue is full.');
          }
          final ScanDraftDetail job =
              await store?.scheduleDetail(photos.first.id) ??
              ScanDraftDetail(
                photoId: photos.first.id,
                presenceComplete: false,
              );
          if (!_currentCapture(epoch)) return false;
          _detailJobs[job.photoId] = job;
          _detailSources[job.photoId] = photos.first;
        }
        _focusStacks[photos.first.id] = photos;
        _photos.add(photos.first);
        photosQueued += photos.length;
        _notify();
        unawaited(_run());
      }
      return true;
    } catch (error) {
      if (!_currentCapture(epoch)) return false;
      if (!diagnosticOnly) {
        storageError = error is ScanDraftStorageBudgetExceeded
            ? ScanDraftStorageBudgetExceeded.userMessage
            : 'Could not save the focus photos on this device. Free storage and retry.';
      }
      _notify();
      return false;
    } finally {
      if (captureId != null && epoch == _captureEpoch) {
        _pendingRefinementPhotoIds.remove('${captureId}_0');
      }
    }
  }

  Future<void> _recognizeFocusStack(
    ScanDraftPhoto root,
    List<ScanDraftPhoto> photos,
    int epoch,
  ) async {
    final List<ScanRecognition> recognition = <ScanRecognition>[];
    final List<ScanRecognition> filtered = <ScanRecognition>[];
    int excludedCount = 0;
    try {
      for (final ScanDraftPhoto photo in photos) {
        if (!_currentCapture(epoch)) return;
        final ScanDraftDetail? detail = _detailJobs[root.id];
        final bool presence =
            detail != null &&
            !detail.presenceComplete &&
            photos.length == 1 &&
            recognizer is CapturePresenceRecognizer &&
            (recognizer as CapturePresenceRecognizer).supportsCapturePresence;
        _readerUsesPresence = presence;
        if (presence) _pumpWorkers();
        if (!presence && _detailReaderRunning) await _detailIdle?.future;
        if (!_currentCapture(epoch)) return;
        final ScanRecognition result = presence
            ? await (recognizer as CapturePresenceRecognizer).recognizePresence(
                photo.imagePath,
                multipleCards: true,
                targetRegions: photo.targetRegions ?? const <List<ScanPoint>>[],
              )
            : await recognizer.recognize(
                photo.imagePath,
                multipleCards: true,
                targetRegions: photo.targetRegions ?? const <List<ScanPoint>>[],
              );
        recognition.add(result);
        if (_currentCapture(epoch)) _recordTargetAppearances(photo, result);
        final List<ScanCrop> remaining = result.crops
            .where((ScanCrop crop) => _retainsPhotoCrop(crop, photo))
            .toList();
        excludedCount += result.crops.length - remaining.length;
        filtered.add(
          ScanRecognition(
            imagePath: result.imagePath,
            width: result.width,
            height: result.height,
            crops: remaining,
          ),
        );
      }
      if (!_currentCapture(epoch)) return;
      final List<ScanFocusSelection> selected = mergeScanFocusStack(
        filtered,
        retainUnreadableContours: photos.every(
          (ScanDraftPhoto photo) => photo.targetRegions?.isNotEmpty == true,
        ),
      );
      if (selected.isEmpty &&
          !_detailJobs.containsKey(root.id) &&
          (photos.any(
                (ScanDraftPhoto photo) =>
                    !photo.diagnosticOnly &&
                    photo.targetRegions?.isNotEmpty == true,
              ) ||
              !(excludedCount > 0 &&
                  filtered.every(
                    (ScanRecognition result) => result.crops.isEmpty,
                  )))) {
        throw StateError('No readable cards in the focus photos.');
      }
      await _commitRecognized(
        selected.map((ScanFocusSelection selection) => selection.crop).toList(),
        selected
            .map(
              (ScanFocusSelection selection) => photos[selection.photoIndex].id,
            )
            .toList(),
        root,
        focusPhotos: photos,
        epoch: epoch,
      );
      if (!_currentCapture(epoch)) return;
      if (_detailJobs.containsKey(root.id)) {
        final ScanDraftDetail next = ScanDraftDetail(
          photoId: root.id,
          presenceComplete: true,
        );
        await store?.updateDetail(next);
        if (!_currentCapture(epoch)) return;
        _detailJobs[root.id] = next;
        _details.add(next);
      }
      _focusStacks.remove(root.id);
      _recordRawRegions(
        root.id,
        filtered.expand((ScanRecognition photo) => photo.crops),
      );
    } finally {
      _readerUsesPresence = false;
      final Set<String> retained = store == null
          ? items.map((ScanSessionItem item) => item.crop.imagePath).toSet()
          : <String>{};
      for (final ScanRecognition photo in recognition) {
        for (final ScanCrop crop in photo.crops) {
          if (!retained.contains(crop.imagePath)) {
            _releaseTemporary(crop.imagePath);
          }
        }
      }
    }
  }

  void pause() {
    _pauseRevision++;
    paused = true;
    _notify();
  }

  void resume() {
    _pauseRevision++;
    paused = false;
    unawaited(_run());
  }

  Future<void> retryUnresolved() async {
    final int epoch = _captureEpoch;
    if (running || !_currentCapture(epoch)) return;
    await _restoreItems();
    if (!_currentCapture(epoch)) return;
    final List<ScanSessionItem> failedAcceptances = items
        .where(
          (ScanSessionItem item) =>
              _failedCaptureAcceptanceIds.contains(item.id),
        )
        .toList();
    if (failedAcceptances.isNotEmpty &&
        !await acceptCaptures(failedAcceptances)) {
      return;
    }
    if (!_currentCapture(epoch)) return;
    _photos.addAll(_failed);
    _failed.clear();
    for (final ScanDraftDetail job
        in _detailJobs.values
            .where((ScanDraftDetail job) => job.failed)
            .toList()) {
      final ScanDraftDetail retry = ScanDraftDetail(
        photoId: job.photoId,
        presenceComplete: true,
      );
      await store?.updateDetail(retry);
      if (!_currentCapture(epoch)) return;
      _detailJobs[job.photoId] = retry;
      _details.add(retry);
    }
    _unresolved.clear();
    for (final ScanSessionItem item in items) {
      if (!_canResolve(item) || _recoveryIds.contains(item.id)) continue;
      if (item.resolution?.candidates.isEmpty == true) {
        if (await _queueRecovery(item, epoch, manual: true)) continue;
      }
      if (item.error != null ||
          item.resolution == null ||
          item.resolution!.candidates.isEmpty) {
        item.error = null;
        item.resolution = null;
        _unresolved.add(item);
      }
    }
    paused = false;
    await _run();
  }

  Future<void> retryItem(ScanSessionItem item) async {
    final Completer<void>? active = _itemRetries[item.id]?.done;
    if (active != null) {
      await active.future;
      return;
    }
    final int epoch = _captureEpoch;
    if (!_currentCapture(epoch) ||
        !_canResolve(item) ||
        item._detailsPending ||
        _recoveryIds.contains(item.id) ||
        _resolvingIds.contains(item.id)) {
      return;
    }
    final bool queued =
        item.resolution?.candidates.isEmpty == true &&
        await _queueRecovery(item, epoch, manual: true);
    if (!_currentCapture(epoch) || !_canResolve(item)) return;
    if (!queued && !_unresolved.contains(item)) {
      item.error = null;
      item.resolution = null;
      item._retrying = true;
      _unresolved.add(item);
    }
    final Completer<void> done = Completer<void>();
    _itemRetries[item.id] = (epoch: epoch, item: item, done: done);
    paused = false;
    unawaited(_run());
    await done.future;
  }

  Future<void> beginRescan(ScanSessionItem item) async {
    final int epoch = _captureEpoch;
    final ScanDraftStore? drafts = store;
    if (drafts == null ||
        !_currentCapture(epoch) ||
        !identical(_byId[item.id], item) ||
        _removing.contains(item.id)) {
      throw StateError('The captured card is no longer available.');
    }
    item._rescanPending = true;
    _notify();
    try {
      final ScanDraftRescan request = await _serializeItemUpdates(() async {
        if (!_currentCapture(epoch) || !identical(_byId[item.id], item)) {
          throw StateError('The captured card changed.');
        }
        return drafts.beginRescan(item.id);
      });
      if (!_currentCapture(epoch) || !identical(_byId[item.id], item)) return;
      _rescans[item.id] = request;
      _unresolved.remove(item);
      _recoveries.removeWhere((ScanDraftRecovery job) => job.itemId == item.id);
      _recoveryIds.remove(item.id);
      item._replacementChoices = request.choices ?? request.original?.approval;
      _notify();
    } catch (_) {
      if (_currentCapture(epoch) && identical(_byId[item.id], item)) {
        item._rescanPending = false;
        _notify();
        _pumpWorkers();
      }
      rethrow;
    }
  }

  Future<void> cancelRescan(ScanSessionItem item) async {
    final int epoch = _captureEpoch;
    final ScanDraftRescan? request = _rescans[item.id];
    if (request == null ||
        !_currentCapture(epoch) ||
        !identical(_byId[item.id], item)) {
      return;
    }
    await _serializeItemUpdates(() async {
      if (!_currentCapture(epoch) || !identical(_byId[item.id], item)) return;
      await store?.cancelRescan(item.id, requestId: request.requestId);
      if (!_currentCapture(epoch) || !identical(_byId[item.id], item)) return;
      _rescans.remove(item.id);
      item._rescanPending = false;
      final String? failure = _rescanFailures.remove(item.id);
      if (failure != null && storageError == failure) storageError = null;
      if (_canResolve(item) &&
          (item.resolution == null || item.error != null) &&
          !_resolvingIds.contains(item.id) &&
          !_unresolved.contains(item)) {
        _unresolved.add(item);
      }
    });
    _pumpWorkers();
  }

  Future<bool> replaceRescanPhoto(
    ScanSessionItem item,
    String path, {
    bool ownedCameraSource = false,
  }) {
    final ScanDraftRescan? request = _rescans[item.id];
    final int epoch = _captureEpoch;
    if (request == null ||
        path.isEmpty ||
        !_currentCapture(epoch) ||
        !identical(_byId[item.id], item) ||
        !item.rescanPending ||
        !_activeReplacements.add(item.id)) {
      return Future<bool>.value(false);
    }
    _replacementReaders++;
    final Future<bool> replacement = _replacementTurns.then((_) async {
      bool current() =>
          _currentCapture(epoch) &&
          identical(_byId[item.id], item) &&
          item.rescanPending &&
          !_removing.contains(item.id) &&
          _rescans[item.id]?.requestId == request.requestId;
      ScanRecognition? recognized;
      try {
        if (!current()) return false;
        final ScanDraftPhoto photo = await store!.importRescanPhoto(
          request,
          path,
          ownedCameraSource: ownedCameraSource,
        );
        if (!current()) return false;
        while ((_readerRunning && !_readerUsesPresence) ||
            _detailReaderRunning) {
          final Future<void>? idle = _detailReaderRunning
              ? _detailIdle?.future
              : _readerIdle?.future;
          if (idle == null) throw StateError('The card reader is unavailable.');
          await idle;
          if (!current()) return false;
        }
        recognized = await recognizer.recognize(
          photo.imagePath,
          multipleCards: true,
          targetRegions: photo.targetRegions ?? const <List<ScanPoint>>[],
        );
        if (!current()) return false;
        _recordTargetAppearances(photo, recognized);
        final List<ScanCrop> usable = recognized.crops
            .where(hasVerifiedSavedCardCapturePresence)
            .toList();
        if (usable.length != 1) return false;
        final ScanCrop crop = usable.single;
        final bool accepted = await _serializeItemUpdates(() async {
          if (!current()) return false;
          final ScanDraftItem saved = await store!.commitRescan(
            request,
            ScanDraftItem(
              id: item.id,
              photoId: photo.id,
              crop: crop,
              defaults: item.defaults,
            ),
          );
          if (!current()) return false;
          final int index = items.indexOf(item);
          if (index < 0) return false;
          final ScanSessionItem fresh = ScanSessionItem.fromDraft(saved)
            ..selected = item.selected
            .._replacementChoices = item._replacementChoices;
          items[index] = fresh;
          _byId[item.id] = fresh;
          _rescans.remove(item.id);
          final String? failure = _rescanFailures.remove(item.id);
          if (failure != null && storageError == failure) storageError = null;
          _photoRefinements.remove(item.id);
          _liveReceiptIds.remove(item.id);
          _unresolved.remove(item);
          if (!items.any(
            (ScanSessionItem sibling) => sibling.photoId == item.photoId,
          )) {
            _details.removeWhere(
              (ScanDraftDetail job) => job.photoId == item.photoId,
            );
            _detailJobs.remove(item.photoId);
            _detailSources.remove(item.photoId);
            _pruneCapturePhotoIds();
          }
          _unresolved.add(fresh);
          paused = false;
          return true;
        });
        _notify();
        return accepted;
      } catch (error) {
        if (current()) {
          storageError = error is ScanDraftStorageBudgetExceeded
              ? ScanDraftStorageBudgetExceeded.userMessage
              : 'Could not replace this capture. The original is still available.';
          _rescanFailures[item.id] = storageError!;
          _notify();
        }
        return false;
      } finally {
        for (final ScanCrop crop in recognized?.crops ?? const <ScanCrop>[]) {
          _releaseTemporary(crop.imagePath);
        }
        _replacementReaders--;
        _activeReplacements.remove(item.id);
        _pumpWorkers();
      }
    });
    _replacementTurns = replacement.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return replacement;
  }

  Future<bool> _queueRecovery(
    ScanSessionItem item,
    int epoch, {
    bool manual = false,
  }) async {
    if (store == null ||
        _detailJobs.containsKey(item.photoId) ||
        (!manual && _detailedPhotoIds.contains(item.photoId)) ||
        !_currentCapture(epoch) ||
        !_canResolve(item) ||
        item.photoId.isEmpty ||
        _recoveryIds.contains(item.id) ||
        pendingPhotoCaptures >= 8 ||
        _activeRecovery?.photoId == item.photoId ||
        _recoveries.any(
          (ScanDraftRecovery job) => job.photoId == item.photoId,
        )) {
      return false;
    }
    return _serializeItemUpdates<bool>(() async {
      if (!_currentCapture(epoch) ||
          !_canResolve(item) ||
          pendingPhotoCaptures >= 8 ||
          _activeRecovery?.photoId == item.photoId ||
          _recoveries.any(
            (ScanDraftRecovery job) => job.photoId == item.photoId,
          )) {
        return false;
      }
      try {
        final ScanDraftRecovery? job = await store!.scheduleRecovery(
          item.id,
          manual: manual,
        );
        if (job == null || !_currentCapture(epoch) || !_canResolve(item)) {
          return false;
        }
        if (!_recoveryIds.add(item.id)) return true;
        item._retrying = true;
        _recoveries.add(job);
        _unresolved.remove(item);
        _notify();
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  Future<void> persist(Iterable<ScanSessionItem> changedItems) {
    if (_disposed) {
      return Future<void>.error(StateError('This scan session is closed.'));
    }
    if (_clearingCaptures) return Future<void>.value();
    final int epoch = _captureEpoch;
    final List<ScanSessionItem> changed = changedItems.toList();
    return _serializeItemUpdates<void>(() async {
      if (!_currentCapture(epoch)) return;
      final ScanDraftStore? drafts = store;
      if (drafts == null) return;
      final List<ScanSessionItem> batch = changed
          .where(
            (ScanSessionItem item) =>
                !_removing.contains(item.id) && identical(_byId[item.id], item),
          )
          .toList();
      final List<ScanDraftItem> saved = await drafts.upsertItems(
        batch.map((ScanSessionItem item) => item.draft).toList(),
      );
      if (!_currentCapture(epoch)) return;
      final Set<String> reviewed = <String>{};
      for (int index = 0; index < batch.length; index++) {
        batch[index].crop = saved[index].crop;
        final ScanDraftItem draft = saved[index];
        if (draft.approval != null) {
          reviewed.add(draft.id);
        }
      }
      if (_forgetReviewFailures(reviewed)) _notify();
    });
  }

  Future<void> _run() {
    if (paused || _disposed || _clearingCaptures) return Future<void>.value();
    final Completer<void>? current = _idle;
    if (current != null) {
      _pumpWorkers();
      return current.future;
    }
    final Completer<void> idle = Completer<void>();
    _idle = idle;
    _pumpWorkers();
    return idle.future;
  }

  void _pumpWorkers() {
    if (!paused && !_disposed && !_clearingCaptures) {
      if (!_readerRunning &&
          _replacementReaders == 0 &&
          (_photos.isNotEmpty || _recoveries.isNotEmpty) &&
          !recognitionBackpressure) {
        _readerRunning = true;
        _readerEpoch = _captureEpoch;
        _readerIdle = Completer<void>();
        unawaited(_readPhotos(_captureEpoch));
      }
      if (!_detailReaderRunning &&
          _replacementReaders == 0 &&
          _details.isNotEmpty &&
          (!_readerRunning || _readerUsesPresence)) {
        _detailReaderRunning = true;
        _detailEpoch = _captureEpoch;
        _detailIdle = Completer<void>();
        unawaited(_readDetails(_captureEpoch));
      }
      while (_resolverWorkers < _maximumResolverWorkers &&
          _unresolved.isNotEmpty) {
        _unresolved.removeWhere(
          (ScanSessionItem item) =>
              !identical(_byId[item.id], item) ||
              item.approval != null ||
              item.manuallyReviewed,
        );
        final List<ScanSessionItem> batch = _unresolved
            .where(
              (ScanSessionItem item) =>
                  !_resolvingIds.contains(item.id) && _canResolve(item),
            )
            .take(_maximumResolverBatch)
            .toList();
        if (batch.isEmpty) break;
        for (final ScanSessionItem item in batch) {
          _unresolved.remove(item);
        }
        _resolvingIds.addAll(batch.map((ScanSessionItem item) => item.id));
        _resolverWorkers++;
        _resolverWorkersByEpoch.update(
          _captureEpoch,
          (int count) => count + 1,
          ifAbsent: () => 1,
        );
        unawaited(_resolveItems(batch, _captureEpoch));
      }
    }
    running = _disposed
        ? _readerRunning || _detailReaderRunning || _resolverWorkers > 0
        : (_readerRunning && _readerEpoch == _captureEpoch) ||
              (_resolverWorkersByEpoch[_captureEpoch] ?? 0) > 0 ||
              (_detailReaderRunning && _detailEpoch == _captureEpoch) ||
              (!paused &&
                  !_clearingCaptures &&
                  (_photos.isNotEmpty ||
                      _recoveries.isNotEmpty ||
                      _details.isNotEmpty ||
                      _unresolved.isNotEmpty));
    if (!running) {
      final Completer<void>? idle = _idle;
      _idle = null;
      if (idle != null && !idle.isCompleted) idle.complete();
    }
    _notify();
  }

  Future<void> _readPhotos(int epoch) async {
    try {
      while ((_photos.isNotEmpty || _recoveries.isNotEmpty) &&
          _replacementReaders == 0 &&
          !recognitionBackpressure &&
          !paused &&
          _currentCapture(epoch)) {
        if (_recoveries.isNotEmpty) {
          _readerUsesPresence = false;
          if (_detailReaderRunning) await _detailIdle?.future;
          if (!_currentCapture(epoch)) return;
          final ScanDraftRecovery job = _recoveries.removeFirst();
          _activeRecovery = job;
          await _readRecovery(job, epoch);
          _activeRecovery = null;
          _pumpWorkers();
          continue;
        }
        final ScanDraftPhoto photo = _photos.removeFirst();
        _activePhotoId = photo.id;
        _activePhoto = photo;
        ScanRecognition? recognition;
        try {
          final List<ScanDraftPhoto> focusStack =
              _focusStacks[photo.id] ??
              await store?.readFocusStack(photo.id) ??
              <ScanDraftPhoto>[];
          if (!_currentCapture(epoch)) return;
          if (focusStack.isNotEmpty) {
            await _recognizeFocusStack(photo, focusStack, epoch);
            if (!_currentCapture(epoch)) return;
            _completeCaptureRead(photo.id);
            if (storageError == ScanDraftStorageBudgetExceeded.userMessage) {
              storageError = null;
            }
            photosRead += focusStack.length;
            _pumpWorkers();
            continue;
          }
          _readerUsesPresence = false;
          if (_detailReaderRunning) await _detailIdle?.future;
          if (!_currentCapture(epoch)) return;
          final ScanRecognition result = await recognizer.recognize(
            photo.imagePath,
            multipleCards: photo.multipleCards,
            targetRegions: photo.targetRegions ?? const <List<ScanPoint>>[],
          );
          recognition = result;
          if (!_currentCapture(epoch)) {
            for (final ScanCrop crop in result.crops) {
              _releaseTemporary(crop.imagePath);
            }
            return;
          }
          if (result.crops.isEmpty) {
            throw StateError('No readable card crops.');
          }
          _recordTargetAppearances(photo, result);
          final List<int> remainingIndexes = <int>[
            for (int index = 0; index < result.crops.length; index++)
              if (_retainsPhotoCrop(result.crops[index], photo)) index,
          ];
          final List<ScanCrop> remaining = remainingIndexes
              .map((int index) => result.crops[index])
              .toList();
          for (final ScanCrop crop in result.crops) {
            if (!remaining.contains(crop)) _releaseTemporary(crop.imagePath);
          }
          await _commitRecognized(
            remaining
                .map(
                  (ScanCrop crop) => ScanCrop(
                    imagePath: crop.imagePath,
                    width: crop.width,
                    height: crop.height,
                    rectified: crop.rectified,
                    sourceCorners: crop.sourceCorners,
                    warnings: crop.warnings,
                    sharpness: crop.sharpness,
                    lines: crop.lines
                        .where(
                          (ScanTextLine line) =>
                              line.confidence.isFinite &&
                              line.confidence >= .30 &&
                              line.confidence <= 1,
                        )
                        .take(64)
                        .toList(),
                  ),
                )
                .toList(),
            List<String>.filled(remaining.length, photo.id),
            photo,
            cropIndexes: remainingIndexes,
            epoch: epoch,
          );
          if (!_currentCapture(epoch)) return;
          _recordRawRegions(
            photo.id,
            result.crops.where(
              (ScanCrop crop) => _retainsPhotoCrop(crop, photo),
            ),
          );
          _completeCaptureRead(photo.id);
          if (storageError == ScanDraftStorageBudgetExceeded.userMessage) {
            storageError = null;
          }
        } catch (error) {
          for (final ScanCrop crop
              in recognition?.crops ?? const <ScanCrop>[]) {
            _releaseTemporary(crop.imagePath);
          }
          if (!_currentCapture(epoch)) return;
          if (error is ScanDraftStorageBudgetExceeded) {
            storageError = ScanDraftStorageBudgetExceeded.userMessage;
          }
          _failed.add(photo); // The durable source remains available for retry, including after relaunch.
        } finally {
          if (!_currentCapture(epoch)) {
            for (final ScanCrop crop
                in recognition?.crops ?? const <ScanCrop>[]) {
              _releaseTemporary(crop.imagePath);
            }
          }
          _activePhotoId = null;
          _activePhoto = null;
        }
        photosRead++;
        _pumpWorkers();
      }
    } finally {
      _readerRunning = false;
      _readerUsesPresence = false;
      _readerEpoch = null;
      final Completer<void>? idle = _readerIdle;
      _readerIdle = null;
      if (idle != null && !idle.isCompleted) idle.complete();
      _pumpWorkers();
    }
  }

  Future<void> _readDetails(int epoch) async {
    try {
      while (_details.isNotEmpty &&
          _replacementReaders == 0 &&
          !paused &&
          _currentCapture(epoch) &&
          (!_readerRunning || _readerUsesPresence)) {
        final ScanDraftDetail job = _details.removeFirst();
        if (!identical(_detailJobs[job.photoId], job)) continue;
        _activeDetail = job;
        ScanRecognition? result;
        bool current() =>
            _currentCapture(epoch) && identical(_detailJobs[job.photoId], job);
        try {
          final ScanDraftPhoto? source =
              await store?.readSource(job.photoId) ??
              _detailSources[job.photoId];
          if (!current()) continue;
          if (source == null) {
            throw StateError('Saved capture source is unavailable.');
          }
          result = await recognizer.recognize(
            source.imagePath,
            multipleCards: true,
            targetRegions: source.targetRegions ?? const <List<ScanPoint>>[],
          );
          if (!current()) continue;
          _recordTargetAppearances(source, result);
          final bool retained = await _commitDetailResult(
            source,
            result,
            epoch,
            job,
          );
          if (!current()) continue;
          if (!retained) {
            throw StateError(
              'The saved source still needs review or another scan.',
            );
          }
          _detailedPhotoIds.add(source.id);
          await store?.completeDetail(source.id);
          if (!current()) continue;
          _detailJobs.remove(source.id);
          _detailSources.remove(source.id);
          _pruneCapturePhotoIds();
          for (final ScanSessionItem item in items.where(
            (ScanSessionItem item) => item.photoId == source.id,
          )) {
            item._detailsPending = false;
          }
          if (storageError == ScanDraftStorageBudgetExceeded.userMessage) {
            storageError = null;
          }
        } catch (error, stack) {
          if (const bool.fromEnvironment('PHYSICAL_CARD_QA')) {
            debugPrint(
              'CAPTURE_DETAIL_DIAGNOSTIC photoId=${job.photoId} error=$error\n$stack',
            );
          }
          if (!current()) continue;
          final ScanDraftDetail failed = ScanDraftDetail(
            photoId: job.photoId,
            presenceComplete: true,
            failed: true,
          );
          try {
            await store?.updateDetail(failed);
          } catch (_) {}
          if (!current()) continue;
          _detailJobs[job.photoId] = failed;
          for (final ScanSessionItem item in items.where(
            (ScanSessionItem item) => item.photoId == job.photoId,
          )) {
            item._detailsPending = false;
          }
          if (error is ScanDraftStorageBudgetExceeded) {
            storageError = ScanDraftStorageBudgetExceeded.userMessage;
          }
        } finally {
          for (final ScanCrop crop in result?.crops ?? const <ScanCrop>[]) {
            if (store != null ||
                !items.any(
                  (ScanSessionItem item) =>
                      item.crop.imagePath == crop.imagePath,
                )) {
              _releaseTemporary(crop.imagePath);
            }
          }
          _activeDetail = null;
          _notify();
        }
      }
    } finally {
      _detailReaderRunning = false;
      _detailEpoch = null;
      final Completer<void>? idle = _detailIdle;
      _detailIdle = null;
      if (idle != null && !idle.isCompleted) idle.complete();
      _pumpWorkers();
    }
  }

  Future<bool> _commitDetailResult(
    ScanDraftPhoto source,
    ScanRecognition result,
    int epoch,
    ScanDraftDetail job,
  ) => _serializeItemUpdates<bool>(() async {
    if (!_currentCapture(epoch) || !identical(_detailJobs[source.id], job)) {
      return false;
    }
    final List<ScanSessionItem> prior = items
        .where((ScanSessionItem item) => item.photoId == source.id)
        .toList();
    final List<List<ScanPoint>> replaced = <List<ScanPoint>>[
      ...(await store?.readReplacedRegions(source.id) ??
          const <List<ScanPoint>>[]),
      ...(_removedPhotoRegions[source.id] ?? const <List<ScanPoint>>[]),
    ];
    if (!_currentCapture(epoch) || !identical(_detailJobs[source.id], job)) {
      return false;
    }
    final List<ScanSessionItem> retained = <ScanSessionItem>[];
    final Map<String, ScanSessionItem> staged = <String, ScanSessionItem>{};
    final Set<String> matched = <String>{};
    for (int index = 0; index < result.crops.length; index++) {
      final ScanCrop crop = result.crops[index];
      if (replaced.any(
        (List<ScanPoint> region) =>
            _replacementRegionMatches(crop.sourceCorners, region),
      )) {
        continue;
      }
      final List<ScanSessionItem> matches = prior
          .where(
            (ScanSessionItem item) =>
                _sameCapturedRegion(crop, item.crop) ||
                _recoveryRegionMatches(crop, item.crop, source),
          )
          .toList();
      if (matches.length > 1 ||
          (matches.isEmpty &&
              prior.any(
                (ScanSessionItem item) =>
                    _capturedRegionsOverlap(crop, item.crop),
              ))) {
        continue;
      }
      final ScanSessionItem? old = matches.firstOrNull;
      if (old != null) {
        if (!matched.add(old.id)) continue;
        retained.add(old);
        if (old.approval != null ||
            old.rescanPending ||
            old.manuallyReviewed ||
            _removing.contains(old.id)) {
          continue;
        }
      } else if (!_retainsPhotoCrop(crop, source) ||
          !_validQuad(crop.sourceCorners)) {
        continue;
      }
      final bool uncertain = _recoveryOwnershipUncertain(crop, source);
      final ScanCrop observed = ScanCrop(
        imagePath: crop.imagePath,
        width: crop.width,
        height: crop.height,
        rectified: crop.rectified,
        sourceCorners: crop.sourceCorners,
        sharpness: crop.sharpness,
        lines: crop.lines
            .where(
              (ScanTextLine line) =>
                  line.confidence.isFinite &&
                  line.confidence >= .30 &&
                  line.confidence <= 1,
            )
            .take(64)
            .toList(),
        warnings: <String>{
          ...crop.warnings,
          if (uncertain) 'capture_ownership_uncertain',
        }.toList(),
      );
      final String id = old?.id ?? '${source.id}_detail_$index';
      if (old == null && _byId.containsKey(id)) continue;
      final ScanSessionItem next = ScanSessionItem(
        observed,
        id: id,
        photoId: source.id,
        defaults: old?.defaults ?? source.defaults,
      )..selected = old?.selected ?? false;
      staged[id] = next;
      if (old == null) retained.add(next);
    }
    if (retained.isEmpty && prior.isEmpty) return false;
    final List<ScanSessionItem> complete = <ScanSessionItem>[
      for (final ScanSessionItem old in prior) staged[old.id] ?? old,
      ...retained.where(
        (ScanSessionItem item) =>
            !prior.any((ScanSessionItem old) => old.id == item.id),
      ),
    ];
    final List<ScanDraftItem>? saved = await store?.completePhoto(
      source.id,
      complete.map((ScanSessionItem item) => item.draft).toList(),
    );
    if (!_currentCapture(epoch) || !identical(_detailJobs[source.id], job)) {
      return false;
    }
    for (int index = 0; index < complete.length; index++) {
      final ScanSessionItem next = complete[index];
      if (saved != null) next.crop = saved[index].crop;
      if (!staged.containsKey(next.id)) continue;
      final ScanSessionItem? old = _byId[next.id];
      if (old != null &&
          (old.approval != null ||
              old.manuallyReviewed ||
              _removing.contains(old.id))) {
        await store?.upsertItems(<ScanDraftItem>[old.draft]);
        continue;
      }
      if (old == null) {
        add(next);
      } else {
        old.crop = next.crop;
        old.resolution = null;
        old.error = null;
        old._detailsPending = false;
      }
      final ScanSessionItem item = _byId[next.id]!;
      if (_resolvingIds.contains(item.id)) {
        _photoRefinements[item.id] = item.crop;
      } else if (!_unresolved.contains(item)) {
        _unresolved.add(item);
      }
    }
    _detailedPhotoIds.add(source.id);
    _notify();
    return true;
  });

  bool _canResolve(ScanSessionItem item) =>
      !_disposed &&
      !_clearingCaptures &&
      identical(_byId[item.id], item) &&
      !_removing.contains(item.id) &&
      !item.rescanPending &&
      item.approval == null &&
      !item.manuallyReviewed;

  Future<void> _readRecovery(ScanDraftRecovery job, int epoch) async {
    final ScanSessionItem? item = _byId[job.itemId];
    ScanRecognition? recognition;
    bool queued = false;
    try {
      if (!_currentCapture(epoch)) return;
      final List<ScanSessionItem> targets = items
          .where(
            (ScanSessionItem candidate) =>
                _canResolve(candidate) &&
                candidate.photoId == job.photoId &&
                (identical(candidate, item) ||
                    candidate.resolution?.candidates.isEmpty == true),
          )
          .toList();
      if (targets.isEmpty) return;
      final ScanDraftPhoto? source = await store?.readSource(job.photoId);
      if (source == null || !_currentCapture(epoch)) return;
      final Map<String, ScanCrop> original = <String, ScanCrop>{
        for (final ScanSessionItem target in targets) target.id: target.crop,
      };
      final Map<String, ScanResolution?> originalResolutions =
          <String, ScanResolution?>{
            for (final ScanSessionItem target in targets)
              target.id: target.resolution,
          };
      final Map<String, String?> originalErrors = <String, String?>{
        for (final ScanSessionItem target in targets) target.id: target.error,
      };
      bool unchanged(ScanSessionItem target) =>
          _canResolve(target) &&
          identical(target.crop, original[target.id]) &&
          identical(target.resolution, originalResolutions[target.id]) &&
          target.error == originalErrors[target.id];
      recognition = await recognizer.recognize(
        source.imagePath,
        multipleCards: source.multipleCards,
        targetRegions: source.targetRegions ?? const <List<ScanPoint>>[],
      );
      if (!_currentCapture(epoch)) return;
      _recordTargetAppearances(source, recognition);
      for (final ScanSessionItem target in targets) {
        if (!_currentCapture(epoch) || !unchanged(target)) continue;
        final List<ScanCrop> matches = recognition.crops
            .where(
              (ScanCrop crop) =>
                  _recoveryRegionMatches(crop, target.crop, source) &&
                  !items.any(
                    (ScanSessionItem other) =>
                        other.id != target.id &&
                        other.photoId == target.photoId &&
                        _capturedRegionsOverlap(crop, other.crop),
                  ),
            )
            .toList();
        if (matches.length != 1) continue;
        await _serializeItemUpdates<void>(() async {
          if (!_currentCapture(epoch) || !unchanged(target)) return;
          final ScanCrop candidate = matches.single;
          final ScanCrop recovered =
              _recoveryOwnershipUncertain(candidate, source)
              ? ScanCrop(
                  imagePath: candidate.imagePath,
                  width: candidate.width,
                  height: candidate.height,
                  rectified: candidate.rectified,
                  sourceCorners: candidate.sourceCorners,
                  lines: candidate.lines,
                  sharpness: candidate.sharpness,
                  warnings: <String>{
                    ...candidate.warnings,
                    'capture_ownership_uncertain',
                  }.toList(),
                )
              : candidate;
          final ScanSessionItem staged = ScanSessionItem.fromDraft(target.draft)
            ..crop = recovered
            ..resolution = null
            ..error = null;
          final List<ScanDraftItem>? saved = await store?.upsertItems(
            <ScanDraftItem>[staged.draft],
          );
          if (!_currentCapture(epoch)) return;
          if (!unchanged(target)) {
            if (_removing.contains(target.id) ||
                !_byId.containsKey(target.id)) {
              await store?.removeItems(<String>[target.id]);
            } else {
              await store?.upsertItems(<ScanDraftItem>[target.draft]);
            }
            return;
          }
          target
            ..crop = saved == null ? staged.crop : saved.single.crop
            ..resolution = null
            ..error = null;
          _photoRefinements.remove(target.id);
          target._retrying = true;
          if (!_unresolved.contains(target)) _unresolved.add(target);
          if (identical(target, item)) queued = true;
        });
      }
    } catch (_) {
      // The existing crop and printing remain available if saved pixels cannot be recovered.
    } finally {
      for (final ScanCrop crop in recognition?.crops ?? <ScanCrop>[]) {
        _releaseTemporary(crop.imagePath);
      }
      if (_currentCapture(epoch)) {
        try {
          await store?.completeRecovery(job);
        } catch (_) {
          storageError = 'Could not save identification retry progress. Retry when storage is available.';
        }
        _recoveryIds.remove(job.itemId);
        if (!queued && item != null) item._retrying = false;
        _notify();
      }
    }
  }

  Future<void> _resolveItems(List<ScanSessionItem> batch, int epoch) async {
    final Map<String, ScanCrop> inputs = <String, ScanCrop>{
      for (final ScanSessionItem item in batch)
        item.id: _photoRefinements[item.id] ?? item.crop,
    };
    final Set<String> published = <String>{};
    final Set<int> processed = <int>{};
    final Set<String> finalized = <String>{};
    void finishItem(ScanSessionItem item) {
      if (!finalized.add(item.id) || epoch != _captureEpoch) return;
      _resolvingIds.remove(item.id);
      final ScanCrop? refinement = _photoRefinements[item.id];
      final bool newerInput = refinement != null
          ? !identical(refinement, inputs[item.id])
          : !published.contains(item.id) &&
                !identical(item.crop, inputs[item.id]);
      if (newerInput && _canResolve(item) && !_unresolved.contains(item)) {
        _unresolved.add(item);
      } else if (!newerInput && published.contains(item.id)) {
        _photoRefinements.remove(item.id);
      }
    }

    Future<void> publish(int index, ScanResolveOutcome? outcome) async {
      if (index < 0 || index >= batch.length || !processed.add(index)) return;
      final ScanSessionItem item = batch[index];
      try {
        if (!_currentCapture(epoch) ||
            !_canResolve(item) ||
            !identical(
              _photoRefinements[item.id] ?? item.crop,
              inputs[item.id],
            )) {
          return;
        }
        await _serializeItemUpdates<void>(() async {
          if (!_currentCapture(epoch) ||
              !_canResolve(item) ||
              !identical(
                _photoRefinements[item.id] ?? item.crop,
                inputs[item.id],
              )) {
            return;
          }
          final ScanSessionItem staged = ScanSessionItem.fromDraft(item.draft);
          if (outcome?.resolution == null) {
            if (item.liveIdentityName != null) return;
            staged.error = 'Printing lookup failed. Retry when connected, or review manually.';
          } else {
            final ScanResolution result = outcome!.resolution!;
            final String? liveName = item.liveIdentityName;
            if (liveName != null) {
              final List<ScanCandidate> supported = result.candidates
                  .where(
                    (ScanCandidate candidate) =>
                        !candidate.hasContradiction &&
                        _canonicalName(candidate.card.name) == liveName &&
                        candidate.evidence.contains(ScanEvidence.nameMatch) &&
                        candidate.evidence.any(
                          (ScanEvidence evidence) => const <ScanEvidence>{
                            ScanEvidence.typeLineMatch,
                            ScanEvidence.rulesTextMatch,
                            ScanEvidence.footerMatch,
                          }.contains(evidence),
                        ),
                  )
                  .toList();
              if (supported.isEmpty) return;
              staged.resolution = _sessionResolution(
                ScanResolution(
                  status: ScanResolutionStatus.needsReview,
                  hints: result.hints,
                  candidates: supported,
                  hasMore: result.hasMore,
                  page: result.page,
                  historicalBodyIdentityProof:
                      result.historicalBodyIdentityProof,
                ),
              );
            } else {
              staged.resolution = _sessionResolution(result);
            }
            staged.error = null;
          }
          final ({
            ScanCrop crop,
            ScanResolution? resolution,
            String? error,
            String? liveName,
            bool selected,
          })
          prior = (
            crop: item.crop,
            resolution: item.resolution,
            error: item.error,
            liveName: item.liveIdentityName,
            selected: item.selected,
          );
          try {
            final List<ScanDraftItem>? saved = await store?.upsertItems(
              <ScanDraftItem>[staged.draft],
            );
            if (!_currentCapture(epoch)) return;
            if (!_canResolve(item) ||
                !identical(
                  _photoRefinements[item.id] ?? item.crop,
                  inputs[item.id],
                ) ||
                !identical(item.crop, prior.crop) ||
                !identical(item.resolution, prior.resolution) ||
                item.error != prior.error ||
                item.liveIdentityName != prior.liveName ||
                item.selected != prior.selected) {
              if (_removing.contains(item.id) || !_byId.containsKey(item.id)) {
                await store?.removeItems(<String>[item.id]);
              } else {
                await store?.upsertItems(<ScanDraftItem>[item.draft]);
              }
              return;
            }
            item.crop = saved == null ? staged.crop : saved.single.crop;
            item.resolution = staged.resolution;
            item.error = staged.error;
            item._retrying = false;
            published.add(item.id);
            _forgetReviewFailures(<String>[item.id]);
          } catch (_) {
            if (_currentCapture(epoch)) {
              _failedReviewIds.add(item.id);
              item._reviewSaveFailed = true;
            }
          }
        });
        if (_currentCapture(epoch) &&
            published.contains(item.id) &&
            item.error == null &&
            item.resolution?.candidates.isEmpty == true) {
          await _queueRecovery(item, epoch);
        }
      } finally {
        finishItem(item);
        if (_currentCapture(epoch)) _pumpWorkers();
      }
    }

    try {
      List<ScanResolveOutcome>? results;
      try {
        results = await resolver.resolveBatchOutcomes(
          batch.map((ScanSessionItem item) => inputs[item.id]!).toList(),
          onOutcome: publish,
        );
        if (results.length != batch.length) results = null;
      } catch (_) {
        if (!_currentCapture(epoch)) return;
      }
      if (!_currentCapture(epoch)) return;
      for (int index = 0; index < batch.length; index++) {
        if (!processed.contains(index)) {
          await publish(index, results?[index]);
        }
      }
    } finally {
      for (final ScanSessionItem item in batch) {
        finishItem(item);
      }
      _resolverWorkers--;
      final int remaining = (_resolverWorkersByEpoch[epoch] ?? 1) - 1;
      if (remaining == 0) {
        _resolverWorkersByEpoch.remove(epoch);
      } else {
        _resolverWorkersByEpoch[epoch] = remaining;
      }
      _pumpWorkers();
    }
  }

  void changed() => _notify();

  Future<void> removeBatch(List<ScanSessionItem> removed) {
    final int epoch = _captureEpoch;
    if (!_currentCapture(epoch)) return Future<void>.value();
    return _serializeItemUpdates<void>(() async {
      if (!_currentCapture(epoch)) return;
      await _removeBatch(
        removed
            .where((ScanSessionItem item) => identical(_byId[item.id], item))
            .toList(),
      );
    });
  }

  Future<void> _removeBatch(List<ScanSessionItem> removed) async {
    final List<String> removingIds = removed
        .map((ScanSessionItem item) => item.id)
        .toList();
    _removing.addAll(removingIds);
    try {
      await store?.removeItems(removingIds);
    } catch (_) {
      _removing.removeAll(removingIds);
      rethrow;
    }
    _removing.removeAll(removingIds);
    _forgetItems(removed);
  }

  void _forgetItems(List<ScanSessionItem> removed) {
    final Set<String> ids = removed
        .map((ScanSessionItem item) => item.id)
        .toSet();
    for (final ScanSessionItem item in removed) {
      if (item.photoId.isNotEmpty && _validQuad(item.crop.sourceCorners)) {
        (_removedPhotoRegions[item.photoId] ??= <List<ScanPoint>>[]).add(
          List<ScanPoint>.of(item.crop.sourceCorners),
        );
      }
    }
    _failedCaptureAcceptanceIds.removeAll(ids);
    _forgetReviewFailures(ids);
    if (_failedCaptureAcceptanceIds.isEmpty &&
        storageError == _acceptanceStorageError) {
      storageError = null;
    }
    for (final String id in ids) {
      final String? receiptId = _liveReceiptIds.remove(id);
      if (receiptId != null) _removedLiveIds.add(receiptId);
      _photoRefinements.remove(id);
      _byId.remove(id);
    }
    items.removeWhere((ScanSessionItem item) => ids.contains(item.id));
    for (final String photoId
        in removed.map((ScanSessionItem item) => item.photoId).toSet()) {
      if (!items.any((ScanSessionItem item) => item.photoId == photoId)) {
        _removedPhotoRegions.remove(photoId);
        _details.removeWhere((ScanDraftDetail job) => job.photoId == photoId);
        _detailJobs.remove(photoId);
        _detailSources.remove(photoId);
      }
    }
    _pruneCapturePhotoIds();
    _unresolved.removeWhere((ScanSessionItem item) => ids.contains(item.id));
    for (final ScanSessionItem item in removed) {
      _releaseTemporary(item.crop.imagePath);
    }
    _notify();
  }

  Future<void> remove(ScanSessionItem item) =>
      removeBatch(<ScanSessionItem>[item]);

  void _releaseTemporary(String path) {
    if (!kIsWeb && path.contains('/ScanCrops/')) {
      unawaited(File(path).delete().catchError((Object _) => File(path)));
    }
  }

  void _notify() {
    for (final MapEntry<
          String,
          ({int epoch, ScanSessionItem item, Completer<void> done})
        >
        entry
        in _itemRetries.entries.toList()) {
      final ScanSessionItem item = entry.value.item;
      final bool invalid =
          _disposed ||
          paused ||
          !_currentCapture(entry.value.epoch) ||
          !identical(_byId[item.id], item) ||
          item.approval != null ||
          item.rescanPending ||
          _removing.contains(item.id);
      final bool busy =
          _unresolved.contains(item) ||
          _resolvingIds.contains(item.id) ||
          _recoveryIds.contains(item.id) ||
          item._detailsPending;
      if (invalid || !busy) {
        _itemRetries.remove(entry.key);
        if (!invalid) {
          item._retrying = false;
        }
        if (!entry.value.done.isCompleted) entry.value.done.complete();
      }
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _details.clear();
    _rescans.clear();
    _rescanFailures.clear();
    _detailJobs.clear();
    _detailSources.clear();
    _disposed = true;
    _notify();
    _lastCameraPhoto = null;
    _captureReadsByPhotoId.clear();
    _readCaptures.clear();
    _rawCaptureRegions.clear();
    _photoRefinements.clear();
    _photoRefinementReceipts.clear();
    _pendingRefinementPhotoIds.clear();
    _removedLiveIds.clear();
    _removedPhotoRegions.clear();
    _liveReceiptIds.clear();
    _capturePhotoIds.clear();
    _savedTargetAppearances.clear();
    _explicitCapturesByPaths.clear();
    _diagnosticSources.clear();
    super.dispose();
  }
}

bool _retainsPhotoCrop(ScanCrop crop, ScanDraftPhoto photo) {
  if (_isExcludedPhotoCrop(crop, photo.excludedRegions)) return false;
  final List<List<ScanPoint>>? targets = photo.targetRegions;
  if (targets == null) return true;
  final List<List<ScanPoint>> strict = targets
      .where(
        (List<ScanPoint> region) =>
            _isExcluded(crop, <List<ScanPoint>>[region]),
      )
      .toList();
  if (strict.isNotEmpty) return strict.length == 1;
  final List<List<ScanPoint>> shifted = targets
      .where((List<ScanPoint> region) => _matchesShiftedTarget(crop, region))
      .toList();
  if (shifted.length != 1) return false;
  return <List<ScanPoint>>[
    ...photo.excludedRegions,
    ...targets.where(
      (List<ScanPoint> region) => !identical(region, shifted.single),
    ),
  ].every(
    (List<ScanPoint> region) =>
        !_targetOverlapIsAmbiguous(crop.sourceCorners, region),
  );
}

bool _matchesShiftedTarget(ScanCrop observed, List<ScanPoint> target) {
  final List<ScanPoint> crop = observed.sourceCorners;
  if (!_validQuad(crop) || !_validQuad(target)) return false;
  final double area = _signedArea(crop).abs();
  final double targetArea = _signedArea(target).abs();
  final double ratio = area / targetArea;
  if (ratio < .75 || ratio > 1.33) return false;
  final double intersection = _signedArea(_clipPolygon(crop, target)).abs();
  if (intersection / (area + targetArea - intersection) < .70 ||
      intersection / area < .78 ||
      intersection / targetArea < .78) {
    return false;
  }
  double dx = 0;
  double dy = 0;
  for (int index = 0; index < 4; index++) {
    dx += crop[index].x - target[index].x;
    dy += crop[index].y - target[index].y;
  }
  final double minimumArea = area < targetArea ? area : targetArea;
  final double centerDistanceSquared = (dx * dx + dy * dy) / 16;
  if (centerDistanceSquared <= .0064 * minimumArea) return true;
  // A repaired perspective border can move the center without changing the
  // card. Keep its warning and all overlap guards; this only retains review.
  return centerDistanceSquared <= .0144 * minimumArea &&
      observed.rectified &&
      observed.imagePath.isNotEmpty &&
      observed.warnings.contains('border_recovered') &&
      observed.lines.any(
        (ScanTextLine line) =>
            !line.sceneFooterGuide &&
            line.confidence.isFinite &&
            line.confidence >= .85 &&
            line.confidence <= 1 &&
            observedCardType(line.text) != null,
      );
}

bool _targetOverlapIsAmbiguous(List<ScanPoint> crop, List<ScanPoint> region) {
  if (!_validQuad(crop) || !_validQuad(region)) return true;
  final double area = _signedArea(crop).abs();
  final double regionArea = _signedArea(region).abs();
  final double minimumArea = area < regionArea ? area : regionArea;
  final double intersection = _signedArea(_clipPolygon(crop, region)).abs();
  return intersection / minimumArea >= .20;
}

bool _replacementRegionMatches(List<ScanPoint> first, List<ScanPoint> second) {
  if (!_validQuad(first) || !_validQuad(second)) return false;
  final double intersection = _signedArea(_clipPolygon(first, second)).abs();
  final double firstArea = _signedArea(first).abs();
  final double secondArea = _signedArea(second).abs();
  final double minimumArea = firstArea < secondArea ? firstArea : secondArea;
  return minimumArea > 0 && intersection / minimumArea >= .80;
}

bool _isExcludedPhotoCrop(ScanCrop crop, List<List<ScanPoint>> regions) {
  if (_isExcluded(crop, regions)) return true;
  final List<ScanPoint> corners = crop.sourceCorners;
  if (crop.rectified ||
      !crop.warnings.contains('no_card_rectangle') ||
      !crop.warnings.contains('partial_card') ||
      !_validQuad(corners)) {
    return false;
  }
  for (int index = 0; index < 4; index++) {
    final ScanPoint first = corners[index];
    final ScanPoint second = corners[(index + 1) % 4];
    if ((first.x - second.x).abs() > .002 &&
        (first.y - second.y).abs() > .002) {
      return false;
    }
  }
  final double area = _signedArea(corners).abs();
  for (final List<ScanPoint> region in regions) {
    if (!_validQuad(region)) continue;
    final double regionArea = _signedArea(region).abs();
    final double ratio = area / regionArea;
    if (ratio < 1 || ratio > 1.6) continue;
    final double intersection = _signedArea(_clipPolygon(corners, region))
        .abs();
    if (intersection / regionArea < .95) continue;
    double dx = 0;
    double dy = 0;
    for (int index = 0; index < 4; index++) {
      dx += corners[index].x - region[index].x;
      dy += corners[index].y - region[index].y;
    }
    if ((dx * dx + dy * dy) / 16 <= .0016) return true;
  }
  return false;
}

bool _isExcluded(ScanCrop crop, List<List<ScanPoint>> regions) {
  final List<ScanPoint> corners = crop.sourceCorners;
  if (regions.isEmpty || !_validQuad(corners)) return false;
  final double area = _signedArea(corners).abs();
  for (final List<ScanPoint> region in regions) {
    if (!_validQuad(region)) continue;
    final double regionArea = _signedArea(region).abs();
    final double intersection = _signedArea(_clipPolygon(corners, region))
        .abs();
    if (intersection / (area + regionArea - intersection) >= .8) return true;
    if (area / regionArea >= .1 &&
        area / regionArea <= 1.05 &&
        intersection / area >= .98) {
      return true;
    }
    if (area / regionArea >= 1 &&
        area / regionArea <= 1.5 &&
        intersection / regionArea >= .98) {
      double dx = 0;
      double dy = 0;
      for (int index = 0; index < 4; index++) {
        dx += corners[index].x - region[index].x;
        dy += corners[index].y - region[index].y;
      }
      if ((dx * dx + dy * dy) / 16 <= .0004) {
        return true;
      }
    }
  }
  return false;
}

double _cross(ScanPoint a, ScanPoint b, ScanPoint point) =>
    (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x);

double _signedArea(List<ScanPoint> points) {
  double area = 0;
  for (int index = 0; index < points.length; index++) {
    final ScanPoint a = points[index];
    final ScanPoint b = points[(index + 1) % points.length];
    area += a.x * b.y - b.x * a.y;
  }
  return area / 2;
}

bool _validQuad(List<ScanPoint> points) {
  if (points.length != 4 ||
      points.any(
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
  final double area = _signedArea(points);
  if (area.abs() < .000001) return false;
  final double winding = area > 0 ? 1 : -1;
  for (int index = 0; index < 4; index++) {
    if (_cross(
              points[index],
              points[(index + 1) % 4],
              points[(index + 2) % 4],
            ) *
            winding <=
        .000000001) {
      return false;
    }
  }
  return true;
}

List<ScanPoint> _clipPolygon(List<ScanPoint> subject, List<ScanPoint> region) {
  List<ScanPoint> result = subject;
  final double winding = _signedArea(region) > 0 ? 1 : -1;
  for (int edge = 0; edge < region.length && result.isNotEmpty; edge++) {
    final ScanPoint a = region[edge];
    final ScanPoint b = region[(edge + 1) % region.length];
    final List<ScanPoint> input = result;
    result = <ScanPoint>[];
    ScanPoint previous = input.last;
    double previousSide = _cross(a, b, previous) * winding;
    for (final ScanPoint current in input) {
      final double side = _cross(a, b, current) * winding;
      if ((side >= 0) != (previousSide >= 0)) {
        final double fraction = previousSide / (previousSide - side);
        result.add(
          ScanPoint(
            previous.x + fraction * (current.x - previous.x),
            previous.y + fraction * (current.y - previous.y),
          ),
        );
      }
      if (side >= 0) result.add(current);
      previous = current;
      previousSide = side;
    }
  }
  return result;
}

String _canonicalName(String name) => name.trim().toLowerCase();

String? _liveIdentityName(ScanResolution? resolution, ScanCrop crop) {
  if (resolution == null || resolution.status == ScanResolutionStatus.noMatch) {
    return null;
  }
  final String? historical = verifiedLiveHistoricalBodyIdentity(
    crop,
    resolution,
  );
  if (historical != null) return _canonicalName(historical);
  final List<ScanCandidate> supported = resolution.candidates
      .where(
        (ScanCandidate candidate) =>
            !candidate.hasContradiction &&
            candidate.evidence.contains(ScanEvidence.nameMatch) &&
            candidate.evidence.any(
              (ScanEvidence evidence) => const <ScanEvidence>{
                ScanEvidence.typeLineMatch,
                ScanEvidence.rulesTextMatch,
                ScanEvidence.footerMatch,
              }.contains(evidence),
            ),
      )
      .toList();
  final Set<String> names = supported
      .map((ScanCandidate candidate) => _canonicalName(candidate.card.name))
      .toSet();
  return names.length == 1 ? names.single : null;
}

ScanResolution _sessionResolution(ScanResolution resolution) => ScanResolution(
  status: resolution.status,
  hints: resolution.hints,
  candidates: resolution.candidates.take(3).toList(),
  hasMore: resolution.hasMore || resolution.candidates.length > 3,
  page: resolution.page,
  historicalBodyIdentityProof: resolution.historicalBodyIdentityProof,
);

ScanCrop _cropWithImage(ScanCrop crop, String path) => ScanCrop(
  imagePath: path,
  width: crop.width,
  height: crop.height,
  rectified: crop.rectified,
  sourceCorners: crop.sourceCorners,
  lines: crop.lines,
  warnings: crop.warnings,
  sharpness: crop.sharpness,
);

bool _sameCapturedRegion(ScanCrop a, ScanCrop b) =>
    _validQuad(a.sourceCorners) &&
    _validQuad(b.sourceCorners) &&
    (_isExcluded(a, <List<ScanPoint>>[b.sourceCorners]) ||
        _isExcluded(b, <List<ScanPoint>>[a.sourceCorners]));

bool _recoveryRegionMatches(
  ScanCrop recovered,
  ScanCrop original,
  ScanDraftPhoto source,
) {
  if (_retainsPhotoCrop(recovered, source) &&
      _sameCapturedRegion(recovered, original)) {
    return true;
  }
  if (!original.warnings.contains('incomplete_card') ||
      !original.warnings.contains('no_text') ||
      original.lines.isNotEmpty ||
      !(hasVerifiedSavedVisualLayout(recovered) ||
          hasVerifiedSavedBasicLandCapturePresence(recovered)) ||
      !_validQuad(original.sourceCorners) ||
      !_validQuad(recovered.sourceCorners)) {
    return false;
  }
  bool encloses(List<ScanPoint> inner) {
    if (!_validQuad(inner)) return false;
    final double innerArea = _signedArea(inner).abs();
    final double outerArea = _signedArea(recovered.sourceCorners).abs();
    final double overlap = _signedArea(
      _clipPolygon(recovered.sourceCorners, inner),
    ).abs();
    return outerArea >= innerArea &&
        outerArea <= innerArea * 4 &&
        overlap / innerArea >= .98;
  }

  if (!encloses(original.sourceCorners)) return false;
  final List<List<ScanPoint>>? targets = source.targetRegions;
  return targets == null ||
      targets
              .where(
                (List<ScanPoint> region) =>
                    encloses(region) ||
                    _isExcluded(recovered, <List<ScanPoint>>[region]) ||
                    _isExcluded(original, <List<ScanPoint>>[region]),
              )
              .length ==
          1;
}

bool _recoveryOwnershipUncertain(ScanCrop crop, ScanDraftPhoto source) =>
    _validQuad(crop.sourceCorners) &&
    source.excludedRegions.any(
      (List<ScanPoint> region) =>
          _validQuad(region) &&
          _signedArea(_clipPolygon(crop.sourceCorners, region)).abs() /
                  _signedArea(region).abs() >=
              .2,
    );

bool _capturedRegionsOverlap(ScanCrop a, ScanCrop b) {
  if (!_validQuad(a.sourceCorners) || !_validQuad(b.sourceCorners)) {
    return false;
  }
  final double intersection = _signedArea(
    _clipPolygon(a.sourceCorners, b.sourceCorners),
  ).abs();
  final double minimumArea =
      _signedArea(a.sourceCorners).abs() < _signedArea(b.sourceCorners).abs()
      ? _signedArea(a.sourceCorners).abs()
      : _signedArea(b.sourceCorners).abs();
  return intersection / minimumArea >= .2;
}
