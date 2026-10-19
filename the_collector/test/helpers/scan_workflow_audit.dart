import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arcane/arcane.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scryfall_api/scryfall_api.dart' hide Color;
import 'package:the_collector/pages/scanning/guided_camera_screen.dart';
import 'package:the_collector/pages/scanning/scan_correction_editor.dart';
import 'package:the_collector/pages/scanning/scan_camera_drawer.dart';
import 'package:the_collector/pages/collection/card/card_add_dialog.dart';
import 'package:the_collector/pages/scanning/scan_screen.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_capture_defaults.dart';
import 'package:the_collector/utils/scanning/scan_accounting.dart';
import 'package:the_collector/utils/scanning/journaled_scan_queue_storage.dart';
import 'package:the_collector/utils/scanning/scan_queue.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_session.dart';

import 'load_collector_fonts.dart';

const String _user = 'scan_workflow_audit';

class _PrintingCatalog extends CardCatalog {
  int searches = 0;

  @override
  Future<PaginableList<MtgCard>> search(
    String query, {
    int page = 1,
    bool allPrintings = false,
  }) async {
    searches++;
    return PaginableList<MtgCard>(
      data: <MtgCard>[_printing(query, variant: 1)],
      hasMore: false,
    );
  }
}

void registerScanRedesignAudit({
  required bool physical,
  Future<void> Function(String)? checkpoint,
}) {
  setUpAll(loadCollectorFonts);
  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    for (final double scale in <double>[1, 2.35]) {
      testWidgets('scanner workspace ${mode.name} scale $scale', (
        WidgetTester tester,
      ) async {
        final CameraPlatform previous = CameraPlatform.instance;
        CameraPlatform.instance = _DeniedCamera();
        addTearDown(() => CameraPlatform.instance = previous);
        if (!physical) {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
        }
        final _PrintingCatalog catalog = _PrintingCatalog();
        addTearDown(catalog.close);
        final _Fixture fixture = await _fixture(tester, <ScanDraftItem>[
          _draft('first'),
        ]);
        await _mount(
          tester,
          fixture,
          mode: mode,
          textScale: scale,
          catalog: catalog,
        );
        final GuidedCameraScreen camera = await _camera(tester);
        final ScanSession session = camera.session!;
        final ScanSessionItem item = session.items.single;
        item.resolution = null;
        session.changed();
        final Future<void> correction = tester
            .widget<ScanCameraDrawer>(find.byType(ScanCameraDrawer))
            .onEdit(item);
        await _wait(
          tester,
          () => find.byType(ScanCorrectionEditor).evaluate().isNotEmpty,
        );
        final ThemeData editorTheme = Theme.of(
          tester.element(find.byType(ScanCorrectionEditor)),
        );
        final ThemeData expectedTheme = MyThemeData.themeData(mode)
            .shadThemeData;
        expect(editorTheme.brightness, expectedTheme.brightness);
        expect(
          editorTheme.colorScheme.background,
          expectedTheme.colorScheme.background,
        );
        expect(
          editorTheme.colorScheme.foreground,
          expectedTheme.colorScheme.foreground,
        );
        expect(editorTheme.colorScheme.input, expectedTheme.colorScheme.input);
        expect(find.text('Reading'), findsWidgets);
        expect(find.byType(ScanScreen), findsOneWidget);
        item.resolution = _resolution(item.crop);
        session.changed();
        await _wait(
          tester,
          () => tester
              .widget<CardPrintingSelector>(find.byType(CardPrintingSelector))
              .initialPrintings
              .isNotEmpty,
        );
        if (checkpoint != null) {
          await checkpoint('scanner-${mode.name}-$scale-ambiguous');
        }
        final Finder remove = find.byKey(
          const ValueKey<String>('scan-correction-remove'),
        );
        expect(find.text('Remove'), findsOneWidget);
        expect(find.text('Cancel'), findsNothing);
        expect(remove.hitTestable(), findsOneWidget);
        expect(tester.getSize(remove).height, greaterThanOrEqualTo(44));
        final Finder search = find.descendant(
          of: find.byKey(const ValueKey<String>('printing-search')),
          matching: find.byType(EditableText),
        );
        await tester.enterText(search, 'Counterspell');
        FocusManager.instance.primaryFocus?.unfocus();
        await _tick(tester);
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('printing-search-submit')),
        );
        await _wait(
          tester,
          () =>
              catalog.searches == 1 &&
              find.text('Counterspell').evaluate().isNotEmpty,
        );
        final Finder printing = find.byKey(
          ValueKey<String>(
            'printing-choice-${_printing('Counterspell', variant: 1).id}',
          ),
        );
        if (printing.evaluate().isEmpty) {
          final Finder list = find.descendant(
            of: find.byType(CardPrintingSelector),
            matching: find.byType(ListView),
          );
          final Finder scrollable = find.descendant(
            of: list,
            matching: find.byType(Scrollable),
          );
          await tester.scrollUntilVisible(
            printing,
            100,
            scrollable: scrollable.first,
          );
          await _tick(tester);
        }
        await _tap(tester, printing);
        await _finish(tester, 'Foil');
        if (checkpoint != null) {
          await checkpoint('scanner-${mode.name}-$scale-correction');
        }
        await _confirm(tester);
        await _awaitWork<void>(tester, () => correction);
        await _wait(tester, () => fixture.queue.count == 1);
        expect(fixture.queue.entries.single.card.name, 'Counterspell');
        expect(fixture.queue.entries.single.card.finish, Finish.foil);
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('camera-drawer-undo')),
        );
        await _wait(tester, () => fixture.queue.count == 0);

        final Future<void> staleCorrection = tester
            .widget<ScanCameraDrawer>(find.byType(ScanCameraDrawer))
            .onEdit(item);
        await _wait(
          tester,
          () => find.byType(ScanCorrectionEditor).evaluate().isNotEmpty,
        );
        final CardPrintingSelector stale = tester.widget<CardPrintingSelector>(
          find.byType(CardPrintingSelector),
        );
        item.crop = ScanCrop(
          imagePath: 'replacement.jpg',
          width: 640,
          height: 900,
          rectified: true,
          sourceCorners: item.crop.sourceCorners,
          lines: item.crop.lines,
        );
        session.changed();
        await _wait(
          tester,
          () => find.text('Capture replaced').evaluate().isNotEmpty,
        );
        stale.onSelected(
          PrintingSelection(
            card: cardFromScryfall(
              _printing('Wrong card'),
              finish: Finish.nonfoil,
            ),
            quantity: 1,
          ),
        );
        await _tick(tester);
        expect(fixture.queue.count, 0);
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('scan-correction-close')),
        );
        await _awaitWork<void>(tester, () => staleCorrection);
        await _discard(tester);
        expect(await _items(tester, fixture), isEmpty);

        final ScanSessionItem exact =
            ScanSessionItem(_crop('Lightning Bolt'), id: 'exact')
              ..resolution = ScanResolution(
                candidates: <ScanCandidate>[
                  ScanCandidate(_printing('Lightning Bolt'), <ScanEvidence>{
                    ScanEvidence.nameMatch,
                    ScanEvidence.footerMatch,
                  }),
                ],
                hints: ScanHints.fromCrop(_crop('Lightning Bolt')),
                status: ScanResolutionStatus.exactPrinting,
              );
        session.add(exact);
        await _awaitWork<void>(
          tester,
          () => session.persist(<ScanSessionItem>[exact]),
        );
        session.changed();
        await _wait(
          tester,
          () => fixture.queue.count == 1,
          reason: 'exact printing queues once',
        );
        expect(fixture.queue.entries.single.card.finish, Finish.nonfoil);
        if (checkpoint != null) {
          await checkpoint('scanner-${mode.name}-$scale-added');
        }
        await _tap(tester, find.byKey(const ValueKey<String>('scan-undo')));
        await _wait(tester, () => fixture.queue.count == 0);
        await _discard(tester);
        expect(await _items(tester, fixture), isEmpty);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }
  }
}

