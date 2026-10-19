import 'dart:async';
import 'dart:io';

import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/src/components/overlay/dialog.dart'
    show showDialog;
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:scryfall_api/scryfall_api.dart' hide Color;

import '../../theme/collector_brand.dart';
import '../../theme/collector_navigation.dart';
import '../../utils/collection_ingestion.dart';
import '../../utils/card_catalog.dart';
import '../collection/card/card_add_dialog.dart';
import '../../utils/crud.dart';
import '../../utils/scanning/scan_queue.dart';
import '../../utils/scanning/scan_capture_defaults.dart';
import '../../utils/scanning/scan_accounting.dart';
import '../../utils/scanning/journaled_scan_queue_storage.dart';
import '../../utils/scanning/scan_draft_store.dart';
import '../../utils/scanning/scan_recognition.dart';
import '../../utils/scanning/scan_resolver.dart';
import '../../utils/scanning/cloud_scan_resolver.dart';
import '../../utils/scanning/cloud_scan_consent.dart';
import '../../utils/scanning/scan_session.dart';
import 'guided_camera_screen.dart';
import 'scan_correction_editor.dart';
import 'scan_camera_drawer.dart';

class ScanScreen extends StatefulWidget {
  final String userId;
  final bool openCamera;
  final bool active;
  final ScanQueue? queue;
  final ScanQueueStorage? queueStorage;
  final ScanQueueWriter? queueWriter;
  final CardRecognizer? recognizer;
  final ScanResolver? resolver;
  final CardCatalog? catalog;
  final Stream<List<MTGDeck>>? decks;
  final ScanDraftStore? draftStore;
  final MTGDeck? destination;
  const ScanScreen({
    super.key,
    required this.userId,
    this.openCamera = false,
    this.active = true,
    this.queue,
    this.queueStorage,
    this.queueWriter,
    this.recognizer,
    this.resolver,
    this.catalog,
    this.decks,
    this.draftStore,
    this.destination,
  });
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

enum _ScanReviewResult { approved, later, rescan, cancelled }

class _ScanScreenState extends State<ScanScreen> {
  late final CardCatalog _catalog = widget.catalog ?? CardCatalog();
  late final ScanResolver _resolver =
      widget.resolver ??
      CloudScanResolver(
        acquireConsent: () =>
            CloudScanConsentStore.instance.acquire(widget.userId),
      );
  late final ScanDraftStore? _drafts =
      widget.draftStore ??
      (widget.queue == null ? ScanDraftStore(userId: widget.userId) : null);
  late final ScanSession _session = ScanSession(
    recognizer: widget.recognizer ?? NativeCardRecognizer(),
    resolver: _resolver,
    store: _drafts,
  );
  late final ScanQueue _queue =
      widget.queue ??
      ScanQueue(
        userId: widget.userId,
        storage: JournaledScanQueueStorage(
          drafts: _drafts!,
          storage: widget.queueStorage,
        ),
        writer:
            widget.queueWriter ??
            (ScanQueueEntry entry) async {
              if (FirebaseAuth.instance.currentUser?.uid != widget.userId) {
                throw StateError('Account changed.');
              }
              await CollectionIngestion().add(
                userId: widget.userId,
                operationId: entry.operationId,
                card: entry.card,
                quantity: entry.quantity,
                deckId: entry.deckId,
                deckSection: entry.deckSection,
              );
            },
      );
  StreamSubscription<List<MTGDeck>>? _subscription;
  Future<void>? _uploadFuture;
  late List<MTGDeck> _decks = <MTGDeck>[
    if (widget.destination != null) widget.destination!,
  ];
  bool _busy = false;
  bool _correcting = false;
  Widget? _correctionView;
  Completer<PrintingSelection?>? _correctionCompletion;
  bool _rescanRouteOpen = false;
  bool _reviewingBatch = false;
  bool _restoreFailed = false;
  int _reviewGeneration = 0;
  final Set<String> _submittedIds = <String>{};
  final ValueNotifier<int> _destinationRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> _cameraRevision = ValueNotifier<int>(0);
  String? _cameraEditingId;
  bool _cameraOpened = false;
  bool _cameraVisible = false;
  bool _editingDefaults = false;
  bool _sessionMenuOpen = false;
  bool _continuous = true;
  bool _multiple = defaultTargetPlatform == TargetPlatform.iOS;
  bool _problemsOnly = false;
  int _cardIndex = 0;
  int _trayPage = 0;
  Finish? _finish = Finish.nonfoil;
  late String _deck = widget.destination?.id ?? '';
  DeckSection _section = DeckSection.mainboard;
  String? _error;
  String? _status;
  bool _startupReady = false;
  bool _autoScheduled = false;
  Future<void>? _autoWork;
  bool _reconciling = false;
  String? _lastAddedId;
  ScanAccounting? _accounting;
  bool _accountingDirty = false;
  int _accountingRevision = 0;
  Future<void>? _accountingRead;
  String? _accountingError;
  String? _lastAddedName;
  bool _automaticSaveFailed = false;
  Timer? _undoTimer;

  String get _destinationName =>
      _decks.where((MTGDeck group) => group.id == _deck).firstOrNull?.name ??
      (_deck.isEmpty ? 'Collection' : 'Unavailable container');

  ScanCaptureDefaults get _captureDefaults => ScanCaptureDefaults(
    finish: _finish ?? Finish.nonfoil,
    deckId: _deck.isEmpty ? null : _deck,
    deckSection: _section,
  );

  @override
  void didUpdateWidget(ScanScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.destination != widget.destination) {
      final MTGDeck? group = widget.destination;
      _deck = group?.id ?? '';
      _section = DeckSection.mainboard;
      if (group != null && !_decks.any((MTGDeck item) => item.id == group.id)) {
        _decks = <MTGDeck>[..._decks, group];
      }
      _destinationRevision.value++;
      _cameraVisible = true;
    }
    if (!oldWidget.active && widget.active && _cameraOpened) {
      _cameraVisible = true;
    }
  }

  @override
  void initState() {
    super.initState();
    _queue.addListener(_changed);
    _session.addListener(_changed);
    _drafts?.accountingChanges.addListener(_accountingChanged);
    _subscription =
        (widget.decks ?? Crud.deck(widget.userId).streamAll()).listen(
          (List<MTGDeck> value) {
            if (mounted) {
              setState(() => _decks = List<MTGDeck>.of(value));
              if (_error == 'Destination unavailable' &&
                  _validDestination(widget.destination?.id) &&
                  _session.items.every(
                    (ScanSessionItem item) =>
                        item.approval == null ||
                        _validDestination(item.approval!.deckId),
                  )) {
                _automaticSaveFailed = false;
                _error = null;
              }
              _destinationRevision.value++;
              _scheduleAutomaticSave();
            }
          },
          onError: (Object _) {
            if (mounted) {
              setState(
                () => _error = 'Decks are unavailable. You can still add to your collection.',
              );
            }
          },
        );
    _load();
  }

  void _accountingChanged() {
    if (!mounted) return;
    _accountingRevision++;
    _accountingDirty = true;
    unawaited(_refreshAccounting());
  }

  Future<void> _refreshAccounting() {
    final ScanDraftStore? drafts = _drafts;
    if (drafts == null || !mounted) return Future<void>.value();
    if (_accountingRead case final Future<void> pending) return pending;
    late final Future<void> read;
    read =
        Future<void>.microtask(() async {
          while (mounted && _accountingDirty) {
            _accountingDirty = false;
            final int revision = _accountingRevision;
            try {
              final ScanAccounting summary = await drafts.readAccounting();
              if (!mounted) return;
              if (revision != _accountingRevision) {
                _accountingDirty = true;
                continue;
              }
              setState(() {
                _accounting = summary;
                _accountingError = null;
              });
            } catch (_) {
              if (mounted && revision == _accountingRevision) {
                setState(() => _accountingError = 'Totals unavailable');
              }
            }
          }
        }).whenComplete(() {
          if (identical(_accountingRead, read)) _accountingRead = null;
          if (mounted && _accountingDirty) unawaited(_refreshAccounting());
        });
    _accountingRead = read;
    return read;
  }

  void _changed() {
    if (mounted) {
      _submittedIds.addAll(
        _queue.entries.map((ScanQueueEntry entry) => entry.operationId),
      );
      final String? editingId = _cameraEditingId;
      final Completer<PrintingSelection?>? correction = _correctionCompletion;
      if (editingId != null &&
          correction != null &&
          !correction.isCompleted &&
          !_session.items.any((ScanSessionItem item) => item.id == editingId)) {
        correction.complete();
      }
      setState(() {});
      _refreshCamera();
      _scheduleAutomaticSave();
    }
  }

