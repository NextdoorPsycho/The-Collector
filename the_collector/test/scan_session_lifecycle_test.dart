import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collector_models/deck/deck_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_capture_defaults.dart';
import 'package:the_collector/utils/scanning/scan_queue.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_session.dart';

class _Recognizer implements CardRecognizer {
  _Recognizer(this.crop, {this.multiple = false});
  final ScanCrop crop;
  final bool multiple;

  @override
  Future<ScanRecognition> recognize(
    String imagePath, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async => ScanRecognition(
    imagePath: imagePath,
    width: 1000,
    height: 1400,
    crops: <ScanCrop>[crop, if (multiple) crop],
  );
}

class _DelayedRecognizer implements CardRecognizer {
  final Completer<void> admitted = Completer<void>();
  final Completer<ScanRecognition> result = Completer<ScanRecognition>();

  @override
  Future<ScanRecognition> recognize(
    String imagePath, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) {
    admitted.complete();
    return result.future;
  }
}

class _DelayedResolver extends ScanResolver {
  final Completer<void> admitted = Completer<void>();
  final Completer<List<ScanResolution>> result =
      Completer<List<ScanResolution>>();

  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) {
    admitted.complete();
    return result.future;
  }
}

class _PausedImportStore extends ScanDraftStore {
  _PausedImportStore() : super(userId: 'lifecycle');
  final Completer<void> admitted = Completer<void>();
  final Completer<void> resumeImport = Completer<void>();
  int calls = 0;

  @override
  Future<List<ScanDraftPhoto>> importPhotos(
    Iterable<String> paths, {
    required bool multipleCards,
    bool ownedCameraSource = false,
    List<List<ScanPoint>> excludedRegions = const <List<ScanPoint>>[],
    ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
  }) async {
    calls++;
    if (calls == 1) {
      admitted.complete();
      await resumeImport.future;
    }
    return super.importPhotos(
      paths,
      multipleCards: multipleCards,
      ownedCameraSource: ownedCameraSource,
      excludedRegions: excludedRegions,
      defaults: defaults,
    );
  }
}

class _ImmediateResolver extends ScanResolver {
  _ImmediateResolver(this.card);
  final MtgCard card;
  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) async =>
      crops.map((ScanCrop _) => _resolution(card)).toList();
}

class _FirstDelayedResolver extends ScanResolver {
  _FirstDelayedResolver(this.card);
  final MtgCard card;
  final Completer<void> admitted = Completer<void>();
  final Completer<List<ScanResolution>> first =
      Completer<List<ScanResolution>>();
  int calls = 0;
  int active = 0;
  int maximumActive = 0;
  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) async {
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      if (++calls == 1) {
        admitted.complete();
        return await first.future;
      }
      return crops.map((ScanCrop _) => _resolution(card)).toList();
    } finally {
      active--;
    }
  }
}

class _FirstDelayedRecognizer implements CardRecognizer {
  _FirstDelayedRecognizer(this.crop);
  final ScanCrop crop;
  final Completer<void> admitted = Completer<void>();
  final Completer<ScanRecognition> first = Completer<ScanRecognition>();
  int calls = 0;
  @override
  Future<ScanRecognition> recognize(
    String path, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) {
    if (++calls == 1) {
      admitted.complete();
      return first.future;
    }
    return _Recognizer(crop).recognize(
      path,
      multipleCards: multipleCards,
      targetRegions: targetRegions,
    );
  }
}

class _PausedUpsertStore extends ScanDraftStore {
  _PausedUpsertStore() : super(userId: 'lifecycle');
  final Completer<void> admitted = Completer<void>();
  final Completer<void> resumeWrite = Completer<void>();
  bool first = true;
  @override
  Future<List<ScanDraftItem>> upsertItems(List<ScanDraftItem> items) async {
    if (first) {
      first = false;
      admitted.complete();
      await resumeWrite.future;
    }
    return super.upsertItems(items);
  }
}

class _FailingClearStore extends ScanDraftStore {
  _FailingClearStore() : super(userId: 'lifecycle');
  bool fail = true;
  @override
  Future<void> clearCaptures() {
    if (fail) {
      return Future<void>.error(
        const FileSystemException('Storage unavailable'),
      );
    }
    return super.clearCaptures();
  }
}