class _DeniedCamera extends CameraPlatform {
  @override
  Future<List<CameraDescription>> availableCameras() async =>
      const <CameraDescription>[
        CameraDescription(
          name: 'workflow',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
      ];
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream<DeviceOrientationChangedEvent>.empty();
  @override
  Future<int> createCameraWithSettings(
    CameraDescription description,
    MediaSettings settings,
  ) async => throw PlatformException(code: 'CameraAccessDenied');
  @override
  Future<void> dispose(int cameraId) async {}
}

MtgCard _printing(String name, {int variant = 0}) =>
    MtgCard.fromJson(<String, Object?>{
      'id': 'd88a8e2d-2577-4a67-af86-e33c0ba9411${variant + 1}',
      'oracle_id': '0ab3db25-3d2b-4a25-824f-794e95ab58a4',
      'lang': 'en',
      'prints_search_uri': 'https://api.scryfall.com/cards/search',
      'rulings_uri': 'https://api.scryfall.com/cards/test/rulings',
      'scryfall_uri': 'https://scryfall.com/card/m11/123',
      'uri': 'https://api.scryfall.com/cards/test',
      'cmc': 1,
      'color_identity': <String>['R'],
      'keywords': <String>[],
      'layout': 'normal',
      'legalities': <String, Object?>{},
      'name': name,
      'oversized': false,
      'reserved': false,
      'type_line': 'Instant',
      'booster': true,
      'border_color': 'black',
      'collector_number': '${123 + variant}',
      'digital': false,
      'foil': true,
      'nonfoil': true,
      'finishes': <String>['nonfoil', 'foil'],
      'frame': '2015',
      'full_art': false,
      'games': <String>['paper'],
      'highres_image': true,
      'image_status': 'highres_scan',
      'prices': <String, Object?>{},
      'promo': false,
      'purchase_uris': <String, String>{},
      'related_uris': <String, String>{},
      'rarity': 'common',
      'released_at': '2010-07-16',
      'reprint': true,
      'scryfall_set_uri': 'https://scryfall.com/sets/m11',
      'set_name': 'Magic 2011',
      'set_search_uri': 'https://api.scryfall.com/cards/search',
      'set_type': 'core',
      'set_uri': 'https://api.scryfall.com/sets/m11',
      'set': 'm11',
      'set_id': 'set-id',
      'story_spotlight': false,
      'textless': false,
      'variation': false,
    });

ScanCrop _crop(String name) => ScanCrop(
  imagePath: '',
  width: 640,
  height: 900,
  rectified: true,
  sourceCorners: const <ScanPoint>[
    ScanPoint(.1, .1),
    ScanPoint(.8, .1),
    ScanPoint(.8, .9),
    ScanPoint(.1, .9),
  ],
  lines: <ScanTextLine>[
    ScanTextLine(
      text: name,
      confidence: .99,
      bounds: const ScanBounds(.1, .05, .7, .025),
    ),
    const ScanTextLine(
      text: '123',
      confidence: .99,
      bounds: ScanBounds(.05, .85, .2, .02),
    ),
    const ScanTextLine(
      text: 'M11 EN',
      confidence: .99,
      bounds: ScanBounds(.05, .9, .2, .02),
    ),
  ],
);

ScanResolution _resolution(ScanCrop crop, {bool empty = false}) =>
    ScanResolution(
      candidates: empty
          ? <ScanCandidate>[]
          : <ScanCandidate>[
              for (int variant = 0; variant < 2; variant++)
                ScanCandidate(
                  _printing(crop.lines.first.text, variant: variant),
                  <ScanEvidence>{ScanEvidence.nameMatch},
                ),
            ],
      hints: ScanHints.fromCrop(crop),
      status: ScanResolutionStatus.needsReview,
    );

ScanDraftItem _draft(
  String id, {
  String name = 'Lightning Bolt',
  bool reviewed = false,
  bool empty = false,
  ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
}) {
  final ScanCrop crop = _crop(name);
  return ScanDraftItem(
    id: id,
    photoId: '',
    crop: crop,
    resolution: _resolution(crop, empty: empty),
    defaults: defaults,
    approval: reviewed
        ? ScanQueueApproval(
            operationId: id,
            card: cardFromScryfall(_printing(name), finish: Finish.nonfoil),
            quantity: 2,
          )
        : null,
    selected: false,
  );
}

class _Catalog implements ScanCatalog {
  @override
  Future<MtgCard?> exactPrinting(
    String setCode,
    String collectorNumber, {
    String? language,
  }) async => null;
  @override
  Future<MtgCard?> fuzzyName(String name) async => null;
  @override
  Future<PaginableList<MtgCard>> printings(
    String name, {
    String? setCode,
    String? language,
    int page = 1,
  }) async =>
      PaginableList<MtgCard>(data: <MtgCard>[_printing(name)], hasMore: false);
  @override
  Future<PaginableList<MtgCard>> rulesTextPrintings(
    String phrase, {
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
    int page = 1,
  }) async => PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false);
  @override
  Future<PaginableList<MtgCard>> rulesKeywordCards(
    List<String> keywords, {
    String? phrase,
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
  }) async => PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false);
}

