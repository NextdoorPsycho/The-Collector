import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collector_models/deck/deck_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_queue.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

class _FailingPhotoBox extends Fake implements Box<String> {
  _FailingPhotoBox(this.delegate);
  final Box<String> delegate;

  @override
  String? get path => delegate.path;

  @override
  String? get(Object? key, {String? defaultValue}) =>
      delegate.get(key, defaultValue: defaultValue);

  @override
  bool containsKey(Object? key) => delegate.containsKey(key);

  @override
  Future<void> put(Object? key, String value) async {
    throw const FileSystemException('Photo record cannot be persisted.');
  }
}

class _InterruptedSourceTransferBox extends Fake implements Box<String> {
  _InterruptedSourceTransferBox(this.delegate);
  final Box<String> delegate;

  @override
  String? get path => delegate.path;
  @override
  Iterable<String> get keys => delegate.keys.whereType<String>();
  @override
  bool containsKey(Object? key) => delegate.containsKey(key);
  @override
  String? get(Object? key, {String? defaultValue}) =>
      delegate.get(key, defaultValue: defaultValue);
  @override
  Future<void> put(Object? key, String value) => delegate.put(key, value);
  @override
  Future<void> putAll(Map<Object?, String> entries) => delegate.putAll(entries);
  @override
  Future<void> flush() => delegate.flush();
  @override
  Future<void> delete(Object? key) async {
    throw const FileSystemException('Interrupted after source retention.');
  }
}

class _FailingClearBox extends Fake implements Box<String> {
  _FailingClearBox(this.delegate, {this.afterDelete = false});
  final Box<String> delegate;
  final bool afterDelete;
  bool failDelete = true;
  bool deletedRecords = false;
  @override
  String? get path => delegate.path;
  @override
  Iterable<String> get keys => delegate.keys.whereType<String>();
  @override
  bool containsKey(Object? key) => delegate.containsKey(key);
  @override
  String? get(Object? key, {String? defaultValue}) =>
      delegate.get(key, defaultValue: defaultValue);
  @override
  Future<void> putAll(Map<Object?, String> entries) => delegate.putAll(entries);
  @override
  Future<void> deleteAll(Iterable<Object?> keys) async {
    if (failDelete && !afterDelete) {
      failDelete = false;
      throw const FileSystemException('Interrupted clear');
    }
    await delegate.deleteAll(keys);
    if (keys.whereType<String>().any(
      (String key) =>
          key.startsWith('photo:') ||
          key.startsWith('source:') ||
          key.startsWith('item:'),
    )) {
      deletedRecords = true;
    }
  }

  @override
  Future<void> flush() async {
    if (afterDelete && failDelete && deletedRecords) {
      failDelete = false;
      throw const FileSystemException('Interrupted clear flush');
    }
    await delegate.flush();
  }
}

class _FailingCleanupBox extends _FailingClearBox {
  _FailingCleanupBox(super.delegate) {
    failDelete = false;
  }

  @override
  Future<void> putAll(Map<Object?, String> entries) async {
    if (entries.keys.whereType<String>().any(
      (String key) => key.startsWith('cleanup:'),
    )) {
      throw const FileSystemException('Cleanup marker cannot be persisted.');
    }
    await super.putAll(entries);
  }
}

class _InterruptedRescanCommitBox extends _InterruptedSourceTransferBox {
  _InterruptedRescanCommitBox(super.delegate);
  bool interrupted = false;
  @override
  Future<void> putAll(Map<Object?, String> entries) async {
    if (!interrupted &&
        entries.keys.whereType<String>().any(
          (String key) => key.startsWith('rescan:'),
        )) {
      interrupted = true;
      final MapEntry<Object?, String> first = entries.entries.first;
      await delegate.put(first.key, first.value);
      throw const FileSystemException('Interrupted replacement commit.');
    }
    await delegate.putAll(entries);
  }

  @override
  Future<void> delete(Object? key) => delegate.delete(key);
  @override
  Future<void> deleteAll(Iterable<Object?> keys) => delegate.deleteAll(keys);
}

class _CountingDraftBox extends _InterruptedSourceTransferBox {
  _CountingDraftBox(super.delegate);
  int keyReads = 0;

  @override
  Iterable<String> get keys {
    keyReads++;
    return super.keys;
  }

  @override
  Future<void> delete(Object? key) => delegate.delete(key);
  @override
  Future<void> deleteAll(Iterable<Object?> keys) => delegate.deleteAll(keys);
}

class _InterruptedCameraAdmissionBox extends _InterruptedSourceTransferBox {
  _InterruptedCameraAdmissionBox(super.delegate);
  bool photoWritten = false;
  bool interrupted = false;

  @override
  Future<void> put(Object? key, String value) async {
    await delegate.put(key, value);
    if (key is String && key.startsWith('photo:')) photoWritten = true;
  }

  @override
  Future<void> putAll(Map<Object?, String> entries) async {
    await delegate.putAll(entries);
    if (entries.keys.whereType<String>().any(
      (String key) => key.startsWith('photo:'),
    )) {
      photoWritten = true;
    }
  }

  @override
  Future<void> flush() async {
    await delegate.flush();
    if (photoWritten && !interrupted) {
      interrupted = true;
      throw const FileSystemException(
        'Interrupted after durable camera admission.',
      );
    }
  }

  @override
  Future<void> delete(Object? key) => delegate.delete(key);
  @override
  Future<void> deleteAll(Iterable<Object?> keys) => delegate.deleteAll(keys);
}

class _InterruptedCameraPromotionBox extends _InterruptedSourceTransferBox {
  _InterruptedCameraPromotionBox(super.delegate);
  bool interrupted = false;

  @override
  Future<void> putAll(Map<Object?, String> entries) async {
    if (!interrupted &&
        entries.keys.whereType<String>().any(
          (String key) => key.startsWith('cleanup:camera:'),
        )) {
      interrupted = true;
      final MapEntry<Object?, String> first = entries.entries.first;
      await delegate.put(first.key, first.value);
      await delegate.flush();
      throw const FileSystemException('Interrupted camera cleanup promotion.');
    }
    await delegate.putAll(entries);
  }
}

class _InterruptedRescanAdmissionBox extends _InterruptedSourceTransferBox {
  _InterruptedRescanAdmissionBox(super.delegate, {this.afterWrite = false});
  final bool afterWrite;
  bool armed = true;

  @override
  Future<void> put(Object? key, String value) async {
    if (armed &&
        key is String &&
        key.startsWith('rescan:') &&
        (jsonDecode(value) as Map<String, Object?>)['photo'] != null) {
      armed = false;
      if (afterWrite) {
        await delegate.put(key, value);
        await delegate.flush();
      }
      throw const FileSystemException('Interrupted replacement admission.');
    }
    await delegate.put(key, value);
  }

  @override
  Future<void> delete(Object? key) => delegate.delete(key);
  @override
  Future<void> deleteAll(Iterable<Object?> keys) => delegate.deleteAll(keys);
}

final class _BlockedCameraDeletes extends IOOverrides {
  _BlockedCameraDeletes(this.paths);
  final Set<String> paths;
  int attempts = 0;

  @override
  File createFile(String path) {
    final File file = super.createFile(path);
    return paths.contains(path) ? _BlockedCameraFile(file, this) : file;
  }
}

class _BlockedCameraFile extends Fake implements File {
  _BlockedCameraFile(this.delegate, this.owner);
  final File delegate;
  final _BlockedCameraDeletes owner;

  @override
  String get path => delegate.path;
  @override
  Uri get uri => delegate.uri;
  @override
  File get absolute => delegate.absolute;
  @override
  Directory get parent => delegate.parent;
  @override
  Future<bool> exists() => delegate.exists();
  @override
  Future<int> length() => delegate.length();
  @override
  Future<FileStat> stat() => delegate.stat();
  @override
  Future<DateTime> lastModified() => delegate.lastModified();
  @override
  Future<Uint8List> readAsBytes() => delegate.readAsBytes();
  @override
  Future<String> resolveSymbolicLinks() => delegate.resolveSymbolicLinks();
  @override
  Future<File> copy(String newPath) => delegate.copy(newPath);
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      delegate.openRead(start, end);
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      delegate.open(mode: mode);
  @override
  Future<File> delete({bool recursive = false}) async {
    owner.attempts++;
    throw const FileSystemException('Camera cache is temporarily unavailable.');
  }
}

Future<List<ScanDraftPhoto>> _importCameraSources(
  ScanDraftStore store,
  List<String> paths, {
  required bool focusStack,
}) => focusStack
    ? store.importFocusStack(
        paths,
        ownedCameraSource: true,
        captureId: 'owned-camera',
      )
    : store.importPhotos(paths, multipleCards: false, ownedCameraSource: true);

ScanCrop _replacementCrop(String path) => ScanCrop(
  imagePath: path,
  width: 640,
  height: 900,
  rectified: true,
  sourceCorners: const <ScanPoint>[
    ScanPoint(.1, .1),
    ScanPoint(.6, .1),
    ScanPoint(.6, .8),
    ScanPoint(.1, .8),
  ],
  lines: const <ScanTextLine>[],
);

Future<ScanDraftRescan> _beginOwnedRescan(
  ScanDraftStore store,
  String originalPath,
) async {
  final ScanDraftPhoto source = (await store.importPhotos(<String>[
    originalPath,
  ], multipleCards: false)).single;
  final ScanDraftItem item = (await store.completePhoto(
    source.id,
    <ScanDraftItem>[
      ScanDraftItem(
        id: 'rescan-original',
        photoId: source.id,
        crop: _replacementCrop(originalPath),
      ),
    ],
  )).single;
  return store.beginRescan(item.id);
}

