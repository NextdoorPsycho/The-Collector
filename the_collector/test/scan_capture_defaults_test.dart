import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collector_models/deck/deck_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/scanning/scan_capture_defaults.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_queue.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_session.dart';

const ScanCaptureDefaults _binder = ScanCaptureDefaults(
  finish: Finish.foil,
  deckId: 'binder',
  deckSection: DeckSection.sideboard,
);

ScanCrop _crop(String path) => ScanCrop(
  imagePath: path,
  width: 1000,
  height: 1400,
  rectified: true,
  sourceCorners: const <ScanPoint>[
    ScanPoint(.1, .1),
    ScanPoint(.6, .1),
    ScanPoint(.6, .9),
    ScanPoint(.1, .9),
  ],
  lines: const <ScanTextLine>[
    ScanTextLine(
      text: 'Lightning Bolt',
      confidence: .99,
      bounds: ScanBounds(.1, .05, .7, .025),
    ),
    ScanTextLine(
      text: 'Instant',
      confidence: .99,
      bounds: ScanBounds(.1, .5, .4, .025),
    ),
    ScanTextLine(
      text: 'M11 EN',
      confidence: .99,
      bounds: ScanBounds(.1, .9, .4, .025),
    ),
  ],
);

class _Recognizer implements CardRecognizer {
  final Completer<void> release = Completer<void>();
  @override
  Future<ScanRecognition> recognize(
    String path, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    await release.future;
    return ScanRecognition(
      imagePath: path,
      width: 2000,
      height: 1600,
      crops: <ScanCrop>[_crop(path)],
    );
  }
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
            candidates: const <ScanCandidate>[],
            status: ScanResolutionStatus.noMatch,
          ),
        ),
      )
      .toList();
}

void main() {
  late Directory directory;
  late File photo;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capture-defaults-');
    Hive.init(directory.path);
    photo = await File('${directory.path}/photo.jpg')
        .writeAsBytes(<int>[1, 2, 3]);
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('photo and crop defaults round trip and survive crop replacement', () {
    final ScanDraftPhoto source = ScanDraftPhoto(
      id: 'source',
      imagePath: '',
      multipleCards: true,
      createdAt: DateTime.utc(2026),
      defaults: _binder,
    );
    expect(
      ScanDraftPhoto.fromMap(source.toMap()).defaults.toMap(),
      _binder.toMap(),
    );
    final ScanDraftItem crop = ScanDraftItem(
      id: 'one',
      photoId: 'source',
      crop: _crop(''),
      defaults: _binder,
    );
    expect(
      ScanDraftItem.fromMap(crop.toMap())
          .withCrop(_crop('replacement'))
          .defaults
          .toMap(),
      _binder.toMap(),
    );
    expect(
      ScanSessionItem.fromDraft(crop).draft.defaults.toMap(),
      _binder.toMap(),
    );
  });

  test(
    'legacy reviewed choices remain authoritative when defaults are absent',
    () {
      final Map<String, Object?> fixture = Map<String, Object?>.from(
        jsonDecode(
          File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
        ) as Map<Object?, Object?>,
      )..['finishes'] = <String>['nonfoil', 'foil'];
      final MtgCard printing = MtgCard.fromJson(fixture);
      final ScanDraftItem saved = ScanDraftItem(
        id: 'legacy',
        photoId: '',
        crop: _crop(''),
        approval: ScanQueueApproval(
          operationId: 'legacy',
          card: cardFromScryfall(printing, finish: Finish.foil),
          deckId: 'legacy-box',
          deckSection: DeckSection.sideboard,
        ),
      );
      final Map<String, Object?> old = saved.toMap()..remove('defaults');
      final ScanDraftItem restored = ScanDraftItem.fromMap(old);
      expect(restored.defaults.finish, Finish.foil);
      expect(restored.defaults.deckId, 'legacy-box');
      expect(restored.defaults.deckSection, DeckSection.sideboard);
      final Map<String, Object?> unread = ScanDraftItem(
        id: 'unread',
        photoId: '',
        crop: _crop(''),
      ).toMap()..remove('defaults');
      expect(ScanDraftItem.fromMap(unread).defaults.finish, Finish.nonfoil);
      expect(ScanDraftItem.fromMap(unread).defaults.deckId, isNull);
    },
  );

  for (final bool focusStack in <bool>[false, true]) {
    test(
      '${focusStack ? 'camera' : 'gallery'} admission retains its defaults while recognition waits and after restart',
      () async {
        final ScanDraftStore store = ScanDraftStore(userId: 'defaults');
        final _Recognizer recognizer = _Recognizer();
        final ScanSession session = ScanSession(
          recognizer: recognizer,
          resolver: _Resolver(),
          store: store,
        );
        await session.load();
        final bool saved = focusStack
            ? await session.addFocusStack(
                <String>[photo.path],
                captureId: 'captured',
                defaults: _binder,
              )
            : await session.addPhotos(
                <String>[photo.path],
                multipleCards: true,
                defaults: _binder,
              );
        expect(saved, isTrue);
        expect(
          (await store.readPhotos()).single.defaults.toMap(),
          _binder.toMap(),
        );
        recognizer.release.complete();
        final DateTime deadline = DateTime.now().add(
          const Duration(seconds: 10),
        );
        while (session.running && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(session.running, isFalse);
        expect(session.items.single.defaults.toMap(), _binder.toMap());
        session.dispose();
        await Hive.close();
        final ScanDraftItem restored = (await ScanDraftStore(
          userId: 'defaults',
        ).readItems()).single;
        expect(restored.defaults.toMap(), _binder.toMap());
      },
    );
  }

  test(
    'replayed focus capture keeps its original destination and finish',
    () async {
      final ScanDraftStore store = ScanDraftStore(userId: 'defaults');
      await store.importFocusStack(
        <String>[photo.path],
        captureId: 'captured',
        defaults: _binder,
      );
      final ScanDraftPhoto replay = (await store.importFocusStack(
        <String>[photo.path],
        captureId: 'captured',
        defaults: const ScanCaptureDefaults(deckId: 'different-box'),
      )).single;
      expect(replay.defaults.toMap(), _binder.toMap());
    },
  );

  test('replacement photo retains the original item defaults', () async {
    final ScanDraftStore store = ScanDraftStore(userId: 'defaults');
    await store.upsertItems(<ScanDraftItem>[
      ScanDraftItem(
        id: 'one',
        photoId: 'old',
        crop: _crop(photo.path),
        defaults: _binder,
      ),
    ]);
    final ScanDraftRescan request = await store.beginRescan('one');
    final ScanDraftPhoto replacement = await store.importRescanPhoto(
      request,
      photo.path,
    );
    expect(replacement.defaults.toMap(), _binder.toMap());
    expect(
      (await store.readRescans()).single.original!.defaults.toMap(),
      _binder.toMap(),
    );
    final ScanDraftItem saved = await store.commitRescan(
      request,
      ScanDraftItem(
        id: 'one',
        photoId: replacement.id,
        crop: _crop(photo.path),
      ),
    );
    expect(saved.defaults.toMap(), _binder.toMap());
    expect((await store.readItems()).single.defaults.toMap(), _binder.toMap());
  });
}
