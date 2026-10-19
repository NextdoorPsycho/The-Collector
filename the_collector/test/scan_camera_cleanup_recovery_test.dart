import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';

class _CleanupFailureBox extends Fake implements Box<String> {
  _CleanupFailureBox(this.delegate);
  final Box<String> delegate;
  bool denyImageDirectory = false;
  bool failCameraPromotion = false;
  int promotionFailures = 0;

  @override
  String? get path {
    if (denyImageDirectory) {
      throw const FileSystemException(
        'Image directory temporarily unavailable.',
      );
    }
    return delegate.path;
  }

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
  Future<void> putAll(Map<Object?, String> entries) async {
    if (failCameraPromotion &&
        entries.keys.whereType<String>().any(
          (String key) => key.startsWith('cleanup:camera:'),
        )) {
      promotionFailures++;
      throw const FileSystemException('Cleanup journal storage is full.');
    }
    await delegate.putAll(entries);
  }

  @override
  Future<void> delete(Object? key) => delegate.delete(key);
  @override
  Future<void> deleteAll(Iterable<Object?> keys) => delegate.deleteAll(keys);
  @override
  Future<void> flush() => delegate.flush();
}

void main() {
  test('persistent camera promotion failure does not block already journaled image cleanup', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'scanner-cleanup-recovery-',
    );
    Hive.init(directory.path);
    late _CleanupFailureBox box;
    final ScanDraftStore store = ScanDraftStore(
      userId: 'cleanup-recovery',
      openBox: (String name) async =>
          box = _CleanupFailureBox(await Hive.openBox<String>(name)),
    );
    try {
      final File gallery = await File('${directory.path}/gallery.jpg')
          .writeAsBytes(<int>[1, 2, 3], flush: true);
      final ScanDraftPhoto retired = (await store.importPhotos(<String>[
        gallery.path,
      ], multipleCards: false)).single;
      box.denyImageDirectory = true;
      await store.removePhotos(<String>[retired.id]);
      box.denyImageDirectory = false;
      expect(box.containsKey('photo:${retired.id}'), isFalse);
      expect(await File(retired.imagePath).exists(), isTrue);

      final File camera = await File('${directory.path}/camera.jpg')
          .writeAsBytes(<int>[4, 5, 6], flush: true);
      box.failCameraPromotion = true;
      final ScanDraftPhoto pending = (await store.importPhotos(
        <String>[camera.path],
        multipleCards: false,
        ownedCameraSource: true,
      )).single;
      expect(box.promotionFailures, 1);
      expect(await camera.exists(), isTrue);

      await store.cleanPendingImages();
      expect(box.promotionFailures, 2);
      expect(
        await File(retired.imagePath).exists(),
        isFalse,
        reason: 'A failed new journal write must not prevent reclaiming a safely retired image.',
      );
      expect(await camera.readAsBytes(), <int>[4, 5, 6]);
      expect(await File(pending.imagePath).readAsBytes(), <int>[4, 5, 6]);
      expect((await store.readPhotos()).single.id, pending.id);
      expect(await gallery.readAsBytes(), <int>[1, 2, 3]);

      box.failCameraPromotion = false;
      await store.cleanPendingImages();
      expect(await camera.exists(), isFalse);
      await Hive.close();
      final ScanDraftPhoto restored = (await ScanDraftStore(
        userId: 'cleanup-recovery',
      ).readPhotos()).single;
      expect(restored.id, pending.id);
      expect(await File(restored.imagePath).readAsBytes(), <int>[4, 5, 6]);
    } finally {
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });
}
