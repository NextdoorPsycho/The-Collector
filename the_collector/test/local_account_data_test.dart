import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collector_models/card/mtg_card.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_collector/utils/auth/local_account_data.dart';
import 'package:the_collector/utils/games/game_preferences.dart';
import 'package:the_collector/utils/games/game_session.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_queue.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';

MTGCard _card() => MTGCard(
  name: 'Lightning Bolt',
  setId: 'set-id',
  description: 'Lightning Bolt deals 3 damage to any target.',
  flavorText: '',
  cmc: 1,
  typeLine: 'Instant',
  rarity: Rarity.common,
  setType: SetType.expansion,
  manaCost: '{R}',
  scryfallId: 'd88a8e2d-2577-4a67-af86-e33c0ba94114',
  language: 'en',
  finish: Finish.nonfoil,
);

GameSession _game(String uid) => GameSession(
  id: '',
  ownerId: uid,
  format: GameFormat.commander,
  names: const <String>['One', 'Two'],
  life: const <int>[37, 42],
  members: <String>[uid],
);

String _hash(String uid) => sha256.convert(utf8.encode(uid)).toString();

class _DelayedPhotoBox extends Fake implements Box<String> {
  _DelayedPhotoBox(this.delegate, this.entered, this.release);
  final Box<String> delegate;
  final Completer<void> entered;
  final Completer<void> release;

  @override
  String? get path => delegate.path;
  @override
  String? get(Object? key, {String? defaultValue}) =>
      delegate.get(key, defaultValue: defaultValue);
  @override
  Future<void> flush() => delegate.flush();
  @override
  Future<void> put(Object? key, String value) async {
    entered.complete();
    await release.future;
    await delegate.put(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'collector-account-delete-',
    );
    Hive.init(directory.path);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LocalAccountData.initialize();
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('pending deletion survives restart and cancellation preserves a manually paused queue', () async {
    final ScanQueue queue = ScanQueue(
      userId: 'alice',
      writer: (ScanQueueEntry _) async {},
    );
    addTearDown(queue.dispose);
    await queue.load();
    await queue.enqueue(card: _card(), quantity: 2);
    queue.pauseUploads();
    int notifications = 0;
    void changed() => notifications++;
    LocalAccountData.deletingUids.addListener(changed);
    addTearDown(() => LocalAccountData.deletingUids.removeListener(changed));
    final Future<void> mark = LocalAccountData.markDeleting('alice');
    expect(LocalAccountData.isDeleting('alice'), isTrue);
    expect(LocalAccountData.isDeletionAccepted('alice'), isFalse);
    expect(LocalAccountData.needsDeletionCleanup('alice'), isFalse);
    await mark;
    await expectLater(
      LocalAccountData.finishDeletionCleanup('alice'),
      throwsStateError,
    );
    await expectLater(
      queue.enqueue(card: _card(), quantity: 3),
      throwsStateError,
    );
    expect(queue.count, 1);
    await LocalAccountData.cancelDeleting('alice');
    await queue.enqueue(card: _card(), quantity: 3);
    expect(queue.quantityCount, 5);
    expect(queue.paused, isTrue);
    expect(notifications, 2);
    await LocalAccountData.markDeleting('alice');
    await Hive.close();
    await LocalAccountData.initialize();
    expect(LocalAccountData.isDeleting('alice'), isTrue);
    expect(LocalAccountData.isDeleting('bob'), isFalse);
    await LocalAccountData.cancelDeleting('alice');
    expect((await HiveScanQueueStorage().readEntries('alice')).length, 2);
  });

  test('server acceptance is durable before any local purge and cannot be cancelled after restart', () async {
    await expectLater(
      LocalAccountData.acceptDeletion('unmarked'),
      throwsStateError,
    );
    expect(LocalAccountData.isDeletionAccepted('unmarked'), isFalse);
    final ScanQueue queue = ScanQueue(
      userId: 'alice',
      writer: (ScanQueueEntry _) async {},
    );
    addTearDown(queue.dispose);
    await queue.load();
    await queue.enqueue(card: _card(), quantity: 4);
    final File gallery = await File('${directory.path}/gallery.jpg')
        .writeAsBytes(<int>[1, 2, 3]);
    await ScanDraftStore(userId: 'alice')
        .importPhotos(<String>[gallery.path], multipleCards: true);
    await const GamePreferences('alice').save(_game('alice'));
    await LocalAccountData.markDeleting('alice');
    await LocalAccountData.acceptDeletion('alice');
    expect(LocalAccountData.needsDeletionCleanup('alice'), isTrue);
    await Hive.close();
    await LocalAccountData.initialize();
    expect(LocalAccountData.isDeleting('alice'), isTrue);
    expect(LocalAccountData.isDeletionAccepted('alice'), isTrue);
    expect(LocalAccountData.needsDeletionCleanup('alice'), isTrue);
    expect(await Hive.boxExists('scanner_queue_v2_${_hash('alice')}'), isTrue);
    expect(await Hive.boxExists('scanner_drafts_v1_${_hash('alice')}'), isTrue);
    expect(
      await Directory('${directory.path}/scanner_images_${_hash('alice')}')
          .exists(),
      isTrue,
    );
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('game.alice.commander.2'), isNotNull);
    expect(await gallery.exists(), isTrue);
    await expectLater(
      LocalAccountData.cancelDeleting('alice'),
      throwsStateError,
    );
  });