class _Resolver extends ScanResolver {
  _Resolver() : super(catalog: _Catalog());
  Completer<ScanResolution>? lookup;
  int calls = 0;
  @override
  Future<void> warmNames() async {}
  @override
  Future<ScanResolution> resolve(
    ScanCrop crop, {
    String? name,
    String? setCode,
    String? collectorNumber,
    String? language,
    int page = 1,
  }) async {
    calls++;
    final Completer<ScanResolution>? pending = lookup;
    if (pending != null) return pending.future;
    return _resolution(crop, empty: crop.lines.first.text == 'No Match');
  }

  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) =>
      Future.wait<ScanResolution>(crops.map(resolve));
}

class _Recognizer implements CardRecognizer {
  Completer<ScanRecognition>? pending;
  int calls = 0;
  @override
  Future<ScanRecognition> recognize(
    String imagePath, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    calls++;
    final Completer<ScanRecognition>? wait = pending;
    if (wait != null) return wait.future;
    return ScanRecognition(
      imagePath: imagePath,
      width: 640,
      height: 900,
      crops: <ScanCrop>[_crop('Giant Growth')],
    );
  }
}

class _Drafts extends ScanDraftStore {
  _Drafts(this.io) : super(userId: _user);
  final Zone io;
  bool failClear = false;
  bool failRemove = false;
  @override
  Future<ScanAccounting> readAccounting() => io.run(super.readAccounting);
  @override
  Future<void> recordQueueEntries(
    List<ScanQueueEntry> entries, {
    required bool completed,
  }) => io.run(() => super.recordQueueEntries(entries, completed: completed));
  @override
  Future<void> reconcileQueueRemovals(Set<String> presentIds) =>
      io.run(() => super.reconcileQueueRemovals(presentIds));
  @override
  Future<void> beginQueueRemoval(List<String> ids) =>
      io.run(() => super.beginQueueRemoval(ids));
  @override
  Future<void> finishQueueRemoval(List<String> ids) =>
      io.run(() => super.finishQueueRemoval(ids));
  @override
  Future<List<String>> clearCompleted({DateTime? now}) =>
      io.run(() => super.clearCompleted(now: now));
  @override
  Future<void> discardRemaining({
    Set<String> protectedIds = const <String>{},
  }) async {
    if (failClear) throw const FileSystemException('Fixture discard failed');
    await io.run(() => super.discardRemaining(protectedIds: protectedIds));
  }

  @override
  Future<List<ScanDraftItem>> readItems() => io.run(super.readItems);
  @override
  Future<List<ScanDraftPhoto>> readPhotos() => io.run(super.readPhotos);
  @override
  Future<List<ScanDraftRescan>> readRescans() => io.run(super.readRescans);
  @override
  Future<List<List<ScanPoint>>> readReplacedRegions(String photoId) =>
      io.run(() => super.readReplacedRegions(photoId));
  @override
  Future<ScanDraftRescan> beginRescan(String itemId) =>
      io.run(() => super.beginRescan(itemId));
  @override
  Future<void> cancelRescan(String itemId, {String? requestId}) =>
      io.run(() => super.cancelRescan(itemId, requestId: requestId));
  @override
  Future<ScanDraftPhoto> importRescanPhoto(
    ScanDraftRescan request,
    String path, {
    bool ownedCameraSource = false,
  }) => io.run(
    () => super.importRescanPhoto(
      request,
      path,
      ownedCameraSource: ownedCameraSource,
    ),
  );
  @override
  Future<ScanDraftItem> commitRescan(
    ScanDraftRescan request,
    ScanDraftItem replacement,
  ) => io.run(() => super.commitRescan(request, replacement));
  @override
  Future<List<ScanDraftDetail>> readDetails() => io.run(super.readDetails);
  @override
  Future<ScanDraftDetail> scheduleDetail(String photoId) =>
      io.run(() => super.scheduleDetail(photoId));
  @override
  Future<void> updateDetail(ScanDraftDetail job) =>
      io.run(() => super.updateDetail(job));
  @override
  Future<void> completeDetail(String photoId) =>
      io.run(() => super.completeDetail(photoId));
  @override
  Future<List<ScanDraftItem>> upsertItems(List<ScanDraftItem> items) =>
      io.run(() => super.upsertItems(items));
  @override
  Future<List<ScanDraftPhoto>> importPhotos(
    Iterable<String> paths, {
    required bool multipleCards,
    bool ownedCameraSource = false,
    List<List<ScanPoint>> excludedRegions = const <List<ScanPoint>>[],
    ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
  }) => io.run(
    () => super.importPhotos(
      paths,
      multipleCards: multipleCards,
      ownedCameraSource: ownedCameraSource,
      excludedRegions: excludedRegions,
      defaults: defaults,
    ),
  );
  @override
  Future<List<ScanDraftItem>> completePhoto(
    String photoId,
    List<ScanDraftItem> items,
  ) => io.run(() => super.completePhoto(photoId, items));
  @override
  Future<void> clearCaptures() async {
    if (failClear) throw const FileSystemException('Fixture clear failed');
    await io.run(super.clearCaptures);
  }

  @override
  Future<void> removeItems(List<String> ids) async {
    if (failRemove) {
      throw const FileSystemException('Fixture retirement failed');
    }
    await io.run(() => super.removeItems(ids));
  }
}

class _QueueStorage implements ScanQueueStorage {
  _QueueStorage(this.io);
  final Zone io;
  final HiveScanQueueStorage delegate = HiveScanQueueStorage();
  @override
  Future<List<ScanQueueEntry>> readEntries(String userId) =>
      io.run(() => delegate.readEntries(userId));
  @override
  Future<void> upsertEntries(String userId, List<ScanQueueEntry> entries) =>
      io.run(() => delegate.upsertEntries(userId, entries));
  @override
  Future<void> removeEntries(String userId, List<String> operationIds) =>
      io.run(() => delegate.removeEntries(userId, operationIds));
  @override
  Future<List<ScanQueueEntry>> readCompletedEntries(String userId) =>
      io.run(() => delegate.readCompletedEntries(userId));
  @override
  Future<void> completeEntry(String userId, ScanQueueEntry entry) =>
      io.run(() => delegate.completeEntry(userId, entry));
  @override
  Future<void> removeCompletedEntries(
    String userId,
    List<String> operationIds,
  ) => io.run(() => delegate.removeCompletedEntries(userId, operationIds));
}

