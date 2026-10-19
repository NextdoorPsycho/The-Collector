import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_session.dart';

class _Recognizer implements CardRecognizer {
  @override
  Future<ScanRecognition> recognize(
    String path, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) => throw UnimplementedError();
}

class _Resolver extends ScanResolver {
  @override
  Future<List<ScanResolveOutcome>> resolveBatchOutcomes(
    List<ScanCrop> crops, {
    ScanOutcomeListener? onOutcome,
  }) async => crops
      .map(
        (ScanCrop crop) => ScanResolveOutcome.success(
          ScanResolution(
            hints: ScanHints.fromCrop(crop),
            status: ScanResolutionStatus.noMatch,
            candidates: const <ScanCandidate>[],
          ),
        ),
      )
      .toList();
}

class _HeldAcceptanceStore extends ScanDraftStore {
  _HeldAcceptanceStore() : super(userId: 'acceptance');
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool fail = false;

  @override
  Future<bool> acceptCaptures(
    List<ScanDraftItem> items, {
    bool Function()? isCurrent,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    if (fail) throw const FileSystemException('Receipt unavailable');
    return super.acceptCaptures(items, isCurrent: isCurrent);
  }
}

ScanCrop _crop(String path, {List<String> warnings = const <String>[]}) =>
    ScanCrop(
      imagePath: path,
      width: 1000,
      height: 1400,
      rectified: true,
      warnings: warnings,
      sourceCorners: const <ScanPoint>[
        ScanPoint(.1, .1),
        ScanPoint(.4, .1),
        ScanPoint(.4, .8),
        ScanPoint(.1, .8),
      ],
      lines: const <ScanTextLine>[
        ScanTextLine(
          text: 'Lightning Bolt',
          confidence: .95,
          bounds: ScanBounds(.1, .05, .5, .04),
        ),
        ScanTextLine(
          text: 'Instant',
          confidence: .95,
          bounds: ScanBounds(.1, .5, .4, .04),
        ),
        ScanTextLine(
          text: 'M11 EN',
          confidence: .95,
          bounds: ScanBounds(.1, .9, .3, .04),
        ),
      ],
    );

void main() {
  late Directory directory;
  late File source;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('scan-acceptance-');
    Hive.init(directory.path);
    source = await File('${directory.path}/crop.jpg')
        .writeAsBytes(<int>[1, 2, 3]);
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<ScanDraftItem> save(ScanDraftStore store, {String id = 'one'}) async =>
      (await store.upsertItems(<ScanDraftItem>[
        ScanDraftItem(id: id, photoId: 'photo', crop: _crop(source.path)),
      ])).single;

  test('a saved crop is not a capture until its durable acceptance', () async {
    final ScanDraftStore store = ScanDraftStore(userId: 'acceptance');
    final ScanDraftItem item = await save(store);
    expect(hasVerifiedSavedCardCapturePresence(item.crop), isTrue);
    expect((await store.readAccounting()).captured, 0);
    expect(await store.acceptCaptures(<ScanDraftItem>[item]), isTrue);
    expect((await store.readAccounting()).captured, 1);
    expect((await store.readRecentReceipts()).single.acceptedAt, isNotNull);
    await store.acceptCaptures(<ScanDraftItem>[item]);
    await store.removeItems(<String>[item.id]);
    await Hive.close();
    expect(
      (await ScanDraftStore(userId: 'acceptance').readAccounting()).captured,
      1,
    );
  });

  test(
    'acceptance rejects placeholders, poor evidence and missing files',
    () async {
      final ScanDraftStore store = ScanDraftStore(userId: 'acceptance');
      final List<ScanDraftItem> items = await store.upsertItems(<ScanDraftItem>[
        ScanDraftItem(id: 'placeholder', photoId: '', crop: _crop('')),
        ScanDraftItem(
          id: 'blurred',
          photoId: 'photo',
          crop: _crop(source.path, warnings: const <String>['blurred']),
        ),
      ]);
      for (final ScanDraftItem item in items) {
        expect(await store.acceptCaptures(<ScanDraftItem>[item]), isFalse);
      }
      final ScanDraftItem missing = await save(store);
      await File(missing.crop.imagePath).delete();
      expect(await store.acceptCaptures(<ScanDraftItem>[missing]), isFalse);
      expect((await store.readAccounting()).captured, 0);
    },
  );

  test(
    'stale crop snapshots and invalidated generations cannot accept',
    () async {
      final ScanDraftStore store = ScanDraftStore(userId: 'acceptance');
      final ScanDraftItem old = await save(store);
      final File replacement = await File('${directory.path}/replacement.jpg')
          .writeAsBytes(<int>[4, 5, 6]);
      final ScanDraftItem next = (await store.upsertItems(<ScanDraftItem>[
        ScanDraftItem(
          id: old.id,
          photoId: 'replacement',
          crop: _crop(replacement.path),
        ),
      ])).single;
      expect(await store.acceptCaptures(<ScanDraftItem>[old]), isFalse);
      expect(
        await store.acceptCaptures(<ScanDraftItem>[
          next,
        ], isCurrent: () => false),
        isFalse,
      );
      expect((await store.readAccounting()).captured, 0);
      expect(await store.acceptCaptures(<ScanDraftItem>[next]), isTrue);
      expect((await store.readAccounting()).captured, 1);
    },
  );

  test('rescan of an accepted occurrence never counts a second card', () async {
    final ScanDraftStore store = ScanDraftStore(userId: 'acceptance');
    final ScanDraftItem first = await save(store);
    await store.acceptCaptures(<ScanDraftItem>[first]);
    final DateTime accepted =
        (await store.readRecentReceipts()).single.acceptedAt!;
    final ScanDraftItem replacement = await save(store);
    expect(await store.acceptCaptures(<ScanDraftItem>[replacement]), isTrue);
    expect((await store.readAccounting()).captured, 1);
    expect((await store.readRecentReceipts()).single.acceptedAt, accepted);
  });

  test('a group accepts all current captures or none', () async {
    final ScanDraftStore store = ScanDraftStore(userId: 'acceptance');
    final ScanDraftItem first = await save(store);
    final ScanDraftItem second = await save(store, id: 'two');
    await File(second.crop.imagePath).delete();
    expect(await store.acceptCaptures(<ScanDraftItem>[first, second]), isFalse);
    expect((await store.readAccounting()).captured, 0);
    expect(await store.acceptCaptures(<ScanDraftItem>[first]), isTrue);
    expect((await store.readAccounting()).captured, 1);
  });

  test('an installed app can accept a restored crop after its container moved', () async {
    late Box<String> box;
    final ScanDraftStore store = ScanDraftStore(
      userId: 'acceptance',
      openBox: (String name) async => box = await Hive.openBox<String>(name),
    );
    final ScanDraftItem saved = await save(store);
    final Map<String, Object?> record = Map<String, Object?>.from(
      jsonDecode(box.get('item:one')!) as Map<Object?, Object?>,
    );
    final Map<String, Object?> crop = Map<String, Object?>.from(
      record['crop'] as Map<Object?, Object?>,
    );
    crop['imagePath'] =
        '/previous-container/${File(saved.crop.imagePath).parent.uri.pathSegments.where((String segment) => segment.isNotEmpty).last}/${File(saved.crop.imagePath).uri.pathSegments.last}';
    record['crop'] = crop;
    await box.put('item:one', jsonEncode(record));
    await box.flush();
    final ScanDraftItem restored = (await store.readItems()).single;
    expect(restored.crop.imagePath, saved.crop.imagePath);
    expect(await store.acceptCaptures(<ScanDraftItem>[restored]), isTrue);
    expect((await store.readAccounting()).captured, 1);
  });

  test('a session rejects a detached item with the same ID', () async {
    final ScanDraftStore store = ScanDraftStore(userId: 'acceptance');
    final ScanSession session = ScanSession(
      recognizer: _Recognizer(),
      resolver: ScanResolver(),
      store: store,
    );
    addTearDown(session.dispose);
    final ScanDraftItem saved = await save(store);
    session.add(ScanSessionItem.fromDraft(saved));
    expect(
      await session.acceptCaptures(<ScanSessionItem>[
        ScanSessionItem.fromDraft(saved),
      ]),
      isFalse,
    );
    expect((await store.readAccounting()).captured, 0);
    expect(await session.acceptCaptures(session.items), isTrue);
    expect((await store.readAccounting()).captured, 1);
  });

  test('an active replacement cannot accept the previous saved crop', () async {
    final ScanDraftStore store = ScanDraftStore(userId: 'acceptance');
    final ScanDraftItem saved = await save(store);
    final ScanDraftRescan request = await store.beginRescan(saved.id);
    expect(await store.acceptCaptures(<ScanDraftItem>[saved]), isFalse);
    expect((await store.readAccounting()).captured, 0);
    await store.cancelRescan(saved.id, requestId: request.requestId);
    expect(await store.acceptCaptures(<ScanDraftItem>[saved]), isTrue);
  });

  for (final bool failure in <bool>[false, true]) {
    test(
      'session acceptance waits for persistence and rejects ${failure ? 'storage failure' : 'clear'}',
      () async {
        final _HeldAcceptanceStore store = _HeldAcceptanceStore()
          ..fail = failure;
        final ScanSession session = ScanSession(
          recognizer: _Recognizer(),
          resolver: ScanResolver(),
          store: store,
        );
        addTearDown(session.dispose);
        final ScanDraftItem saved = await save(store);
        final ScanSessionItem item = ScanSessionItem.fromDraft(saved);
        session.add(item);
        bool finished = false;
        final Future<bool> accepted = session
            .acceptCaptures(<ScanSessionItem>[item])
            .then((bool value) {
              finished = true;
              return value;
            });
        await store.entered.future;
        expect(finished, isFalse);
        expect((await store.readAccounting()).captured, 0);
        final Future<void>? clear = failure ? null : session.discardRemaining();
        store.release.complete();
        expect(await accepted, isFalse);
        await clear;
        expect((await store.readAccounting()).captured, 0);
        if (failure) expect(session.storageError, isNotNull);
      },
    );
  }

  test('a held acceptance from a signed-out session cannot accept a new account occurrence', () async {
    final _HeldAcceptanceStore previousStore = _HeldAcceptanceStore();
    addTearDown(() {
      if (!previousStore.release.isCompleted) previousStore.release.complete();
    });
    final ScanSession previous = ScanSession(
      recognizer: _Recognizer(),
      resolver: _Resolver(),
      store: previousStore,
    );
    final ScanDraftItem previousDraft = await save(previousStore);
    previous.add(ScanSessionItem.fromDraft(previousDraft));
    final Future<bool> lateAcceptance = previous.acceptCaptures(previous.items);
    await previousStore.entered.future;
    previous.dispose();

    final ScanDraftStore nextStore = ScanDraftStore(userId: 'other-account');
    final ScanSession next = ScanSession(
      recognizer: _Recognizer(),
      resolver: _Resolver(),
      store: nextStore,
    );
    addTearDown(next.dispose);
    final ScanDraftItem nextDraft = await save(nextStore);
    expect(nextDraft.id, previousDraft.id);
    expect(nextDraft.crop.imagePath, isNot(previousDraft.crop.imagePath));
    next.add(ScanSessionItem.fromDraft(nextDraft));
    expect(await next.acceptCaptures(next.items), isTrue);
    previousStore.release.complete();
    expect(await lateAcceptance, isFalse);
    expect((await previousStore.readAccounting()).captured, 0);
    expect((await nextStore.readAccounting()).captured, 1);
    expect((await previousStore.readItems()).single.id, previousDraft.id);
    expect(await File(nextDraft.crop.imagePath).exists(), isTrue);
  });

  test(
    'retry recovers a failed confirmation without another photograph',
    () async {
      final _HeldAcceptanceStore store = _HeldAcceptanceStore()
        ..fail = true
        ..release.complete();
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(),
        resolver: _Resolver(),
        store: store,
      );
      addTearDown(session.dispose);
      final ScanDraftItem saved = await save(store);
      final ScanSessionItem item = ScanSessionItem.fromDraft(saved);
      session.add(item);
      expect(await session.acceptCaptures(<ScanSessionItem>[item]), isFalse);
      expect(session.storageError, isNotNull);
      store.fail = false;
      await session.retryUnresolved();
      expect(session.storageError, isNull);
      expect((await store.readAccounting()).captured, 1);
    },
  );
}