  test('purge removes only exact owner Hive files, managed images, and saved games', () async {
    final File gallery = await File('${directory.path}/gallery.jpg')
        .writeAsBytes(<int>[1, 2, 3]);
    for (final String uid in <String>['Alice', 'alice']) {
      final ScanQueue queue = ScanQueue(
        userId: uid,
        writer: (ScanQueueEntry _) async {},
      );
      addTearDown(queue.dispose);
      await queue.load();
      await queue.enqueue(card: _card(), quantity: 4);
      final ScanDraftStore drafts = ScanDraftStore(userId: uid);
      final List<ScanDraftPhoto> photos = await drafts.importPhotos(<String>[
        gallery.path,
        gallery.path,
      ], multipleCards: true);
      await drafts.completePhoto(photos.last.id, <ScanDraftItem>[
        ScanDraftItem(
          id: 'crop_$uid',
          photoId: photos.last.id,
          crop: ScanCrop(
            imagePath: gallery.path,
            width: 1000,
            height: 1400,
            rectified: true,
            sourceCorners: const <ScanPoint>[],
            lines: const <ScanTextLine>[],
          ),
        ),
      ]);
      await GamePreferences(uid).save(_game(uid));
    }
    await const GamePreferences('Alice.child').save(_game('Alice.child'));
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setString('unrelated.preference', 'keep');
    await preferences.setBool('scan.cloudConsent.Alice', true);
    await preferences.setBool('scan.cloudConsent.alice', true);
    await preferences.setBool('scan.cloudConsent.Alice.child', true);
    final Directory ownImages = Directory(
      '${directory.path}/scanner_images_${_hash('Alice')}',
    );
    final Directory otherImages = Directory(
      '${directory.path}/scanner_images_${_hash('alice')}',
    );
    expect(await ownImages.exists(), isTrue);
    expect(await ownImages.list().length, 3);
    await LocalAccountData.markDeleting('Alice');
    await LocalAccountData.purge('Alice');
    expect(await Hive.boxExists('scanner_queue_v2_${_hash('Alice')}'), isFalse);
    expect(
      await Hive.boxExists('scanner_drafts_v1_${_hash('Alice')}'),
      isFalse,
    );
    expect(await ownImages.exists(), isFalse);
    expect(await gallery.exists(), isTrue);
    expect(await otherImages.exists(), isTrue);
    expect(
      (await HiveScanQueueStorage().readEntries('alice')).single.quantity,
      4,
    );
    expect((await ScanDraftStore(userId: 'alice').readPhotos()).length, 1);
    expect((await ScanDraftStore(userId: 'alice').readItems()).length, 1);
    expect(preferences.getString('game.Alice.commander.2'), isNull);
    expect(
      (await const GamePreferences(
        'alice',
      ).read(GameFormat.commander, 2))!.life,
      <int>[37, 42],
    );
    expect(
      (await const GamePreferences(
        'Alice.child',
      ).read(GameFormat.commander, 2))!.life,
      <int>[37, 42],
    );
    expect(preferences.getString('unrelated.preference'), 'keep');
    expect(preferences.getBool('scan.cloudConsent.Alice'), isNull);
    expect(preferences.getBool('scan.cloudConsent.alice'), isTrue);
    expect(preferences.getBool('scan.cloudConsent.Alice.child'), isTrue);
    await Hive.close();
    await LocalAccountData.initialize();
    expect(LocalAccountData.isDeleting('Alice'), isTrue);
    expect(LocalAccountData.isDeletionAccepted('Alice'), isTrue);
    expect(LocalAccountData.needsDeletionCleanup('Alice'), isTrue);
    await LocalAccountData.purge('Alice');
    await LocalAccountData.finishDeletionCleanup('Alice');
    await Hive.close();
    await LocalAccountData.initialize();
    expect(LocalAccountData.isDeleting('Alice'), isTrue);
    expect(LocalAccountData.isDeletionAccepted('Alice'), isTrue);
    expect(LocalAccountData.needsDeletionCleanup('Alice'), isFalse);
    await expectLater(
      LocalAccountData.cancelDeleting('Alice'),
      throwsStateError,
    );
    expect(() => HiveScanQueueStorage().readEntries('Alice'), throwsStateError);
  });