  void _scheduleAutomaticSave() {
    if (!mounted ||
        !_startupReady ||
        _autoScheduled ||
        _autoWork != null ||
        _busy ||
        _rescanRouteOpen ||
        _reviewingBatch ||
        _reconciling ||
        !_queue.loaded ||
        !_session.loaded ||
        _session.clearingCaptures ||
        _session.storageError != null ||
        _automaticSaveFailed ||
        !_hasAutomaticWork) {
      return;
    }
    _autoScheduled = true;
    scheduleMicrotask(() {
      _autoScheduled = false;
      if (!mounted ||
          _busy ||
          _rescanRouteOpen ||
          _reviewingBatch ||
          _session.clearingCaptures ||
          _automaticSaveFailed) {
        return;
      }
      final Future<void> work = _saveReadyAutomatically();
      _autoWork = work;
      unawaited(
        work.whenComplete(() {
          if (identical(_autoWork, work)) _autoWork = null;
          if (mounted) _scheduleAutomaticSave();
        }),
      );
    });
  }

  bool get _hasAutomaticWork =>
      _queue.completedCount > 0 ||
      _session.items.any(
        (ScanSessionItem item) =>
            (item.id != _cameraEditingId &&
                !_submitted(item) &&
                !item.rescanPending &&
                ((item.selected && item.approval != null) ||
                    (!item.manuallyReviewed &&
                        item.approval == null &&
                        _exactReady(item)))) ||
            (_submitted(item) && !_queue.canUndo(item.id)),
      );

  Future<void> _saveReadyAutomatically() async {
    final int generation = _reviewGeneration;
    _reviewingBatch = true;
    try {
      await _selectExact();
    } finally {
      _reviewingBatch = false;
    }
    if (!mounted ||
        _busy ||
        _rescanRouteOpen ||
        generation != _reviewGeneration ||
        _session.clearingCaptures ||
        _session.storageError != null ||
        _automaticSaveFailed) {
      return;
    }
    if (_session.items.any(
      (ScanSessionItem item) =>
          item.id != _cameraEditingId &&
          item.selected &&
          item.approval != null &&
          !item.rescanPending &&
          !_submitted(item),
    )) {
      await _approveBatch();
    }
    if (!mounted || _busy || _session.clearingCaptures) return;
    _reconciling = true;
    try {
      await _reconcileQueuedCaptures();
    } catch (_) {
      _automaticSaveFailed = true;
      if (mounted) setState(() => _error = 'Save failed');
    } finally {
      _reconciling = false;
      _refreshCamera();
    }
  }