class _Clock {
  DateTime now = DateTime.utc(2026, 10, 13);
}

class _Fixture {
  _Fixture(this.directory, this.queue, this.clock, this.drafts)
    : io = Zone.current;
  final Directory directory;
  final Zone io;
  ScanQueue queue;
  final _Clock clock;
  _Drafts drafts;
  final _Resolver resolver = _Resolver();
  final _Recognizer recognizer = _Recognizer();
  final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
  String get photoPath => '${directory.path}/camera.png';
}

Future<void> _tick(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 100));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 25)),
  );
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _expireUndo(WidgetTester tester, _Fixture fixture) async {
  fixture.clock.now = fixture.clock.now.add(const Duration(seconds: 11));
  await tester.pump(const Duration(seconds: 11));
  await _tick(tester);
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() ready, {
  String reason = 'workflow transition',
  bool advanceTimeWhileWaiting = true,
}) async {
  if (!advanceTimeWhileWaiting) await _tick(tester);
  for (int attempt = 0; attempt < 160 && !ready(); attempt++) {
    if (advanceTimeWhileWaiting) {
      await _tick(tester);
    } else {
      // Hive latency must not consume upload deadlines in the fake clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
  }
  expect(ready(), isTrue, reason: reason);
  if (advanceTimeWhileWaiting) {
    await _tick(tester);
  } else {
    await tester.pump();
  }
  expect(tester.takeException(), isNull);
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  if (target.evaluate().length == 1 &&
      target.hitTestable().evaluate().isEmpty &&
      MediaQuery.textScalerOf(tester.element(target)).scale(14) > 21) {
    await tester.ensureVisible(target);
    await _tick(tester);
  }
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target.hitTestable());
  await _tick(tester);
}

Future<List<ScanDraftItem>> _items(
  WidgetTester tester,
  _Fixture fixture, {
  bool advanceTimeWhileWaiting = true,
}) => _awaitWork(
  tester,
  fixture.drafts.readItems,
  advanceTimeWhileWaiting: advanceTimeWhileWaiting,
);

Future<T> _awaitWork<T>(
  WidgetTester tester,
  Future<T> Function() action, {
  bool advanceTimeWhileWaiting = true,
}) async {
  bool finished = false;
  T? result;
  Object? failure;
  StackTrace? failureStack;
  unawaited(
    Future<T>.sync(action).then<void>(
      (T value) {
        result = value;
        finished = true;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        failureStack = stack;
        finished = true;
      },
    ),
  );
  await _wait(
    tester,
    () => finished,
    reason: 'durable workflow operation',
    advanceTimeWhileWaiting: advanceTimeWhileWaiting,
  );
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  return result as T;
}

Future<_Fixture> _fixture(
  WidgetTester tester,
  List<ScanDraftItem> drafts, {
  ScanQueueWriter? writer,
}) async {
  final _Fixture fixture = (await tester.runAsync(() async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'collector-scan-workflow-',
    );
    Hive.init(directory.path);
    await File('${directory.path}/camera.png').writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
      ),
    );
    final _Clock clock = _Clock();
    final _Drafts draftStore = _Drafts(Zone.current);
    final ScanQueue queue = ScanQueue(
      userId: _user,
      now: () => clock.now,
      storage: JournaledScanQueueStorage(
        drafts: draftStore,
        storage: _QueueStorage(Zone.current),
      ),
      writer: writer ?? (ScanQueueEntry _) async {},
    );
    final _Fixture result = _Fixture(directory, queue, clock, draftStore);
    await result.drafts.upsertItems(drafts);
    return result;
  }))!;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _tick(tester);
    fixture.queue.dispose();
    await _awaitWork<void>(
      tester,
      () => fixture.io.run(() async {
        await Hive.close();
        await fixture.directory.delete(recursive: true);
      }),
    );
  });
  return fixture;
}