  test('purge waits for copied photo persistence and blocks late OCR from recreating the owner box', () async {
    final File gallery = await File('${directory.path}/gallery.jpg')
        .writeAsBytes(<int>[9, 8, 7]);
    final Completer<void> entered = Completer<void>();
    final Completer<void> release = Completer<void>();
    final ScanDraftStore drafts = ScanDraftStore(
      userId: 'alice',
      openBox: (String name) async =>
          _DelayedPhotoBox(await Hive.openBox<String>(name), entered, release),
    );
    final Future<List<ScanDraftPhoto>> importing = drafts.importPhotos(<String>[
      gallery.path,
    ], multipleCards: true);
    await Future.any<void>(<Future<void>>[
      entered.future,
      importing.then<void>((_) => throw StateError('Import was not delayed.')),
    ]).timeout(const Duration(seconds: 5));
    await LocalAccountData.markDeleting('alice');
    bool purged = false;
    final Future<void> purge = LocalAccountData.purge('alice')
        .then((_) => purged = true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(purged, isFalse);
    expect(
      await Directory('${directory.path}/scanner_images_${_hash('alice')}')
          .exists(),
      isTrue,
    );
    release.complete();
    expect((await importing).length, 1);
    await purge;
    expect(await gallery.exists(), isTrue);
    expect(
      await Directory('${directory.path}/scanner_images_${_hash('alice')}')
          .exists(),
      isFalse,
    );
    await expectLater(
      drafts.upsertItems(const <ScanDraftItem>[]),
      throwsStateError,
    );
    expect(
      await Hive.boxExists('scanner_drafts_v1_${_hash('alice')}'),
      isFalse,
    );
  });

  for (final bool succeeds in <bool>[true, false]) {
    test(
      'purge completes with unresolved remote upload; late success=$succeeds cannot recreate data',
      () async {
        final Completer<void> entered = Completer<void>();
        final Completer<void> release = Completer<void>();
        int writes = 0;
        final ScanQueue queue = ScanQueue(
          userId: 'alice',
          uploadConcurrency: 1,
          writer: (ScanQueueEntry _) async {
            writes++;
            entered.complete();
            await release.future;
          },
        );
        await queue.load();
        await queue.enqueueBatch(<ScanQueueApproval>[
          ScanQueueApproval(card: _card()),
          ScanQueueApproval(card: _card()),
        ]);
        final Future<void> flushing = queue.flush();
        await entered.future;
        await LocalAccountData.markDeleting('alice');
        queue.dispose();
        await LocalAccountData.purge('alice')
            .timeout(const Duration(seconds: 5));
        expect(release.isCompleted, isFalse);
        expect(
          await Hive.boxExists('scanner_queue_v2_${_hash('alice')}'),
          isFalse,
        );
        if (succeeds) {
          release.complete();
        } else {
          release.completeError(StateError('Remote upload rejected.'));
        }
        await flushing;
        expect(writes, 1);
        await expectLater(
          queue.enqueue(card: _card(), quantity: 1),
          throwsStateError,
        );
        expect(
          await Hive.boxExists('scanner_queue_v2_${_hash('alice')}'),
          isFalse,
        );
      },
    );
  }

  test(
    'deletion between preference acquisition and save rejects the late write',
    () async {
      final Future<void> saving = const GamePreferences('alice')
          .save(_game('alice'));
      final Future<void> rejected = expectLater(saving, throwsStateError);
      await LocalAccountData.markDeleting('alice');
      await rejected;
      await LocalAccountData.purge('alice');
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      expect(preferences.getString('game.alice.commander.2'), isNull);
      expect(
        () => const GamePreferences('alice').save(_game('alice')),
        throwsStateError,
      );
    },
  );
}