  Future<void> _load() async {
    try {
      Object? uploadFailure;
      Object? captureFailure;
      try {
        await _queue.load();
        _submittedIds.addAll(
          _queue.entries.map((ScanQueueEntry entry) => entry.operationId),
        );
      } catch (error) {
        uploadFailure = error;
      }
      try {
        await _session.load();
      } catch (error) {
        captureFailure = error;
      }
      if (!mounted) return;
      setState(() {
        _restoreFailed = uploadFailure != null || captureFailure != null;
        _error = captureFailure != null
            ? 'Captures unavailable. Retry restore.'
            : uploadFailure != null
            ? 'Could not restore pending additions. Retry restore before adding cards.'
            : null;
      });
      if (_restoreFailed) return;
      await _reconcileQueuedCaptures();
      _accountingDirty = true;
      await _refreshAccounting();
      if (!mounted) return;
      _startupReady = true;
      _lastAddedId = _queue.entries
          .where((ScanQueueEntry entry) => _queue.canUndo(entry.operationId))
          .lastOrNull
          ?.operationId;
      _lastAddedName = _queue.entries
          .where((ScanQueueEntry entry) => entry.operationId == _lastAddedId)
          .firstOrNull
          ?.card
          .name;
      _startUndoTimer();
      if (_queue.count > 0) unawaited(_saveQueue(resumePaused: false));
      _scheduleAutomaticSave();
      if (mounted &&
          widget.openCamera &&
          !_cameraOpened &&
          NativeCardRecognizer.supported) {
        _cameraOpened = true;
        unawaited(_capture());
      }
      if (NativeCardRecognizer.supported &&
          defaultTargetPlatform == TargetPlatform.android) {
        final LostDataResponse lost = await ImagePicker().retrieveLostData();
        if (mounted && lost.files != null) {
          _session.addPhotos(
            lost.files!.map((XFile file) => file.path),
            multipleCards: false,
          );
        }
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not restore pending additions. Retry before adding more cards.',
        );
      }
    }
  }

  Future<void> _capture() async {
    if (_busy || !_queue.loaded || !_session.loaded) return;
    unawaited(_resolver.warmNames());
    setState(() {
      _cameraOpened = true;
      _cameraVisible = true;
    });
  }

  Widget _cameraWorkspace() {
    final ScanCaptureDefaults defaults = _captureDefaults;
    return GuidedCameraScreen(
      active:
          widget.active &&
          _cameraVisible &&
          !_editingDefaults &&
          !_correcting &&
          !_rescanRouteOpen &&
          !_sessionMenuOpen,
      session: _session,
      destinationLabel: _destinationName,
      captureDrawerBuilder: _cameraDrawer,
      onDone: () => setState(() => _cameraVisible = false),
      onClearCaptures: _discardRemaining,
      multipleCards: _multiple,
      continuous: _continuous,
      onUnidentifiedPhotoCaptured:
          (
            List<String> paths,
            List<List<ScanPoint>> exclusions,
            String captureId,
            List<List<ScanPoint>> targets,
          ) => _session.addFocusStack(
            paths,
            defaults: defaults,
            ownedCameraSource: true,
            excludedRegions: exclusions,
            captureId: captureId,
            diagnosticOnly: false,
            preferFastPresence: true,
            targetRegions: targets,
          ),
      onFocusStackCaptured:
          (
            List<String> paths,
            List<List<ScanPoint>> excludedRegions,
            String captureId,
            List<List<ScanPoint>>? targetRegions,
          ) => _session.addFocusStack(
            paths,
            defaults: defaults,
            ownedCameraSource: true,
            excludedRegions: excludedRegions,
            captureId: captureId,
            diagnosticOnly: false,
            preferFastPresence: true,
            targetRegions: targetRegions,
          ),
      onCaptured: (String path, List<List<ScanPoint>> excludedRegions) =>
          _session.addPhotos(
            <String>[path],
            defaults: defaults,
            multipleCards: _multiple,
            ownedCameraSource: true,
            excludedRegions: excludedRegions,
          ),
    );
  }

  void _refreshCamera() {
    if (mounted) _cameraRevision.value++;
  }

  Widget _cameraDrawer(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[
      _session,
      _queue,
      _cameraRevision,
      _destinationRevision,
    ]),
    builder: (BuildContext context, Widget? child) => ScanCameraDrawer(
      items: List<ScanSessionItem>.of(_session.items),
      submittedIds: <String>{
        for (final ScanSessionItem item in _session.items)
          if (_submitted(item)) item.id,
      },
      pendingPhotos:
          _session.pendingPhotoCaptures + _session.pendingDetailSources,
      busy: _busy || _session.clearingCaptures,
      error: _error ?? _session.storageError,
      lastAddedId: _lastAddedId,
      lastAddedName: _lastAddedName,
      canUndo: _queue.canUndo,
      onEdit: _reviewCard,
      onRemove: _removeReviewCapture,
      onUndo: (String id) => _undoAdded(id),
    ),
  );

  Future<void> _rescan(ScanSessionItem item) async {
    if (_busy ||
        _rescanRouteOpen ||
        !_session.items.contains(item) ||
        _submitted(item)) {
      return;
    }
    setState(() => _rescanRouteOpen = true);
    final int generation = _reviewGeneration;
    bool replaced = false;
    ScanSessionItem? rescanAgain;
    try {
      await _session.beginRescan(item);
      if (!mounted ||
          generation != _reviewGeneration ||
          !_session.items.contains(item) ||
          !item.rescanPending) {
        return;
      }
      Future<bool> replace(String path) async {
        if (replaced ||
            !mounted ||
            generation != _reviewGeneration ||
            !_session.items.contains(item)) {
          return false;
        }
        replaced = await _session.replaceRescanPhoto(
          item,
          path,
          ownedCameraSource: true,
        );
        return replaced;
      }

      await Arcane.push<void>(
        context,
        GuidedCameraScreen(
          destinationLabel: _destinationName,
          automaticCapture: true,
          continuous: false,
          multipleCards: false,
          onCaptured: (String path, List<List<ScanPoint>> _) => replace(path),
          onFocusStackCaptured:
              (
                List<String> paths,
                List<List<ScanPoint>> exclusions,
                String captureId,
                List<List<ScanPoint>>? targets,
              ) async {
                if (paths.length != 1 || targets?.length != 1) {
                  return false;
                }
                return replace(paths.single);
              },
        ),
      );
      if (replaced && mounted && generation == _reviewGeneration) {
        final ScanSessionItem? replacement = _session.items
            .where((ScanSessionItem current) => current.id == item.id)
            .firstOrNull;
        if (replacement != null) {
          final _ScanReviewResult result = await _review(
            replacement,
            confirmLabel: 'Confirm',
          );
          if (result == _ScanReviewResult.rescan) {
            rescanAgain = replacement;
          }
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Rescan failed');
      }
    } finally {
      if (!replaced && _session.items.contains(item)) {
        try {
          await _session.cancelRescan(item);
        } catch (_) {
          if (mounted) {
            setState(() => _error = 'Rescan failed');
          }
        }
      }
      _rescanRouteOpen = false;
      if (mounted) setState(() {});
      if (rescanAgain == null) {
        _scheduleAutomaticSave();
      }
    }
    if (rescanAgain != null && mounted && generation == _reviewGeneration) {
      await _rescan(rescanAgain);
    }
  }

  Future<void> _gallery() async {
    if (_busy || !_queue.loaded || !_session.loaded) return;
    final ScanCaptureDefaults defaults = _captureDefaults;
    try {
      final List<XFile> images = await ImagePicker().pickMultiImage(
        requestFullMetadata: false,
      );
      if (mounted) {
        _session.addPhotos(
          images.map((XFile file) => file.path),
          defaults: defaults,
          multipleCards: _multiple,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not select photos. Try selecting them again.',
        );
      }
    }
  }

  Future<_ScanReviewResult> _review(
    ScanSessionItem? item, {
    String? progressLabel,
    String? confirmLabel,
  }) async {
    if (_busy ||
        _correcting ||
        !_queue.loaded ||
        !_session.loaded ||
        !mounted) {
      return _ScanReviewResult.cancelled;
    }
    if (item != null && _submitted(item)) {
      setState(() => _error = 'Already submitted. Check pending additions.');
      return _ScanReviewResult.cancelled;
    }
    setState(() => _error = null);
    final int generation = _reviewGeneration;
    final ScanCrop crop =
        item?.crop ??
        const ScanCrop(
          imagePath: '',
          width: 0,
          height: 0,
          rectified: false,
          sourceCorners: <ScanPoint>[],
          lines: <ScanTextLine>[],
        );
    _correcting = true;
    _cameraEditingId = item?.id;
    final ScanCaptureDefaults defaults = item?.defaults ?? _captureDefaults;
    final Completer<PrintingSelection?> completion =
        Completer<PrintingSelection?>();
    _correctionCompletion = completion;
    void finish([PrintingSelection? selection]) {
      if (!completion.isCompleted) completion.complete(selection);
    }

    _ScanReviewResult exit = _ScanReviewResult.cancelled;
    final PrintingSelection? review;
    try {
      setState(
        () => _correctionView = ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[
            _session,
            _destinationRevision,
          ]),
          builder: (BuildContext context, Widget? child) =>
              ScanCorrectionEditor(
                key: ValueKey<String>(item?.id ?? 'manual-correction'),
                crop: item?.crop ?? crop,
                catalog: _catalog,
                onConfirmed: finish,
                onClose: () => finish(),
                progressLabel: progressLabel,
                confirmLabel: confirmLabel ?? 'Save',
                preferredFinish:
                    item?.approval?.card.finish ??
                    item?.replacementChoices?.card.finish ??
                    defaults.finish,
                preferredQuantity:
                    item?.approval?.quantity ?? item?.replacementQuantity ?? 1,
                preferredDeckId: item?.approval != null
                    ? item!.approval!.deckId
                    : item?.replacementChoices != null
                    ? item!.replacementChoices!.deckId
                    : defaults.deckId,
                preferredDeckSection: item?.approval != null
                    ? item!.approval!.deckSection
                    : item?.replacementChoices != null
                    ? item!.replacementChoices!.deckSection
                    : defaults.deckSection,
                decks: _decks,
                initialResolution: item?.resolution,
                phase: item?.phase,
                lookupError: item?.error,
                onRetry: item == null ? null : () => _session.retryItem(item),
                onLater: item == null
                    ? null
                    : () {
                        exit = _ScanReviewResult.later;
                        finish();
                      },
                onRescan: item == null
                    ? null
                    : () {
                        exit = _ScanReviewResult.rescan;
                        finish();
                      },
                onRemove: item == null
                    ? null
                    : () async {
                        await _removeReviewCapture(item);
                        finish();
                      },
                initialSelection: item?.approval == null
                    ? null
                    : PrintingSelection(
                        card: item!.approval!.card,
                        quantity: item.approval!.quantity,
                        destinationId: item.approval!.deckId,
                        deckSection: item.approval!.deckSection,
                      ),
              ),
        ),
      );
      review = await completion.future;
    } finally {
      _correcting = false;
      _cameraEditingId = null;
      _correctionCompletion = null;
      if (mounted) setState(() => _correctionView = null);
    }
    if (review == null) return exit;
    await _autoWork;
    if (!mounted ||
        generation != _reviewGeneration ||
        (item != null &&
            (!_session.items.contains(item) || _submitted(item)))) {
      return _ScanReviewResult.cancelled;
    }
    if (item?.rescanPending == true) {
      setState(() => _busy = true);
      try {
        await _session.cancelRescan(item!);
      } catch (_) {
        if (mounted) {
          setState(() {
            _busy = false;
            _error = 'Rescan failed';
          });
        }
        return _ScanReviewResult.cancelled;
      }
      if (!mounted ||
          generation != _reviewGeneration ||
          !_session.items.contains(item)) {
        if (mounted) {
          setState(() => _busy = false);
        }
        return _ScanReviewResult.cancelled;
      }
    }
    final ScanSessionItem target =
        item ?? ScanSessionItem(crop, defaults: defaults);
    final ScanQueueApproval? previousApproval = target.approval;
    final bool wasSelected = target.selected;
    final bool wasReviewed = target.manuallyReviewed;
    target.approval = ScanQueueApproval(
      operationId: target.id,
      card: review.card,
      quantity: review.quantity,
      deckId: review.destinationId,
      deckSection: review.deckSection,
    );
    target.selected = true;
    target.manuallyReviewed = true;
    setState(() => _busy = true);
    try {
      if (item == null) _session.add(target);
      await _session.persist(<ScanSessionItem>[target]);
      _automaticSaveFailed = false;
    } catch (_) {
      target.approval = previousApproval;
      target.selected = wasSelected;
      target.manuallyReviewed = wasReviewed;
      _automaticSaveFailed = true;
      if (mounted) setState(() => _error = 'Could not save correction. Retry.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    _session.changed();
    return _session.storageError == null && _error == null
        ? _ScanReviewResult.approved
        : _ScanReviewResult.cancelled;
  }

  Future<void> _reviewCard(ScanSessionItem item) async {
    if (_busy || _reviewingBatch) return;
    final _ScanReviewResult result = await _review(
      item,
      confirmLabel: 'Confirm',
    );
    if (result == _ScanReviewResult.rescan && mounted) {
      await _rescan(item);
    } else if (mounted) {
      _scheduleAutomaticSave();
    }
  }

  Future<void> _reviewBatch() async {
    if (_busy ||
        _reviewingBatch ||
        !_queue.loaded ||
        !_session.loaded ||
        !mounted) {
      return;
    }
    _reviewingBatch = true;
    final int generation = _reviewGeneration;
    ScanSessionItem? rescan;
    try {
      setState(() {
        _error = null;
        _problemsOnly = false;
      });
      await _selectExact();
      if (!mounted ||
          generation != _reviewGeneration ||
          _error != null ||
          _session.storageError != null ||
          _session.clearingCaptures) {
        return;
      }
      final List<ScanSessionItem> pending = _visibleItems
          .where(_needsReview)
          .toList();
      if (pending.isEmpty) return;
      final int start = _cardIndex.clamp(0, _visibleItems.length - 1);
      final ScanSessionItem current = _visibleItems[start];
      final int first = pending.indexOf(current);
      final List<ScanSessionItem> ordered = first < 0
          ? pending
          : <ScanSessionItem>[...pending.skip(first), ...pending.take(first)];
      for (
        int index = 0;
        index < ordered.length && mounted && generation == _reviewGeneration;
        index++
      ) {
        final ScanSessionItem item = ordered[index];
        if (!_session.items.contains(item)) continue;
        setState(
          () => _cardIndex = _visibleItems
              .indexOf(item)
              .clamp(0, _visibleItems.length - 1),
        );
        final _ScanReviewResult result = await _review(
          item,
          progressLabel:
              'Card ${ordered.take(index + 1).where(_session.items.contains).length} of ${ordered.where(_session.items.contains).length}',
          confirmLabel: index + 1 == ordered.length ? 'Confirm' : 'Next',
        );
        if (!mounted || generation != _reviewGeneration) {
          break;
        }
        if (result == _ScanReviewResult.rescan) {
          rescan = item;
          break;
        }
        final bool confirmed = result == _ScanReviewResult.approved;
        await _selectExact();
        if (!mounted ||
            generation != _reviewGeneration ||
            _session.clearingCaptures) {
          break;
        }
        for (final ScanSessionItem arrived in _visibleItems) {
          if (_needsReview(arrived) && !ordered.contains(arrived)) {
            ordered.add(arrived);
          }
        }
        if (!_session.items.contains(item)) continue;
        if (!mounted ||
            (!confirmed && result != _ScanReviewResult.later) ||
            _session.storageError != null ||
            _error != null) {
          break;
        }
      }
    } finally {
      _reviewingBatch = false;
      if (mounted) setState(() {});
      _scheduleAutomaticSave();
    }
    if (rescan != null && mounted) await _rescan(rescan);
  }

  bool _submitted(ScanSessionItem item) =>
      _submittedIds.contains(item.id) || _queue.hasCompleted(item.id);

  bool _sameQueuedApproval(ScanSessionItem item, ScanQueueEntry entry) {
    final ScanQueueApproval? approval = item.approval;
    if (approval == null) return false;
    return CollectionIngestion.inventoryId(approval.card) ==
            CollectionIngestion.inventoryId(entry.card) &&
        approval.card.language == entry.card.language &&
        approval.quantity == entry.quantity &&
        approval.deckId == entry.deckId &&
        (approval.deckId == null || approval.deckSection == entry.deckSection);
  }

  Future<void> _reconcileQueuedCaptures() async {
    _submittedIds.addAll(
      _queue.entries.map((ScanQueueEntry entry) => entry.operationId),
    );
    final List<ScanSessionItem> retired = <ScanSessionItem>[];
    final Map<String, ScanQueueEntry> pending = <String, ScanQueueEntry>{
      for (final ScanQueueEntry entry in _queue.entries)
        entry.operationId: entry,
    };
    bool conflict = false;
    for (final ScanSessionItem item in _session.items) {
      final ScanQueueEntry? queued = pending[item.id];
      if (queued == null) {
        if (_submitted(item) && item.approval != null) retired.add(item);
        if (_queue.hasCompleted(item.id) && item.approval == null) {
          conflict = true;
        }
        continue;
      }
      if (_queue.canUndo(queued.operationId)) continue;
      if (_sameQueuedApproval(item, queued)) {
        retired.add(item);
      } else {
        conflict = true;
      }
    }
    try {
      if (retired.isNotEmpty) await _session.removeBatch(retired);
      if (_session.loaded &&
          !_restoreFailed &&
          !conflict &&
          !_session.clearingCaptures &&
          _session.storageError == null) {
        await _queue.pruneCompleted(
          _session.items.map((ScanSessionItem item) => item.id).toSet(),
        );
      }
      if (conflict && mounted) {
        _automaticSaveFailed = true;
        setState(
          () => _error = 'Submitted details differ. Check pending additions.',
        );
      }
    } catch (_) {
      _automaticSaveFailed = true;
      if (mounted) {
        setState(
          () => _error = 'Additions saved. Could not remove old reviews.',
        );
      }
    }
  }

  Future<void> _removeReviewCapture(ScanSessionItem item) async {
    if (_busy) throw StateError('A capture operation is already running.');
    if (!_session.items.contains(item) || _submitted(item)) {
      throw StateError('Capture is no longer available to remove.');
    }
    setState(() => _busy = true);
    _refreshCamera();
    try {
      await _session.remove(item);
      if (mounted) {
        setState(() {
          _cardIndex = 0;
          _trayPage = 0;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _refreshCamera();
    }
  }

  List<ScanSessionItem> get _visibleItems => _session.items
      .where((ScanSessionItem item) => !_problemsOnly || !item.manuallyReviewed)
      .toList();

  void _changeBulk(VoidCallback change) {
    setState(() {
      change();
      _automaticSaveFailed = false;
    });
    _scheduleAutomaticSave();
  }

  bool _validDestination(String? deckId) =>
      deckId == null || _decks.any((MTGDeck deck) => deck.id == deckId);

  bool _exactReady(ScanSessionItem item) {
    final MtgCard? card = item.printing;
    final ScanQueueApproval? choices = item.approval ?? item.replacementChoices;
    final Finish finish = choices?.card.finish ?? item.defaults.finish;
    return !_submitted(item) &&
        !item.rescanPending &&
        item.error == null &&
        item.exactMatch &&
        card != null &&
        card.finishes.contains(finish) &&
        (item.approval == null || item.approval!.card.printingId == card.id) &&
        _validDestination(
          choices != null ? choices.deckId : item.defaults.deckId,
        );
  }

  bool _needsReview(ScanSessionItem item) =>
      !_submitted(item) &&
      (item.rescanPending ||
          (!item.manuallyReviewed &&
              item.phase != ScanItemPhase.processing &&
              item.phase != ScanItemPhase.retrying &&
              !_exactReady(item)));

  Future<void> _selectExact() async {
    if (_finish == null || _session.clearingCaptures || !mounted) return;
    for (final ScanSessionItem item in _session.items) {
      final MtgCard? card = item.printing;
      if (item.id != _cameraEditingId &&
          _exactReady(item) &&
          card != null &&
          item.approval == null &&
          !item.manuallyReviewed) {
        final ScanQueueApproval? choices = item.replacementChoices;
        item.approval = ScanQueueApproval(
          operationId: item.id,
          card: cardFromScryfall(
            card,
            finish: choices?.card.finish ?? item.defaults.finish,
          ),
          quantity: item.replacementQuantity,
          deckId: choices != null ? choices.deckId : item.defaults.deckId,
          deckSection: choices?.deckSection ?? item.defaults.deckSection,
        );
        item.selected = true;
      }
    }
    _session.changed();
    final List<ScanSessionItem> staged = _session.items
        .where(
          (ScanSessionItem item) =>
              item.id != _cameraEditingId &&
              item.selected &&
              !item.manuallyReviewed &&
              item.approval != null &&
              !_submitted(item),
        )
        .toList();
    if (staged.isNotEmpty) await _persistDrafts(staged);
  }

  bool _validBatchDestination(List<ScanSessionItem> selected) => selected.every(
    (ScanSessionItem item) =>
        item.approval != null && _validDestination(item.approval!.deckId),
  );

  Future<void> _approveBatch({String? onlyId}) async {
    if (_busy) return;
    final List<ScanSessionItem> selected = _session.items
        .where(
          (ScanSessionItem item) =>
              (onlyId == null
                  ? item.id != _cameraEditingId
                  : item.id == onlyId) &&
              item.selected &&
              item.approval != null &&
              !item.rescanPending &&
              !_submitted(item),
        )
        .toList();
    if (selected.isEmpty) return;
    if (!_validBatchDestination(selected)) {
      setState(() {
        _automaticSaveFailed = true;
        _error = 'Destination unavailable';
      });
      return;
    }
    setState(() => _busy = true);
    _refreshCamera();
    bool queued = false;
    try {
      await _session.persist(selected);
      if (!mounted ||
          _session.clearingCaptures ||
          selected.any(
            (ScanSessionItem item) => !_session.items.contains(item),
          )) {
        return;
      }
      if (!_validBatchDestination(selected)) {
        setState(() {
          _automaticSaveFailed = true;
          _error = 'Destination unavailable';
        });
        return;
      }
      await _queue.enqueueBatch(
        selected.map((ScanSessionItem item) => item.approval!).toList(),
        undoWindow: const Duration(seconds: 10),
      );
      _submittedIds.addAll(selected.map((ScanSessionItem item) => item.id));
      queued = true;
      final List<ScanSessionItem> retired = selected
          .where((ScanSessionItem item) => !_queue.canUndo(item.id))
          .toList();
      if (retired.isNotEmpty) await _session.removeBatch(retired);
      if (mounted) {
        setState(() {
          _status = null;
          _lastAddedId = selected.last.id;
          _lastAddedName = selected.last.approval!.card.name;
        });
        _startUndoTimer();
      }
      if (_uploadFuture == null) unawaited(_saveQueue(resumePaused: false));
    } catch (_) {
      _automaticSaveFailed = true;
      if (mounted) {
        setState(
          () => _error = queued
              ? 'Additions saved. Could not remove old reviews.'
              : 'Could not save this batch on your device. Free storage and retry; your selections remain here.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _refreshCamera();
    }
  }

  void _startUndoTimer() {
    if (_undoTimer != null ||
        !_queue.entries.any(
          (ScanQueueEntry entry) => _queue.canUndo(entry.operationId),
        )) {
      return;
    }
    _undoTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        _undoTimer = null;
        return;
      }
      setState(() {});
      _refreshCamera();
      _scheduleAutomaticSave();
      if (!_queue.entries.any(
        (ScanQueueEntry entry) => _queue.canUndo(entry.operationId),
      )) {
        timer.cancel();
        _undoTimer = null;
      }
    });
  }

  Future<void> _undoAdded([String? operationId]) async {
    final String? id = operationId ?? _lastAddedId;
    if (_busy || id == null || !_queue.canUndo(id)) return;
    final ScanSessionItem? item = _session.items
        .where((ScanSessionItem item) => item.id == id)
        .firstOrNull;
    if (!_session.loaded || (item != null && item.approval == null)) return;
    setState(() => _busy = true);
    _refreshCamera();
    try {
      final bool undone = await _queue.undo(
        id,
        beforeRemove: () async {
          if (item == null) {
            return;
          }
          final bool wasReviewed = item.manuallyReviewed;
          final bool wasSelected = item.selected;
          item.manuallyReviewed = true;
          item.selected = false;
          try {
            await _session.persist(<ScanSessionItem>[item]);
          } catch (_) {
            item.manuallyReviewed = wasReviewed;
            item.selected = wasSelected;
            rethrow;
          }
        },
      );
      if (!mounted) return;
      if (undone) {
        _submittedIds.remove(id);
        setState(() {
          _lastAddedId = _queue.entries
              .where(
                (ScanQueueEntry entry) => _queue.canUndo(entry.operationId),
              )
              .lastOrNull
              ?.operationId;
          _lastAddedName = _queue.entries
              .where(
                (ScanQueueEntry entry) => entry.operationId == _lastAddedId,
              )
              .firstOrNull
              ?.card
              .name;
        });
        _session.changed();
      } else {
        setState(() => _error = 'Undo unavailable');
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Undo failed');
    } finally {
      if (mounted) setState(() => _busy = false);
      _refreshCamera();
      _scheduleAutomaticSave();
    }
  }

  Future<void> _saveQueue({bool resumePaused = true}) {
    final Future<void> prior = _uploadFuture ?? Future<void>.value();
    final Future<void> uploads = prior.then<void>(
      (_) => _uploadQueue(resumePaused: resumePaused),
    );
    _uploadFuture = uploads;
    unawaited(
      uploads.whenComplete(() {
        if (identical(_uploadFuture, uploads)) _uploadFuture = null;
      }),
    );
    return uploads;
  }

  Future<void> _uploadQueue({required bool resumePaused}) async {
    try {
      if (resumePaused) {
        await _queue.resumeUploads();
      } else {
        await _queue.flush(retryFailures: false);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not update upload status. Your additions are saved; retry the upload.',
        );
      }
    }
  }

  Future<void> _persistDrafts(Iterable<ScanSessionItem> items) async {
    try {
      await _session.persist(items);
    } catch (_) {
      _automaticSaveFailed = true;
      if (mounted) {
        setState(
          () => _error = 'Could not save your review. Free storage and retry before closing.',
        );
      }
    }
  }

  Future<void> _discard(ScanSessionItem item) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _session.remove(item);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not remove capture. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _discardRemaining() async {
    if (_busy) {
      throw StateError('The capture queue is not ready to clear.');
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    _refreshCamera();
    try {
      await _session.discardRemaining(
        protectedIds: <String>{
          ..._queue.entries.map((ScanQueueEntry entry) => entry.operationId),
          for (final ScanSessionItem item in _session.items)
            if (_queue.hasCompleted(item.id)) item.id,
        },
      );
      _reviewGeneration++;
      if (!mounted) return;
      setState(() {
        _cardIndex = 0;
        _trayPage = 0;
        _problemsOnly = false;
        _automaticSaveFailed = false;
        _startupReady = _session.loaded && _queue.loaded;
        _restoreFailed = !_queue.loaded;
        if (!_queue.loaded) {
          _error = 'Pending additions unavailable. Retry restore.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not discard remaining captures');
      }
      rethrow;
    } finally {
      if (mounted) setState(() => _busy = false);
      _refreshCamera();
    }
  }

  Future<void> _discardBatchRemaining() async {
    try {
      await _discardRemaining();
    } catch (_) {}
    _scheduleAutomaticSave();
  }

  Future<void> _clearCompleted() async {
    if (_busy) return;
    setState(() => _busy = true);
    _refreshCamera();
    try {
      await _session.clearCompleted();
      _accountingDirty = true;
      await _refreshAccounting();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not clear completed captures');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _refreshCamera();
    }
  }

  Widget _batchStatus(String? message, {bool showAdded = true}) {
    final bool needsAttention =
        _session.storageError != null ||
        _error != null ||
        _accountingError != null;
    Widget action(String text, String label, VoidCallback onPressed) =>
        Expanded(
          child: Semantics(
            button: true,
            label: label,
            onTap: onPressed,
            child: ExcludeSemantics(
              child: _touchTarget(
                GhostButton(
                  density: ButtonDensity.compact,
                  onPressed: onPressed,
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
        );
    return Row(
      children: <Widget>[
        if (message != null)
          action(
            needsAttention ? 'Attention' : 'Saved',
            '${needsAttention ? "Needs attention" : "Batch saved on device"}: $message',
            () => unawaited(_message(message)),
          ),
        if (message != null && showAdded && _queue.count > 0)
          const SizedBox(width: 8),
        if (showAdded && _queue.count > 0)
          action(
            'Added (${_queue.count})',
            '${_queue.count} additions waiting to upload',
            () => unawaited(_uploads()),
          ),
      ],
    );
  }

  Widget _accountingSummary({bool showUndo = true}) {
    final ScanAccounting? summary = _accounting;
    final int added = summary?.added ?? _queue.quantityCount;
    final int pending = summary?.pendingDelivery ?? _queue.quantityCount;
    return Wrap(
      key: const ValueKey<String>('scan-accounting'),
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        if (summary != null)
          Text(
            'Captured ${summary.captured}',
            style: const TextStyle(fontSize: 12),
          ),
        if (added > 0)
          Semantics(
            liveRegion: true,
            label: _lastAddedName == null
                ? 'Added $added'
                : 'Added $added: $_lastAddedName',
            child: pending > 0
                ? _touchTarget(
                    GhostButton(
                      onPressed: () => unawaited(_uploads()),
                      child: ExcludeSemantics(
                        child: Text(
                          'Added $added',
                          key: const ValueKey<String>('scan-added'),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  )
                : ExcludeSemantics(
                    child: Text(
                      'Added $added',
                      key: const ValueKey<String>('scan-added'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
          ),
        if ((summary?.needsCheck ?? 0) > 0)
          Text(
            'Check ${summary!.needsCheck}',
            style: const TextStyle(fontSize: 12),
          ),
        if (pending > 0)
          Text('Pending $pending', style: const TextStyle(fontSize: 12)),
        if (showUndo && _lastAddedId != null && _queue.canUndo(_lastAddedId!))
          _touchTarget(
            GhostButton(
              key: const ValueKey<String>('scan-undo'),
              onPressed: _busy ? null : _undoAdded,
              child: const Text('Undo', style: TextStyle(fontSize: 14)),
            ),
          ),
      ],
    );
  }

  bool get _hasCaptures =>
      _session.items.isNotEmpty ||
      (_restoreFailed && !_session.loaded) ||
      _session.running ||
      _session.remainingPhotos > 0 ||
      _session.pendingDetailSources > 0 ||
      _session.failedPhotos > 0;

  Widget _clearCaptureButton(bool ready) => _touchTarget(
    GhostButton(
      key: const ValueKey<String>('scan-discard-remaining'),
      density: ButtonDensity.compact,
      onPressed: ready ? _discardBatchRemaining : null,
      child: const Icon(
        Icons.trash,
        size: 18,
        semanticLabel: 'Discard remaining',
      ),
    ),
  );

  @override
  void dispose() {
    final Completer<PrintingSelection?>? correction = _correctionCompletion;
    if (correction != null && !correction.isCompleted) correction.complete();
    _undoTimer?.cancel();
    unawaited(_subscription?.cancel());
    _queue.removeListener(_changed);
    _session.removeListener(_changed);
    _drafts?.accountingChanges.removeListener(_accountingChanged);
    _accountingRevision++;
    _session.dispose();
    _destinationRevision.dispose();
    _cameraRevision.dispose();
    if (widget.queue == null) {
      final Future<void>? uploads = _uploadFuture;
      if (uploads == null) {
        _queue.dispose();
      } else {
        unawaited(uploads.whenComplete(_queue.dispose));
      }
    }
    if (widget.resolver == null && _resolver.catalog is ScryfallScanCatalog) {
      (_resolver.catalog as ScryfallScanCatalog).close();
    }
    if (widget.catalog == null) _catalog.close();
    super.dispose();
  }

  Widget _touchTarget(Widget child) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
    child: child,
  );

  Widget _optionSwitch(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) => MergeSemantics(
    child: Row(
      children: <Widget>[
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        _touchTarget(Switch(value: value, onChanged: onChanged)),
      ],
    ),
  );

  Future<void> _captureOptions() async {
    if (_busy) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter updateDialog) =>
            ArcaneDialog(
              title: const Text('Capture options'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _optionSwitch('Keep camera open', _continuous, (bool value) {
                    if (!mounted || !context.mounted) return;
                    setState(() => _continuous = value);
                    updateDialog(() {});
                  }),
                  if (defaultTargetPlatform == TargetPlatform.iOS) ...<Widget>[
                    const SizedBox(height: 12),
                    _optionSwitch('Multiple cards per photo', _multiple, (
                      bool value,
                    ) {
                      if (!mounted || !context.mounted) return;
                      setState(() => _multiple = value);
                      updateDialog(() {});
                    }),
                  ] else ...<Widget>[
                    const SizedBox(height: 12),
                    const Text('Android: one card per photo'),
                  ],
                ],
              ),
              actions: <Widget>[
                _touchTarget(
                  PrimaryButton(
                    density: ButtonDensity.normal,
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
      ),
    );
  }

  Future<void> _batchOptions() async {
    if (_busy) return;
    setState(() => _editingDefaults = true);
    try {
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => StatefulBuilder(
          builder: (BuildContext context, StateSetter updateDialog) => ArcaneDialog(
            title: const Text('Scan defaults'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text('Finish for exact matches'),
                const SizedBox(height: 8),
                _touchTarget(
                  Selector<Finish>(
                    value: _finish,
                    values: const <Finish>[
                      Finish.nonfoil,
                      Finish.foil,
                      Finish.etched,
                      Finish.glossy,
                    ],
                    labelBuilder: (Finish value) =>
                        value == Finish.nonfoil ? 'Normal' : value.name,
                    onChanged: (Finish? value) {
                      if (!mounted || !context.mounted) return;
                      _changeBulk(() => _finish = value);
                      updateDialog(() {});
                    },
                  ),
                ),
                ...<Widget>[
                  const SizedBox(height: 12),
                  const Text('Destination'),
                  const SizedBox(height: 8),
                  _touchTarget(
                    Selector<String>(
                      value: _deck,
                      values: <String>[
                        '',
                        ..._decks
                            .where((MTGDeck deck) => deck.id != null)
                            .map((MTGDeck deck) => deck.id!),
                      ],
                      labelBuilder: (String value) => value.isEmpty
                          ? 'Collection'
                          : 'Collection + ${_decks.where((MTGDeck deck) => deck.id == value).firstOrNull?.name ?? 'Unavailable container'}',
                      onChanged: (String? value) {
                        if (!mounted || !context.mounted) return;
                        _changeBulk(() {
                          _deck = value ?? '';
                          if (_decks
                                  .where((MTGDeck deck) => deck.id == _deck)
                                  .firstOrNull
                                  ?.kind !=
                              CollectionGroupKind.deck) {
                            _section = DeckSection.mainboard;
                          }
                        });
                        updateDialog(() {});
                      },
                    ),
                  ),
                ],
                if (_deck.isNotEmpty &&
                    _decks
                            .where((MTGDeck deck) => deck.id == _deck)
                            .firstOrNull
                            ?.kind ==
                        CollectionGroupKind.deck) ...<Widget>[
                  const SizedBox(height: 12),
                  const Text('Deck section'),
                  const SizedBox(height: 8),
                  _touchTarget(
                    Selector<DeckSection>(
                      value: _section,
                      values: CollectionIngestion.destinationSections,
                      labelBuilder: (DeckSection value) => value.name,
                      onChanged: (DeckSection? value) {
                        if (!mounted || !context.mounted) return;
                        _changeBulk(
                          () => _section = value ?? DeckSection.mainboard,
                        );
                        updateDialog(() {});
                      },
                    ),
                  ),
                ],
              ],
            ),
            actions: <Widget>[
              _touchTarget(
                PrimaryButton(
                  density: ButtonDensity.normal,
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _editingDefaults = false);
    }
  }

  Future<void> _more() async {
    setState(() => _sessionMenuOpen = true);
    try {
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => ArcaneDialog(
          title: const Text('Session'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_accountingError != null)
                _touchTarget(
                  SecondaryButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      _accountingDirty = true;
                      unawaited(_refreshAccounting());
                    },
                    child: const Text('Retry totals'),
                  ),
                ),
              _touchTarget(
                GhostButton(
                  key: const ValueKey<String>('scan-clear-completed'),
                  onPressed: _busy
                      ? null
                      : () {
                          Navigator.pop(dialogContext);
                          unawaited(_clearCompleted());
                        },
                  child: const Text('Clear completed'),
                ),
              ),
              if (_automaticSaveFailed)
                _touchTarget(
                  SecondaryButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      setState(() {
                        _automaticSaveFailed = false;
                        _error = null;
                      });
                      _scheduleAutomaticSave();
                    },
                    child: const Text('Retry save'),
                  ),
                ),
              if (NativeCardRecognizer.supported)
                _touchTarget(
                  SecondaryButton(
                    density: ButtonDensity.normal,
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      unawaited(_gallery());
                    },
                    child: const Text('Select photos'),
                  ),
                ),
              const SizedBox(height: 8),
              _touchTarget(
                SecondaryButton(
                  density: ButtonDensity.normal,
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    unawaited(_review(null));
                  },
                  child: const Text('Enter card details'),
                ),
              ),
              if (_session.items.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                _touchTarget(
                  SecondaryButton(
                    density: ButtonDensity.normal,
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      unawaited(_batchOptions());
                    },
                    child: const Text('Batch options'),
                  ),
                ),
                const SizedBox(height: 8),
                _touchTarget(
                  GhostButton(
                    density: ButtonDensity.normal,
                    onPressed: () {
                      setState(() {
                        _problemsOnly = !_problemsOnly;
                        _cardIndex = 0;
                        _trayPage = 0;
                      });
                      Navigator.pop(dialogContext);
                    },
                    child: Text(
                      _problemsOnly ? 'Show all cards' : 'Needs review only',
                    ),
                  ),
                ),
              ],
              if (_session.running || _session.paused)
                _touchTarget(
                  GhostButton(
                    density: ButtonDensity.normal,
                    onPressed: () {
                      _session.paused ? _session.resume() : _session.pause();
                      Navigator.pop(dialogContext);
                    },
                    child: Text(
                      _session.paused ? 'Resume reading' : 'Pause reading',
                    ),
                  ),
                ),
              if (!_session.running &&
                  (_session.failedPhotos > 0 ||
                      _session.items.any(
                        (ScanSessionItem item) =>
                            item.approval == null &&
                            (item.error != null || item.resolution == null),
                      )))
                _touchTarget(
                  SecondaryButton(
                    density: ButtonDensity.normal,
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      unawaited(_session.retryUnresolved());
                    },
                    child: const Text('Retry reading'),
                  ),
                ),
            ],
          ),
          actions: <Widget>[
            _touchTarget(
              GhostButton(
                density: ButtonDensity.normal,
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _sessionMenuOpen = false);
    }
  }

  Future<void> _message(String message) => showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => ArcaneDialog(
      title: const Text('Scan status'),
      content: Text(message),
      actions: <Widget>[
        _touchTarget(
          PrimaryButton(
            density: ButtonDensity.normal,
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Done'),
          ),
        ),
      ],
    ),
  );

  Widget _cardImage(ScanSessionItem item) {
    final MtgCard? printing = item.printing;
    final ScanQueueApproval? approval = item.approval;
    final String? image =
        approval?.card.imageUrl ??
        printing?.imageUris?.normal.toString() ??
        printing?.cardFaces?.firstOrNull?.imageUris?.normal.toString();
    const Widget unavailable = Center(
      child: Icon(Icons.image, size: 20, semanticLabel: 'Artwork unavailable'),
    );
    final Widget captured = item.crop.imagePath.isEmpty || kIsWeb
        ? unavailable
        : Image.file(
            File(item.crop.imagePath),
            fit: BoxFit.contain,
            cacheWidth: 512,
            excludeFromSemantics: true,
            errorBuilder: (
              BuildContext context,
              Object error,
              StackTrace? stack,
            ) => unavailable,
          );
    return image == null || image.isEmpty
        ? captured
        : Image.network(
            image,
            key: ValueKey<String>('scan-thumbnail-${item.id}'),
            fit: BoxFit.contain,
            cacheWidth: 512,
            excludeFromSemantics: true,
            errorBuilder: (
              BuildContext context,
              Object error,
              StackTrace? stack,
            ) => captured,
          );
  }

  Widget _batchTile(ScanSessionItem item) {
    final bool blocked = _busy || _reviewingBatch;
    final ScanQueueApproval? approval = item.approval;
    final MtgCard? printing = item.printing;
    final String name =
        approval?.card.name ??
        printing?.name ??
        ScanHints.fromCrop(item.crop).names.firstOrNull ??
        'Unresolved card';
    final String? set = approval?.card.setCode ?? printing?.set;
    final String? number =
        approval?.card.collectorNumber ?? printing?.collectorNumber;
    final String status = _submitted(item)
        ? 'Added'
        : item.rescanPending
        ? 'Rescan'
        : item.manuallyReviewed
        ? '${approval?.quantity ?? 1} × ${approval?.card.finish == Finish.nonfoil ? 'Normal' : approval?.card.finish?.name ?? 'confirmed'} · Reviewed'
        : switch (item.phase) {
            ScanItemPhase.processing => 'Reading',
            ScanItemPhase.retrying => 'Retrying',
            ScanItemPhase.lookupFailed => 'Lookup failed',
            ScanItemPhase.noIdentity => 'Unmatched',
            ScanItemPhase.needsReview => 'Check printing',
            ScanItemPhase.ready => 'Ready',
          };
    final bool accessible = MediaQuery.textScalerOf(context).scale(13) > 21;
    Widget cornerControl(Widget control) => DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.background,
        borderRadius: BorderRadius.zero,
      ),
      child: SizedBox.square(dimension: 44, child: control),
    );
    return Stack(
      key: ValueKey<String>('scan-card-${item.id}'),
      fit: StackFit.expand,
      children: <Widget>[
        Semantics(
          button: true,
          enabled: !blocked && !_submitted(item),
          label: 'Review $name',
          value: status,
          child: GhostButton(
            onPressed: blocked || _submitted(item)
                ? null
                : () {
                    _cardIndex = _visibleItems.indexOf(item);
                    unawaited(_reviewCard(item));
                  },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: _cardImage(item)),
                const SizedBox(height: 4),
                Text(
                  name,
                  maxLines: accessible ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (set != null && number != null)
                  Text(
                    '${set.toUpperCase()} #$number',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                Text(
                  status,
                  maxLines: accessible ? null : 1,
                  overflow: accessible ? null : TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (approval != null)
          Positioned(
            top: 0,
            left: 0,
            child: cornerControl(
              Semantics(
                selected: item.selected,
                child: IconButton(
                  density: ButtonDensity.iconDense,
                  variance: item.selected
                      ? ButtonVariance.secondary
                      : ButtonVariance.ghost,
                  icon: Icon(
                    item.selected ? Icons.check_square : Icons.square,
                    semanticLabel: item.selected
                        ? 'Deselect captured card'
                        : 'Select captured card',
                  ),
                  onPressed: blocked || _submitted(item)
                      ? null
                      : () {
                          item.selected = !item.selected;
                          _session.changed();
                          unawaited(_persistDrafts(<ScanSessionItem>[item]));
                        },
                ),
              ),
            ),
          ),
        Positioned(
          top: 0,
          right: 0,
          child: cornerControl(
            IconButton(
              density: ButtonDensity.iconDense,
              icon: const Icon(Icons.x, semanticLabel: 'Discard capture'),
              onPressed: blocked ? null : () => unawaited(_discard(item)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _batchTray(List<ScanSessionItem> items) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final bool accessible = MediaQuery.textScalerOf(context).scale(12) > 20;
      final double minimumHeight = accessible ? 320 : 150;
      final int columns = accessible || constraints.maxWidth < 280
          ? 1
          : constraints.maxWidth >= 600
          ? 3
          : 2;
      final double contentHeight = constraints.maxHeight - 44;
      final int rows = ((contentHeight + 6) / (minimumHeight + 6))
          .floor()
          .clamp(1, 3);
      final int capacity = (columns * rows).clamp(1, 6);
      final int pages = (items.length / capacity).ceil();
      final int page = _trayPage.clamp(0, pages - 1);
      final List<ScanSessionItem> visible = items
          .skip(page * capacity)
          .take(capacity)
          .toList();
      final int visibleRows = (visible.length / columns).ceil();
      final double rowHeight = visibleRows == 0
          ? minimumHeight
          : ((contentHeight - 6 * (visibleRows - 1)) / visibleRows).clamp(
              minimumHeight,
              accessible ? 440 : 260,
            );
      final List<Widget> tileRows = <Widget>[
        for (int row = 0; row < visibleRows; row++)
          SizedBox(
            height: rowHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int column = 0; column < columns; column++) ...<Widget>[
                  if (column > 0) const SizedBox(width: 6),
                  Expanded(
                    child: row * columns + column < visible.length
                        ? _batchTile(visible[row * columns + column])
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
      ];
      final Widget tiles = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int row = 0; row < tileRows.length; row++) ...<Widget>[
            if (row > 0) const SizedBox(height: 6),
            tileRows[row],
          ],
        ],
      );
      return Column(
        children: <Widget>[
          Expanded(
            child: contentHeight < minimumHeight
                ? SingleChildScrollView(child: tiles)
                : Align(alignment: Alignment.topCenter, child: tiles),
          ),
          if (pages > 1)
            Row(
              children: <Widget>[
                SizedBox.square(
                  dimension: 44,
                  child: IconButton(
                    key: const ValueKey<String>('scan-tray-previous'),
                    icon: const Icon(
                      Icons.caret_left,
                      semanticLabel: 'Previous captured cards',
                    ),
                    onPressed: page > 0
                        ? () => setState(() => _trayPage = page - 1)
                        : null,
                  ),
                ),
                Expanded(
                  child: Text(
                    '${page * capacity + 1}–${page * capacity + visible.length} / ${items.length}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                SizedBox.square(
                  dimension: 44,
                  child: IconButton(
                    key: const ValueKey<String>('scan-tray-next'),
                    icon: const Icon(
                      Icons.caret_right,
                      semanticLabel: 'Next captured cards',
                    ),
                    onPressed: page + 1 < pages
                        ? () => setState(() => _trayPage = page + 1)
                        : null,
                  ),
                ),
              ],
            ),
        ],
      );
    },
  );

  Future<void> _uploads() async {
    int index = 0;
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => ListenableBuilder(
        listenable: _queue,
        builder: (BuildContext context, Widget? child) => StatefulBuilder(
          builder: (BuildContext context, StateSetter updateDialog) {
            final ScanQueueEntry? entry = _queue.count == 0
                ? null
                : _queue.entryAt(index.clamp(0, _queue.count - 1));
            return ArcaneDialog(
              title: Text('${_queue.count} waiting to upload'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (entry != null) ...<Widget>[
                    Text('${entry.quantity} × ${entry.card.name}'),
                    Text(
                      '${entry.card.setCode} · ${entry.card.collectorNumber} · ${entry.card.finish?.name ?? 'confirmed finish'}',
                    ),
                    if (entry.error != null) Text(entry.error!),
                    if (_queue.isSending(entry.operationId))
                      const Text('Uploading…'),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        _touchTarget(
                          IconButton(
                            icon: const Icon(
                              Icons.caret_left,
                              semanticLabel: 'Previous addition',
                            ),
                            onPressed: index > 0
                                ? () => updateDialog(() => index--)
                                : null,
                          ),
                        ),
                        Text(
                          '${index.clamp(0, _queue.count - 1) + 1} / ${_queue.count}',
                        ),
                        _touchTarget(
                          IconButton(
                            icon: const Icon(
                              Icons.caret_right,
                              semanticLabel: 'Next addition',
                            ),
                            onPressed: index + 1 < _queue.count
                                ? () => updateDialog(() => index++)
                                : null,
                          ),
                        ),
                      ],
                    ),
                    _touchTarget(
                      GhostButton(
                        density: ButtonDensity.normal,
                        onPressed: _queue.isSending(entry.operationId)
                            ? null
                            : () => _removePending(entry),
                        child: const Text('Remove pending addition'),
                      ),
                    ),
                  ] else
                    const Text('All additions uploaded.'),
                  if (entry != null)
                    _touchTarget(
                      SecondaryButton(
                        density: ButtonDensity.normal,
                        onPressed: _queue.sending && !_queue.paused
                            ? _queue.pauseUploads
                            : _saveQueue,
                        child: Text(
                          _queue.sending && !_queue.paused
                              ? 'Pause uploads'
                              : _queue.paused
                              ? 'Resume uploads'
                              : 'Upload approved additions',
                        ),
                      ),
                    ),
                ],
              ),
              actions: <Widget>[
                _touchTarget(
                  GhostButton(
                    density: ButtonDensity.normal,
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Done'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _removePending(ScanQueueEntry entry) async {
    final bool? remove = await DialogConfirm(
      title: 'Remove pending addition?',
      description:
          '${entry.quantity} × ${entry.card.name}. Already uploaded copies stay saved in your collection or deck.',
      destructive: true,
      confirmText: 'Remove addition',
      onConfirm: () {},
    ).open<bool>(context);
    if (remove != true || !mounted) return;
    try {
      await _queue.remove(entry.operationId);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not remove this addition. Retry after its upload finishes.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.background,
    child: SafeArea(child: _workspace(context)),
  );

  Widget _workspace(BuildContext context) {
    if (_cameraOpened && NativeCardRecognizer.supported) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_correctionView == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: GhostButton(
                      key: const ValueKey<String>('scan-defaults'),
                      onPressed: _busy ? null : _batchOptions,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '$_destinationName · ${_finish == Finish.nonfoil ? 'Normal' : _finish?.name ?? 'Finish'}',
                          style: const TextStyle(fontSize: 13),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                  _touchTarget(
                    IconButton(
                      icon: const Icon(
                        Icons.dots_three,
                        semanticLabel: 'Session actions',
                      ),
                      onPressed: _busy ? null : _more,
                    ),
                  ),
                ],
              ),
            ),
          if (_cameraVisible && _correctionView == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _accountingSummary(showUndo: false),
            ),
          Expanded(
            child: IndexedStack(
              index: _correctionView != null
                  ? 2
                  : _cameraVisible
                  ? 0
                  : 1,
              children: <Widget>[
                TickerMode(
                  enabled:
                      widget.active &&
                      _cameraVisible &&
                      _correctionView == null,
                  child: _cameraWorkspace(),
                ),
                TickerMode(
                  enabled:
                      widget.active &&
                      !_cameraVisible &&
                      _correctionView == null,
                  child: _batchWorkspace(context),
                ),
                _correctionView ?? const SizedBox.shrink(),
              ],
            ),
          ),
        ],
      );
    }
    return _correctionView ?? _batchWorkspace(context);
  }

  Widget _batchWorkspace(BuildContext context) {
    final bool native = NativeCardRecognizer.supported;
    final bool ready =
        _queue.loaded && _session.loaded && !_busy && !_reviewingBatch;
    final List<ScanSessionItem> items = _visibleItems;
    final int reviewable = items.where(_needsReview).length;
    final bool reading =
        _session.pendingPhotoCaptures + _session.pendingDetailSources >
            _session.failedPhotos ||
        _session.pendingRecognitionCards > 0;
    final String? message =
        _session.storageError ?? _error ?? _accountingError ?? _status;
    final String destination = _destinationName;
    final bool accessible = MediaQuery.textScalerOf(context).scale(14) > 21;
    final List<Widget> reviewActions = <Widget>[
      if (reviewable > 0)
        _touchTarget(
          PrimaryButton(
            onPressed: ready ? _reviewBatch : null,
            child: Text(
              'Check ($reviewable)',
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ),
    ];
    return PopScope<Object?>(
      canPop: !_busy,
      child: Scaffold(
        headers: <Widget>[
          if (!usesSwipeBack)
            AppBar(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              leading: <Widget>[
                _touchTarget(
                  IconButton(
                    icon: const Icon(Icons.arrow_left, semanticLabel: 'Back'),
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
        ],
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            destination,
                            softWrap: true,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (_hasCaptures)
                          _clearCaptureButton(
                            !_busy && !_session.clearingCaptures,
                          ),
                      ],
                    ),
                    if (message != null)
                      _batchStatus(message, showAdded: false),
                    _accountingSummary(),
                    if (!ready && !_busy && message == null)
                      const CollectorLoading(label: 'Restoring…'),
                    if ((!_queue.loaded || !_session.loaded) && message != null)
                      _touchTarget(
                        SecondaryButton(
                          onPressed: _load,
                          child: const Text('Retry restore'),
                        ),
                      ),
                    if (reading || _session.paused)
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _session.paused ? 'Reading paused' : 'Reading…',
                          key: const ValueKey<String>('scan-reading-saved'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    Expanded(
                      child: items.isNotEmpty
                          ? _batchTray(items)
                          : Center(
                              child: reading
                                  ? const CollectorLoading(
                                      label: 'Saved · Identifying…',
                                    )
                                  : Text(
                                      _session.failedPhotos > 0
                                          ? 'Read failed'
                                          : _problemsOnly &&
                                                _session.items.isNotEmpty
                                          ? 'All cards reviewed'
                                          : 'Ready',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(fontSize: 14),
                                    ),
                            ),
                    ),
                    if (reviewActions.isNotEmpty) ...<Widget>[
                      if (accessible)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            for (
                              int i = 0;
                              i < reviewActions.length;
                              i++
                            ) ...<Widget>[
                              if (i > 0) const SizedBox(height: 4),
                              reviewActions[i],
                            ],
                          ],
                        )
                      else
                        Row(
                          children: <Widget>[
                            for (
                              int i = 0;
                              i < reviewActions.length;
                              i++
                            ) ...<Widget>[
                              if (i > 0) const SizedBox(width: 6),
                              Expanded(child: reviewActions[i]),
                            ],
                          ],
                        ),
                      const SizedBox(height: 4),
                    ],
                    _touchTarget(
                      SecondaryButton(
                        key: const ValueKey<String>('scan-continue'),
                        onPressed: ready
                            ? (native ? _capture : () => _review(null))
                            : null,
                        child: Text(
                          native ? 'Continue scanning' : 'Enter card details',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                    ),
                    Row(
                      children: <Widget>[
                        if (native)
                          _touchTarget(
                            IconButton(
                              icon: const Icon(
                                Icons.sliders,
                                semanticLabel: 'Capture options',
                              ),
                              onPressed: ready ? _captureOptions : null,
                            ),
                          ),
                        _touchTarget(
                          IconButton(
                            icon: const Icon(
                              Icons.dots_three,
                              semanticLabel: 'More scan actions',
                            ),
                            onPressed: ready ? _more : null,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