Future<void> _mount(
  WidgetTester tester,
  _Fixture fixture, {
  MTGDeck? destination,
  ThemeMode mode = ThemeMode.dark,
  double textScale = 1,
  CardCatalog? catalog,
}) async {
  await tester.pumpWidget(
    ArcaneApp(
      navigatorKey: fixture.navigator,
      theme: MyThemeData.themeData(mode),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (BuildContext context) => Center(
          child: PrimaryButton(
            child: const Text('Open scanner'),
            onPressed: () => unawaited(
              Arcane.push<void>(
                context,
                ScanScreen(
                  userId: _user,
                  queue: fixture.queue,
                  draftStore: fixture.drafts,
                  resolver: fixture.resolver,
                  catalog: catalog,
                  recognizer: fixture.recognizer,
                  decks: Stream<List<MTGDeck>>.value(<MTGDeck>[?destination]),
                  destination: destination,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _tap(tester, find.text('Open scanner'));
  await _wait(tester, () {
    if (!fixture.queue.loaded) return false;
    final Finder primary = find
        .widgetWithText(PrimaryButton, 'Continue scanning')
        .hitTestable();
    final Finder secondary = find
        .widgetWithText(SecondaryButton, 'Continue scanning')
        .hitTestable();
    return primary.evaluate().isNotEmpty &&
            tester.widget<PrimaryButton>(primary).onPressed != null ||
        secondary.evaluate().isNotEmpty &&
            tester.widget<SecondaryButton>(secondary).onPressed != null;
  });
}

Future<GuidedCameraScreen> _camera(WidgetTester tester) async {
  await _tap(tester, find.text('Continue scanning'));
  await _wait(
    tester,
    () =>
        find.byType(GuidedCameraScreen).evaluate().isNotEmpty &&
        find.byType(ScanCameraDrawer).evaluate().isNotEmpty,
  );
  return tester.widget<GuidedCameraScreen>(find.byType(GuidedCameraScreen));
}

Future<void> _toBatch(WidgetTester tester) async {
  if (find.byType(GuidedCameraScreen).evaluate().isNotEmpty) {
    tester
        .widget<GuidedCameraScreen>(find.byType(GuidedCameraScreen))
        .onDone!();
    await _wait(
      tester,
      () => find.byType(GuidedCameraScreen).evaluate().isEmpty,
    );
  }
}

Future<void> _check(WidgetTester tester) async {
  await _toBatch(tester);
  await _tap(tester, find.textContaining(RegExp(r'^Check \([0-9]+\)$')));
}

Future<void> _review(WidgetTester tester, {bool individual = false}) async {
  await _camera(tester);
  if (individual) {
    await _toBatch(tester);
    await _tap(
      tester,
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('scan-card-first')),
            matching: find.byType(GhostButton),
          )
          .hitTestable(),
    );
  } else {
    await _check(tester);
  }
  await _wait(
    tester,
    () => find.byType(ScanCorrectionEditor).evaluate().isNotEmpty,
  );
}

Future<void> _confirm(WidgetTester tester) =>
    _tap(tester, find.byKey(const ValueKey<String>('printing-confirm')));

Future<void> _finish(WidgetTester tester, String label) async {
  await _tap(tester, find.byKey(const ValueKey<String>('printing-finish')));
  await _tap(tester, find.text(label).last);
}

Future<void> _discard(WidgetTester tester) async {
  if (find.byType(ScanCorrectionEditor).evaluate().isNotEmpty) {
    tester
        .widget<ScanCorrectionEditor>(find.byType(ScanCorrectionEditor))
        .onClose();
    await _wait(
      tester,
      () => find.byType(ScanCorrectionEditor).evaluate().isEmpty,
    );
  }
  if (find.byType(GuidedCameraScreen).evaluate().isNotEmpty) {
    tester
        .widget<GuidedCameraScreen>(find.byType(GuidedCameraScreen))
        .onDone!();
    await _wait(
      tester,
      () => find.byType(GuidedCameraScreen).evaluate().isEmpty,
    );
  }
  await _tap(
    tester,
    find.byKey(const ValueKey<String>('scan-discard-remaining')),
  );
}

void registerScanWorkflowAudit({
  required bool physical,
  Future<void> Function(String)? checkpoint,
}) {
  setUpAll(loadCollectorFonts);
  setUp(() {
    final CameraPlatform previous = CameraPlatform.instance;
    CameraPlatform.instance = _DeniedCamera();
    addTearDown(() => CameraPlatform.instance = previous);
  });
  void metrics(WidgetTester tester) {
    if (physical) return;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> shot(String name) async {
    if (checkpoint != null) await checkpoint(name);
  }

  for (final String panel in <String>[
    'reviewed',
    'unreviewed',
    'no-match',
    'quantity',
    'evidence',
    'correction',
  ]) {
    testWidgets('workflow clear from $panel retires the whole capture batch', (
      WidgetTester tester,
    ) async {
      metrics(tester);
      final _Fixture fixture = await _fixture(tester, <ScanDraftItem>[
        _draft(
          'first',
          reviewed: panel == 'reviewed',
          empty: panel == 'no-match',
        ),
        _draft('second', name: 'Counterspell'),
      ]);
      await _mount(tester, fixture);
      await _review(tester, individual: panel == 'reviewed');
      if (panel == 'quantity') {
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey<String>('printing-copies')),
            matching: find.byType(EditableText),
          ),
          '2',
        );
        await _tick(tester);
      }
      if (panel == 'evidence') {
        await _tap(
          tester,
          find.byKey(
            ValueKey<String>(
              'printing-artwork-${_printing('Lightning Bolt').id}',
            ),
          ),
        );
      }
      if (panel == 'correction') {
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey<String>('printing-search')),
            matching: find.byType(EditableText),
          ),
          'Counterspell',
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await _tick(tester);
      }
      if (panel == 'no-match') {
        expect(
          find.byKey(const ValueKey<String>('printing-search')),
          findsOneWidget,
        );
      }
      await shot('clear-$panel');
      await _discard(tester);
      await _wait(
        tester,
        () => find.byType(ScanCorrectionEditor).evaluate().isEmpty,
      );
      expect(await _items(tester, fixture), isEmpty);
      expect(fixture.queue.count, 0);
      expect(find.textContaining('Card 2 of'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }

  testWidgets(
    'workflow saved photo opens a truthful waiting tray before native OCR finishes',
    (WidgetTester tester) async {
      metrics(tester);
      final _Fixture fixture = await _fixture(tester, <ScanDraftItem>[]);
      fixture.recognizer.pending = Completer<ScanRecognition>();
      fixture.resolver.lookup = Completer<ScanResolution>();
      await _mount(tester, fixture);
      final GuidedCameraScreen camera = await _camera(tester);
      expect(camera.session!.pendingPhotoCaptures, 0);
      await _awaitWork<bool>(
        tester,
        () => camera.onCaptured!(fixture.photoPath, const <List<ScanPoint>>[]),
      );
      await _wait(tester, () => fixture.recognizer.calls == 1);
      expect(camera.session!.pendingPhotoCaptures, 1);
      await _toBatch(tester);
      await _wait(
        tester,
        () => find.byType(GuidedCameraScreen).evaluate().isEmpty,
      );
      expect(find.byType(ScanCorrectionEditor), findsNothing);
      expect(find.text('Reading…').hitTestable(), findsOneWidget);
      expect(find.text('Saved · Identifying…').hitTestable(), findsOneWidget);
      expect(
        find
            .byKey(const ValueKey<String>('scan-discard-remaining'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(find.text('Continue scanning').hitTestable(), findsOneWidget);
      fixture.recognizer.pending!.complete(
        ScanRecognition(
          imagePath: fixture.photoPath,
          width: 640,
          height: 900,
          crops: <ScanCrop>[_crop('Giant Growth')],
        ),
      );
      await _wait(
        tester,
        () => camera.session!.items.length == 1 && fixture.resolver.calls > 0,
      );
      await _tap(
        tester,
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is Semantics &&
              widget.properties.label == 'Review Giant Growth',
        ),
      );
      await _wait(
        tester,
        () => find.byType(ScanCorrectionEditor).evaluate().isNotEmpty,
      );
      expect(camera.session!.items.single.resolution, isNull);
      fixture.resolver.lookup!.complete(_resolution(_crop('Giant Growth')));
      await _wait(
        tester,
        () =>
            find.text('Giant Growth').hitTestable().evaluate().isNotEmpty &&
            find
                .byKey(const ValueKey<String>('printing-finish'))
                .hitTestable()
                .evaluate()
                .isNotEmpty,
      );
      await shot('delayed-native-printing');
      await _discard(tester);
      await _wait(
        tester,
        () => find.byType(ScanCorrectionEditor).evaluate().isEmpty,
      );
      expect(await _items(tester, fixture), isEmpty);
      expect(fixture.queue.count, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'workflow discard advances to the next captured card without approval',
    (WidgetTester tester) async {
      metrics(tester);
      final _Fixture fixture = await _fixture(tester, <ScanDraftItem>[
        _draft('first'),
        _draft('second', name: 'Counterspell'),
      ]);
      await _mount(tester, fixture);
      await _review(tester);
      await _tap(
        tester,
        find.byKey(const ValueKey<String>('scan-correction-remove')),
      );
      await _wait(
        tester,
        () => find.text('Card 1 of 1').hitTestable().evaluate().isNotEmpty,
      );
      final List<ScanDraftItem> remaining = await _items(tester, fixture);
      expect(remaining.single.id, 'second');
      expect(remaining.single.approval, isNull);
      expect(fixture.queue.count, 0);
      await _discard(tester);
      await _wait(
        tester,
        () => find.byType(ScanCorrectionEditor).evaluate().isEmpty,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'workflow failed discard preserves durable approvals until retry',
    (WidgetTester tester) async {
      metrics(tester);
      final _Fixture fixture = await _fixture(tester, <ScanDraftItem>[
        _draft('first', reviewed: true),
        _draft('second'),
      ]);
      await _mount(tester, fixture);
      fixture.drafts.failClear = true;
      await _discard(tester);
      await _wait(
        tester,
        () => find.text('Attention').hitTestable().evaluate().isNotEmpty,
      );
      await _tap(tester, find.text('Attention'));
      expect(
        find
            .text(
              'Could not clear the captured cards. Retry when storage is available.',
            )
            .hitTestable(),
        findsOneWidget,
      );
      await _tap(tester, find.text('Done'));
      final List<ScanDraftItem> retained = await _items(tester, fixture);
      expect(retained, hasLength(2));
      expect(retained.first.approval!.quantity, 2);
      expect(retained.first.approval!.card.finish, Finish.nonfoil);
      expect(fixture.queue.count, 0);
      fixture.drafts.failClear = false;
      await _discard(tester);
      await _wait(
        tester,
        () => find.byType(ScanCorrectionEditor).evaluate().isEmpty,
      );
      expect(await _items(tester, fixture), isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'workflow clear invalidates a blocked printing lookup without resurrection or advance',
    (WidgetTester tester) async {
      metrics(tester);
      final _Fixture fixture = await _fixture(tester, <ScanDraftItem>[
        _draft('first'),
        _draft('second'),
      ]);
      await _mount(tester, fixture);
      final GuidedCameraScreen camera = await _camera(tester);
      fixture.resolver.lookup = Completer<ScanResolution>();
      final int before = fixture.resolver.calls;
      camera.session!.items.first.resolution = null;
      camera.session!.retryUnresolved();
      await _wait(tester, () => fixture.resolver.calls > before);
      await _discard(tester);
      await _wait(
        tester,
        () => find.byType(ScanCorrectionEditor).evaluate().isEmpty,
      );
      fixture.resolver.lookup!.complete(_resolution(_crop('Lightning Bolt')));
      for (int index = 0; index < 5; index++) {
        await _tick(tester);
      }
      expect(await _items(tester, fixture), isEmpty);
      expect(find.byType(ScanCorrectionEditor), findsNothing);
      expect(fixture.queue.count, 0);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'workflow restart restores a reviewed printing and clear remains durable',
    (WidgetTester tester) async {
      metrics(tester);
      final _Fixture fixture = await _fixture(tester, <ScanDraftItem>[
        _draft('first'),
        _draft('second', name: 'Counterspell'),
      ]);
      await _mount(tester, fixture);
      await _review(tester);
      await _tap(
        tester,
        find.byKey(
          ValueKey<String>(
            'printing-choice-${_printing('Lightning Bolt', variant: 1).id}',
          ),
        ),
      );
      await _finish(tester, 'Foil');
      await _confirm(tester);
      await _wait(
        tester,
        () => find.text('Card 2 of 2').hitTestable().evaluate().isNotEmpty,
      );
      await _tap(
        tester,
        find.byKey(const ValueKey<String>('scan-correction-close')),
      );
      await _wait(
        tester,
        () => find.byType(ScanCorrectionEditor).evaluate().isEmpty,
      );
      final ScanDraftItem approved = (await _items(
        tester,
        fixture,
      )).singleWhere((ScanDraftItem item) => item.id == 'first');
      expect(
        approved.approval!.card.printingId,
        _printing('Lightning Bolt', variant: 1).id,
      );
      expect(approved.approval!.card.finish, Finish.foil);
      await _wait(
        tester,
        () => find
            .byKey(const ValueKey<String>('scan-undo'))
            .hitTestable()
            .evaluate()
            .isNotEmpty,
      );
      await _tap(tester, find.byKey(const ValueKey<String>('scan-undo')));
      expect(
        (await _items(
          tester,
          fixture,
        )).firstWhere((ScanDraftItem item) => item.id == 'first').selected,
        isFalse,
      );
      expect(fixture.queue.count, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await _tick(tester);
      fixture.queue.dispose();
      await _awaitWork<void>(tester, () => fixture.io.run(Hive.close));
      fixture.drafts = fixture.io.run(() => _Drafts(fixture.io));
      fixture.queue = fixture.io.run(
        () => ScanQueue(
          userId: _user,
          now: () => fixture.clock.now,
          storage: JournaledScanQueueStorage(
            drafts: fixture.drafts,
            storage: _QueueStorage(fixture.io),
          ),
          writer: (ScanQueueEntry _) async {},
        ),
      );
      await _mount(tester, fixture);
      await _review(tester, individual: true);
      expect(
        tester
            .widget<CardPrintingSelector>(find.byType(CardPrintingSelector))
            .initialPrinting!
            .id,
        _printing('Lightning Bolt', variant: 1).id,
      );
      expect(
        tester
            .widget<Selector<Finish>>(
              find.byKey(const ValueKey<String>('printing-finish')),
            )
            .value,
        Finish.foil,
      );
      await _discard(tester);
      await _wait(
        tester,
        () => find.byType(ScanCorrectionEditor).evaluate().isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await _tick(tester);
      await _awaitWork<void>(tester, () => fixture.io.run(Hive.close));
      fixture.drafts = fixture.io.run(() => _Drafts(fixture.io));
      expect(await _items(tester, fixture), isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'workflow startup retires matching submitted drafts and locks conflicting approvals',
    (WidgetTester tester) async {
      metrics(tester);
      final _Fixture fixture = await _fixture(tester, <ScanDraftItem>[
        _draft('matched', reviewed: true),
        _draft('conflict', reviewed: true),
      ]);
      await _awaitWork<void>(tester, () async {
        await fixture.queue.load();
        await fixture.queue.enqueueBatch(<ScanQueueApproval>[
          (await fixture.drafts.readItems())
              .singleWhere((ScanDraftItem item) => item.id == 'matched')
              .approval!,
          ScanQueueApproval(
            operationId: 'conflict',
            card: cardFromScryfall(
              _printing('Lightning Bolt'),
              finish: Finish.foil,
            ),
            quantity: 2,
          ),
        ]);
      });
      fixture.queue.pauseUploads();
      final List<Map<String, Object?>> queued = fixture.queue.entries
          .map((ScanQueueEntry entry) => entry.toMap())
          .toList();
      await _mount(tester, fixture);
      await _wait(
        tester,
        () =>
            find.text('Continue scanning').hitTestable().evaluate().isNotEmpty,
      );
      final List<ScanDraftItem> remaining = await _items(tester, fixture);
      expect(remaining.single.id, 'conflict');
      final GuidedCameraScreen camera = await _camera(tester);
      expect(camera.session!.items.single.id, 'conflict');
      tester
          .widget<GuidedCameraScreen>(find.byType(GuidedCameraScreen))
          .onDone!();
      await _tick(tester);
      expect(
        tester
            .widget<Semantics>(
              find.byWidgetPredicate(
                (Widget widget) =>
                    widget is Semantics &&
                    widget.properties.label == 'Review Lightning Bolt',
              ),
            )
            .properties
            .enabled,
        isFalse,
      );
      expect(
        fixture.queue.entries
            .map((ScanQueueEntry entry) => entry.toMap())
            .toList(),
        queued,
      );
      await _tap(
        tester,
        find.byKey(const ValueKey<String>('scan-discard-remaining')),
      );
      expect((await _items(tester, fixture)).single.id, 'conflict');
      expect(
        fixture.queue.entries
            .map((ScanQueueEntry entry) => entry.toMap())
            .toList(),
        queued,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'workflow final approval followed by failed retirement stays locked and uploads once',
    (WidgetTester tester) async {
      metrics(tester);
      final Completer<void> upload = Completer<void>();
      addTearDown(() {
        if (!upload.isCompleted) upload.complete();
      });
      final List<String> attempts = <String>[];
      final Set<String> receipts = <String>{};
      final _Fixture fixture = await _fixture(
        tester,
        <ScanDraftItem>[_draft('first')],
        writer: (ScanQueueEntry entry) async {
          attempts.add(entry.operationId);
          await upload.future;
          receipts.add(entry.operationId);
        },
      );
      await _mount(tester, fixture);
      await _review(tester);
      await _finish(tester, 'Foil');
      fixture.drafts.failRemove = true;
      await _confirm(tester);
      await _wait(
        tester,
        () =>
            fixture.queue.count == 1 &&
            find.byType(ScanCorrectionEditor).evaluate().isEmpty,
      );
      expect(attempts, isEmpty);
      await _expireUndo(tester, fixture);
      await _wait(tester, () => attempts.length == 1);
      final Map<String, Object?> submitted = fixture.queue.entries.single
          .toMap();
      expect((await _items(tester, fixture)).single.id, 'first');
      final Semantics locked = tester.widget<Semantics>(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is Semantics &&
              widget.properties.label == 'Review Lightning Bolt',
        ),
      );
      expect(locked.properties.enabled, isFalse);
      expect(attempts, <String>['first']);
      expect(find.textContaining('Confirm'), findsNothing);
      fixture.drafts.failRemove = false;
      fixture.navigator.currentState!.pop();
      await _tick(tester);
      await _tap(tester, find.text('Open scanner'));
      await _wait(
        tester,
        () =>
            find.text('Continue scanning').hitTestable().evaluate().isNotEmpty,
      );
      expect(await _items(tester, fixture), isEmpty);
      expect(fixture.queue.entries.single.toMap(), submitted);
      expect(attempts, <String>['first']);
      upload.complete();
      await _wait(tester, () => fixture.queue.count == 0);
      expect(attempts, <String>['first']);
      expect(receipts, <String>{'first'});
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'workflow approvals added during upload automatically drain a second snapshot',
    (WidgetTester tester) async {
      metrics(tester);
      final Completer<void> firstWrite = Completer<void>();
      final List<String> attempts = <String>[];
      final _Fixture fixture = await _fixture(
        tester,
        <ScanDraftItem>[_draft('first')],
        writer: (ScanQueueEntry entry) async {
          attempts.add(entry.operationId);
          if (attempts.length == 1) await firstWrite.future;
        },
      );
      addTearDown(() {
        if (!firstWrite.isCompleted) firstWrite.complete();
      });
      await _mount(tester, fixture);
      final GuidedCameraScreen camera = await _camera(tester);
      final ScanSession session = camera.session!;
      await _check(tester);
      await _wait(
        tester,
        () => find.byType(ScanCorrectionEditor).evaluate().isNotEmpty,
      );
      await _confirm(tester);
      await _wait(tester, () => fixture.queue.count == 1);
      expect(attempts, isEmpty);
      await _expireUndo(tester, fixture);
      await _wait(tester, () => attempts.length == 1);
      final ScanSessionItem second = ScanSessionItem.fromDraft(
        _draft('second', name: 'Counterspell'),
      );
      session.add(second);
      await _awaitWork<void>(
        tester,
        () => session.persist(<ScanSessionItem>[second]),
      );
      session.changed();
      await _review(tester);
      await _confirm(tester);
      await _wait(tester, () => fixture.queue.count == 2);
      expect(attempts, <String>['first']);
      await _expireUndo(tester, fixture);
      firstWrite.complete();
      await _wait(tester, () => fixture.queue.count == 0);
      expect(attempts, <String>['first', 'second']);
      expect(await _items(tester, fixture), isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'workflow container approval drains its upload tail after the scanner route closes',
    (WidgetTester tester) async {
      metrics(tester);
      final Completer<void> firstWrite = Completer<void>();
      final List<ScanQueueEntry> attempts = <ScanQueueEntry>[];
      final _Fixture fixture = await _fixture(
        tester,
        <ScanDraftItem>[
          _draft(
            'first',
            defaults: const ScanCaptureDefaults(deckId: 'binder'),
          ),
        ],
        writer: (ScanQueueEntry entry) async {
          attempts.add(entry);
          if (entry.operationId == 'first') await firstWrite.future;
        },
      );
      addTearDown(() {
        if (!firstWrite.isCompleted) firstWrite.complete();
      });
      final MTGDeck binder = MTGDeck(
        name: 'Trade binder',
        kind: CollectionGroupKind.binder,
      )..id = 'binder';
      fixture.recognizer.pending = Completer<ScanRecognition>();
      await _mount(tester, fixture, destination: binder);
      final GuidedCameraScreen camera = await _camera(tester);
      await _awaitWork<bool>(
        tester,
        () => camera.onCaptured!(fixture.photoPath, const <List<ScanPoint>>[]),
      );
      await _wait(tester, () => fixture.recognizer.calls == 1);
      await _check(tester);
      await _wait(
        tester,
        () => find.byType(ScanCorrectionEditor).evaluate().isNotEmpty,
      );
      await _confirm(tester);
      await _wait(tester, () => fixture.queue.count == 1);
      await _expireUndo(tester, fixture);
      await _wait(
        tester,
        () =>
            attempts.length == 1 &&
            find.byType(ScanCorrectionEditor).evaluate().isEmpty,
        advanceTimeWhileWaiting: false,
      );
      expect(camera.session!.running, isTrue);
      expect(find.byType(ScanScreen), findsOneWidget);
      expect(firstWrite.isCompleted, isFalse);
      fixture.recognizer.pending!.complete(
        ScanRecognition(
          imagePath: fixture.photoPath,
          width: 640,
          height: 900,
          crops: <ScanCrop>[_crop('Counterspell')],
        ),
      );
      await _wait(
        tester,
        () =>
            camera.session!.items.length == 1 &&
            !camera.session!.running &&
            camera.session!.items.single.resolution != null,
        advanceTimeWhileWaiting: false,
      );
      final String secondOperation = camera.session!.items.single.id;
      await _review(tester);
      expect(
        tester
            .widget<ScanCorrectionEditor>(find.byType(ScanCorrectionEditor))
            .preferredDeckId,
        'binder',
      );
      await _confirm(tester);
      await _wait(
        tester,
        () =>
            fixture.queue.count == 2 &&
            find.byType(ScanCorrectionEditor).evaluate().isEmpty,
        advanceTimeWhileWaiting: false,
      );
      expect(find.byType(ScanScreen), findsOneWidget);
      await _expireUndo(tester, fixture);
      await _wait(
        tester,
        () => camera.session!.items.isEmpty,
        advanceTimeWhileWaiting: false,
      );
      fixture.navigator.currentState!.pop();
      await _wait(
        tester,
        () => find.text('Open scanner').hitTestable().evaluate().isNotEmpty,
        advanceTimeWhileWaiting: false,
      );
      expect(firstWrite.isCompleted, isFalse);
      expect(
        attempts.map((ScanQueueEntry entry) => entry.operationId),
        <String>['first'],
      );
      expect(fixture.queue.count, 2);
      expect(
        await _items(tester, fixture, advanceTimeWhileWaiting: false),
        isEmpty,
      );
      expect(fixture.queue.sending, isTrue);
      expect(
        fixture.queue.paused,
        isFalse,
        reason: 'Local I/O polling must not expire the held upload deadline.',
      );
      firstWrite.complete();
      await _wait(
        tester,
        () => fixture.queue.count == 0,
        advanceTimeWhileWaiting: false,
      );
      expect(
        attempts.map((ScanQueueEntry entry) => entry.operationId),
        <String>['first', secondOperation],
      );
      expect(attempts.last.deckId, 'binder');
      expect(attempts.last.deckSection, DeckSection.mainboard);
      expect(attempts.last.card.name, 'Counterspell');
      expect(await _items(tester, fixture), isEmpty);
      expect(find.byType(ScanScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'workflow late fourth OCR card keeps container review open until all four confirmations',
    (WidgetTester tester) async {
      metrics(tester);
      final List<ScanQueueEntry> attempts = <ScanQueueEntry>[];
      final _Fixture fixture = await _fixture(
        tester,
        <ScanDraftItem>[
          _draft(
            'first',
            defaults: const ScanCaptureDefaults(deckId: 'binder'),
          ),
          _draft(
            'second',
            name: 'Counterspell',
            defaults: const ScanCaptureDefaults(deckId: 'binder'),
          ),
          _draft(
            'third',
            name: 'Dark Ritual',
            defaults: const ScanCaptureDefaults(deckId: 'binder'),
          ),
        ],
        writer: (ScanQueueEntry entry) async {
          attempts.add(entry);
        },
      );
      final MTGDeck binder = MTGDeck(
        name: 'Trade binder',
        kind: CollectionGroupKind.binder,
      )..id = 'binder';
      fixture.recognizer.pending = Completer<ScanRecognition>();
      await _mount(tester, fixture, destination: binder);
      final GuidedCameraScreen camera = await _camera(tester);
      await _awaitWork<bool>(
        tester,
        () => camera.onCaptured!(fixture.photoPath, const <List<ScanPoint>>[]),
      );
      await _wait(tester, () => fixture.recognizer.calls == 1);
      await _check(tester);
      await _wait(
        tester,
        () => find.byType(ScanCorrectionEditor).evaluate().isNotEmpty,
      );
      fixture.recognizer.pending!.complete(
        ScanRecognition(
          imagePath: fixture.photoPath,
          width: 640,
          height: 900,
          crops: <ScanCrop>[_crop('Giant Growth')],
        ),
      );
      await _wait(
        tester,
        () => camera.session!.items.length == 4 && !camera.session!.running,
      );
      for (int index = 0; index < 3; index++) {
        await _confirm(tester);
        await _wait(
          tester,
          () =>
              find.byType(ScanCorrectionEditor).evaluate().isNotEmpty &&
              find
                  .text('Card ${index + 2} of 4')
                  .hitTestable()
                  .evaluate()
                  .isNotEmpty,
        );
        expect(attempts, isEmpty);
        expect(find.text('Open scanner').hitTestable(), findsNothing);
      }
      await shot('container-fourth-review');
      await _confirm(tester);
      await _wait(
        tester,
        () =>
            fixture.queue.count == 4 &&
            find.byType(ScanCorrectionEditor).evaluate().isEmpty,
      );
      expect(find.byType(ScanScreen), findsOneWidget);
      expect(attempts, isEmpty);
      await _expireUndo(tester, fixture);
      await _wait(tester, () => fixture.queue.count == 0);
      expect(attempts, hasLength(4));
      expect(
        attempts.map((ScanQueueEntry entry) => entry.operationId).toSet(),
        hasLength(4),
      );
      expect(
        attempts.every(
          (ScanQueueEntry entry) =>
              entry.deckId == 'binder' &&
              entry.deckSection == DeckSection.mainboard,
        ),
        isTrue,
      );
      expect(
        attempts.map((ScanQueueEntry entry) => entry.card.name),
        contains('Giant Growth'),
      );
      expect(await _items(tester, fixture), isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