class _PausedReadStore extends ScanDraftStore {
  _PausedReadStore({this.failAfterResume = false}) : super(userId: 'lifecycle');
  final bool failAfterResume;
  final Completer<void> admitted = Completer<void>();
  final Completer<void> resumeRead = Completer<void>();
  @override
  Future<List<ScanDraftItem>> readItems() async {
    final List<ScanDraftItem> snapshot = await super.readItems();
    admitted.complete();
    await resumeRead.future;
    if (failAfterResume) throw const FileSystemException('Late load failure');
    return snapshot;
  }
}

class _PausedClearStore extends ScanDraftStore {
  _PausedClearStore() : super(userId: 'lifecycle');
  final Completer<void> admitted = Completer<void>();
  final Completer<void> resumeClear = Completer<void>();
  @override
  Future<void> clearCaptures() async {
    admitted.complete();
    await resumeClear.future;
    await super.clearCaptures();
  }
}

ScanCrop _crop(String path) => ScanCrop(
  imagePath: path,
  width: 1000,
  height: 1400,
  rectified: true,
  sourceCorners: const <ScanPoint>[],
  lines: const <ScanTextLine>[],
);

ScanResolution _resolution(MtgCard card) => ScanResolution(
  hints: ScanHints(names: <String>[card.name]),
  candidates: <ScanCandidate>[
    ScanCandidate(card, <ScanEvidence>{ScanEvidence.nameMatch}),
  ],
  status: ScanResolutionStatus.needsReview,
);

Future<void> _settle(ScanSession session) async {
  await (() async {
    while (session.running) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  })().timeout(const Duration(seconds: 5));
}