void main() {
  test(
    'draft round-trip retains ambiguous scene footer without numeric authority',
    () {
      const ScanDraftItem item = ScanDraftItem(
        id: 'scene-footer',
        photoId: 'photo',
        crop: ScanCrop(
          imagePath: '/tmp/card.jpg',
          width: 1000,
          height: 1400,
          rectified: true,
          sourceCorners: <ScanPoint>[],
          warnings: <String>['border_recovered'],
          lines: <ScanTextLine>[
            ScanTextLine(
              text: 'C 07B2',
              confidence: 1,
              bounds: ScanBounds(.06, .93, .13, .018),
              glyphHeight: .015,
              alternatives: <String>['C 0782'],
              sceneFooterGuide: true,
            ),
          ],
        ),
      );
      final ScanDraftItem restored = ScanDraftItem.fromMap(
        jsonDecode(jsonEncode(item.toMap())) as Map<String, Object?>,
      );
      final ScanTextLine line = restored.crop.lines.single;
      expect(line.sceneFooterGuide, isTrue);
      expect(line.text, 'C 07B2');
      expect(line.confidence, 1);
      expect(line.alternatives, <String>['C 0782']);
      expect(line.glyphHeight, .015);
      expect(line.bounds.y, .93);
      expect(restored.crop.warnings, <String>['border_recovered']);
      expect(ScanHints.fromCrop(restored.crop).collectorNumber, isNull);
      expect(ScanHints.fromCrop(restored.crop).setCode, isNull);
    },
  );
  test(
    'draft round-trip preserves measured glyph height and original bounds',
    () {
      const ScanDraftItem item = ScanDraftItem(
        id: 'slanted-title',
        photoId: 'photo',
        crop: ScanCrop(
          imagePath: '/tmp/title.jpg',
          width: 1000,
          height: 1400,
          rectified: true,
          sourceCorners: <ScanPoint>[],
          lines: <ScanTextLine>[
            ScanTextLine(
              text: 'Circle of Protection: Blue',
              confidence: 1,
              bounds: ScanBounds(.03, .02, .75, .118766),
              glyphHeight: .037616,
            ),
          ],
        ),
      );
      final ScanDraftItem restored = ScanDraftItem.fromMap(
        jsonDecode(jsonEncode(item.toMap())) as Map<String, Object?>,
      );
      expect(restored.crop.lines.single.glyphHeight, .037616);
      expect(restored.crop.lines.single.bounds.height, .118766);
      expect(ScanHints.fromCrop(restored.crop).names, <String>[
        'Circle of Protection: Blue',
      ]);
    },
  );
  late Directory directory;
  late File gallery;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('collector-drafts-');
    Hive.init(directory.path);
    gallery = await File('${directory.path}/gallery.jpg')
        .writeAsBytes(<int>[1, 2, 3, 4], flush: true);
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('owned camera rescan retry keeps admitted pixels when the input path is reused', () async {
    final ScanDraftStore store = ScanDraftStore(userId: 'rescan-camera');
    final ScanDraftRescan request = await _beginOwnedRescan(
      store,
      gallery.path,
    );
    final File camera = await File('${directory.path}/retake.jpg')
        .writeAsBytes(<int>[5, 6, 7], flush: true);
    final ScanDraftPhoto photo = await store.importRescanPhoto(
      request,
      camera.path,
      ownedCameraSource: true,
    );
    expect(await camera.exists(), isFalse);
    final ScanDraftPhoto retry = await store.importRescanPhoto(
      request,
      camera.path,
      ownedCameraSource: true,
    );
    expect(retry.id, photo.id);
    expect(await File(retry.imagePath).readAsBytes(), <int>[5, 6, 7]);
    await camera.writeAsBytes(<int>[9, 8, 7], flush: true);
    final ScanDraftPhoto reused = await store.importRescanPhoto(
      request,
      camera.path,
      ownedCameraSource: true,
    );
    await store.cleanPendingImages();
    expect(reused.id, photo.id);
    expect(await File(reused.imagePath).readAsBytes(), <int>[5, 6, 7]);
    expect(await camera.readAsBytes(), <int>[9, 8, 7]);
    expect(await gallery.readAsBytes(), <int>[1, 2, 3, 4]);
  });

  for (final String recovery in <String>[
    'restart',
    'cancel',
    'commit',
    'clear',
  ]) {
    test('owned camera rescan cleanup survives $recovery', () async {
      final ScanDraftStore store = ScanDraftStore(userId: 'rescan-camera');
      final ScanDraftRescan request = await _beginOwnedRescan(
        store,
        gallery.path,
      );
      final File camera = await File('${directory.path}/retake.jpg')
          .writeAsBytes(<int>[5, 6, 7], flush: true);
      final _BlockedCameraDeletes blocked = _BlockedCameraDeletes(<String>{
        camera.path,
        await camera.resolveSymbolicLinks(),
      });
      late ScanDraftPhoto photo;
      await IOOverrides.runWithIOOverrides<Future<void>>(() async {
        photo = await store.importRescanPhoto(
          request,
          camera.path,
          ownedCameraSource: true,
        );
        expect(blocked.attempts, greaterThan(0));
        if (recovery == 'cancel') {
          await store.cancelRescan(
            request.itemId,
            requestId: request.requestId,
          );
        } else if (recovery == 'commit') {
          await store.commitRescan(
            request,
            ScanDraftItem(
              id: request.itemId,
              photoId: photo.id,
              crop: _replacementCrop(gallery.path),
            ),
          );
        } else if (recovery == 'clear') {
          await store.clearCaptures();
        }
        await store.cleanPendingImages();
        expect(await camera.exists(), isTrue);
        await Hive.close();
      }, blocked);
      final ScanDraftStore restarted = ScanDraftStore(userId: 'rescan-camera');
      await restarted.cleanPendingImages();
      expect(await camera.exists(), isFalse);
      expect(await gallery.readAsBytes(), <int>[1, 2, 3, 4]);
      if (recovery == 'cancel' || recovery == 'clear') {
        expect(await File(photo.imagePath).exists(), isFalse);
      } else {
        expect(await File(photo.imagePath).readAsBytes(), <int>[5, 6, 7]);
      }
      if (recovery == 'clear') {
        expect(await restarted.readItems(), isEmpty);
      } else {
        final ScanDraftItem saved = (await restarted.readItems()).single;
        expect(
          saved.photoId,
          recovery == 'commit' ? photo.id : request.original!.photoId,
        );
      }
    });
  }

  test('owned camera rescan interrupted retake preserves the prior admitted pixels', () async {
    late Box<String> box;
    final ScanDraftStore store = ScanDraftStore(
      userId: 'rescan-camera',
      openBox: (String name) async => box = await Hive.openBox<String>(name),
    );
    final ScanDraftRescan request = await _beginOwnedRescan(
      store,
      gallery.path,
    );
    final File first = await File('${directory.path}/retake-first.jpg')
        .writeAsBytes(<int>[5, 6, 7], flush: true);
    final ScanDraftPhoto prior = await store.importRescanPhoto(
      request,
      first.path,
      ownedCameraSource: true,
    );
    expect(await first.exists(), isFalse);
    final Set<String> before = File(prior.imagePath).parent
        .listSync()
        .whereType<File>()
        .map((File file) => file.path)
        .toSet();
    final File next = await File('${directory.path}/retake-next.jpg')
        .writeAsBytes(<int>[9, 8, 7], flush: true);
    final ScanDraftStore failing = ScanDraftStore(
      userId: 'rescan-camera',
      openBox: (String _) async => _InterruptedRescanAdmissionBox(box),
    );
    await expectLater(
      failing.importRescanPhoto(request, next.path, ownedCameraSource: true),
      throwsA(isA<FileSystemException>()),
    );
    await store.cleanPendingImages();
    expect((await store.readRescans()).single.photo!.id, prior.id);
    expect(await File(prior.imagePath).readAsBytes(), <int>[5, 6, 7]);
    expect(await next.readAsBytes(), <int>[9, 8, 7]);
    expect(
      File(prior.imagePath).parent
          .listSync()
          .whereType<File>()
          .map((File file) => file.path)
          .toSet(),
      before,
    );
    final ScanDraftPhoto retry = await store.importRescanPhoto(
      request,
      first.path,
      ownedCameraSource: true,
    );
    expect(retry.id, prior.id);
    final ScanDraftPhoto replacement = await store.importRescanPhoto(
      request,
      next.path,
      ownedCameraSource: true,
    );
    await store.cleanPendingImages();
    expect(replacement.id, isNot(prior.id));
    expect(await File(prior.imagePath).exists(), isFalse);
    expect(await File(replacement.imagePath).readAsBytes(), <int>[9, 8, 7]);
    expect(await next.exists(), isFalse);
  });

  test('owned camera rescan recovers admission after durable write acknowledgment fails', () async {
    late Box<String> box;
    final ScanDraftStore store = ScanDraftStore(
      userId: 'rescan-camera',
      openBox: (String name) async => box = await Hive.openBox<String>(name),
    );
    final ScanDraftRescan request = await _beginOwnedRescan(
      store,
      gallery.path,
    );
    final File camera = await File('${directory.path}/retake.jpg')
        .writeAsBytes(<int>[5, 6, 7], flush: true);
    final ScanDraftStore interrupted = ScanDraftStore(
      userId: 'rescan-camera',
      openBox: (String _) async =>
          _InterruptedRescanAdmissionBox(box, afterWrite: true),
    );
    await expectLater(
      interrupted.importRescanPhoto(
        request,
        camera.path,
        ownedCameraSource: true,
      ),
      throwsA(isA<FileSystemException>()),
    );
    await Hive.close();
    final ScanDraftStore restarted = ScanDraftStore(userId: 'rescan-camera');
    await restarted.cleanPendingImages();
    expect(await camera.exists(), isFalse);
    final ScanDraftPhoto admitted =
        (await restarted.readRescans()).single.photo!;
    final ScanDraftPhoto retry = await restarted.importRescanPhoto(
      request,
      camera.path,
      ownedCameraSource: true,
    );
    expect(retry.id, admitted.id);
    expect(await File(retry.imagePath).readAsBytes(), <int>[5, 6, 7]);
    expect(
      (await restarted.readItems()).single.photoId,
      request.original!.photoId,
    );
  });

  test('owned camera rescan default import preserves gallery input', () async {
    final ScanDraftStore store = ScanDraftStore(userId: 'rescan-gallery');
    final ScanDraftRescan request = await _beginOwnedRescan(
      store,
      gallery.path,
    );
    await store.importRescanPhoto(request, gallery.path);
    await store.cancelRescan(request.itemId, requestId: request.requestId);
    await store.cleanPendingImages();
    expect(await gallery.readAsBytes(), <int>[1, 2, 3, 4]);
  });

  test('pending replacement restores its original and cancels without a phantom photo', () async {
    final ScanDraftStore store = ScanDraftStore(userId: 'rescan-pending');
    final ScanDraftPhoto source = (await store.importPhotos(<String>[
      gallery.path,
    ], multipleCards: false)).single;
    final ScanDraftItem original = (await store.completePhoto(
      source.id,
      <ScanDraftItem>[
        ScanDraftItem(
          id: 'retained',
          photoId: source.id,
          crop: _replacementCrop(gallery.path),
        ),
      ],
    )).single;
    final ScanDraftRescan request = await store.beginRescan(original.id);
    final ScanDraftPhoto replacement = await store.importRescanPhoto(
      request,
      gallery.path,
    );
    await Hive.close();
    final ScanDraftStore reopened = ScanDraftStore(userId: 'rescan-pending');
    expect((await reopened.readRescans()).single.complete, isFalse);
    expect((await reopened.readItems()).single.photoId, source.id);
    expect(await reopened.readPhotos(), isEmpty);
    await reopened.cancelRescan(original.id, requestId: request.requestId);
    expect(await reopened.readRescans(), isEmpty);
    expect(await File(replacement.imagePath).exists(), isFalse);
    expect(await File(original.crop.imagePath).readAsBytes(), <int>[
      1,
      2,
      3,
      4,
    ]);
    expect(await File(source.imagePath).exists(), isTrue);
  });

  test('replacement commits one stable ID and preserves sibling source and repeated choices across restart', () async {
    final Map<String, Object?> fixture = jsonDecode(
      File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final MtgCard printing = MtgCard.fromJson(<String, Object?>{
      ...fixture,
      'foil': true,
      'finishes': <String>['nonfoil', 'foil'],
    });
    final ScanDraftStore store = ScanDraftStore(userId: 'rescan-choices');
    final ScanDraftPhoto source = (await store.importPhotos(<String>[
      gallery.path,
    ], multipleCards: true)).single;
    final ScanQueueApproval choices = ScanQueueApproval(
      operationId: 'retained',
      card: cardFromScryfall(printing, finish: Finish.foil),
      quantity: 7,
      deckId: 'binder',
      deckSection: DeckSection.sideboard,
    );
    final List<ScanDraftItem> old = await store.completePhoto(
      source.id,
      <ScanDraftItem>[
        ScanDraftItem(
          id: 'retained',
          photoId: source.id,
          crop: _replacementCrop(gallery.path),
          approval: choices,
        ),
        ScanDraftItem(
          id: 'sibling',
          photoId: source.id,
          crop: _replacementCrop(gallery.path),
        ),
      ],
    );
    final File newPixels = await File('${directory.path}/fresh.jpg')
        .writeAsBytes(<int>[9, 8, 7], flush: true);
    final ScanDraftRescan request = await store.beginRescan('retained');
    final ScanDraftPhoto replacement = await store.importRescanPhoto(
      request,
      newPixels.path,
    );
    expect(await File(old.first.crop.imagePath).exists(), isTrue);
    final ScanDraftItem saved = await store.commitRescan(
      request,
      ScanDraftItem(
        id: 'retained',
        photoId: replacement.id,
        crop: _replacementCrop(newPixels.path),
      ),
    );
    expect(saved.id, old.first.id);
    expect(saved.approval, isNull);
    expect(saved.crop.imagePath, isNot(old.first.crop.imagePath));
    expect(await File(saved.crop.imagePath).readAsBytes(), <int>[9, 8, 7]);
    expect(await File(source.imagePath).exists(), isTrue);
    expect(await File(old.last.crop.imagePath).exists(), isTrue);
    expect(await store.readReplacedRegions(source.id), hasLength(1));
    final ScanDraftRescan repeat = await store.beginRescan('retained');
    expect(repeat.original!.approval, isNull);
    expect(repeat.choices!.quantity, 7);
    await store.cancelRescan('retained', requestId: repeat.requestId);
    await Hive.close();
    final ScanDraftStore reopened = ScanDraftStore(userId: 'rescan-choices');
    final List<ScanDraftItem> restored = await reopened.readItems();
    expect(restored.map((ScanDraftItem item) => item.id).toSet(), <String>{
      'retained',
      'sibling',
    });
    expect(
      restored
          .singleWhere((ScanDraftItem item) => item.id == 'retained')
          .approval,
      isNull,
    );
    final ScanDraftRescan metadata = (await reopened.readRescans()).single;
    expect(metadata.complete, isTrue);
    expect(metadata.choices!.quantity, 7);
    expect(metadata.choices!.card.finish, Finish.foil);
    expect(metadata.choices!.deckId, 'binder');
    expect(metadata.choices!.deckSection, DeckSection.sideboard);
  });

  for (final bool itemAlreadyRestored in <bool>[false, true]) {
    test(
      'interrupted replacement rollback repairs source after item restoration $itemAlreadyRestored',
      () async {
        Box<String>? box;
        final ScanDraftStore store = ScanDraftStore(
          userId: 'rescan-prefix',
          openBox: (String name) async {
            return box = await Hive.openBox<String>(name);
          },
        );
        final ScanDraftPhoto source = (await store.importPhotos(<String>[
          gallery.path,
        ], multipleCards: true)).single;
        final ScanDraftItem original = (await store.completePhoto(
          source.id,
          <ScanDraftItem>[
            ScanDraftItem(
              id: 'retained',
              photoId: source.id,
              crop: _replacementCrop(gallery.path),
            ),
          ],
        )).single;
        final ScanDraftRescan request = await store.beginRescan(original.id);
        final ScanDraftPhoto replacement = await store.importRescanPhoto(
          request,
          gallery.path,
        );
        final Map<String, Object?> oldSource = jsonDecode(
          box!.get('source:${source.id}')!,
        ) as Map<String, Object?>;
        oldSource['itemIds'] = <String>[];
        oldSource['replacedRegions'] = <Object?>[
          original.crop.sourceCorners
              .map(
                (ScanPoint point) => <String, double>{
                  'x': point.x,
                  'y': point.y,
                },
              )
              .toList(),
        ];
        await box!.putAll(<String, String>{
          'item:${original.id}': jsonEncode(
            ScanDraftItem(
              id: original.id,
              photoId: itemAlreadyRestored ? source.id : replacement.id,
              crop: original.crop,
              selected: itemAlreadyRestored,
            ).toMap(),
          ),
          'source:${source.id}': jsonEncode(oldSource),
          'source:${replacement.id}': jsonEncode(<String, Object?>{
            'photo': replacement.toMap(),
            'itemIds': <String>[original.id],
          }),
        });
        await box!.flush();
        await Hive.close();
        final ScanDraftStore reopened = ScanDraftStore(
          userId: 'rescan-prefix',
          openBox: (String name) async {
            return box = await Hive.openBox<String>(name);
          },
        );
        final ScanDraftItem restored = (await reopened.readItems()).single;
        expect(restored.photoId, source.id);
        expect(restored.selected, itemAlreadyRestored);
        expect(await File(restored.crop.imagePath).readAsBytes(), <int>[
          1,
          2,
          3,
          4,
        ]);
        expect(
          (jsonDecode(box!.get('source:${source.id}')!)
              as Map<String, dynamic>)['itemIds'],
          <String>[original.id],
        );
        expect(await reopened.readReplacedRegions(source.id), isEmpty);
        expect(await reopened.readSource(replacement.id), isNull);
        expect((await reopened.readRescans()).single.complete, isFalse);
        expect(await File(replacement.imagePath).exists(), isTrue);
        expect((await reopened.readItems()).single.photoId, source.id);
        await reopened.cancelRescan(original.id, requestId: request.requestId);
        expect(await File(replacement.imagePath).exists(), isFalse);
        expect(await File(source.imagePath).exists(), isTrue);
      },
    );
  }

  test('bulk removal recovers pending replacements once and preserves an unremoved sibling', () async {
    late Box<String> box;
    final ScanDraftStore store = ScanDraftStore(
      userId: 'bulk-rescan-recovery',
      openBox: (String name) async => box = await Hive.openBox<String>(name),
    );
    final ScanDraftPhoto source = (await store.importPhotos(<String>[
      gallery.path,
    ], multipleCards: true)).single;
    final List<ScanDraftItem> originals = await store.completePhoto(
      source.id,
      List<ScanDraftItem>.generate(
        32,
        (int index) => ScanDraftItem(
          id: 'bulk-$index',
          photoId: source.id,
          crop: _replacementCrop(gallery.path),
        ),
      ),
    );
    final List<ScanDraftRescan> requests = <ScanDraftRescan>[];
    final List<ScanDraftPhoto> replacements = <ScanDraftPhoto>[];
    for (final ScanDraftItem item in originals.take(3)) {
      final ScanDraftRescan request = await store.beginRescan(item.id);
      requests.add(request);
      replacements.add(await store.importRescanPhoto(request, gallery.path));
    }
    final Map<String, Object?> interruptedSource =
        jsonDecode(box.get('source:${source.id}')!) as Map<String, Object?>;
    interruptedSource['itemIds'] = originals
        .where(
          (ScanDraftItem item) =>
              item.id != originals[0].id && item.id != originals[2].id,
        )
        .map((ScanDraftItem item) => item.id)
        .toList();
    for (final int index in <int>[0, 2]) {
      await box.putAll(<String, String>{
        'item:${originals[index].id}': jsonEncode(
          ScanDraftItem(
            id: originals[index].id,
            photoId: replacements[index].id,
            crop: originals[index].crop,
          ).toMap(),
        ),
        'source:${replacements[index].id}': jsonEncode(<String, Object?>{
          'photo': replacements[index].toMap(),
          'itemIds': <String>[originals[index].id],
        }),
      });
    }
    await box.put('source:${source.id}', jsonEncode(interruptedSource));
    await box.flush();
    await Hive.close();
    late _CountingDraftBox counted;
    final ScanDraftStore reopened = ScanDraftStore(
      userId: 'bulk-rescan-recovery',
      openBox: (String name) async =>
          counted = _CountingDraftBox(await Hive.openBox<String>(name)),
    );
    await reopened.removeItems(
      originals
          .where((ScanDraftItem item) => item.id != originals[2].id)
          .map((ScanDraftItem item) => item.id)
          .toList(),
    );
    expect(counted.keyReads, lessThanOrEqualTo(6));
    final ScanDraftItem survivor = (await reopened.readItems()).single;
    expect(survivor.id, originals[2].id);
    expect(survivor.photoId, source.id);
    expect(await File(source.imagePath).exists(), isTrue);
    expect(await File(survivor.crop.imagePath).readAsBytes(), <int>[
      1,
      2,
      3,
      4,
    ]);
    expect(await File(replacements[0].imagePath).exists(), isFalse);
    expect(await File(replacements[1].imagePath).exists(), isFalse);
    expect(await File(replacements[2].imagePath).exists(), isTrue);
    expect((await reopened.readRescans()).single.itemId, survivor.id);
    expect(await reopened.readSource(replacements[2].id), isNull);
    for (final ScanDraftItem removed in originals.where(
      (ScanDraftItem item) => item.id != survivor.id,
    )) {
      expect(await File(removed.crop.imagePath).exists(), isFalse);
    }
    await reopened.cancelRescan(survivor.id, requestId: requests[2].requestId);
    expect(await reopened.readRescans(), isEmpty);
    expect(await File(replacements[2].imagePath).exists(), isFalse);
    expect(await File(source.imagePath).exists(), isTrue);
    expect((await reopened.readItems()).single.id, survivor.id);
  });

  test('failed partial replacement commit rolls back before deleting original pixels', () async {
    late Box<String> box;
    final ScanDraftStore store = ScanDraftStore(
      userId: 'rescan-failure',
      openBox: (String name) async {
        return box = await Hive.openBox<String>(name);
      },
    );
    final ScanDraftPhoto source = (await store.importPhotos(<String>[
      gallery.path,
    ], multipleCards: false)).single;
    final ScanDraftItem original = (await store.completePhoto(
      source.id,
      <ScanDraftItem>[
        ScanDraftItem(
          id: 'retained',
          photoId: source.id,
          crop: _replacementCrop(gallery.path),
        ),
      ],
    )).single;
    final ScanDraftRescan request = await store.beginRescan(original.id);
    final ScanDraftPhoto replacement = await store.importRescanPhoto(
      request,
      gallery.path,
    );
    final _InterruptedRescanCommitBox interrupted = _InterruptedRescanCommitBox(
      box,
    );
    final ScanDraftStore failing = ScanDraftStore(
      userId: 'rescan-failure',
      openBox: (String _) async => interrupted,
    );
    await expectLater(
      failing.commitRescan(
        request,
        ScanDraftItem(
          id: original.id,
          photoId: replacement.id,
          crop: _replacementCrop(gallery.path),
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect((await store.readItems()).single.photoId, source.id);
    expect(await File(original.crop.imagePath).readAsBytes(), <int>[
      1,
      2,
      3,
      4,
    ]);
    expect(await store.readSource(replacement.id), isNull);
    expect((await store.readRescans()).single.complete, isFalse);
  });

  test('image budget includes retained originals and crops across restart without deleting evidence', () async {
    ScanDraftStore store = ScanDraftStore(
      userId: 'budget',
      maximumImageBytes: 8,
    );
    final ScanDraftPhoto photo = (await store.importPhotos(<String>[
      gallery.path,
    ], multipleCards: false)).single;
    final ScanCrop crop = ScanCrop(
      imagePath: gallery.path,
      width: 1000,
      height: 1400,
      rectified: true,
      sourceCorners: const <ScanPoint>[],
      lines: const <ScanTextLine>[],
    );
    final ScanDraftItem item = (await store.completePhoto(
      photo.id,
      <ScanDraftItem>[
        ScanDraftItem(id: '${photo.id}_0', photoId: photo.id, crop: crop),
      ],
    )).single;
    await Hive.close();
    store = ScanDraftStore(userId: 'budget', maximumImageBytes: 8);
    await expectLater(
      store.importPhotos(
        <String>[gallery.path],
        multipleCards: false,
        ownedCameraSource: true,
      ),
      throwsA(isA<ScanDraftStorageBudgetExceeded>()),
    );
    expect(await gallery.readAsBytes(), <int>[1, 2, 3, 4]);
    expect(await File(photo.imagePath).readAsBytes(), <int>[1, 2, 3, 4]);
    expect(await File(item.crop.imagePath).readAsBytes(), <int>[1, 2, 3, 4]);
    expect((await store.readItems()).single.id, item.id);
    expect(await store.readPhotos(), isEmpty);
    await store.removeItems(<String>[item.id]);
    await store.cleanPendingImages();
    expect(
      await store.importPhotos(<String>[gallery.path], multipleCards: false),
      hasLength(1),
    );
  });

  test('staged detail ownership survives zero initial crops and restart until explicit completion or clear', () async {
    ScanDraftStore store = ScanDraftStore(userId: 'staged-detail');
    final List<ScanDraftPhoto> photos = await store.importFocusStack(
      <String>[gallery.path],
      captureId: 'staged',
      targetRegions: const <List<ScanPoint>>[
        <ScanPoint>[
          ScanPoint(.1, .2),
          ScanPoint(.32, .2),
          ScanPoint(.32, .65),
          ScanPoint(.1, .65),
        ],
      ],
    );
    final ScanDraftDetail job = await store.scheduleDetail(photos.single.id);
    expect(job.presenceComplete, isFalse);
    await store.completeFocusStack(photos, const <ScanDraftItem>[]);
    expect((await store.readDetails()).single.presenceComplete, isTrue);
    await Hive.close();
    store = ScanDraftStore(userId: 'staged-detail');
    expect(await store.readPhotos(), isEmpty);
    expect((await store.readDetails()).single.presenceComplete, isTrue);
    expect(await store.readItems(), isEmpty);
    expect(
      await File((await store.readSource(job.photoId))!.imagePath)
          .readAsBytes(),
      <int>[1, 2, 3, 4],
    );
    await store.completeDetail(job.photoId);
    expect(await store.readDetails(), isEmpty);
    expect(await store.readSource(job.photoId), isNotNull);
    await store.clearCaptures();
    expect(await store.readDetails(), isEmpty);
    expect(await store.readSource(job.photoId), isNull);
    expect(await gallery.exists(), isTrue);
  });

  for (final bool hasInitialCrop in <bool>[false, true]) {
    test(
      'interrupted staged presence transition restores one detail job with ${hasInitialCrop ? 'one crop' : 'zero crops'}',
      () async {
        final ScanDraftStore store = ScanDraftStore(
          userId: 'interrupted-detail',
          openBox: (String name) async =>
              _InterruptedSourceTransferBox(await Hive.openBox<String>(name)),
        );
        final List<ScanDraftPhoto> photos = await store.importFocusStack(
          <String>[gallery.path],
          captureId: 'staged-interruption',
          targetRegions: const <List<ScanPoint>>[
            <ScanPoint>[
              ScanPoint(.1, .2),
              ScanPoint(.32, .2),
              ScanPoint(.32, .65),
              ScanPoint(.1, .65),
            ],
          ],
        );
        final ScanDraftPhoto photo = photos.single;
        await store.scheduleDetail(photo.id);
        final ScanDraftItem initial = ScanDraftItem(
          id: '${photo.id}_0_0',
          photoId: photo.id,
          crop: ScanCrop(
            imagePath: photo.imagePath,
            width: 1000,
            height: 1400,
            rectified: true,
            sourceCorners: photo.targetRegions!.single,
            lines: const <ScanTextLine>[],
            warnings: const <String>['details_pending'],
          ),
        );
        await expectLater(
          store.completeFocusStack(
            photos,
            hasInitialCrop ? <ScanDraftItem>[initial] : const <ScanDraftItem>[],
          ),
          throwsA(isA<FileSystemException>()),
        );
        await Hive.close();
        final ScanDraftStore restarted = ScanDraftStore(
          userId: 'interrupted-detail',
        );
        expect(await restarted.readPhotos(), isEmpty);
        final ScanDraftDetail pending = (await restarted.readDetails()).single;
        expect(pending.photoId, photo.id);
        expect(pending.presenceComplete, isTrue);
        expect(pending.failed, isFalse);
        expect(
          await File((await restarted.readSource(photo.id))!.imagePath)
              .readAsBytes(),
          <int>[1, 2, 3, 4],
        );
        expect(await restarted.readItems(), hasLength(hasInitialCrop ? 1 : 0));
        await restarted.completePhoto(photo.id, <ScanDraftItem>[initial]);
        await restarted.completeDetail(photo.id);
        await Hive.close();
        final ScanDraftStore completed = ScanDraftStore(
          userId: 'interrupted-detail',
        );
        expect(await completed.readDetails(), isEmpty);
        expect(await completed.readPhotos(), isEmpty);
        expect((await completed.readItems()).single.id, initial.id);
        expect(await completed.readSource(photo.id), isNotNull);
        expect(await gallery.exists(), isTrue);
      },
    );
  }

  test(
    'image budget preserves a pending source when its crop cannot fit',
    () async {
      final ScanDraftStore store = ScanDraftStore(
        userId: 'crop-budget',
        maximumImageBytes: 6,
      );
      final ScanDraftPhoto photo = (await store.importPhotos(<String>[
        gallery.path,
      ], multipleCards: false)).single;
      await expectLater(
        store.completePhoto(photo.id, <ScanDraftItem>[
          ScanDraftItem(
            id: '${photo.id}_0',
            photoId: photo.id,
            crop: ScanCrop(
              imagePath: gallery.path,
              width: 1000,
              height: 1400,
              rectified: true,
              sourceCorners: const <ScanPoint>[],
              lines: const <ScanTextLine>[],
            ),
          ),
        ]),
        throwsA(isA<ScanDraftStorageBudgetExceeded>()),
      );
      expect(await store.readItems(), isEmpty);
      expect((await store.readPhotos()).single.id, photo.id);
      expect(await File(photo.imagePath).readAsBytes(), <int>[1, 2, 3, 4]);
      expect(await gallery.exists(), isTrue);
    },
  );

  test('image budget rejects a focus stack atomically before deleting camera sources', () async {
    final File second = await File('${directory.path}/second.jpg')
        .writeAsBytes(<int>[5, 6, 7, 8]);
    final ScanDraftStore store = ScanDraftStore(
      userId: 'stack-budget',
      maximumImageBytes: 6,
    );
    await expectLater(
      store.importFocusStack(
        <String>[gallery.path, second.path],
        captureId: 'over_budget',
        ownedCameraSource: true,
      ),
      throwsA(isA<ScanDraftStorageBudgetExceeded>()),
    );
    expect(await store.readPhotos(), isEmpty);
    expect(await store.readSource('over_budget_0'), isNull);
    expect(await gallery.readAsBytes(), <int>[1, 2, 3, 4]);
    expect(await second.readAsBytes(), <int>[5, 6, 7, 8]);
    expect(
      await store.importPhotos(<String>[gallery.path], multipleCards: false),
      hasLength(1),
    );
  });

  for (final bool afterDelete in <bool>[false, true]) {
    test(
      'failed clear ${afterDelete ? 'flush' : 'deletion'} rolls back cleanup markers before restarted source recovery',
      () async {
        Box<String>? opened;
        final ScanDraftStore original = ScanDraftStore(
          userId: 'clear-owner',
          openBox: (String name) async =>
              opened = await Hive.openBox<String>(name),
        );
        final ScanDraftPhoto photo = (await original.importPhotos(<String>[
          gallery.path,
        ], multipleCards: true)).single;
        final Box<String> box = opened!;
        await box.put(
          'source:${photo.id}',
          jsonEncode(<String, Object?>{
            'photo': photo.toMap(),
            'itemIds': <String>[],
          }),
        );
        await box.flush();
        final ScanDraftStore failing = ScanDraftStore(
          userId: 'clear-owner',
          openBox: (String _) async =>
              _FailingClearBox(box, afterDelete: afterDelete),
        );
        await expectLater(
          failing.clearCaptures(),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          box.keys.whereType<String>().where(
            (String key) => key.startsWith('cleanup:'),
          ),
          isEmpty,
        );
        await original.readItems();
        await original.cleanPendingImages();
        expect(box.containsKey('source:${photo.id}'), isTrue);
        expect(box.containsKey('photo:${photo.id}'), isTrue);
        await Hive.close();
        final ScanDraftStore restarted = ScanDraftStore(userId: 'clear-owner');
        await restarted.readItems();
        final ScanDraftPhoto? restored = await restarted.readSource(photo.id);
        expect(restored, isNotNull);
        expect(await File(restored!.imagePath).exists(), isTrue);
        await restarted.clearCaptures();
        await restarted.cleanPendingImages();
        expect(await restarted.readSource(photo.id), isNull);
        expect(await restarted.readPhotos(), isEmpty);
        expect(await gallery.exists(), isTrue);
      },
    );
  }

  test('a cleanup-write failure cannot undo cleared metadata and owned orphans are reclaimable', () async {
    Box<String>? opened;
    final ScanDraftStore original = ScanDraftStore(
      userId: 'cleanup-owner',
      openBox: (String name) async => opened = await Hive.openBox<String>(name),
    );
    final ScanDraftPhoto photo = (await original.importPhotos(<String>[
      gallery.path,
    ], multipleCards: true)).single;
    final ScanDraftStore failing = ScanDraftStore(
      userId: 'cleanup-owner',
      openBox: (String _) async => _FailingCleanupBox(opened!),
    );
    await failing.clearCaptures();
    expect(await original.readPhotos(), isEmpty);
    expect(await File(photo.imagePath).exists(), isTrue);
    await original.clearCaptures();
    await original.cleanPendingImages();
    expect(await File(photo.imagePath).exists(), isFalse);
    expect(await gallery.exists(), isTrue);
  });

  test('removing empty-image drafts projects cleanup ownership without validating unrelated photo metadata', () async {
    Box<String>? opened;
    final ScanDraftStore store = ScanDraftStore(
      userId: 'projection-owner',
      openBox: (String name) async => opened = await Hive.openBox<String>(name),
    );
    const ScanDraftItem item = ScanDraftItem(
      id: 'live-card',
      photoId: 'owned-empty',
      crop: ScanCrop(
        imagePath: '',
        width: 1000,
        height: 1400,
        rectified: true,
        sourceCorners: <ScanPoint>[],
        lines: <ScanTextLine>[],
      ),
    );
    await store.upsertItems(<ScanDraftItem>[item]);
    final ScanDraftPhoto empty = ScanDraftPhoto(
      id: 'owned-empty',
      imagePath: '',
      multipleCards: true,
      createdAt: DateTime.utc(2026),
    );
    final ScanDraftPhoto unrelated = ScanDraftPhoto(
      id: 'unrelated',
      imagePath: '',
      multipleCards: true,
      createdAt: DateTime.utc(2026),
    );
    final Map<String, Object?> invalidPhoto = unrelated.toMap()
      ..['diagnosticOnly'] = 'invalid';
    await opened!.putAll(<String, String>{
      'source:owned-empty': jsonEncode(<String, Object?>{
        'photo': empty.toMap(),
        'itemIds': <String>[item.id],
      }),
      'source:unrelated': jsonEncode(<String, Object?>{
        'photo': invalidPhoto,
        'itemIds': <String>[],
      }),
    });
    await opened!.flush();
    await expectLater(store.readSource('unrelated'), throwsA(isA<TypeError>()));
    await store.removeItems(<String>[item.id]);
    await store.cleanPendingImages();
    expect(await store.readItems(), isEmpty);
    expect(opened!.containsKey('source:owned-empty'), isFalse);
    expect(opened!.containsKey('source:unrelated'), isTrue);
    await expectLater(store.readSource('unrelated'), throwsA(isA<TypeError>()));
    expect(await gallery.exists(), isTrue);
  });

  test('clear deletes pending and completed focus-stack sources with all owned images', () async {
    final ScanDraftStore store = ScanDraftStore(userId: 'clear-stacks');
    final File second = await File('${directory.path}/second.jpg')
        .writeAsBytes(<int>[5, 6, 7]);
    final List<ScanDraftPhoto> pending = await store.importFocusStack(<String>[
      gallery.path,
      second.path,
    ], captureId: 'pending');
    final List<ScanDraftPhoto> complete = await store.importFocusStack(<String>[
      gallery.path,
      second.path,
    ], captureId: 'complete');
    final List<ScanDraftItem> items = await store.completeFocusStack(
      complete,
      <ScanDraftItem>[
        ScanDraftItem(
          id: 'complete-card',
          photoId: complete.first.id,
          crop: ScanCrop(
            imagePath: gallery.path,
            width: 1000,
            height: 1400,
            rectified: true,
            sourceCorners: const <ScanPoint>[],
            lines: const <ScanTextLine>[],
          ),
        ),
      ],
    );
    final List<String> paths = <String>[
      ...pending.map((ScanDraftPhoto photo) => photo.imagePath),
      ...complete.map((ScanDraftPhoto photo) => photo.imagePath),
      ...items.map((ScanDraftItem item) => item.crop.imagePath),
    ];
    await store.clearCaptures();
    await store.cleanPendingImages();
    expect(await store.readPhotos(), isEmpty);
    expect(await store.readItems(), isEmpty);
    for (final ScanDraftPhoto photo in <ScanDraftPhoto>[
      ...pending,
      ...complete,
    ]) {
      expect(await store.readSource(photo.id), isNull);
    }
    for (final String path in paths) {
      expect(await File(path).exists(), isFalse);
    }
    expect(await gallery.exists(), isTrue);
  });

  test(
    'persisted refinement aliases allow only existing canonical receipt writes',
    () async {
      final ScanDraftStore storage = ScanDraftStore(userId: 'refinement-owner');
      const String receipt = 'live_original_card1';
      const ScanCrop crop = ScanCrop(
        imagePath: '',
        width: 1000,
        height: 1400,
        rectified: true,
        sourceCorners: <ScanPoint>[],
        lines: <ScanTextLine>[],
      );
      const ScanDraftItem owned = ScanDraftItem(
        id: receipt,
        photoId: 'original_0',
        crop: crop,
        liveCaptureReceiptId: receipt,
      );
      await storage.upsertItems(<ScanDraftItem>[owned]);
      final List<ScanDraftPhoto> imported = await storage.importFocusStack(
        <String>[gallery.path],
        captureId: 'recovery',
        refinementReceiptIds: <String>[receipt],
      );
      final ScanDraftStore reopened = ScanDraftStore(
        userId: 'refinement-owner',
      );
      final List<ScanDraftPhoto> pending = await reopened.readFocusStack(
        imported.first.id,
      );
      expect(pending.single.refinementReceiptIds, <String>[receipt]);
      const ScanDraftItem unowned = ScanDraftItem(
        id: 'other',
        photoId: 'recovery_0',
        crop: crop,
      );
      await expectLater(
        reopened.completeFocusStack(pending, <ScanDraftItem>[unowned]),
        throwsArgumentError,
      );
      expect((await reopened.readItems()).single.id, receipt);
      await reopened.completeFocusStack(pending, <ScanDraftItem>[owned]);
      expect((await reopened.readItems()).single.id, receipt);
      await reopened.removeItems(<String>[receipt]);
      expect(await reopened.readSource(imported.first.id), isNull);
      await expectLater(
        reopened.completeFocusStack(pending, <ScanDraftItem>[owned]),
        throwsArgumentError,
      );
      expect(await reopened.readItems(), isEmpty);
    },
  );

  test('draft persistence retains independent historical identity proof and printing pagination', () async {
    final MtgCard printing = MtgCard.fromJson(
      jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<String, Object?>,
    );
    final ScanDraftStore storage = ScanDraftStore(userId: 'historical-owner');
    final ScanDraftPhoto photo = (await storage.importPhotos(<String>[
      gallery.path,
    ], multipleCards: false)).single;
    const HistoricalBodyIdentityProof proof = HistoricalBodyIdentityProof(
      name: 'Dusk // Dawn',
      bodySignature: 'verified-body-and-footer-signature',
    );
    final ScanDraftItem item = ScanDraftItem(
      id: '${photo.id}_0',
      photoId: photo.id,
      crop: ScanCrop(
        imagePath: photo.imagePath,
        width: 1000,
        height: 1400,
        rectified: true,
        sourceCorners: const <ScanPoint>[],
        lines: const <ScanTextLine>[],
      ),
      resolution: ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(printing, const <ScanEvidence>{
            ScanEvidence.rulesKeywordMatch,
          }),
        ],
        hints: const ScanHints(names: <String>[]),
        status: ScanResolutionStatus.needsReview,
        hasMore: true,
        historicalBodyIdentityProof: proof,
      ),
    );
    await storage.completePhoto(photo.id, <ScanDraftItem>[item]);
    await Hive.close();
    final ScanDraftItem restored = (await ScanDraftStore(
      userId: 'historical-owner',
    ).readItems()).single;
    final ScanResolution resolution = restored.resolution!;
    expect(resolution.historicalBodyIdentityProof!.name, proof.name);
    expect(
      resolution.historicalBodyIdentityProof!.bodySignature,
      proof.bodySignature,
    );
    expect(resolution.hasMore, isTrue);
    expect(resolution.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(restored.crop, resolution), isFalse);
    final Map<String, Object?> unproved = restored.toMap();
    (unproved['resolution']!
            as Map<String, Object?>)['historicalBodyIdentityProof'] =
        null;
    expect(
      ScanDraftItem.fromMap(unproved).resolution!.historicalBodyIdentityProof,
      isNull,
    );
  });

  test('restart restores quoted body evidence without promoting it to rules', () async {
    final ScanDraftStore storage = ScanDraftStore(userId: 'quoted-body-owner');
    final ScanDraftPhoto photo = (await storage.importPhotos(<String>[
      gallery.path,
    ], multipleCards: false)).single;
    final ScanCrop crop = ScanCrop(
      imagePath: photo.imagePath,
      width: 1000,
      height: 1400,
      rectified: true,
      sourceCorners: const <ScanPoint>[
        ScanPoint(.1, .1),
        ScanPoint(.7, .1),
        ScanPoint(.7, .8),
        ScanPoint(.1, .8),
      ],
      lines: const <ScanTextLine>[
        ScanTextLine(
          text: 'Sample',
          confidence: 1,
          bounds: ScanBounds(.05, .04, .5, .03),
        ),
        ScanTextLine(
          text: 'Sorcery',
          confidence: 1,
          bounds: ScanBounds(.05, .55, .3, .03),
        ),
        ScanTextLine(
          text: 'Draw two cards.',
          confidence: 1,
          bounds: ScanBounds(.05, .62, .7, .03),
        ),
        ScanTextLine(
          text: '"A story from another age begins',
          confidence: .80,
          bounds: ScanBounds(.05, .70, .7, .03),
        ),
        ScanTextLine(
          text: 'Destroy target nonartifact creature.',
          confidence: 1,
          bounds: ScanBounds(.05, .75, .8, .03),
        ),
      ],
    );
    final ScanHints hints = ScanHints.fromCrop(crop);
    expect(hints.rulesText, <String>['Draw two cards.']);
    expect(hints.postQuoteText, <String>[
      'Destroy target nonartifact creature.',
    ]);
    await storage.completePhoto(photo.id, <ScanDraftItem>[
      ScanDraftItem(
        id: '${photo.id}_0',
        photoId: photo.id,
        crop: crop,
        resolution: ScanResolution(
          candidates: const <ScanCandidate>[],
          hints: hints,
          status: ScanResolutionStatus.noMatch,
        ),
      ),
    ]);
    await Hive.close();
    final ScanDraftItem restored = (await ScanDraftStore(
      userId: 'quoted-body-owner',
    ).readItems()).single;
    expect(restored.resolution!.hints.rulesText, hints.rulesText);
    expect(restored.resolution!.hints.postQuoteText, hints.postQuoteText);
    expect(restored.crop.lines.last.text, hints.postQuoteText.single);
    expect(restored.resolution!.candidates, isEmpty);
    expect(restored.resolution!.status, ScanResolutionStatus.noMatch);
  });

  test('photo and focus exclusions freeze at import and persist through relocation and idempotent retry', () async {
    final List<ScanPoint> region = <ScanPoint>[
      const ScanPoint(.1, .1),
      const ScanPoint(.4, .1),
      const ScanPoint(.4, .7),
      const ScanPoint(.1, .7),
    ];
    final List<List<ScanPoint>> exclusions = <List<ScanPoint>>[region];
    final ScanDraftStore storage = ScanDraftStore(userId: 'exclusion-owner');
    final Future<List<ScanDraftPhoto>> pendingPhoto = storage.importPhotos(
      <String>[gallery.path],
      multipleCards: true,
      excludedRegions: exclusions,
    );
    region[0] = const ScanPoint(.9, .9);
    exclusions.clear();
    final ScanDraftPhoto photo = (await pendingPhoto).single;
    expect(photo.excludedRegions.single.first.x, .1);
    expect(
      () => photo.excludedRegions.single.add(const ScanPoint(.2, .2)),
      throwsUnsupportedError,
    );
    expect(() => photo.excludedRegions.clear(), throwsUnsupportedError);
    final File second = await File('${directory.path}/second.jpg')
        .writeAsBytes(<int>[5, 6, 7]);
    final List<String> paths = <String>[gallery.path, second.path];
    final List<ScanDraftPhoto> stack = await storage.importFocusStack(
      paths,
      excludedRegions: photo.excludedRegions,
    );
    final ScanDraftStore other = ScanDraftStore(userId: 'another-owner');
    final ScanDraftPhoto otherPhoto = (await other.importPhotos(<String>[
      gallery.path,
    ], multipleCards: false)).single;
    final String formerRoot = directory.path;
    final String otherRelative = otherPhoto.imagePath.substring(
      formerRoot.length,
    );
    await Hive.close();
    directory = await directory.rename('$formerRoot-relocated');
    Hive.init(directory.path);
    gallery = File('${directory.path}/gallery.jpg');
    final ScanDraftStore reopened = ScanDraftStore(userId: 'exclusion-owner');
    final List<ScanDraftPhoto> restored = await reopened.readPhotos();
    expect(restored, hasLength(2));
    final ScanDraftPhoto restoredPhoto = restored.firstWhere(
      (ScanDraftPhoto candidate) => candidate.id == photo.id,
    );
    expect(restoredPhoto.excludedRegions.single.first.x, .1);
    expect(restoredPhoto.imagePath, startsWith(directory.path));
    final List<ScanDraftPhoto> retry = await reopened.importFocusStack(paths);
    expect(
      retry.map((ScanDraftPhoto candidate) => candidate.id),
      stack.map((ScanDraftPhoto candidate) => candidate.id),
    );
    expect(
      retry.every(
        (ScanDraftPhoto candidate) =>
            candidate.excludedRegions.single.first.x == .1,
      ),
      isTrue,
    );
    await reopened.completeFocusStack(retry, const <ScanDraftItem>[]);
    expect(await reopened.focusStackComplete(retry.first.id), isTrue);
    final List<ScanDraftPhoto> completedRetry = await reopened.importFocusStack(
      paths,
    );
    expect(
      completedRetry.map((ScanDraftPhoto candidate) => candidate.id),
      stack.map((ScanDraftPhoto candidate) => candidate.id),
    );
    expect(
      (await reopened.readSource(retry.first.id))!
          .excludedRegions
          .single
          .first
          .x,
      .1,
    );
    expect(await File('${directory.path}$otherRelative').exists(), isTrue);
    expect(await gallery.exists(), isTrue);
    expect(await reopened.readItems(), isEmpty);
  });

  test('frozen diagnostic targets survive pending and completed focus-source restart and cannot be widened by retry', () async {
    final List<ScanPoint> region = <ScanPoint>[
      const ScanPoint(.1, .1),
      const ScanPoint(.4, .1),
      const ScanPoint(.4, .7),
      const ScanPoint(.1, .7),
    ];
    final List<List<ScanPoint>> targets = <List<ScanPoint>>[region];
    final ScanDraftStore storage = ScanDraftStore(userId: 'target-owner');
    final Future<List<ScanDraftPhoto>> importing = storage.importFocusStack(
      <String>[gallery.path],
      captureId: 'owned_target',
      targetRegions: targets,
    );
    region[0] = const ScanPoint(.9, .9);
    targets.clear();
    final ScanDraftPhoto photo = (await importing).single;
    expect(photo.targetRegions!.single.first.x, .1);
    expect(() => photo.targetRegions!.clear(), throwsUnsupportedError);
    expect(
      () => photo.targetRegions!.single.add(const ScanPoint(.2, .2)),
      throwsUnsupportedError,
    );
    await Hive.close();
    Hive.init(directory.path);
    final ScanDraftStore reopened = ScanDraftStore(userId: 'target-owner');
    final ScanDraftPhoto restored = (await reopened.readPhotos()).single;
    expect(restored.targetRegions!.single.first.x, .1);
    final List<ScanDraftPhoto> stack = await reopened.readFocusStack(
      restored.id,
    );
    expect(stack.single.targetRegions!.single.first.x, .1);
    await reopened.completeFocusStack(stack, const <ScanDraftItem>[]);
    expect(
      (await reopened.readSource(restored.id))!.targetRegions!.single.first.x,
      .1,
    );
    final List<ScanDraftPhoto> retry = await reopened.importFocusStack(<String>[
      gallery.path,
    ], captureId: 'owned_target');
    expect(retry.single.targetRegions!.single.first.x, .1);
    expect(await reopened.readItems(), isEmpty);
    expect(await gallery.exists(), isTrue);
  });

  test(
    'focus-photo purpose survives pending and completed source restart',
    () async {
      final ScanDraftStore storage = ScanDraftStore(userId: 'photo-purpose');
      final List<ScanDraftPhoto> ordinary = await storage.importFocusStack(
        <String>[gallery.path],
        captureId: 'ordinary_purpose',
      );
      final List<ScanDraftPhoto> diagnostic = await storage.importFocusStack(
        <String>[gallery.path],
        captureId: 'diagnostic_purpose',
        diagnosticOnly: true,
        targetRegions: const <List<ScanPoint>>[],
      );
      expect(ordinary.single.diagnosticOnly, isFalse);
      expect(diagnostic.single.diagnosticOnly, isTrue);
      await Hive.close();
      Hive.init(directory.path);
      final ScanDraftStore reopened = ScanDraftStore(userId: 'photo-purpose');
      final List<ScanDraftPhoto> restoredOrdinary = await reopened
          .readFocusStack(ordinary.single.id);
      final List<ScanDraftPhoto> restoredDiagnostic = await reopened
          .readFocusStack(diagnostic.single.id);
      expect(restoredOrdinary.single.diagnosticOnly, isFalse);
      expect(restoredDiagnostic.single.diagnosticOnly, isTrue);
      await reopened.completeFocusStack(
        restoredDiagnostic,
        const <ScanDraftItem>[],
      );
      expect(
        (await reopened.readSource(diagnostic.single.id))!.diagnosticOnly,
        isTrue,
      );
      final List<ScanDraftPhoto> retry = await reopened.importFocusStack(
        <String>[gallery.path],
        captureId: 'diagnostic_purpose',
      );
      expect(retry.single.diagnosticOnly, isTrue);
    },
  );

  test('diagnostic target schema distinguishes unrestricted null from empty and rejects invalid owned footprints', () {
    final ScanDraftPhoto ordinary = ScanDraftPhoto(
      id: 'ordinary',
      imagePath: 'photo.jpg',
      multipleCards: true,
      createdAt: DateTime.utc(2026),
    );
    expect(ScanDraftPhoto.fromMap(ordinary.toMap()).targetRegions, isNull);
    final ScanDraftPhoto empty = ScanDraftPhoto(
      id: 'empty',
      imagePath: 'photo.jpg',
      multipleCards: true,
      createdAt: DateTime.utc(2026),
      targetRegions: const <List<ScanPoint>>[],
    );
    expect(ScanDraftPhoto.fromMap(empty.toMap()).targetRegions, isEmpty);
    for (final List<ScanPoint> invalid in <List<ScanPoint>>[
      const <ScanPoint>[
        ScanPoint(.1, .1),
        ScanPoint(.4, .7),
        ScanPoint(.4, .1),
        ScanPoint(.1, .7),
      ],
      const <ScanPoint>[
        ScanPoint(.1, .1),
        ScanPoint(.1, .1),
        ScanPoint(.4, .7),
        ScanPoint(.1, .7),
      ],
      <ScanPoint>[
        const ScanPoint(.1, .1),
        ScanPoint(double.nan, .1),
        const ScanPoint(.4, .7),
        const ScanPoint(.1, .7),
      ],
    ]) {
      expect(
        () => ScanDraftPhoto.freezeTargetRegions(<List<ScanPoint>>[invalid]),
        throwsArgumentError,
      );
    }
    expect(
      () => ScanDraftPhoto.freezeTargetRegions(
        List<List<ScanPoint>>.filled(9, const <ScanPoint>[
          ScanPoint(.1, .1),
          ScanPoint(.4, .1),
          ScanPoint(.4, .7),
          ScanPoint(.1, .7),
        ]),
      ),
      throwsArgumentError,
    );
  });

  test('ordinary records default to no exclusions and invalid import geometry is rejected', () async {
    final ScanDraftPhoto ordinary = ScanDraftPhoto.fromMap(<String, Object?>{
      'id': 'ordinary',
      'imagePath': 'photo.jpg',
      'multipleCards': false,
      'diagnosticOnly': false,
      'createdAt': '2026-10-10T00:00:00Z',
    });
    expect(ordinary.excludedRegions, isEmpty);
    final ScanDraftStore storage = ScanDraftStore(userId: 'invalid-exclusions');
    for (final List<ScanPoint> region in <List<ScanPoint>>[
      const <ScanPoint>[
        ScanPoint(.1, .1),
        ScanPoint(.2, .1),
        ScanPoint(.2, .2),
      ],
      <ScanPoint>[
        const ScanPoint(.1, .1),
        ScanPoint(double.nan, .1),
        const ScanPoint(.2, .2),
        const ScanPoint(.1, .2),
      ],
      const <ScanPoint>[
        ScanPoint(-.1, .1),
        ScanPoint(.2, .1),
        ScanPoint(.2, .2),
        ScanPoint(.1, .2),
      ],
    ]) {
      expect(
        () => storage.importPhotos(
          <String>[gallery.path],
          multipleCards: true,
          excludedRegions: <List<ScanPoint>>[region],
        ),
        throwsArgumentError,
      );
    }
    expect(await storage.readPhotos(), isEmpty);
    final ScanDraftPhoto imported = (await storage.importPhotos(<String>[
      gallery.path,
    ], multipleCards: false)).single;
    expect(imported.excludedRegions, isEmpty);
    expect(await gallery.exists(), isTrue);
    await expectLater(
      storage.completeFocusStack(<ScanDraftPhoto>[
        imported,
      ], const <ScanDraftItem>[]),
      throwsArgumentError,
    );
  });

  test('moving the real Hive directory retains saved crops, originals and pending focus sources and cleans relocated owned files', () async {
    late Box<String> aliceBox;
    final ScanDraftStore storage = ScanDraftStore(
      userId: 'alice',
      openBox: (String name) async {
        aliceBox = await Hive.openBox<String>(name);
        return aliceBox;
      },
    );
    final File second = await File('${directory.path}/second.jpg')
        .writeAsBytes(<int>[9, 8, 7], flush: true);
    final ScanDraftPhoto original = (await storage.importPhotos(<String>[
      gallery.path,
    ], multipleCards: false)).single;
    final ScanDraftItem saved = (await storage.completePhoto(
      original.id,
      <ScanDraftItem>[
        ScanDraftItem(
          id: '${original.id}_0',
          photoId: original.id,
          crop: ScanCrop(
            imagePath: original.imagePath,
            width: 200,
            height: 280,
            rectified: true,
            sourceCorners: const <ScanPoint>[],
            lines: const <ScanTextLine>[],
          ),
        ),
      ],
    )).single;
    final List<ScanDraftPhoto> pending = await storage.importFocusStack(
      <String>[gallery.path, second.path],
    );
    final ScanDraftStore bob = ScanDraftStore(userId: 'bob');
    final ScanDraftPhoto bobPhoto = (await bob.importPhotos(<String>[
      second.path,
    ], multipleCards: false)).single;
    final Directory owned = File(original.imagePath).parent;
    final File queuedCleanup = await File('${owned.path}/photo-retired.jpg')
        .writeAsBytes(<int>[6, 5], flush: true);
    await aliceBox.put(
      'cleanup:photo:retired',
      jsonEncode(<String, String>{
        'key': 'photo:retired',
        'path': queuedCleanup.path,
      }),
    );
    await aliceBox.flush();
    final String formerRoot = directory.path;
    final String relativeCleanup = queuedCleanup.path.substring(
      formerRoot.length,
    );
    final String bobRelative = bobPhoto.imagePath.substring(formerRoot.length);
    await Hive.close();
    directory = await directory.rename('$formerRoot-relocated');
    Hive.init(directory.path);
    gallery = File('${directory.path}/gallery.jpg');
    expect(await Directory(formerRoot).exists(), isFalse);

    final ScanDraftStore restored = ScanDraftStore(userId: 'alice');
    final ScanDraftPhoto restoredSource = (await restored.readSource(
      original.id,
    ))!;
    final ScanDraftItem restoredItem = (await restored.readItems()).single;
    expect(restoredSource.imagePath, startsWith('${directory.path}/'));
    expect(restoredItem.crop.imagePath, startsWith('${directory.path}/'));
    expect(restoredSource.imagePath, isNot(original.imagePath));
    expect(restoredItem.crop.imagePath, isNot(saved.crop.imagePath));
    expect(await File(restoredSource.imagePath).readAsBytes(), <int>[
      1,
      2,
      3,
      4,
    ]);
    expect(await File(restoredItem.crop.imagePath).readAsBytes(), <int>[
      1,
      2,
      3,
      4,
    ]);
    expect(await File('${directory.path}$relativeCleanup').exists(), isFalse);
    final List<ScanDraftPhoto> restoredPending = await restored.readPhotos();
    expect(restoredPending.single.id, pending.first.id);
    final List<ScanDraftPhoto> restoredStack = await restored.readFocusStack(
      pending.first.id,
    );
    expect(
      restoredStack.map((ScanDraftPhoto photo) => photo.id),
      pending.map((ScanDraftPhoto photo) => photo.id),
    );
    expect(await File(restoredStack.first.imagePath).readAsBytes(), <int>[
      1,
      2,
      3,
      4,
    ]);
    expect(await File(restoredStack.last.imagePath).readAsBytes(), <int>[
      9,
      8,
      7,
    ]);
    expect(restoredPending.single.imagePath, restoredStack.first.imagePath);
    final List<ScanDraftPhoto> retriedStack = await restored.importFocusStack(
      <String>['$formerRoot/gallery.jpg', '$formerRoot/second.jpg'],
    );
    expect(
      retriedStack.map((ScanDraftPhoto photo) => photo.imagePath),
      restoredStack.map((ScanDraftPhoto photo) => photo.imagePath),
    );
    final ScanDraftItem stackItem = (await restored.completeFocusStack(
      restoredStack,
      <ScanDraftItem>[
        ScanDraftItem(
          id: '${restoredStack.first.id}_0',
          photoId: restoredStack.last.id,
          crop: ScanCrop(
            imagePath: restoredStack.last.imagePath,
            width: 200,
            height: 280,
            rectified: true,
            sourceCorners: const <ScanPoint>[],
            lines: const <ScanTextLine>[],
          ),
        ),
      ],
    )).single;
    expect(await File(stackItem.crop.imagePath).readAsBytes(), <int>[9, 8, 7]);
    expect(await restored.readPhotos(), isEmpty);
    for (final ScanDraftPhoto photo in restoredStack) {
      expect((await restored.readSource(photo.id))!.imagePath, photo.imagePath);
    }
    await restored.removeItems(<String>[restoredItem.id]);
    expect(await File(restoredSource.imagePath).exists(), isFalse);
    expect(await File(restoredItem.crop.imagePath).exists(), isFalse);
    expect(await File(restoredStack.first.imagePath).exists(), isTrue);
    await restored.removeItems(<String>[stackItem.id]);
    await restored.cleanPendingImages();
    for (final ScanDraftPhoto photo in restoredStack) {
      expect(await restored.readSource(photo.id), isNull);
      expect(await File(photo.imagePath).exists(), isFalse);
    }
    expect(await File(stackItem.crop.imagePath).exists(), isFalse);
    final ScanDraftPhoto restoredBob = (await ScanDraftStore(
      userId: 'bob',
    ).readPhotos()).single;
    expect(restoredBob.imagePath, '${directory.path}$bobRelative');
    expect(await File(restoredBob.imagePath).readAsBytes(), <int>[9, 8, 7]);
    expect(await gallery.readAsBytes(), <int>[1, 2, 3, 4]);
    expect(await File('${directory.path}/second.jpg').readAsBytes(), <int>[
      9,
      8,
      7,
    ]);
  });

  test('relocation never rebases external, other-owner or wrong-name references into an owned image with the same basename', () async {
    late Box<String> aliceBox;
    final ScanDraftStore alice = ScanDraftStore(
      userId: 'alice',
      openBox: (String name) async {
        aliceBox = await Hive.openBox<String>(name);
        return aliceBox;
      },
    );
    final ScanDraftPhoto valid = (await alice.importPhotos(<String>[
      gallery.path,
    ], multipleCards: false)).single;
    final ScanDraftPhoto bobPhoto = (await ScanDraftStore(
      userId: 'bob',
    ).importPhotos(<String>[gallery.path], multipleCards: false)).single;
    final Directory owned = File(valid.imagePath).parent;
    final Directory bobOwned = File(bobPhoto.imagePath).parent;
    final Map<String, String> rejected = <String, String>{
      'external': '${directory.path}/photo-external.jpg',
      'cross-owner': '${bobOwned.path}/photo-cross-owner.jpg',
      'wrong-name': '${owned.path}/photo-different-name.jpg',
    };
    for (final MapEntry<String, String> entry in rejected.entries) {
      await File(entry.value).writeAsBytes(<int>[7, 7], flush: true);
      await File('${owned.path}/photo-${entry.key}.jpg')
          .writeAsBytes(<int>[8, 8], flush: true);
      await aliceBox.put(
        'photo:${entry.key}',
        jsonEncode(
          ScanDraftPhoto(
            id: entry.key,
            imagePath: entry.value,
            multipleCards: false,
            createdAt: DateTime.utc(2026),
          ).toMap(),
        ),
      );
    }
    final String otherOwnerCleanup =
        '${bobOwned.path}/photo-foreign-cleanup.jpg';
    await File(otherOwnerCleanup).writeAsBytes(<int>[4, 4], flush: true);
    await File('${owned.path}/photo-foreign-cleanup.jpg')
        .writeAsBytes(<int>[3, 3], flush: true);
    await aliceBox.put(
      'cleanup:photo:foreign-cleanup',
      jsonEncode(<String, String>{
        'key': 'photo:foreign-cleanup',
        'path': otherOwnerCleanup,
      }),
    );
    await aliceBox.flush();
    final String formerRoot = directory.path;
    final String ownedRelative = owned.path.substring(formerRoot.length);
    final String foreignRelative = otherOwnerCleanup.substring(
      formerRoot.length,
    );
    await Hive.close();
    directory = await directory.rename('$formerRoot-relocated');
    Hive.init(directory.path);
    gallery = File('${directory.path}/gallery.jpg');
    final ScanDraftStore restored = ScanDraftStore(userId: 'alice');
    await expectLater(restored.readPhotos(), throwsA(isA<FormatException>()));
    for (final String id in rejected.keys) {
      await expectLater(
        restored.readSource(id),
        throwsA(isA<FormatException>()),
      );
    }
    await restored.removePhotos(rejected.keys.toList());
    final List<ScanDraftPhoto> photos = await restored.readPhotos();
    expect(photos.single.id, valid.id);
    expect(photos.single.imagePath, startsWith('${directory.path}/'));
    await restored.cleanPendingImages();
    for (final MapEntry<String, String> entry in rejected.entries) {
      final String relocatedRejected =
          '${directory.path}${entry.value.substring(formerRoot.length)}';
      expect(await File(relocatedRejected).readAsBytes(), <int>[7, 7]);
      expect(
        await File('${directory.path}$ownedRelative/photo-${entry.key}.jpg')
            .readAsBytes(),
        <int>[8, 8],
      );
    }
    expect(await File('${directory.path}$foreignRelative').readAsBytes(), <int>[
      4,
      4,
    ]);
    expect(
      await File('${directory.path}$ownedRelative/photo-foreign-cleanup.jpg')
          .readAsBytes(),
      <int>[3, 3],
    );
    final ScanDraftPhoto restoredBob = (await ScanDraftStore(
      userId: 'bob',
    ).readPhotos()).single;
    expect(await File(restoredBob.imagePath).readAsBytes(), <int>[1, 2, 3, 4]);
    expect(await gallery.readAsBytes(), <int>[1, 2, 3, 4]);
  });

  test(
    'camera cache source is removed only after its copied draft is durable',
    () async {
      final File camera = await File('${directory.path}/camera.jpg')
          .writeAsBytes(<int>[5, 6, 7], flush: true);
      final ScanDraftStore storage = ScanDraftStore(userId: 'alice');
      final ScanDraftPhoto photo = (await storage.importPhotos(
        <String>[camera.path],
        multipleCards: false,
        ownedCameraSource: true,
      )).single;
      expect(await camera.exists(), isFalse);
      await Hive.close();
      final ScanDraftPhoto restored = (await ScanDraftStore(
        userId: 'alice',
      ).readPhotos()).single;
      expect(restored.id, photo.id);
      expect(await File(restored.imagePath).readAsBytes(), <int>[5, 6, 7]);
      expect(await gallery.exists(), isTrue);
    },
  );

  for (final bool focusStack in <bool>[false, true]) {
    final String lane = focusStack ? 'focus stack' : 'photo';
    for (final String recovery in <String>[
      'restart',
      'clear',
      'completed source retirement',
      'reused source path',
      'interrupted admission',
    ]) {
      test('owned camera $lane cleanup survives $recovery', () async {
        final List<File> cameras = <File>[
          for (int index = 0; index < (focusStack ? 2 : 1); index++)
            await File('${directory.path}/camera-$index.jpg')
                .writeAsBytes(<int>[5, 6, index], flush: true),
        ];
        final List<String> paths = cameras
            .map((File file) => file.path)
            .toList();
        final _BlockedCameraDeletes blocked = _BlockedCameraDeletes(<String>{
          ...paths,
          for (final File camera in cameras)
            await camera.resolveSymbolicLinks(),
        });
        final ScanDraftStore storage = ScanDraftStore(
          userId: 'camera-cleanup',
          openBox: recovery == 'interrupted admission'
              ? (String name) async => _InterruptedCameraAdmissionBox(
                  await Hive.openBox<String>(name),
                )
              : null,
        );
        List<ScanDraftPhoto> imported = <ScanDraftPhoto>[];
        await IOOverrides.runWithIOOverrides<Future<void>>(() async {
          if (recovery == 'interrupted admission') {
            await expectLater(
              _importCameraSources(storage, paths, focusStack: focusStack),
              throwsA(isA<FileSystemException>()),
            );
          } else {
            imported = await _importCameraSources(
              storage,
              paths,
              focusStack: focusStack,
            );
            expect(blocked.attempts, greaterThan(0));
          }
          for (int index = 0; index < cameras.length; index++) {
            expect(await cameras[index].readAsBytes(), <int>[5, 6, index]);
          }
          if (recovery == 'clear') {
            await storage.clearCaptures();
          } else if (recovery == 'completed source retirement') {
            final ScanDraftItem item = ScanDraftItem(
              id: 'retired-camera-card',
              photoId: imported.first.id,
              crop: _replacementCrop(''),
            );
            if (focusStack) {
              await storage.completeFocusStack(imported, <ScanDraftItem>[item]);
            } else {
              await storage.completePhoto(imported.single.id, <ScanDraftItem>[
                item,
              ]);
            }
            await storage.removeItems(<String>[item.id]);
          }
          await storage.cleanPendingImages();
          for (final File camera in cameras) {
            expect(await camera.exists(), isTrue);
          }
          await Hive.close();
        }, blocked);

        if (recovery == 'reused source path') {
          for (int index = 0; index < cameras.length; index++) {
            final DateTime modified = await cameras[index].lastModified();
            await cameras[index].writeAsBytes(<int>[9, 8, index], flush: true);
            await cameras[index].setLastModified(modified);
          }
        }
        final ScanDraftStore restarted = ScanDraftStore(
          userId: 'camera-cleanup',
        );
        final List<ScanDraftPhoto> pending = await restarted.readPhotos();
        await restarted.cleanPendingImages();
        if (recovery == 'reused source path') {
          if (focusStack) {
            final List<ScanDraftPhoto> retry = await _importCameraSources(
              restarted,
              paths,
              focusStack: true,
            );
            expect(retry.first.id, imported.first.id);
          }
          for (int index = 0; index < cameras.length; index++) {
            expect(await cameras[index].readAsBytes(), <int>[9, 8, index]);
          }
        } else {
          for (final File camera in cameras) {
            expect(
              await camera.exists(),
              isFalse,
              reason:
                  'Durable admission must retain camera cleanup ownership across $recovery.',
            );
          }
        }
        if (recovery == 'clear' || recovery == 'completed source retirement') {
          expect(pending, isEmpty);
          expect(await restarted.readItems(), isEmpty);
          for (final ScanDraftPhoto photo in imported) {
            expect(await File(photo.imagePath).exists(), isFalse);
          }
        } else {
          expect(pending, hasLength(1));
          final List<ScanDraftPhoto> retained = focusStack
              ? await restarted.readFocusStack(pending.single.id)
              : pending;
          expect(retained, hasLength(cameras.length));
          for (int index = 0; index < retained.length; index++) {
            expect(await File(retained[index].imagePath).readAsBytes(), <int>[
              5,
              6,
              index,
            ]);
          }
        }
        expect(await gallery.readAsBytes(), <int>[1, 2, 3, 4]);
      });
    }

    for (final String owner in <String>['alice', 'bob']) {
      test('owned camera $lane never deletes $owner managed source', () async {
        final ScanDraftStore storage = ScanDraftStore(userId: 'alice');
        final ScanDraftPhoto original = (await ScanDraftStore(
          userId: owner,
        ).importPhotos(<String>[gallery.path], multipleCards: false)).single;
        final List<ScanDraftPhoto> copied = await _importCameraSources(
          storage,
          <String>[original.imagePath],
          focusStack: focusStack,
        );
        await storage.cleanPendingImages();
        expect(await File(original.imagePath).readAsBytes(), <int>[1, 2, 3, 4]);
        expect(await File(copied.single.imagePath).readAsBytes(), <int>[
          1,
          2,
          3,
          4,
        ]);
        await Hive.close();
        await ScanDraftStore(userId: 'alice').cleanPendingImages();
        expect(await File(original.imagePath).exists(), isTrue);
      });
    }
    test('owned camera $lane never deletes a source symlink', () async {
      final Link camera = await Link('${directory.path}/camera-link.jpg')
          .create(gallery.path);
      final ScanDraftStore storage = ScanDraftStore(userId: 'alice');
      final List<ScanDraftPhoto> imported = await _importCameraSources(
        storage,
        <String>[camera.path],
        focusStack: focusStack,
      );
      await storage.cleanPendingImages();
      expect(await camera.exists(), isTrue);
      expect(await File(imported.single.imagePath).readAsBytes(), <int>[
        1,
        2,
        3,
        4,
      ]);
      expect(await gallery.readAsBytes(), <int>[1, 2, 3, 4]);
    });
  }

  test('owned camera focus stack recovers partial cleanup promotion without losing either source', () async {
    final List<File> cameras = <File>[
      for (int index = 0; index < 2; index++)
        await File('${directory.path}/camera-$index.jpg')
            .writeAsBytes(<int>[1, 2, index], flush: true),
    ];
    final ScanDraftStore storage = ScanDraftStore(
      userId: 'camera-promotion',
      openBox: (String name) async =>
          _InterruptedCameraPromotionBox(await Hive.openBox<String>(name)),
    );
    final List<ScanDraftPhoto> admitted = await _importCameraSources(
      storage,
      cameras.map((File camera) => camera.path).toList(),
      focusStack: true,
    );
    for (final File camera in cameras) {
      expect(await camera.exists(), isTrue);
    }
    await Hive.close();
    final ScanDraftStore restarted = ScanDraftStore(userId: 'camera-promotion');
    expect((await restarted.readPhotos()).single.id, admitted.first.id);
    await restarted.cleanPendingImages();
    final List<ScanDraftPhoto> retained = await restarted.readFocusStack(
      admitted.first.id,
    );
    expect(
      retained.map((ScanDraftPhoto photo) => photo.id),
      admitted.map((ScanDraftPhoto photo) => photo.id),
    );
    for (int index = 0; index < cameras.length; index++) {
      expect(await cameras[index].exists(), isFalse);
      expect(await File(retained[index].imagePath).readAsBytes(), <int>[
        1,
        2,
        index,
      ]);
    }
  });

  test('owned camera cleanup retains both source identities when a cleared focus capture ID is reused', () async {
    final File first = await File('${directory.path}/first-camera.jpg')
        .writeAsBytes(<int>[1, 2, 3], flush: true);
    final File second = await File('${directory.path}/second-camera.jpg')
        .writeAsBytes(<int>[4, 5, 6], flush: true);
    final _BlockedCameraDeletes blocked = _BlockedCameraDeletes(<String>{
      first.path,
      second.path,
      await first.resolveSymbolicLinks(),
      await second.resolveSymbolicLinks(),
    });
    await IOOverrides.runWithIOOverrides<Future<void>>(() async {
      final ScanDraftStore storage = ScanDraftStore(userId: 'camera-cleanup');
      await _importCameraSources(storage, <String>[
        first.path,
      ], focusStack: true);
      await storage.clearCaptures();
      await _importCameraSources(storage, <String>[
        second.path,
      ], focusStack: true);
      expect(await first.exists(), isTrue);
      expect(await second.exists(), isTrue);
      await Hive.close();
    }, blocked);
    final ScanDraftStore restarted = ScanDraftStore(userId: 'camera-cleanup');
    final ScanDraftPhoto retained = (await restarted.readPhotos()).single;
    await restarted.cleanPendingImages();
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isFalse);
    expect(await File(retained.imagePath).readAsBytes(), <int>[4, 5, 6]);
  });

  test(
    'owned camera cleanup bounds failed attempts and drains after restart',
    () async {
      final List<File> cameras = <File>[
        for (int index = 0; index < 70; index++)
          await File('${directory.path}/camera-$index.jpg')
              .writeAsBytes(<int>[index], flush: true),
      ];
      final _BlockedCameraDeletes blocked = _BlockedCameraDeletes(<String>{
        for (final File camera in cameras) camera.path,
        for (final File camera in cameras) await camera.resolveSymbolicLinks(),
      });
      await IOOverrides.runWithIOOverrides<Future<void>>(() async {
        final ScanDraftStore storage = ScanDraftStore(userId: 'camera-cleanup');
        await _importCameraSources(
          storage,
          cameras.map((File file) => file.path).toList(),
          focusStack: false,
        );
        expect(
          blocked.attempts,
          cameras.length,
          reason: 'Each admission should attempt only its own source cleanup.',
        );
        blocked.attempts = 0;
        await storage.cleanPendingImages();
        expect(blocked.attempts, inInclusiveRange(1, 64));
        await Hive.close();
      }, blocked);
      final ScanDraftStore restarted = ScanDraftStore(userId: 'camera-cleanup');
      await restarted.cleanPendingImages();
      expect(await restarted.readPhotos(), hasLength(70));
      for (final File camera in cameras) {
        expect(await camera.exists(), isFalse);
      }
      expect(await gallery.exists(), isTrue);
    },
  );

  test(
    'owned camera focus stack preserves inputs when draft persistence fails',
    () async {
      final File camera = await File('${directory.path}/camera.jpg')
          .writeAsBytes(<int>[5, 6, 7], flush: true);
      final ScanDraftStore storage = ScanDraftStore(
        userId: 'alice',
        openBox: (String name) async =>
            _FailingPhotoBox(await Hive.openBox<String>(name)),
      );
      await expectLater(
        _importCameraSources(storage, <String>[camera.path], focusStack: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(await camera.readAsBytes(), <int>[5, 6, 7]);
      await Hive.close();
      final ScanDraftStore restarted = ScanDraftStore(userId: 'alice');
      await restarted.cleanPendingImages();
      expect(await restarted.readPhotos(), isEmpty);
      expect(await camera.readAsBytes(), <int>[5, 6, 7]);
    },
  );

  test('camera source survives failure to persist its copied draft', () async {
    final File camera = await File('${directory.path}/camera.jpg')
        .writeAsBytes(<int>[5, 6, 7], flush: true);
    final ScanDraftStore storage = ScanDraftStore(
      userId: 'alice',
      openBox: (String name) async =>
          _FailingPhotoBox(await Hive.openBox<String>(name)),
    );
    await expectLater(
      storage.importPhotos(
        <String>[camera.path],
        multipleCards: false,
        ownedCameraSource: true,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await camera.readAsBytes(), <int>[5, 6, 7]);
    expect(await ScanDraftStore(userId: 'alice').readPhotos(), isEmpty);
    expect(
      directory.listSync().whereType<Directory>().single.listSync(),
      isEmpty,
    );
  });

  test(
    'reimported managed photo remains available to its original draft',
    () async {
      final ScanDraftStore storage = ScanDraftStore(userId: 'alice');
      final ScanDraftPhoto original = (await storage.importPhotos(<String>[
        gallery.path,
      ], multipleCards: false)).single;
      final ScanDraftPhoto copied = (await storage.importPhotos(
        <String>[original.imagePath],
        multipleCards: true,
        ownedCameraSource: true,
      )).single;
      expect(await File(original.imagePath).readAsBytes(), <int>[1, 2, 3, 4]);
      expect(await File(copied.imagePath).readAsBytes(), <int>[1, 2, 3, 4]);
      expect(await storage.readPhotos(), hasLength(2));
      expect(await gallery.exists(), isTrue);
    },
  );

  test('unprocessed photos survive restart in owned storage while gallery stays untouched', () async {
    final ScanDraftStore storage = ScanDraftStore(userId: 'alice');
    final List<ScanDraftPhoto> imported = await storage.importPhotos(<String>[
      gallery.path,
    ], multipleCards: true);
    expect(imported.single.imagePath, isNot(gallery.path));
    expect(await File(imported.single.imagePath).readAsBytes(), <int>[
      1,
      2,
      3,
      4,
    ]);
    await Hive.close();
    final ScanDraftStore reopened = ScanDraftStore(userId: 'alice');
    final List<ScanDraftPhoto> pending = await reopened.readPhotos();
    expect(pending.single.id, imported.single.id);
    expect(pending.single.multipleCards, isTrue);
    expect(await ScanDraftStore(userId: 'bob').readPhotos(), isEmpty);
    await reopened.removePhotos(<String>[pending.single.id]);
    expect(await File(pending.single.imagePath).exists(), isFalse);
    expect(await gallery.readAsBytes(), <int>[1, 2, 3, 4]);
  });

  test('durable recognition and review retains evidence, printing, approval and separate crop copy', () async {
    final MtgCard printing = MtgCard.fromJson(
      jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<String, dynamic>,
    );
    final ScanDraftStore storage = ScanDraftStore(userId: 'alice');
    final ScanDraftPhoto photo = (await storage.importPhotos(<String>[
      gallery.path,
    ], multipleCards: true)).single;
    final ScanCrop crop = ScanCrop(
      imagePath: photo.imagePath,
      width: 200,
      height: 280,
      rectified: true,
      sourceCorners: const <ScanPoint>[
        ScanPoint(.1, .1),
        ScanPoint(.7, .1),
        ScanPoint(.7, .8),
        ScanPoint(.1, .8),
      ],
      lines: const <ScanTextLine>[
        ScanTextLine(
          text: 'Dusk // Dawn',
          confidence: .98,
          bounds: ScanBounds(.1, .05, .8, .05),
        ),
      ],
    );
    final ScanDraftItem item = ScanDraftItem(
      id: '${photo.id}_0',
      photoId: photo.id,
      crop: crop,
      resolution: ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(
            printing,
            <ScanEvidence>{ScanEvidence.footerMatch, ScanEvidence.nameMatch},
            artworkDistance: .37,
            symbolDistance: .21,
          ),
        ],
        hints: const ScanHints(
          names: <String>['Dusk // Dawn'],
          setCode: 'akh',
          collectorNumber: '210',
          language: 'en',
          rulesText: <String>['Destroy all creatures with power 3 or greater.'],
          typeLine: 'sorcery',
        ),
        status: ScanResolutionStatus.exactPrinting,
      ),
      approval: ScanQueueApproval(
        operationId: '${photo.id}_0',
        card: cardFromScryfall(printing, finish: Finish.nonfoil),
        quantity: 4,
        deckId: 'deck',
        deckSection: DeckSection.sideboard,
      ),
      selected: true,
    );
    final List<ScanDraftItem> saved = await storage.completePhoto(
      photo.id,
      <ScanDraftItem>[item],
    );
    expect(await storage.readPhotos(), isEmpty);
    expect(saved.single.crop.imagePath, isNot(photo.imagePath));
    expect(await File(photo.imagePath).exists(), isTrue);
    expect((await storage.readSource(photo.id))!.imagePath, photo.imagePath);
    expect(await File(saved.single.crop.imagePath).exists(), isTrue);
    await Hive.close();
    final ScanDraftStore reopened = ScanDraftStore(userId: 'alice');
    final ScanDraftItem restored = (await reopened.readItems()).single;
    expect(restored.crop.lines.single.confidence, .98);
    expect(restored.crop.sourceCorners.length, 4);
    expect(restored.resolution!.candidates.single.card.id, printing.id);
    expect(restored.resolution!.candidates.single.artworkDistance, .37);
    expect(restored.resolution!.candidates.single.symbolDistance, .21);
    expect(restored.resolution!.hints.typeLine, 'sorcery');
    expect(restored.resolution!.hints.rulesText, <String>[
      'Destroy all creatures with power 3 or greater.',
    ]);
    expect(restored.resolution!.candidates.single.evidence, <ScanEvidence>{
      ScanEvidence.footerMatch,
      ScanEvidence.nameMatch,
    });
    expect(restored.approval!.operationId, '${photo.id}_0');
    expect(restored.approval!.quantity, 4);
    expect(restored.approval!.deckSection, DeckSection.sideboard);
    expect(restored.selected, isTrue);
    await reopened.removeItems(<String>[restored.id]);
    expect(await File(restored.crop.imagePath).exists(), isFalse);
    expect(await reopened.readSource(photo.id), isNull);
    expect(await File(photo.imagePath).exists(), isFalse);
    expect(await gallery.exists(), isTrue);
  });

  test('full source survives relaunch and partial approval until its final crop is removed', () async {
    final ScanDraftStore storage = ScanDraftStore(userId: 'alice');
    final ScanDraftPhoto photo = (await storage.importPhotos(<String>[
      gallery.path,
    ], multipleCards: true)).single;
    final List<ScanDraftItem> saved = await storage.completePhoto(
      photo.id,
      List<ScanDraftItem>.generate(
        2,
        (int index) => ScanDraftItem(
          id: '${photo.id}_$index',
          photoId: photo.id,
          crop: ScanCrop(
            imagePath: photo.imagePath,
            width: 200,
            height: 280,
            rectified: true,
            sourceCorners: const <ScanPoint>[],
            lines: const <ScanTextLine>[],
          ),
        ),
      ),
    );
    expect(await storage.readPhotos(), isEmpty);
    await storage.removeItems(<String>[saved.first.id]);
    expect(await File(photo.imagePath).exists(), isTrue);
    await Hive.close();
    final ScanDraftStore reopened = ScanDraftStore(userId: 'alice');
    expect(await reopened.readPhotos(), isEmpty);
    expect((await reopened.readSource(photo.id))!.imagePath, photo.imagePath);
    expect(await ScanDraftStore(userId: 'bob').readSource(photo.id), isNull);
    await reopened.removeItems(<String>[saved.last.id]);
    expect(await reopened.readSource(photo.id), isNull);
    expect(await File(photo.imagePath).exists(), isFalse);
    expect(await gallery.exists(), isTrue);
  });

  test('interrupted source transfer retains provenance without scheduling duplicate recognition', () async {
    final ScanDraftStore storage = ScanDraftStore(
      userId: 'alice',
      openBox: (String name) async =>
          _InterruptedSourceTransferBox(await Hive.openBox<String>(name)),
    );
    final ScanDraftPhoto photo = (await storage.importPhotos(<String>[
      gallery.path,
    ], multipleCards: true)).single;
    final ScanDraftItem item = ScanDraftItem(
      id: '${photo.id}_0',
      photoId: photo.id,
      crop: ScanCrop(
        imagePath: photo.imagePath,
        width: 200,
        height: 280,
        rectified: true,
        sourceCorners: const <ScanPoint>[],
        lines: const <ScanTextLine>[],
      ),
    );
    await expectLater(
      storage.completePhoto(photo.id, <ScanDraftItem>[item]),
      throwsA(isA<FileSystemException>()),
    );
    await Hive.close();
    final ScanDraftStore reopened = ScanDraftStore(userId: 'alice');
    expect(await reopened.readPhotos(), isEmpty);
    expect((await reopened.readSource(photo.id))!.imagePath, photo.imagePath);
    expect((await reopened.readItems()).single.id, item.id);
    await reopened.removeItems(<String>[item.id]);
    expect(await reopened.readPhotos(), isEmpty);
    expect(await reopened.readSource(photo.id), isNull);
    expect(await File(photo.imagePath).exists(), isFalse);
    expect(await gallery.exists(), isTrue);
  });

  test(
    'partial failed import retains completed photos and source files',
    () async {
      final ScanDraftStore storage = ScanDraftStore(userId: 'alice');
      await expectLater(
        storage.importPhotos(<String>[
          gallery.path,
          '${directory.path}/missing.jpg',
        ], multipleCards: true),
        throwsA(isA<FileSystemException>()),
      );
      final List<ScanDraftPhoto> recoverable = await storage.readPhotos();
      expect(recoverable, hasLength(1));
      expect(await File(recoverable.single.imagePath).exists(), isTrue);
      expect(await gallery.exists(), isTrue);
    },
  );
  test('partial crop persistence keeps pending original and completed crops recoverable', () async {
    final ScanDraftStore storage = ScanDraftStore(userId: 'alice');
    final ScanDraftPhoto photo = (await storage.importPhotos(<String>[
      gallery.path,
    ], multipleCards: true)).single;
    ScanDraftItem item(int index, String path) => ScanDraftItem(
      id: '${photo.id}_$index',
      photoId: photo.id,
      crop: ScanCrop(
        imagePath: path,
        width: 200,
        height: 280,
        rectified: true,
        sourceCorners: const <ScanPoint>[],
        lines: const <ScanTextLine>[],
      ),
    );
    await expectLater(
      storage.completePhoto(photo.id, <ScanDraftItem>[
        item(0, photo.imagePath),
        item(1, '${directory.path}/missing.jpg'),
      ]),
      throwsA(isA<FileSystemException>()),
    );
    await Hive.close();
    final ScanDraftStore reopened = ScanDraftStore(userId: 'alice');
    expect((await reopened.readPhotos()).single.id, photo.id);
    final ScanDraftItem saved = (await reopened.readItems()).single;
    expect(await File(saved.crop.imagePath).exists(), isTrue);
    expect(await File(photo.imagePath).exists(), isTrue);
    expect(await gallery.exists(), isTrue);
  });

  test('manual draft metadata never creates an image directory', () async {
    final ScanDraftStore storage = ScanDraftStore(userId: 'alice');
    const ScanDraftItem manual = ScanDraftItem(
      id: 'manual_0',
      photoId: 'manual',
      crop: ScanCrop(
        imagePath: '',
        width: 0,
        height: 0,
        rectified: false,
        sourceCorners: <ScanPoint>[],
        lines: <ScanTextLine>[],
      ),
    );
    await storage.upsertItems(<ScanDraftItem>[manual]);
    expect((await storage.readItems()).single.crop.imagePath, '');
    await storage.removeItems(<String>[manual.id]);
    expect(await storage.readItems(), isEmpty);
    expect(directory.listSync().whereType<Directory>(), isEmpty);
  });
  test('identity recovery jobs survive restart and consume one automatic attempt per source', () async {
    final ScanDraftStore storage = ScanDraftStore(userId: 'alice');
    final ScanDraftPhoto photo = (await storage.importPhotos(<String>[
      gallery.path,
    ], multipleCards: true)).single;
    ScanDraftItem item(String id) => ScanDraftItem(
      id: id,
      photoId: photo.id,
      crop: ScanCrop(
        imagePath: gallery.path,
        width: 1000,
        height: 1400,
        rectified: true,
        sourceCorners: const <ScanPoint>[],
        lines: const <ScanTextLine>[],
      ),
    );
    await storage.completePhoto(photo.id, <ScanDraftItem>[
      item('first'),
      item('second'),
    ]);
    final ScanDraftRecovery job = (await storage.scheduleRecovery('first'))!;
    expect(await storage.scheduleRecovery('first'), isNull);
    expect(await storage.scheduleRecovery('second'), isNull);
    await Hive.close();
    final ScanDraftStore reopened = ScanDraftStore(userId: 'alice');
    expect((await reopened.readRecoveries()).single.itemId, 'first');
    expect(
      (await reopened.readSource(job.photoId))!.imagePath,
      photo.imagePath,
    );
    await reopened.completeRecovery(job);
    expect(await reopened.readRecoveries(), isEmpty);
    expect(await reopened.scheduleRecovery('first'), isNull);
    expect(await reopened.scheduleRecovery('second'), isNull);
    final ScanDraftRecovery manual = (await reopened.scheduleRecovery(
      'second',
      manual: true,
    ))!;
    expect(manual.photoId, photo.id);
    await reopened.removeItems(<String>['second']);
    expect(await reopened.readRecoveries(), isEmpty);
    expect(await File(photo.imagePath).exists(), isTrue);
    await reopened.clearCaptures();
    expect(await reopened.readItems(), isEmpty);
    expect(await reopened.readRecoveries(), isEmpty);
    expect(await gallery.exists(), isTrue);
  });
  test('bulk managed-image cleanup drains bounded chunks without touching the gallery', () async {
    final ScanDraftStore storage = ScanDraftStore(userId: 'alice');
    final List<ScanDraftPhoto> photos = await storage.importPhotos(
      List<String>.filled(70, gallery.path),
      multipleCards: true,
    );
    await storage.removePhotos(
      photos.map((ScanDraftPhoto photo) => photo.id).toList(),
    );
    await storage.cleanPendingImages();
    expect(await storage.readPhotos(), isEmpty);
    for (final ScanDraftPhoto photo in photos) {
      expect(await File(photo.imagePath).exists(), isFalse);
    }
    expect(await gallery.exists(), isTrue);
  });
}
