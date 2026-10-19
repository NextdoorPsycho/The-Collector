import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';

ScanCrop _crop(String path) => ScanCrop(
  imagePath: path,
  width: 630,
  height: 880,
  rectified: true,
  sourceCorners: const <ScanPoint>[
    ScanPoint(.1, .1),
    ScanPoint(.6, .1),
    ScanPoint(.6, .8),
    ScanPoint(.1, .8),
  ],
  lines: const <ScanTextLine>[],
);

void main() {
  test('admitted unresolved evidence survives native crop cache removal across accounts', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'collector-native-cache-retention-',
    );
    final Directory hive = await Directory('${directory.path}/hive').create();
    final Directory crops = await Directory('${directory.path}/ScanCrops')
        .create();
    final Directory generation = await Directory(
      '${crops.path}/ec186f14-cafc-443a-8827-deb8e915aac1',
    ).create();
    final Directory camera = await Directory(
      '${directory.path}/camera/pictures',
    ).create(recursive: true);
    Hive.init(hive.path);
    final Map<String, Map<String, List<int>>> managed =
        <String, Map<String, List<int>>>{};
    final Map<String, String> focusIds = <String, String>{};
    final Map<String, String> completedIds = <String, String>{};
    final Map<String, String> pendingIds = <String, String>{};
    final Map<String, String> rescanIds = <String, String>{};
    final Map<String, List<int>> inputs = <String, List<int>>{};
    try {
      for (final String owner in <String>['alice', 'bob']) {
        final ScanDraftStore store = ScanDraftStore(userId: owner);
        final List<int> pixels = <int>[owner.length, 2, 3, 4];
        final File original = await File('${camera.path}/$owner.jpg')
            .writeAsBytes(pixels, flush: true);
        final File focused = await File('${camera.path}/$owner-focus.jpg')
            .writeAsBytes(<int>[...pixels, 5], flush: true);
        inputs[original.path] = pixels;
        inputs[focused.path] = <int>[...pixels, 5];
        final ScanDraftPhoto pending = (await store.importPhotos(<String>[
          original.path,
        ], multipleCards: true)).single;
        pendingIds[owner] = pending.id;
        final List<ScanDraftPhoto> stack = await store.importFocusStack(
          <String>[original.path, focused.path],
          captureId: '$owner-focus',
        );
        focusIds[owner] = stack.first.id;
        final ScanDraftPhoto source = (await store.importPhotos(<String>[
          original.path,
        ], multipleCards: true)).single;
        completedIds[owner] = source.id;
        final List<ScanDraftItem> items = <ScanDraftItem>[];
        for (int index = 0; index < 2; index++) {
          final File native = await File(
            '${index == 0 ? crops.path : generation.path}/$owner-$index.jpg',
          ).writeAsBytes(<int>[...pixels, index], flush: true);
          items.add(
            ScanDraftItem(
              id: '$owner-$index',
              photoId: source.id,
              crop: _crop(native.path),
            ),
          );
        }
        final List<ScanDraftItem> saved = await store.completePhoto(
          source.id,
          items,
        );
        await store.scheduleDetail(source.id);
        final ScanDraftRescan request = await store.beginRescan(saved.last.id);
        final ScanDraftPhoto replacement = await store.importRescanPhoto(
          request,
          focused.path,
        );
        rescanIds[owner] = replacement.id;
        final List<String> paths = <String>[
          pending.imagePath,
          source.imagePath,
          replacement.imagePath,
          ...stack.map((ScanDraftPhoto photo) => photo.imagePath),
          ...saved.map((ScanDraftItem item) => item.crop.imagePath),
        ];
        managed[owner] = <String, List<int>>{};
        for (final String path in paths) {
          expect(path, contains('/scanner_images_'));
          expect(path, isNot(contains('/ScanCrops/')));
          managed[owner]![path] = await File(path).readAsBytes();
        }
      }
      await Hive.close();
      await crops.delete(recursive: true);
      for (final String owner in managed.keys) {
        final ScanDraftStore reopened = ScanDraftStore(userId: owner);
        final List<ScanDraftItem> items = await reopened.readItems();
        expect(items.map((ScanDraftItem item) => item.id).toSet(), <String>{
          '$owner-0',
          '$owner-1',
        });
        expect(
          items.every(
            (ScanDraftItem item) =>
                item.resolution == null && item.approval == null,
          ),
          isTrue,
        );
        expect(
          (await reopened.readPhotos())
              .map((ScanDraftPhoto photo) => photo.id)
              .toSet(),
          <String>{pendingIds[owner]!, focusIds[owner]!},
        );
        expect(await reopened.readFocusStack(focusIds[owner]!), hasLength(2));
        expect(
          (await reopened.readSource(completedIds[owner]!))!.id,
          completedIds[owner],
        );
        expect(
          (await reopened.readDetails()).single.photoId,
          completedIds[owner],
        );
        final ScanDraftRescan rescan = (await reopened.readRescans()).single;
        expect(rescan.complete, isFalse);
        expect(rescan.photo!.id, rescanIds[owner]);
        for (final MapEntry<String, List<int>> image
            in managed[owner]!.entries) {
          expect(await File(image.key).readAsBytes(), image.value);
        }
      }
      for (final MapEntry<String, List<int>> image in inputs.entries) {
        expect(await File(image.key).readAsBytes(), image.value);
      }
    } finally {
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });
}