void main() {
  late Directory directory;
  late File gallery;
  late MtgCard printing;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'collector-session-lifecycle-',
    );
    Hive.init(directory.path);
    gallery = await File('${directory.path}/gallery.jpg')
        .writeAsBytes(<int>[1, 2, 3, 4]);
    printing = MtgCard.fromJson(
      Map<String, Object?>.from(
        jsonDecode(
          await File('test/fixtures/scryfall_split_card.json').readAsString(),
        ) as Map<Object?, Object?>,
      ),
    );
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('clear removes local captures and receipts across restart while preserving uploads', () async {
    final ScanDraftStore store = ScanDraftStore(userId: 'lifecycle');
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(_crop(gallery.path)),
      resolver: _ImmediateResolver(printing),
      store: store,
    );
    addTearDown(session.dispose);
    session.pause();
    await session.addPhotos(<String>[gallery.path], multipleCards: true);
    final ScanDraftPhoto pending = (await store.readPhotos()).single;
    final ScanSessionItem item = ScanSessionItem(
      _crop(gallery.path),
      id: 'live_retained_card',
    )..liveCaptureReceiptId = 'live_retained_card';
    session.add(item);
    await session.persist(<ScanSessionItem>[item]);
    final String ownedCrop = item.crop.imagePath;
    final HiveScanQueueStorage queue = HiveScanQueueStorage();
    await queue.upsertEntries('lifecycle', <ScanQueueEntry>[
      ScanQueueEntry(
        operationId: 'already-added',
        card: cardFromScryfall(printing, finish: Finish.nonfoil),
        quantity: 3,
        createdAt: DateTime.now(),
      ),
    ]);
    await session.clearCaptures();
    await store.cleanPendingImages();
    expect(session.items, isEmpty);
    expect(session.remainingPhotos, 0);
    expect(session.failedPhotos, 0);
    expect(session.pendingRecognitionCards, 0);
    expect(session.photosQueued, 0);
    expect(session.photosRead, 0);
    expect(session.captureReadComplete(<String>[gallery.path]), isFalse);
    expect(await store.readItems(), isEmpty);
    expect(await store.readPhotos(), isEmpty);
    expect(await store.readSource(pending.id), isNull);
    expect(await File(pending.imagePath).exists(), isFalse);
    expect(await File(ownedCrop).exists(), isFalse);
    expect(await gallery.exists(), isTrue);
    expect((await queue.readEntries('lifecycle')).single.quantity, 3);
    final ScanSession restarted = ScanSession(
      recognizer: _Recognizer(_crop(gallery.path)),
      resolver: _ImmediateResolver(printing),
      store: ScanDraftStore(userId: 'lifecycle'),
    );
    addTearDown(restarted.dispose);
    restarted.pause();
    await restarted.load();
    expect(restarted.items, isEmpty);
    expect(restarted.remainingPhotos, 0);
  });

  test(
    'clear invalidates a busy OCR result and releases its late temporary crop',
    () async {
      final ScanDraftStore store = ScanDraftStore(userId: 'lifecycle');
      final _DelayedRecognizer recognizer = _DelayedRecognizer();
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: _ImmediateResolver(printing),
        store: store,
      );
      addTearDown(session.dispose);
      await session.addPhotos(<String>[gallery.path], multipleCards: true);
      await recognizer.admitted.future;
      await session.clearCaptures();
      final Directory crops = await Directory('${directory.path}/ScanCrops')
          .create();
      final File late = await File('${crops.path}/late.jpg')
          .writeAsBytes(<int>[8]);
      recognizer.result.complete(
        ScanRecognition(
          imagePath: gallery.path,
          width: 1000,
          height: 1400,
          crops: <ScanCrop>[_crop(late.path)],
        ),
      );
      await _settle(session);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.items, isEmpty);
      expect(session.failedPhotos, 0);
      expect(session.photosRead, 0);
      expect(await store.readItems(), isEmpty);
      expect(await store.readPhotos(), isEmpty);
      expect(await late.exists(), isFalse);
    },
  );

  test(
    'clear releases OCR crops waiting behind an admitted item write',
    () async {
      final _PausedUpsertStore store = _PausedUpsertStore();
      final _DelayedRecognizer recognizer = _DelayedRecognizer();
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: _ImmediateResolver(printing),
        store: store,
      );
      addTearDown(session.dispose);
      final ScanSessionItem blocker = ScanSessionItem(
        _crop(gallery.path),
        id: 'blocking-write',
      );
      session.add(blocker);
      final Future<void> write = session.persist(<ScanSessionItem>[blocker]);
      await store.admitted.future;
      await session.addPhotos(<String>[gallery.path], multipleCards: true);
      await recognizer.admitted.future;
      final Directory crops = await Directory('${directory.path}/ScanCrops')
          .create();
      final File crop = await File('${crops.path}/unpublished.jpg')
          .writeAsBytes(<int>[9]);
      recognizer.result.complete(
        ScanRecognition(
          imagePath: gallery.path,
          width: 1000,
          height: 1400,
          crops: <ScanCrop>[_crop(crop.path)],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final Future<void> clear = session.clearCaptures();
      store.resumeWrite.complete();
      await write;
      await clear;
      await _settle(session);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await crop.exists(), isFalse);
      expect(session.items, isEmpty);
      expect(await store.readItems(), isEmpty);
      expect(await store.readPhotos(), isEmpty);
    },
  );

  test('clear invalidates a busy printing lookup without resurrecting stored review', () async {
    final ScanDraftStore store = ScanDraftStore(userId: 'lifecycle');
    final _DelayedResolver resolver = _DelayedResolver();
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(_crop(gallery.path)),
      resolver: resolver,
      store: store,
    );
    addTearDown(session.dispose);
    await session.addPhotos(<String>[gallery.path], multipleCards: true);
    await resolver.admitted.future;
    expect(session.items, isNotEmpty);
    await session.clearCaptures();
    expect(session.running, isFalse);
    resolver.result.complete(<ScanResolution>[_resolution(printing)]);
    await _settle(session);
    expect(session.items, isEmpty);
    expect(session.pendingRecognitionCards, 0);
    expect(await store.readItems(), isEmpty);
    expect(await store.readPhotos(), isEmpty);
  });

  test('a cleared review is ready while old lookup drains and new capture still resolves', () async {
    final ScanDraftStore store = ScanDraftStore(userId: 'lifecycle');
    final _FirstDelayedResolver resolver = _FirstDelayedResolver(printing);
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(_crop(gallery.path)),
      resolver: resolver,
      store: store,
    );
    addTearDown(session.dispose);
    await session.addPhotos(<String>[gallery.path], multipleCards: false);
    await resolver.admitted.future;
    await session.clearCaptures();
    expect(session.running, isFalse);
    expect(session.pendingRecognitionCards, 0);
    await session.addPhotos(<String>[gallery.path], multipleCards: false);
    await _settle(session);
    expect(session.items, hasLength(1));
    expect(session.items.single.resolution, isNotNull);
    expect(resolver.maximumActive, lessThanOrEqualTo(2));
    expect(resolver.active, 1);
    final String newId = session.items.single.id;
    resolver.first.complete(<ScanResolution>[_resolution(printing)]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(resolver.active, 0);
    expect(session.items.single.id, newId);
    expect(session.pendingRecognitionCards, 0);
    expect(session.running, isFalse);
    expect((await store.readItems()).single.id, newId);
  });

  test('clear waits admitted import and persistence but rejects their stale publication', () async {
    final _PausedImportStore imports = _PausedImportStore();
    final ScanSession imported = ScanSession(
      recognizer: _Recognizer(_crop(gallery.path)),
      resolver: _ImmediateResolver(printing),
      store: imports,
    );
    addTearDown(imported.dispose);
    imported.pause();
    final Future<bool> admission = imported.addPhotos(<String>[
      gallery.path,
    ], multipleCards: true);
    await imports.admitted.future;
    final Future<void> clearImport = imported.clearCaptures();
    expect(imported.clearingCaptures, isTrue);
    expect(
      await imported.addPhotos(<String>[gallery.path], multipleCards: true),
      isFalse,
    );
    imports.resumeImport.complete();
    expect(await admission, isFalse);
    await clearImport;
    expect(await imports.readPhotos(), isEmpty);
    expect(imported.remainingPhotos, 0);

    final _PausedUpsertStore writes = _PausedUpsertStore();
    final ScanSession persisted = ScanSession(
      recognizer: _Recognizer(_crop(gallery.path)),
      resolver: _ImmediateResolver(printing),
      store: writes,
    );
    addTearDown(persisted.dispose);
    persisted.pause();
    final ScanSessionItem item = ScanSessionItem(
      _crop(gallery.path),
      id: 'late-persist',
    );
    persisted.add(item);
    final Future<void> write = persisted.persist(<ScanSessionItem>[item]);
    await writes.admitted.future;
    final Future<void> clearWrite = persisted.clearCaptures();
    writes.resumeWrite.complete();
    await write;
    await clearWrite;
    await persisted.persist(<ScanSessionItem>[item]);
    expect(persisted.items, isEmpty);
    expect(await writes.readItems(), isEmpty);
  });

  test('clear rejects late live persistence and allows the cleared receipt to be scanned again', () async {
    final _PausedUpsertStore store = _PausedUpsertStore();
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(_crop(gallery.path)),
      resolver: _ImmediateResolver(printing),
      store: store,
    );
    addTearDown(session.dispose);
    session.pause();
    const ScanCrop liveCrop = ScanCrop(
      imagePath: '',
      width: 1000,
      height: 1400,
      rectified: true,
      sourceCorners: <ScanPoint>[
        ScanPoint(.1, .1),
        ScanPoint(.7, .1),
        ScanPoint(.7, .9),
        ScanPoint(.1, .9),
      ],
      lines: <ScanTextLine>[],
    );
    final ScanResolution identity = ScanResolution(
      hints: ScanHints(names: <String>[printing.name]),
      candidates: <ScanCandidate>[
        ScanCandidate(printing, const <ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.typeLineMatch,
        }),
      ],
      status: ScanResolutionStatus.needsReview,
    );
    final List<({String id, ScanCrop crop, ScanResolution resolution})>
    observed = <({String id, ScanCrop crop, ScanResolution resolution})>[
      (id: 'card', crop: liveCrop, resolution: identity),
    ];
    final Future<bool> old = session.adoptLiveCapture('capture', observed);
    await store.admitted.future;
    final Future<void> clear = session.clearCaptures();
    expect(await session.adoptLiveCapture('capture', observed), isFalse);
    store.resumeWrite.complete();
    expect(await old, isFalse);
    await clear;
    expect(session.items, isEmpty);
    expect(await store.readItems(), isEmpty);
    expect(await session.adoptLiveCapture('capture', observed), isTrue);
    expect(session.items.single.liveCaptureReceiptId, 'live_capture_card');
    await session.remove(session.items.single);
    expect(await session.adoptLiveCapture('capture', observed), isFalse);
    await session.clearCaptures();
    expect(await session.adoptLiveCapture('capture', observed), isTrue);
  });

  test(
    'clear invalidates a load snapshot taken before durable deletion',
    () async {
      final ScanDraftStore original = ScanDraftStore(userId: 'lifecycle');
      await original.upsertItems(<ScanDraftItem>[
        ScanDraftItem(id: 'old-load', photoId: '', crop: _crop(gallery.path)),
      ]);
      final _PausedReadStore store = _PausedReadStore();
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(_crop(gallery.path)),
        resolver: _ImmediateResolver(printing),
        store: store,
      );
      addTearDown(session.dispose);
      session.pause();
      final Future<void> loading = session.load();
      await store.admitted.future;
      await session.clearCaptures();
      store.resumeRead.complete();
      await loading;
      expect(session.loaded, isTrue);
      expect(session.items, isEmpty);
      expect(await original.readItems(), isEmpty);
    },
  );

  test(
    'clearing unreadable saved drafts recovers load without touching gallery',
    () async {
      Box<String>? opened;
      final ScanDraftStore store = ScanDraftStore(
        userId: 'lifecycle',
        openBox: (String name) async =>
            opened = await Hive.openBox<String>(name),
      );
      final ScanDraftPhoto photo = (await store.importPhotos(<String>[
        gallery.path,
      ], multipleCards: true)).single;
      await opened!.putAll(<String, String>{
        'item:corrupt': '{unfinished',
        'source:corrupt': 'invalid source',
        'cleanup:corrupt': 'invalid cleanup',
      });
      await opened!.flush();
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(_crop(gallery.path)),
        resolver: _ImmediateResolver(printing),
        store: store,
      );
      addTearDown(session.dispose);
      await expectLater(session.load(), throwsA(isA<FormatException>()));
      expect(session.loaded, isFalse);
      await session.clearCaptures();
      await store.cleanPendingImages();
      expect(session.loaded, isTrue);
      expect(session.items, isEmpty);
      expect(session.running, isFalse);
      expect(session.storageError, isNull);
      expect(await store.readPhotos(), isEmpty);
      expect(await store.readItems(), isEmpty);
      expect(await File(photo.imagePath).exists(), isFalse);
      expect(await gallery.exists(), isTrue);
      await session.load();
    },
  );

  for (final bool requestPause in <bool>[false, true]) {
    test(
      'clear preserves an explicit ${requestPause ? 'pause' : 'resume'} requested while storage is busy',
      () async {
        final _PausedClearStore store = _PausedClearStore();
        final ScanSession session = ScanSession(
          recognizer: _Recognizer(_crop(gallery.path)),
          resolver: _ImmediateResolver(printing),
          store: store,
        );
        addTearDown(session.dispose);
        if (!requestPause) session.pause();
        final Future<void> clearing = session.clearCaptures();
        await store.admitted.future;
        if (requestPause) {
          session.pause();
        } else {
          session.resume();
        }
        store.resumeClear.complete();
        await clearing;
        expect(session.paused, requestPause);
        expect(session.running, isFalse);
        expect(session.items, isEmpty);
      },
    );
  }

  test('late failure of an invalidated load cannot restore the cleared error state', () async {
    final ScanDraftStore original = ScanDraftStore(userId: 'lifecycle');
    await original.upsertItems(<ScanDraftItem>[
      ScanDraftItem(id: 'late-load', photoId: '', crop: _crop(gallery.path)),
    ]);
    final _PausedReadStore store = _PausedReadStore(failAfterResume: true);
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(_crop(gallery.path)),
      resolver: _ImmediateResolver(printing),
      store: store,
    );
    addTearDown(session.dispose);
    session.pause();
    final Future<void> loading = session.load();
    await store.admitted.future;
    await session.clearCaptures();
    store.resumeRead.complete();
    await loading;
    expect(session.loaded, isTrue);
    expect(session.items, isEmpty);
    expect(session.storageError, isNull);
    expect(session.running, isFalse);
  });

  test('failed clear keeps durable captures and requeues invalidated active recognition', () async {
    final _FailingClearStore store = _FailingClearStore();
    final _FirstDelayedRecognizer recognizer = _FirstDelayedRecognizer(
      _crop(gallery.path),
    );
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: _ImmediateResolver(printing),
      store: store,
    );
    addTearDown(session.dispose);
    await session.addPhotos(<String>[gallery.path], multipleCards: true);
    await recognizer.admitted.future;
    session.pause();
    await expectLater(
      session.clearCaptures(),
      throwsA(isA<FileSystemException>()),
    );
    expect(session.clearingCaptures, isFalse);
    expect(session.storageError, isNotNull);
    expect(session.remainingPhotos, 1);
    expect(await store.readPhotos(), hasLength(1));
    recognizer.first.complete(
      ScanRecognition(
        imagePath: gallery.path,
        width: 1000,
        height: 1400,
        crops: <ScanCrop>[_crop(gallery.path)],
      ),
    );
    await _settle(session);
    expect(session.items, isEmpty);
    session.resume();
    await _settle(session);
    expect(recognizer.calls, 2);
    expect(session.items, hasLength(1));
    expect(await store.readItems(), hasLength(1));
    store.fail = false;
    await session.clearCaptures();
    expect(session.items, isEmpty);
    expect(session.storageError, isNull);
  });

  for (final bool lookupFails in <bool>[false, true]) {
    test(
      'disposed lookup ${lookupFails ? 'failure' : 'success'} cannot overwrite a reopened review',
      () async {
        final ScanDraftStore store = ScanDraftStore(userId: 'lifecycle');
        final _DelayedResolver oldResolver = _DelayedResolver();
        final ScanSession oldSession = ScanSession(
          recognizer: _Recognizer(_crop(gallery.path), multiple: true),
          resolver: oldResolver,
          store: store,
        );
        await oldSession.addPhotos(<String>[gallery.path], multipleCards: true);
        await oldResolver.admitted.future.timeout(const Duration(seconds: 5));
        expect(oldSession.items, hasLength(2));
        oldSession.dispose();

        final ScanSession reopened = ScanSession(
          recognizer: _Recognizer(_crop(gallery.path)),
          resolver: _DelayedResolver(),
          store: ScanDraftStore(userId: 'lifecycle'),
        );
        addTearDown(reopened.dispose);
        reopened.pause();
        await reopened.load();
        final ScanSessionItem reviewed = reopened.items.first;
        reviewed.resolution = _resolution(printing);
        reviewed.approval = ScanQueueApproval(
          operationId: reviewed.id,
          card: cardFromScryfall(printing, finish: Finish.nonfoil),
          quantity: 7,
          deckId: 'reviewed-deck',
          deckSection: DeckSection.sideboard,
        );
        reviewed.manuallyReviewed = true;
        reviewed.selected = true;
        await reopened.persist(<ScanSessionItem>[reviewed]);
        if (lookupFails) {
          oldResolver.result.completeError(StateError('old lookup failed'));
        } else {
          oldResolver.result.complete(<ScanResolution>[
            _resolution(printing),
            _resolution(printing),
          ]);
        }
        await _settle(oldSession);

        final List<ScanDraftItem> durable = await ScanDraftStore(
          userId: 'lifecycle',
        ).readItems();
        expect(durable, hasLength(2));
        final ScanDraftItem saved = durable.singleWhere(
          (ScanDraftItem item) => item.id == reviewed.id,
        );
        expect(saved.approval?.quantity, 7);
        expect(saved.approval?.card.finish, Finish.nonfoil);
        expect(saved.approval?.deckId, 'reviewed-deck');
        expect(saved.approval?.deckSection, DeckSection.sideboard);
        expect(saved.approval?.operationId, reviewed.id);
        expect(saved.selected, isTrue);
        expect(saved.error, isNull);
        expect(await File(saved.crop.imagePath).exists(), isTrue);
        expect(await store.readSource(saved.photoId), isNotNull);
      },
    );
  }

  for (final String generation in <String>[
    '',
    '/ec186f14-cafc-443a-8827-deb8e915aac1',
  ]) {
    test(
      'disposed OCR releases temporary crops$generation and retains the pending original',
      () async {
        final Directory cache = await Directory(
          '${directory.path}/ScanCrops$generation',
        ).create(recursive: true);
        final File temporary = await File('${cache.path}/late.jpg')
            .writeAsBytes(<int>[5, 6, 7]);
        final ScanDraftStore store = ScanDraftStore(userId: 'lifecycle');
        final _DelayedRecognizer recognizer = _DelayedRecognizer();
        final ScanSession session = ScanSession(
          recognizer: recognizer,
          resolver: _DelayedResolver(),
          store: store,
        );
        await session.addPhotos(<String>[gallery.path], multipleCards: false);
        await recognizer.admitted.future;
        final ScanDraftPhoto pending = (await store.readPhotos()).single;
        session.dispose();
        recognizer.result.complete(
          ScanRecognition(
            imagePath: pending.imagePath,
            width: 1000,
            height: 1400,
            crops: <ScanCrop>[_crop(temporary.path)],
          ),
        );
        await _settle(session);
        for (
          int attempt = 0;
          attempt < 100 && await temporary.exists();
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(await temporary.exists(), isFalse);
        expect(await store.readItems(), isEmpty);
        expect((await store.readPhotos()).single.id, pending.id);
        expect(await File(pending.imagePath).exists(), isTrue);
        expect(await gallery.exists(), isTrue);
      },
    );
  }

  test('gallery disposal finishes the admitted photo but never imports the remaining paths', () async {
    final _PausedImportStore store = _PausedImportStore();
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(_crop(gallery.path)),
      resolver: _DelayedResolver(),
      store: store,
    );
    session.pause();
    final Future<bool> imported = session.addPhotos(
      List<String>.filled(1000, gallery.path),
      multipleCards: true,
    );
    await store.admitted.future;
    session.dispose();
    store.resumeImport.complete();
    expect(await imported, isFalse);
    expect(store.calls, 1);
    final ScanDraftPhoto retained = (await store.readPhotos()).single;
    expect(await File(retained.imagePath).exists(), isTrue);
    expect(await gallery.exists(), isTrue);
  });

  test(
    'a disposed camera import still acknowledges its admitted durable source',
    () async {
      final File camera = await File('${directory.path}/camera.jpg')
          .writeAsBytes(<int>[8, 9]);
      final _PausedImportStore store = _PausedImportStore();
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(_crop(gallery.path)),
        resolver: _DelayedResolver(),
        store: store,
      );
      session.pause();
      final Future<bool> imported = session.addPhotos(
        <String>[camera.path],
        multipleCards: true,
        ownedCameraSource: true,
      );
      await store.admitted.future;
      session.dispose();
      store.resumeImport.complete();
      expect(await imported, isTrue);
      expect(store.calls, 1);
      expect(await camera.exists(), isFalse);
      final ScanDraftPhoto retained = (await store.readPhotos()).single;
      expect(await File(retained.imagePath).readAsBytes(), <int>[8, 9]);
    },
  );

  test(
    'persisting a closed session rejects without changing durable review',
    () async {
      final ScanDraftStore store = ScanDraftStore(userId: 'lifecycle');
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(_crop(gallery.path)),
        resolver: _DelayedResolver(),
        store: store,
      );
      final ScanSessionItem item = ScanSessionItem(
        _crop(gallery.path),
        id: 'manual',
      );
      session.add(item);
      await session.persist(<ScanSessionItem>[item]);
      session.dispose();
      item.error = 'stale closed callback';
      await expectLater(
        session.persist(<ScanSessionItem>[item]),
        throwsStateError,
      );
      expect((await store.readItems()).single.error, isNull);
    },
  );
}
