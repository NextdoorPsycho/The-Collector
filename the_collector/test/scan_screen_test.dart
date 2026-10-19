import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, ValueListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:scryfall_api/scryfall_api.dart' hide Color;
import 'package:the_collector/pages/scanning/scan_screen.dart';
import 'package:the_collector/pages/scanning/guided_camera_screen.dart';
import 'package:the_collector/pages/scanning/scan_camera_drawer.dart';
import 'package:the_collector/pages/scanning/scan_correction_editor.dart';
import 'package:the_collector/pages/collection/card/card_add_dialog.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_accounting.dart';
import 'package:the_collector/utils/scanning/scan_capture_defaults.dart';
import 'package:the_collector/utils/scanning/scan_queue.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_session.dart';

import 'helpers/load_collector_fonts.dart';

DateTime _queueNow = DateTime.utc(2026, 10, 13);
Future<({Future<void> closed, ScanCorrectionEditor editor})> _openCorrection(
  WidgetTester tester,
  ScanSessionItem item,
) async {
  final ScanCameraDrawer rail = tester.widget<ScanCameraDrawer>(
    find.byType(ScanCameraDrawer),
  );
  final Future<void> closed = rail.onEdit(item);
  await tester.pumpAndSettle();
  return (
    closed: closed,
    editor: tester.widget<ScanCorrectionEditor>(
      find.byType(ScanCorrectionEditor),
    ),
  );
}

PrintingSelection _choice(ScanSessionItem item, Finish finish) =>
    PrintingSelection(
      card: cardFromScryfall(item.printing!, finish: finish),
      printing: item.printing,
      quantity: item.approval?.quantity ?? 1,
      destinationId: item.approval == null
          ? item.defaults.deckId
          : item.approval!.deckId,
      deckSection: item.approval?.deckSection ?? item.defaults.deckSection,
    );

void _closeCamera(WidgetTester tester) {
  final GuidedCameraScreen camera = tester.widget<GuidedCameraScreen>(
    find.byType(GuidedCameraScreen),
  );
  if (camera.onDone != null) {
    camera.onDone!();
  } else {
    Navigator.of(tester.element(find.byType(GuidedCameraScreen))).pop();
  }
}

Future<void> _expireUndo(WidgetTester tester) async {
  _queueNow = _queueNow.add(const Duration(seconds: 11));
  await tester.pump(const Duration(seconds: 11));
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}

class _UnavailableCamera extends CameraPlatform {
  @override
  Future<List<CameraDescription>> availableCameras() async =>
      const <CameraDescription>[
        CameraDescription(
          name: 'fixture',
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

class _Storage implements ScanQueueStorage {
  _Storage([List<ScanQueueEntry> initial = const <ScanQueueEntry>[]])
    : entries = List<ScanQueueEntry>.of(initial);
  final List<ScanQueueEntry> entries;
  final Map<String, Map<String, ScanQueueEntry>> completed =
      <String, Map<String, ScanQueueEntry>>{};
  @override
  Future<List<ScanQueueEntry>> readEntries(String userId) async =>
      entries.toList();
  @override
  Future<void> upsertEntries(
    String userId,
    List<ScanQueueEntry> entries,
  ) async {
    for (final ScanQueueEntry entry in entries) {
      this.entries.removeWhere(
        (ScanQueueEntry saved) => saved.operationId == entry.operationId,
      );
      this.entries.add(entry);
    }
  }

  @override
  Future<void> removeEntries(String userId, List<String> operationIds) async {
    entries.removeWhere(
      (ScanQueueEntry entry) => operationIds.contains(entry.operationId),
    );
  }

  @override
  Future<List<ScanQueueEntry>> readCompletedEntries(String userId) async =>
      completed[userId]?.values.toList() ?? <ScanQueueEntry>[];
  @override
  Future<void> completeEntry(String userId, ScanQueueEntry entry) async {
    (completed[userId] ??= <String, ScanQueueEntry>{})[entry.operationId] =
        entry;
    await removeEntries(userId, <String>[entry.operationId]);
  }

  @override
  Future<void> removeCompletedEntries(
    String userId,
    List<String> operationIds,
  ) async {
    for (final String id in operationIds) {
      completed[userId]?.remove(id);
    }
    await removeEntries(userId, operationIds);
  }
}

MtgCard _printing([String name = 'Lightning Bolt']) =>
    MtgCard.fromJson(<String, Object?>{
      'id': 'd88a8e2d-2577-4a67-af86-e33c0ba94114',
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
      'collector_number': '123a',
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

class _Catalog implements ScanCatalog {
  int calls = 0;
  @override
  Future<PaginableList<MtgCard>> rulesKeywordCards(
    List<String> keywords, {
    String? phrase,
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
  }) async => PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false);
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
  }) async {
    calls++;
    return PaginableList<MtgCard>(data: <MtgCard>[_printing()], hasMore: false);
  }
}

class _PendingResolver extends ScanResolver {
  _PendingResolver() : super(catalog: _Catalog());
  final Completer<ScanResolution> pending = Completer<ScanResolution>();
  int calls = 0;
  @override
  Future<ScanResolution> resolve(
    ScanCrop crop, {
    String? name,
    String? setCode,
    String? collectorNumber,
    String? language,
    int page = 1,
  }) {
    calls++;
    return pending.future;
  }
}

class _ReplacementRecognizer implements CardRecognizer {
  bool fail = false;
  int calls = 0;

  @override
  Future<ScanRecognition> recognize(
    String imagePath, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    calls++;
    if (fail) throw StateError('Recognition unavailable.');
    final ScanCrop base = _draft('fresh', exact: true).crop;
    return ScanRecognition(
      imagePath: imagePath,
      width: 640,
      height: 900,
      crops: <ScanCrop>[
        ScanCrop(
          imagePath: 'replacement-crop.jpg',
          width: base.width,
          height: base.height,
          rectified: true,
          sourceCorners: const <ScanPoint>[
            ScanPoint(.1, .1),
            ScanPoint(.9, .1),
            ScanPoint(.9, .9),
            ScanPoint(.1, .9),
          ],
          lines: <ScanTextLine>[
            ...base.lines,
            const ScanTextLine(
              text: 'Instant',
              confidence: .99,
              bounds: ScanBounds(.1, .47, .7, .025),
            ),
          ],
        ),
      ],
    );
  }
}

Future<void> _show(
  WidgetTester tester,
  Widget screen,
  Brightness brightness, {
  double scale = 1,
  Size size = const Size(320, 640),
  EdgeInsets safePadding = EdgeInsets.zero,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(
        brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      ),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(scale),
          padding: safePadding,
          viewPadding: safePadding,
        ),
        child: child!,
      ),
      home: screen,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }
}

class _Drafts extends ScanDraftStore {
  _Drafts(this.items) : super(userId: 'fixture');
  final List<ScanDraftItem> items;
  final List<String> removed = <String>[];
  final Map<String, ScanDraftRescan> rescans = <String, ScanDraftRescan>{};
  final List<bool> rescanCameraOwnership = <bool>[];
  int rescanRequests = 0;
  bool failClear = false;
  int clears = 0;
  ScanQueue? queue;
  final ValueNotifier<int> accountingRevision = ValueNotifier<int>(0);
  @override
  ValueListenable<int> get accountingChanges => accountingRevision;
  void refreshAccounting() => accountingRevision.value++;

  @override
  Future<ScanAccounting> readAccounting() async => ScanAccounting(
    added: queue?.quantityCount ?? 0,
    pendingDelivery: queue?.quantityCount ?? 0,
  );

  @override
  Future<List<String>> clearCompleted({DateTime? now}) async => <String>[];

  @override
  Future<void> discardRemaining({
    Set<String> protectedIds = const <String>{},
  }) async {
    clears++;
    if (failClear) throw StateError('Storage unavailable.');
    final Set<String> discarded = items
        .where((ScanDraftItem item) => !protectedIds.contains(item.id))
        .map((ScanDraftItem item) => item.id)
        .toSet();
    removed.addAll(discarded);
    items.removeWhere((ScanDraftItem item) => discarded.contains(item.id));
    rescans.removeWhere(
      (String id, ScanDraftRescan _) => discarded.contains(id),
    );
  }

  @override
  Future<void> clearCaptures() async {
    clears++;
    if (failClear) throw StateError('Storage unavailable.');
    removed.addAll(items.map((ScanDraftItem item) => item.id));
    items.clear();
    rescans.clear();
  }

  @override
  Future<List<ScanDraftItem>> readItems() async => items.toList();
  @override
  Future<List<ScanDraftPhoto>> readPhotos() async => <ScanDraftPhoto>[];
  @override
  Future<List<ScanDraftRescan>> readRescans() async => rescans.values.toList();
  @override
  Future<List<List<ScanPoint>>> readReplacedRegions(String photoId) async =>
      <List<ScanPoint>>[];
  @override
  Future<ScanDraftRescan> beginRescan(String itemId) async {
    final ScanDraftRescan request = ScanDraftRescan(
      itemId: itemId,
      requestId: 'rescan-${++rescanRequests}',
      original: items.singleWhere((ScanDraftItem item) => item.id == itemId),
    );
    rescans[itemId] = request;
    return request;
  }

  @override
  Future<void> cancelRescan(String itemId, {String? requestId}) async {
    if (requestId == null || rescans[itemId]?.requestId == requestId) {
      rescans.remove(itemId);
    }
  }

  @override
  Future<ScanDraftPhoto> importRescanPhoto(
    ScanDraftRescan request,
    String path, {
    bool ownedCameraSource = false,
  }) async {
    rescanCameraOwnership.add(ownedCameraSource);
    final ScanDraftPhoto photo = ScanDraftPhoto(
      id: 'photo-${request.requestId}',
      imagePath: path,
      multipleCards: false,
      createdAt: DateTime.utc(2026, 10, 13),
    );
    rescans[request.itemId] = ScanDraftRescan(
      itemId: request.itemId,
      requestId: request.requestId,
      original: request.original,
      photo: photo,
    );
    return photo;
  }

  @override
  Future<ScanDraftItem> commitRescan(
    ScanDraftRescan request,
    ScanDraftItem replacement,
  ) async {
    if (rescans[request.itemId]?.requestId != request.requestId) {
      throw StateError('Rescan cancelled.');
    }
    final ScanDraftPhoto? photo = rescans[request.itemId]?.photo;
    await upsertItems(<ScanDraftItem>[replacement]);
    rescans[request.itemId] = ScanDraftRescan(
      itemId: request.itemId,
      requestId: request.requestId,
      original: request.original,
      photo: photo,
      complete: true,
    );
    return replacement;
  }

  @override
  Future<List<ScanDraftDetail>> readDetails() async => <ScanDraftDetail>[];
  @override
  Future<ScanDraftDetail> scheduleDetail(String photoId) async =>
      throw StateError('This fixture has no captured detail sources.');
  @override
  Future<void> updateDetail(ScanDraftDetail job) async {}
  @override
  Future<void> completeDetail(String photoId) async {}
  @override
  Future<List<ScanDraftRecovery>> readRecoveries() async =>
      <ScanDraftRecovery>[];
  @override
  Future<ScanDraftRecovery?> scheduleRecovery(
    String itemId, {
    bool manual = false,
  }) async => null;
  @override
  Future<void> completeRecovery(ScanDraftRecovery job) async {}
  @override
  Future<List<ScanDraftItem>> upsertItems(List<ScanDraftItem> values) async {
    for (final ScanDraftItem value in values) {
      items.removeWhere((ScanDraftItem item) => item.id == value.id);
      items.add(value);
    }
    return values;
  }

  @override
  Future<void> removeItems(List<String> ids) async {
    removed.addAll(ids);
    items.removeWhere((ScanDraftItem item) => ids.contains(item.id));
    for (final String id in ids) {
      rescans.remove(id);
    }
  }
}

class _BrokenDrafts extends _Drafts {
  _BrokenDrafts(super.items);
  @override
  Future<List<ScanDraftItem>> readItems() async {
    if (items.isNotEmpty) throw const FormatException('Invalid saved capture');
    return super.readItems();
  }
}

class _HeldPersistenceDrafts extends _Drafts {
  _HeldPersistenceDrafts(super.items, {required this.failPersistence});
  final bool failPersistence;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<List<ScanDraftItem>> upsertItems(List<ScanDraftItem> values) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    if (failPersistence) throw StateError('Persistence unavailable.');
    return super.upsertItems(values);
  }
}

class _FailNextApprovalDrafts extends _Drafts {
  _FailNextApprovalDrafts(super.items);
  bool failNext = true;

  @override
  Future<List<ScanDraftItem>> upsertItems(List<ScanDraftItem> values) async {
    if (failNext && values.any((ScanDraftItem item) => item.approval != null)) {
      failNext = false;
      throw StateError('Persistence unavailable.');
    }
    return super.upsertItems(values);
  }
}

class _HeldUndoDrafts extends _Drafts {
  _HeldUndoDrafts(super.items, {required this.failPersistence});
  bool failPersistence;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<List<ScanDraftItem>> upsertItems(List<ScanDraftItem> values) async {
    if (values.any(
      (ScanDraftItem item) => item.approval != null && !item.selected,
    )) {
      if (!started.isCompleted) started.complete();
      await release.future;
      if (failPersistence) throw StateError('Persistence unavailable.');
    }
    return super.upsertItems(values);
  }
}

class _UnreadableUploads extends _Storage {
  bool fail = true;
  @override
  Future<List<ScanQueueEntry>> readEntries(String userId) async {
    if (fail) throw const FormatException('Invalid saved upload');
    return super.readEntries(userId);
  }
}

ScanDraftItem _draft(
  String id, {
  String name = 'Lightning Bolt',
  String path = '',
  bool reviewed = false,
  bool selected = false,
  bool exact = false,
  bool uncertain = false,
  bool processing = false,
  Finish approvedFinish = Finish.nonfoil,
  int approvedQuantity = 2,
  String? approvedDeckId,
  DeckSection approvedSection = DeckSection.mainboard,
  ScanCaptureDefaults defaults = const ScanCaptureDefaults(),
}) {
  final MtgCard card = _printing(name);
  final ScanCrop crop = ScanCrop(
    imagePath: path,
    width: 640,
    height: 900,
    rectified: true,
    sourceCorners: const <ScanPoint>[],
    lines: <ScanTextLine>[
      ScanTextLine(
        text: name,
        confidence: .99,
        bounds: const ScanBounds(.1, .05, .7, .02),
      ),
      const ScanTextLine(
        text: '123a',
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
  return ScanDraftItem(
    id: id,
    photoId: '',
    crop: crop,
    defaults: defaults,
    resolution: processing
        ? null
        : ScanResolution(
            candidates: exact || reviewed || uncertain
                ? <ScanCandidate>[
                    ScanCandidate(card, <ScanEvidence>{
                      ScanEvidence.nameMatch,
                      ScanEvidence.footerMatch,
                    }),
                  ]
                : <ScanCandidate>[],
            hints: ScanHints.fromCrop(crop),
            status: exact
                ? ScanResolutionStatus.exactPrinting
                : ScanResolutionStatus.needsReview,
          ),
    approval: reviewed
        ? ScanQueueApproval(
            operationId: id,
            card: cardFromScryfall(card, finish: approvedFinish),
            quantity: approvedQuantity,
            deckId: approvedDeckId,
            deckSection: approvedSection,
          )
        : null,
    selected: selected,
  );
}

ScanScreen _screen(
  ScanQueue queue, {
  _Drafts? drafts,
  List<MTGDeck> decks = const <MTGDeck>[],
  MTGDeck? destination,
  ScanResolver? resolver,
  CardRecognizer? recognizer,
}) {
  drafts?.queue = queue;
  if (drafts != null) queue.addListener(drafts.refreshAccounting);
  return ScanScreen(
    userId: 'fixture',
    queue: queue,
    draftStore: drafts,
    resolver: resolver ?? ScanResolver(catalog: _Catalog()),
    recognizer: recognizer,
    decks: Stream<List<MTGDeck>>.value(<MTGDeck>[
      ...decks,
      if (destination != null &&
          !decks.any((MTGDeck deck) => deck.id == destination.id))
        destination,
    ]),
    destination: destination,
  );
}

Future<void> _choose<T>(WidgetTester tester, String label) async {
  final Finder destination = find.byKey(
    const ValueKey<String>('printing-destination'),
  );
  final Finder selector = T == String && destination.evaluate().isNotEmpty
      ? destination
      : find.byType(Selector<T>).first;
  await tester.ensureVisible(selector);
  await tester.pumpAndSettle();
  await tester.tap(selector);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.ensureVisible(find.text(label).last);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(find.text(label).last);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

Future<void> _more(WidgetTester tester) async {
  await tester.tap(find.widgetWithIcon(IconButton, Icons.dots_three));
  await tester.pumpAndSettle();
}

Finder _capturedArtwork(String name) => find.byWidgetPredicate(
  (Widget widget) =>
      widget is Semantics && widget.properties.label == 'Review $name',
);

void main() {
  setUpAll(loadCollectorFonts);
  setUp(() => _queueNow = DateTime.utc(2026, 10, 13));

  testWidgets(
    'standalone scanner keeps defaults and correction controls inside notched safe areas',
    (WidgetTester tester) async {
      final CameraPlatform previous = CameraPlatform.instance;
      CameraPlatform.instance = _UnavailableCamera();
      addTearDown(() => CameraPlatform.instance = previous);
      final _Storage storage = _Storage();
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: storage,
        writer: (ScanQueueEntry _) async {},
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('first', uncertain: true),
      ]);
      await _show(
        tester,
        Builder(
          builder: (BuildContext context) => Scaffold(
            child: Center(
              child: PrimaryButton(
                onPressed: () => unawaited(
                  Arcane.push<void>(context, _screen(queue, drafts: drafts)),
                ),
                child: const Text('Open scanner'),
              ),
            ),
          ),
        ),
        Brightness.dark,
        size: const Size(390, 844),
        safePadding: const EdgeInsets.only(top: 59, bottom: 34),
      );
      await tester.tap(find.text('Open scanner'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue scanning'));
      await tester.pumpAndSettle();
      final Rect defaults = tester.getRect(
        find.byKey(const ValueKey<String>('scan-defaults')),
      );
      final ScanSessionItem item = tester
          .widget<GuidedCameraScreen>(find.byType(GuidedCameraScreen))
          .session!
          .items
          .single;
      final ({Future<void> closed, ScanCorrectionEditor editor}) edit =
          await _openCorrection(tester, item);
      final Finder close = find.byKey(
        const ValueKey<String>('scan-correction-close'),
      );
      final Finder confirm = find.byKey(
        const ValueKey<String>('printing-confirm'),
      );
      expect(close.hitTestable(), findsOneWidget);
      expect(confirm.hitTestable(), findsOneWidget);
      final Rect closeBounds = tester.getRect(close);
      final Rect confirmBounds = tester.getRect(confirm);
      await tester.tap(close);
      await tester.pumpAndSettle();
      await edit.closed;
      expect(queue.count, 0);
      expect(storage.entries, isEmpty);
      expect(drafts.items.single.id, 'first');
      for (final (String, Rect) control in <(String, Rect)>[
        ('Capture defaults', defaults),
        ('Close correction', closeBounds),
        ('Save correction', confirmBounds),
      ]) {
        expect(control.$2.top, greaterThanOrEqualTo(59), reason: control.$1);
        expect(control.$2.bottom, lessThanOrEqualTo(810), reason: control.$1);
        expect(control.$2.left, greaterThanOrEqualTo(0), reason: control.$1);
        expect(control.$2.right, lessThanOrEqualTo(390), reason: control.$1);
      }
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a held addition finishing after route exit retires its restored photo without replay or phantom Undo',
    (WidgetTester tester) async {
      final _Storage storage = _Storage();
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('completed', exact: true),
      ]);
      int writes = 0;
      final ScanQueue original = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: storage,
        writer: (ScanQueueEntry _) async {
          writes++;
        },
      );
      addTearDown(original.dispose);
      await _show(tester, _screen(original, drafts: drafts), Brightness.dark);
      expect(original.canUndo('completed'), isTrue);
      expect(drafts.items, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await _expireUndo(tester);
      expect(writes, 1);
      expect(original.count, 0);
      expect(original.hasCompleted('completed'), isTrue);
      expect(drafts.items, hasLength(1));
      final ScanQueue restored = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: storage,
        writer: (ScanQueueEntry _) async {
          writes++;
        },
      );
      addTearDown(restored.dispose);
      await _show(tester, _screen(restored, drafts: drafts), Brightness.dark);
      expect(drafts.items, isEmpty);
      expect(drafts.removed, <String>['completed']);
      expect(restored.count, 0);
      expect(restored.completedCount, 0);
      expect(find.text('Undo'), findsNothing);
      await _expireUndo(tester);
      expect(writes, 1);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'camera drawer keeps Reading visible and a late verified result autoqueues once',
    (WidgetTester tester) async {
      final CameraPlatform previous = CameraPlatform.instance;
      CameraPlatform.instance = _UnavailableCamera();
      addTearDown(() => CameraPlatform.instance = previous);
      final _PendingResolver resolver = _PendingResolver();
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async => writes.add(entry),
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('reading', processing: true),
      ]);
      await _show(
        tester,
        _screen(queue, drafts: drafts, resolver: resolver),
        Brightness.dark,
        settle: false,
      );
      expect(resolver.calls, 1);
      expect(find.textContaining('Check ('), findsNothing);
      await tester.tap(find.text('Continue scanning'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(GuidedCameraScreen), findsOneWidget);
      expect(find.byType(ScanCameraDrawer), findsOneWidget);
      expect(find.byType(ScanCorrectionEditor), findsNothing);
      expect(find.textContaining('Reading').hitTestable(), findsWidgets);
      expect(resolver.calls, 1);
      expect(queue.count, 0);
      resolver.pending.complete(_draft('reading', exact: true).resolution!);
      await tester.pumpAndSettle();
      expect(queue.entries.single.operationId, 'reading');
      expect(queue.entries.single.card.finish, Finish.nonfoil);
      expect(queue.canUndo('reading'), isTrue);
      expect(writes, isEmpty);
      expect(find.byType(GuidedCameraScreen), findsOneWidget);
      await _expireUndo(tester);
      expect(writes, hasLength(1));
      expect(drafts.items, isEmpty);
      expect(find.byType(GuidedCameraScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'inline camera corrections queue each choice and Undo targets one operation',
    (WidgetTester tester) async {
      final CameraPlatform previous = CameraPlatform.instance;
      CameraPlatform.instance = _UnavailableCamera();
      addTearDown(() => CameraPlatform.instance = previous);
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async => writes.add(entry),
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('first', uncertain: true),
        _draft('second', uncertain: true),
      ]);
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      await tester.tap(find.text('Continue scanning'));
      await tester.pumpAndSettle();
      final ScanSession session = tester
          .widget<GuidedCameraScreen>(find.byType(GuidedCameraScreen))
          .session!;
      for (final ScanSessionItem item in List<ScanSessionItem>.of(
        session.items,
      )) {
        final ({Future<void> closed, ScanCorrectionEditor editor}) edit =
            await _openCorrection(tester, item);
        edit.editor.onConfirmed(
          _choice(item, item.id == 'first' ? Finish.foil : Finish.nonfoil),
        );
        await tester.pumpAndSettle();
        await edit.closed;
      }
      expect(
        queue.entries.map((ScanQueueEntry entry) => entry.operationId),
        <String>['first', 'second'],
      );
      expect(queue.entries.first.card.finish, Finish.foil);
      final ScanCameraDrawer rail = tester.widget<ScanCameraDrawer>(
        find.byType(ScanCameraDrawer),
      );
      await rail.onUndo('first');
      await tester.pumpAndSettle();
      expect(queue.entries.single.operationId, 'second');
      expect(
        drafts.items
            .firstWhere((ScanDraftItem item) => item.id == 'first')
            .selected,
        isFalse,
      );
      await _expireUndo(tester);
      expect(writes.single.operationId, 'second');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final bool deferred in <bool>[false, true]) {
    testWidgets(
      'failed inline confirmation never queues later, deferred=$deferred',
      (WidgetTester tester) async {
        final CameraPlatform previous = CameraPlatform.instance;
        CameraPlatform.instance = _UnavailableCamera();
        addTearDown(() => CameraPlatform.instance = previous);
        final _Storage storage = _Storage();
        final ScanQueue queue = ScanQueue(
          userId: 'fixture',
          now: () => _queueNow,
          storage: storage,
          writer: (_) async {},
        );
        addTearDown(queue.dispose);
        final _Drafts drafts = deferred
            ? _HeldPersistenceDrafts(<ScanDraftItem>[
                _draft('first', uncertain: true),
              ], failPersistence: true)
            : _FailNextApprovalDrafts(<ScanDraftItem>[
                _draft('first', uncertain: true),
              ]);
        if (drafts is _HeldPersistenceDrafts) {
          addTearDown(() {
            if (!drafts.release.isCompleted) drafts.release.complete();
          });
        }
        await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
        await tester.tap(find.text('Continue scanning'));
        await tester.pumpAndSettle();
        final ScanSession session = tester
            .widget<GuidedCameraScreen>(find.byType(GuidedCameraScreen))
            .session!;
        final ScanSessionItem item = session.items.single;
        final ({Future<void> closed, ScanCorrectionEditor editor}) edit =
            await _openCorrection(tester, item);
        edit.editor.onConfirmed(_choice(item, Finish.foil));
        await tester.pump();
        if (drafts is _HeldPersistenceDrafts) {
          expect(drafts.started.isCompleted, isTrue);
          expect(storage.entries, isEmpty);
          drafts.release.complete();
        }
        await tester.pumpAndSettle();
        await edit.closed;
        expect(queue.count, 0);
        expect(storage.entries, isEmpty);
        expect(item.approval, isNull);
        expect(item.selected, isFalse);
        session.changed();
        await _expireUndo(tester);
        expect(queue.count, 0);
        if (!deferred) {
          final ({Future<void> closed, ScanCorrectionEditor editor}) retry =
              await _openCorrection(tester, item);
          retry.editor.onConfirmed(_choice(item, Finish.foil));
          await tester.pumpAndSettle();
          await retry.closed;
          expect(queue.entries.single.card.finish, Finish.foil);
          await _expireUndo(tester);
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'inline correction blocks a second editor and keeps incoming exact cards separate',
    (WidgetTester tester) async {
      final CameraPlatform previous = CameraPlatform.instance;
      CameraPlatform.instance = _UnavailableCamera();
      addTearDown(() => CameraPlatform.instance = previous);
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (_) async {},
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('first', uncertain: true),
        _draft('second', uncertain: true),
      ]);
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      await tester.tap(find.text('Continue scanning'));
      await tester.pumpAndSettle();
      final ScanCameraDrawer rail = tester.widget<ScanCameraDrawer>(
        find.byType(ScanCameraDrawer),
      );
      final ScanSession session = tester
          .widget<GuidedCameraScreen>(find.byType(GuidedCameraScreen))
          .session!;
      final ScanSessionItem first = session.items.first;
      final ScanSessionItem second = session.items.last;
      final ({Future<void> closed, ScanCorrectionEditor editor}) edit =
          await _openCorrection(tester, first);
      await rail.onEdit(second);
      await tester.pumpAndSettle();
      expect(find.byType(ScanCorrectionEditor), findsOneWidget);
      expect(
        tester
            .widget<ScanCorrectionEditor>(find.byType(ScanCorrectionEditor))
            .crop,
        same(first.crop),
      );
      first.resolution = _draft('first', exact: true).resolution;
      second.resolution = _draft('second', exact: true).resolution;
      session.changed();
      await tester.pumpAndSettle();
      expect(first.approval, isNull);
      expect(queue.entries.single.operationId, 'second');
      edit.editor.onClose();
      await tester.pumpAndSettle();
      await edit.closed;
      expect(
        queue.entries.map((ScanQueueEntry entry) => entry.operationId).toSet(),
        <String>{'first', 'second'},
      );
      await _expireUndo(tester);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'destination removed during inline confirmation never receives a queued card',
    (WidgetTester tester) async {
      final CameraPlatform previous = CameraPlatform.instance;
      CameraPlatform.instance = _UnavailableCamera();
      addTearDown(() => CameraPlatform.instance = previous);
      final StreamController<List<MTGDeck>> groups =
          StreamController<List<MTGDeck>>();
      addTearDown(groups.close);
      final _Storage storage = _Storage();
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: storage,
        writer: (_) async {},
      );
      addTearDown(queue.dispose);
      final MTGDeck binder = MTGDeck(
        name: 'Binder',
        kind: CollectionGroupKind.binder,
      )..id = 'binder';
      final _HeldPersistenceDrafts drafts = _HeldPersistenceDrafts(
        <ScanDraftItem>[
          _draft(
            'first',
            uncertain: true,
            defaults: const ScanCaptureDefaults(deckId: 'binder'),
          ),
        ],
        failPersistence: false,
      );
      addTearDown(() {
        if (!drafts.release.isCompleted) drafts.release.complete();
      });
      await _show(
        tester,
        ScanScreen(
          userId: 'fixture',
          queue: queue,
          draftStore: drafts,
          resolver: ScanResolver(catalog: _Catalog()),
          decks: groups.stream,
          destination: binder,
        ),
        Brightness.dark,
      );
      groups.add(<MTGDeck>[binder]);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue scanning'));
      await tester.pumpAndSettle();
      final ScanSessionItem item = tester
          .widget<GuidedCameraScreen>(find.byType(GuidedCameraScreen))
          .session!
          .items
          .single;
      final ({Future<void> closed, ScanCorrectionEditor editor}) edit =
          await _openCorrection(tester, item);
      edit.editor.onConfirmed(_choice(item, Finish.nonfoil));
      await tester.pump();
      expect(drafts.started.isCompleted, isTrue);
      groups.add(<MTGDeck>[]);
      await tester.pump();
      drafts.release.complete();
      await tester.pumpAndSettle();
      await edit.closed;
      expect(queue.count, 0);
      expect(storage.entries, isEmpty);
      expect(drafts.items.single.id, 'first');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Later advances an unmatched card without approving it and keeps its retained capture',
    (WidgetTester tester) async {
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async => writes.add(entry),
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('unmatched'),
        _draft('uncertain', name: 'Counterspell', uncertain: true),
      ]);
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      await tester.tap(find.text('Check (2)'));
      await tester.pumpAndSettle();
      expect(find.text('No match'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('printing-search')),
        findsOneWidget,
      );
      await tester.tap(
        find
            .byKey(const ValueKey<String>('scan-correction-later'))
            .hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ScanCorrectionEditor>(find.byType(ScanCorrectionEditor))
            .initialResolution!
            .candidates
            .single
            .card
            .name,
        'Counterspell',
      );
      expect(drafts.items.first.approval, isNull);
      expect(queue.count, 0);
      await tester.tap(find.byKey(const ValueKey<String>('printing-confirm')));
      await tester.pumpAndSettle();
      expect(queue.entries.single.operationId, 'uncertain');
      await _expireUndo(tester);
      expect(drafts.items.single.id, 'unmatched');
      expect(drafts.items.single.approval, isNull);
      expect(writes.single.operationId, 'uncertain');
      expect(find.text('Check (1)').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final bool failPersistence in <bool>[false, true]) {
    testWidgets(
      'batch navigation waits for local persistence ${failPersistence ? 'failure' : 'success'} then permits back',
      (WidgetTester tester) async {
        final ScanQueue queue = ScanQueue(
          userId: 'fixture',
          now: () => _queueNow,
          storage: _Storage(),
          writer: (ScanQueueEntry _) async {},
        );
        addTearDown(queue.dispose);
        final _HeldPersistenceDrafts drafts = _HeldPersistenceDrafts(
          <ScanDraftItem>[_draft('held', reviewed: true, selected: true)],
          failPersistence: failPersistence,
        );
        await _show(
          tester,
          const Scaffold(child: Text('Previous route')),
          Brightness.dark,
        );
        unawaited(
          Arcane.push<void>(
            tester.element(find.text('Previous route')),
            _screen(queue, drafts: drafts),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await drafts.started.future;
        await tester.pump();
        final PopScope<Object?> scope = tester.widget<PopScope<Object?>>(
          find
              .descendant(
                of: find.byType(ScanScreen),
                matching: find.byType(PopScope<Object?>),
              )
              .first,
        );
        expect(scope.canPop, isFalse);
        final Finder back = find.widgetWithIcon(IconButton, Icons.arrow_left);
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          expect(back, findsNothing);
        } else {
          expect(tester.widget<IconButton>(back).onPressed, isNull);
        }
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.byType(ScanScreen), findsOneWidget);
        expect(drafts.removed, isEmpty);
        expect(queue.count, 0);
        drafts.release.complete();
        await tester.pumpAndSettle();
        expect(find.byType(ScanScreen), findsOneWidget);
        expect(drafts.items, hasLength(1));
        expect(drafts.removed, isEmpty);
        if (!failPersistence) {
          expect(queue.canUndo('held'), isTrue);
          await _expireUndo(tester);
          expect(drafts.items, isEmpty);
          expect(drafts.removed, <String>['held']);
        }
        if (defaultTargetPlatform != TargetPlatform.iOS) {
          expect(tester.widget<IconButton>(back).onPressed, isNotNull);
        }
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(ScanScreen), findsNothing);
        expect(find.text('Previous route').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant(<TargetPlatform>{
        TargetPlatform.iOS,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets(
    'clear captures removes the batch while retaining pending uploads',
    (WidgetTester tester) async {
      int writes = 0;
      final ScanQueueEntry pending = ScanQueueEntry(
        operationId: 'already-approved',
        card: cardFromScryfall(_printing(), finish: Finish.nonfoil),
        quantity: 2,
        createdAt: DateTime.utc(2026, 10, 12),
      );
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(<ScanQueueEntry>[pending]),
        writer: (ScanQueueEntry _) async {
          writes++;
        },
      );
      addTearDown(queue.dispose);
      queue.pauseUploads();
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('unreviewed', uncertain: true),
        _draft('reviewed', reviewed: true),
      ]);
      await _show(
        tester,
        _screen(queue, drafts: drafts),
        Brightness.dark,
        scale: 2,
      );
      expect(find.byType(AppBar), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey<String>('scan-discard-remaining')),
      );
      await tester.pumpAndSettle();
      expect(drafts.clears, 1);
      expect(drafts.items, isEmpty);
      expect(
        drafts.removed,
        unorderedEquals(<String>['unreviewed', 'reviewed']),
      );
      expect(queue.count, 1);
      expect(queue.entryAt(0).operationId, pending.operationId);
      expect(writes, 0);
      expect(find.text('Continue scanning').hitTestable(), findsOneWidget);
      expect(find.text('Added 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'reviewed capture removes directly while pending additions stay saved',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        final ScanQueueEntry pending = ScanQueueEntry(
          operationId: 'pending-addition',
          card: cardFromScryfall(_printing(), finish: Finish.nonfoil),
          quantity: 2,
          createdAt: DateTime.utc(2026, 10, 12),
        );
        int writes = 0;
        final ScanQueue queue = ScanQueue(
          userId: 'fixture',
          now: () => _queueNow,
          storage: _Storage(<ScanQueueEntry>[pending]),
          writer: (ScanQueueEntry _) async {
            writes++;
          },
        );
        addTearDown(queue.dispose);
        queue.pauseUploads();
        final _Drafts drafts = _Drafts(<ScanDraftItem>[
          _draft('reviewed', reviewed: true),
        ]);
        await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
        await tester.tap(find.bySemanticsLabel('Discard capture'));
        await tester.pumpAndSettle();
        expect(find.byType(DialogConfirm), findsNothing);
        expect(drafts.removed, contains('reviewed'));
        expect(drafts.items, isEmpty);
        expect(queue.count, 1);
        expect(queue.entryAt(0).operationId, pending.operationId);
        expect(writes, 0);
        expect(find.text('Continue scanning').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('failed clear keeps drafts and exposes a retryable error', (
    WidgetTester tester,
  ) async {
    final ScanQueue queue = ScanQueue(
      userId: 'fixture',
      now: () => _queueNow,
      storage: _Storage(),
      writer: (ScanQueueEntry _) async {},
    );
    addTearDown(queue.dispose);
    final _Drafts drafts = _Drafts(<ScanDraftItem>[
      _draft('retained', uncertain: true),
    ])..failClear = true;
    await _show(tester, _screen(queue, drafts: drafts), Brightness.light);
    await tester.tap(
      find.byKey(const ValueKey<String>('scan-discard-remaining')),
    );
    await tester.pumpAndSettle();
    expect(drafts.items.single.id, 'retained');
    expect(find.text('Attention').hitTestable(), findsOneWidget);
    drafts.failClear = false;
    await tester.tap(
      find.byKey(const ValueKey<String>('scan-discard-remaining')),
    );
    await tester.pumpAndSettle();
    expect(drafts.items, isEmpty);
    expect(drafts.clears, 2);
    expect(find.text('Attention'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('failed capture restore still allows a durable reset', (
    WidgetTester tester,
  ) async {
    final ScanQueue queue = ScanQueue(
      userId: 'fixture',
      now: () => _queueNow,
      storage: _Storage(),
      writer: (ScanQueueEntry _) async {},
    );
    addTearDown(queue.dispose);
    final _BrokenDrafts drafts = _BrokenDrafts(<ScanDraftItem>[
      _draft('invalid'),
    ]);
    await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
    final Finder clear = find.byKey(
      const ValueKey<String>('scan-discard-remaining'),
    );
    expect(tester.widget<GhostButton>(clear).onPressed, isNotNull);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(drafts.items, isEmpty);
    expect(find.text('Attention'), findsNothing);
    expect(
      tester
          .widget<SecondaryButton>(
            find.widgetWithText(SecondaryButton, 'Continue scanning'),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'failed upload restore does not block clearing captures or hide recovery',
    (WidgetTester tester) async {
      final _UnreadableUploads storage = _UnreadableUploads();
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: storage,
        writer: (ScanQueueEntry _) async {},
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('retained', exact: true),
      ]);
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      await tester.tap(
        find.byKey(const ValueKey<String>('scan-discard-remaining')),
      );
      await tester.pumpAndSettle();
      expect(drafts.items, isEmpty);
      expect(queue.loaded, isFalse);
      expect(find.text('Retry restore').hitTestable(), findsOneWidget);
      expect(find.text('Restoring…'), findsNothing);
      storage.fail = false;
      await tester.tap(find.text('Retry restore'));
      await tester.pumpAndSettle();
      expect(queue.loaded, isTrue);
      expect(find.text('Attention'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'camera controls clear the same batch when camera access is unavailable',
    (WidgetTester tester) async {
      final CameraPlatform previous = CameraPlatform.instance;
      CameraPlatform.instance = _UnavailableCamera();
      addTearDown(() => CameraPlatform.instance = previous);
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry _) async {},
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('captured', uncertain: true),
      ]);
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      await tester.tap(find.text('Continue scanning'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('camera-adjustments')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('camera-clear-captures')),
      );
      for (int i = 0; i < 20 && drafts.clears == 0; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 350));
      expect(drafts.items, isEmpty);
      expect(drafts.clears, 1);
      expect(find.byType(ScanCameraDrawer), findsOneWidget);
      expect(find.textContaining('Camera access denied'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final bool reviewed in <bool>[false, true]) {
    testWidgets(
      'verified cards queue once with Undo in the camera drawer, reviewed=$reviewed',
      (WidgetTester tester) async {
        final CameraPlatform previous = CameraPlatform.instance;
        CameraPlatform.instance = _UnavailableCamera();
        addTearDown(() => CameraPlatform.instance = previous);
        int writes = 0;
        final ScanQueue queue = ScanQueue(
          userId: 'fixture',
          now: () => _queueNow,
          storage: _Storage(),
          writer: (ScanQueueEntry _) async {
            writes++;
          },
        );
        addTearDown(queue.dispose);
        final _Drafts drafts = _Drafts(<ScanDraftItem>[
          _draft('first', exact: true, reviewed: reviewed, selected: reviewed),
          _draft(
            'second',
            name: 'Counterspell',
            exact: true,
            reviewed: reviewed,
            selected: reviewed,
          ),
        ]);
        await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
        await tester.tap(find.text('Continue scanning'));
        await tester.pumpAndSettle();
        expect(find.byType(GuidedCameraScreen), findsOneWidget);
        expect(find.byType(ScanCameraDrawer), findsOneWidget);
        expect(find.byType(ScanCorrectionEditor), findsNothing);
        expect(find.text('Undo').hitTestable(), findsOneWidget);
        expect(find.textContaining('Check ('), findsNothing);
        expect(find.byType(GuidedCameraScreen), findsOneWidget);
        expect(drafts.items, hasLength(2));
        expect(writes, 0);
        expect(
          drafts.items.every((ScanDraftItem item) => item.selected),
          isTrue,
        );
        expect(
          drafts.items.map((ScanDraftItem item) => item.approval!.quantity),
          everyElement(reviewed ? 2 : 1),
        );
        expect(
          drafts.items.map((ScanDraftItem item) => item.approval!.card.finish),
          everyElement(Finish.nonfoil),
        );
        expect(queue.count, 2);
        expect(queue.canUndo('first'), isTrue);
        expect(queue.canUndo('second'), isTrue);
        await _expireUndo(tester);
        expect(writes, 2);
        expect(drafts.items, isEmpty);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'mixed batch opens only uncertain printing and queues its explicit finish confirmation',
    (WidgetTester tester) async {
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async => writes.add(entry),
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('exact', exact: true),
        _draft('uncertain', name: 'Counterspell', uncertain: true),
      ]);
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      expect(find.text('Check (1)').hitTestable(), findsOneWidget);
      expect(find.text('Undo').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Check (1)'));
      await tester.pumpAndSettle();
      final ScanCorrectionEditor review = tester.widget<ScanCorrectionEditor>(
        find.byType(ScanCorrectionEditor),
      );
      expect(
        review.initialResolution!.candidates.single.card.name,
        'Counterspell',
      );
      expect(review.progressLabel, 'Card 1 of 1');
      expect(review.confirmLabel, 'Confirm');
      expect(
        drafts.items
            .firstWhere((ScanDraftItem item) => item.id == 'exact')
            .approval!
            .card
            .finish,
        Finish.nonfoil,
      );
      expect(writes, isEmpty);
      expect(queue.count, 1);
      await _choose<Finish>(tester, 'Foil');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(queue.count, 2);
      expect(writes, isEmpty);
      await _expireUndo(tester);
      expect(writes.map((ScanQueueEntry entry) => entry.operationId), <String>[
        'exact',
        'uncertain',
      ]);
      expect(writes.first.card.finish, Finish.nonfoil);
      expect(writes.last.card.finish, Finish.foil);
      expect(drafts.items, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'camera tray removes one capture and confirms its sibling in place',
    (WidgetTester tester) async {
      final CameraPlatform previous = CameraPlatform.instance;
      CameraPlatform.instance = _UnavailableCamera();
      addTearDown(() => CameraPlatform.instance = previous);
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry _) async {},
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('first', uncertain: true),
        _draft('second', name: 'Counterspell', uncertain: true),
      ]);
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      await tester.tap(find.text('Continue scanning'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('camera-drawer-needs-check')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('camera-drawer-remove-first')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GuidedCameraScreen), findsOneWidget);
      expect(find.byType(ScanCorrectionEditor), findsNothing);
      expect(drafts.items.single.id, 'second');
      expect(queue.count, 0);
      await tester.tap(
        find.byKey(const ValueKey<String>('camera-drawer-check-second')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(queue.entries.single.operationId, 'second');
      expect(queue.entries.single.card.name, 'Counterspell');
      expect(find.byType(GuidedCameraScreen), findsOneWidget);
      await _expireUndo(tester);
      expect(drafts.items, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'removing one card in review advances and only confirms remaining cards after restart',
    (WidgetTester tester) async {
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async => writes.add(entry),
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('first', uncertain: true),
        _draft('second', name: 'Counterspell', uncertain: true),
        _draft('third', name: 'Doom Blade', uncertain: true),
      ]);
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      await tester.tap(find.text('Check (3)'));
      await tester.pumpAndSettle();
      expect(find.text('Remove').hitTestable(), findsOneWidget);
      expect(find.text('Cancel'), findsNothing);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(drafts.removed, <String>['first']);
      expect(drafts.items.map((ScanDraftItem item) => item.id), <String>[
        'second',
        'third',
      ]);
      expect(
        tester
            .widget<ScanCorrectionEditor>(find.byType(ScanCorrectionEditor))
            .initialResolution!
            .candidates
            .single
            .card
            .name,
        'Counterspell',
      );
      expect(queue.count, 0);
      await tester.tap(
        find.byKey(const ValueKey<String>('scan-correction-close')),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await _show(tester, _screen(queue, drafts: drafts), Brightness.light);
      expect(find.text('Check (2)').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Check (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(queue.count, 2);
      await _expireUndo(tester);
      expect(writes.map((ScanQueueEntry entry) => entry.operationId), <String>[
        'second',
        'third',
      ]);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'exact preparation preserves a reviewed foil quantity and deck section',
    (WidgetTester tester) async {
      final CameraPlatform previous = CameraPlatform.instance;
      CameraPlatform.instance = _UnavailableCamera();
      addTearDown(() => CameraPlatform.instance = previous);
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async => writes.add(entry),
      );
      addTearDown(queue.dispose);
      final MTGDeck deck = MTGDeck(name: 'Existing deck')..id = 'deck';
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft(
          'reviewed',
          reviewed: true,
          selected: true,
          approvedFinish: Finish.foil,
          approvedQuantity: 4,
          approvedDeckId: 'deck',
          approvedSection: DeckSection.sideboard,
        ),
        _draft('exact', exact: true),
      ]);
      await _show(
        tester,
        _screen(queue, drafts: drafts, decks: <MTGDeck>[deck]),
        Brightness.dark,
      );
      await tester.tap(find.text('Continue scanning'));
      await tester.pumpAndSettle();
      expect(find.byType(ScanCameraDrawer), findsOneWidget);
      expect(find.byType(GuidedCameraScreen), findsOneWidget);
      expect(find.byType(ScanCorrectionEditor), findsNothing);
      expect(writes, isEmpty);
      final ScanQueueApproval approval = drafts.items
          .firstWhere((ScanDraftItem item) => item.id == 'reviewed')
          .approval!;
      expect(approval.card.finish, Finish.foil);
      expect(approval.quantity, 4);
      expect(approval.deckId, 'deck');
      expect(approval.deckSection, DeckSection.sideboard);
      expect(queue.count, 2);
      await _expireUndo(tester);
      final ScanQueueEntry saved = writes.singleWhere(
        (ScanQueueEntry entry) => entry.operationId == 'reviewed',
      );
      expect(saved.card.finish, Finish.foil);
      expect(saved.quantity, 4);
      expect(saved.deckId, 'deck');
      expect(saved.deckSection, DeckSection.sideboard);
      expect(writes, hasLength(2));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'held exact staging locks tile mutations and stale review callbacks while Clear remains available',
    (WidgetTester tester) async {
      final CameraPlatform previous = CameraPlatform.instance;
      CameraPlatform.instance = _UnavailableCamera();
      addTearDown(() => CameraPlatform.instance = previous);
      int writes = 0;
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry _) async {
          writes++;
        },
      );
      addTearDown(queue.dispose);
      final _HeldPersistenceDrafts drafts = _HeldPersistenceDrafts(
        <ScanDraftItem>[_draft('exact', uncertain: true)],
        failPersistence: false,
      );
      addTearDown(() {
        if (!drafts.release.isCompleted) drafts.release.complete();
      });
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      final Finder tile = find.byKey(const ValueKey<String>('scan-card-exact'));
      final Finder review = find.descendant(
        of: tile,
        matching: find.byType(GhostButton),
      );
      final VoidCallback staleReview = tester
          .widget<GhostButton>(review)
          .onPressed!;
      await tester.tap(find.text('Continue scanning'));
      await tester.pumpAndSettle();
      final ScanSession session = tester
          .widget<GuidedCameraScreen>(find.byType(GuidedCameraScreen))
          .session!;
      _closeCamera(tester);
      await tester.pumpAndSettle();
      session.items.single.resolution = _draft('exact', exact: true).resolution;
      session.changed();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await drafts.started.future;
      final Finder selection = find.descendant(
        of: tile,
        matching: find.widgetWithIcon(IconButton, Icons.check_square),
      );
      final Finder discard = find.descendant(
        of: tile,
        matching: find.widgetWithIcon(IconButton, Icons.x),
      );
      expect(tester.widget<GhostButton>(review).onPressed, isNull);
      expect(tester.widget<IconButton>(selection).onPressed, isNull);
      expect(tester.widget<IconButton>(discard).onPressed, isNull);
      final Finder clear = find.byKey(
        const ValueKey<String>('scan-discard-remaining'),
      );
      expect(clear.hitTestable(), findsOneWidget);
      expect(tester.widget<GhostButton>(clear).onPressed, isNotNull);
      final ScanQueueApproval staged = session.items.single.approval!;
      for (final Finder control in <Finder>[review, selection, discard]) {
        final Rect bounds = tester.getRect(control);
        expect(bounds.intersect(const Rect.fromLTWH(0, 0, 320, 640)), bounds);
        await tester.tapAt(bounds.center);
        await tester.pump();
      }
      staleReview();
      await tester.pump();
      expect(find.byType(ScanCorrectionEditor), findsNothing);
      expect(session.items, hasLength(1));
      expect(session.items.single.selected, isTrue);
      expect(session.items.single.approval, same(staged));
      expect(drafts.removed, isEmpty);
      expect(queue.count, 0);
      expect(writes, 0);
      drafts.release.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<GhostButton>(review).onPressed, isNull);
      expect(tester.widget<IconButton>(selection).onPressed, isNull);
      expect(find.text('Undo').hitTestable(), findsOneWidget);
      expect(queue.count, 1);
      expect(queue.canUndo('exact'), isTrue);
      expect(writes, 0);
      await _expireUndo(tester);
      expect(writes, 1);
      expect(drafts.items, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'clearing while exact staging is pending cannot resurrect approvals or upload',
    (WidgetTester tester) async {
      final CameraPlatform previous = CameraPlatform.instance;
      CameraPlatform.instance = _UnavailableCamera();
      addTearDown(() => CameraPlatform.instance = previous);
      int writes = 0;
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry _) async {
          writes++;
        },
      );
      addTearDown(queue.dispose);
      final _HeldPersistenceDrafts drafts = _HeldPersistenceDrafts(
        <ScanDraftItem>[_draft('exact', uncertain: true)],
        failPersistence: false,
      );
      addTearDown(() {
        if (!drafts.release.isCompleted) drafts.release.complete();
      });
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      await tester.tap(find.text('Continue scanning'));
      await tester.pumpAndSettle();
      final ScanSession session = tester
          .widget<GuidedCameraScreen>(find.byType(GuidedCameraScreen))
          .session!;
      _closeCamera(tester);
      await tester.pumpAndSettle();
      session.items.single.resolution = _draft('exact', exact: true).resolution;
      session.changed();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await drafts.started.future;
      expect(
        find
            .byKey(const ValueKey<String>('scan-discard-remaining'))
            .hitTestable(),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('scan-discard-remaining')),
      );
      await tester.pump();
      expect(session.clearingCaptures, isTrue);
      drafts.release.complete();
      for (
        int attempt = 0;
        attempt < 30 && session.clearingCaptures;
        attempt++
      ) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(session.clearingCaptures, isFalse);
      expect(drafts.items, isEmpty);
      expect(find.byType(ScanCorrectionEditor), findsNothing);
      expect(find.textContaining('Add ('), findsNothing);
      expect(queue.count, 0);
      expect(writes, 0);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'new exact arrivals are staged and uncertain arrivals still require confirmation',
    (WidgetTester tester) async {
      final CameraPlatform previous = CameraPlatform.instance;
      CameraPlatform.instance = _UnavailableCamera();
      addTearDown(() => CameraPlatform.instance = previous);
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async => writes.add(entry),
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('exact', exact: true),
        _draft('uncertain', uncertain: true),
      ]);
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      await tester.tap(find.text('Continue scanning'));
      await tester.pumpAndSettle();
      final ScanSession session = tester
          .widget<GuidedCameraScreen>(find.byType(GuidedCameraScreen))
          .session!;
      _closeCamera(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check (1)'));
      await tester.pumpAndSettle();
      session.add(
        ScanSessionItem.fromDraft(
          _draft('new-exact', name: 'Doom Blade', exact: true),
        ),
      );
      session.add(
        ScanSessionItem.fromDraft(
          _draft('new-uncertain', name: 'Counterspell', uncertain: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      expect(
        tester
            .widget<ScanCorrectionEditor>(find.byType(ScanCorrectionEditor))
            .initialResolution!
            .candidates
            .single
            .card
            .name,
        'Counterspell',
      );
      expect(find.text('Card 2 of 2').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(queue.count, 4);
      expect(writes, isEmpty);
      await _expireUndo(tester);
      expect(
        writes.map((ScanQueueEntry entry) => entry.operationId).toSet(),
        <String>{'exact', 'uncertain', 'new-exact', 'new-uncertain'},
      );
      expect(writes, hasLength(4));
      expect(drafts.items, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'missing fixed destination blocks automatic Normal without Collection fallback',
    (WidgetTester tester) async {
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async => writes.add(entry),
      );
      addTearDown(queue.dispose);
      final MTGDeck binder = MTGDeck(
        name: 'Binder',
        kind: CollectionGroupKind.binder,
      )..id = 'binder';
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft(
          'exact',
          exact: true,
          reviewed: true,
          selected: true,
          approvedDeckId: 'binder',
        ),
      ]);
      await _show(
        tester,
        ScanScreen(
          userId: 'fixture',
          queue: queue,
          draftStore: drafts,
          resolver: ScanResolver(catalog: _Catalog()),
          decks: Stream<List<MTGDeck>>.value(<MTGDeck>[]),
          destination: binder,
        ),
        Brightness.dark,
      );
      expect(
        find.bySemanticsLabel('Needs attention: Destination unavailable'),
        findsOneWidget,
      );
      expect(queue.count, 0);
      expect(drafts.items.single.approval!.deckId, 'binder');
      expect(drafts.items.single.selected, isTrue);
      await _expireUndo(tester);
      expect(writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('camera back returns to batch without starting review', (
    WidgetTester tester,
  ) async {
    final CameraPlatform previous = CameraPlatform.instance;
    CameraPlatform.instance = _UnavailableCamera();
    addTearDown(() => CameraPlatform.instance = previous);
    final ScanQueue queue = ScanQueue(
      userId: 'fixture',
      now: () => _queueNow,
      storage: _Storage(),
      writer: (ScanQueueEntry _) async {},
    );
    addTearDown(queue.dispose);
    final _Drafts drafts = _Drafts(<ScanDraftItem>[
      _draft('first', exact: true),
    ]);
    await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
    await tester.tap(find.text('Continue scanning'));
    await tester.pumpAndSettle();
    _closeCamera(tester);
    await tester.pumpAndSettle();
    expect(find.byType(ScanCorrectionEditor), findsNothing);
    expect(find.text('Undo').hitTestable(), findsOneWidget);
    expect(drafts.items.single.approval!.card.finish, Finish.nonfoil);
    expect(queue.canUndo('first'), isTrue);
    await _expireUndo(tester);
    expect(queue.count, 0);
    expect(drafts.items, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  for (final bool captureFails in <bool>[false, true]) {
    testWidgets(
      'Rescan ${captureFails ? 'failure then cancel' : 'cancel'} retains the original observation without an addition',
      (WidgetTester tester) async {
        final CameraPlatform previous = CameraPlatform.instance;
        CameraPlatform.instance = _UnavailableCamera();
        addTearDown(() => CameraPlatform.instance = previous);
        final _ReplacementRecognizer recognizer = _ReplacementRecognizer()
          ..fail = captureFails;
        final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
        final ScanQueue queue = ScanQueue(
          userId: 'fixture',
          now: () => _queueNow,
          storage: _Storage(),
          writer: (ScanQueueEntry entry) async => writes.add(entry),
        );
        addTearDown(queue.dispose);
        final _Drafts drafts = _Drafts(<ScanDraftItem>[
          _draft('original', path: 'original-crop.jpg'),
        ]);
        await _show(
          tester,
          _screen(queue, drafts: drafts, recognizer: recognizer),
          Brightness.dark,
        );
        await tester.tap(find.text('Check (1)').hitTestable());
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .byKey(const ValueKey<String>('scan-correction-rescan'))
              .hitTestable(),
        );
        await tester.pumpAndSettle();
        final GuidedCameraScreen camera = tester.widget<GuidedCameraScreen>(
          find.byType(GuidedCameraScreen),
        );
        expect(camera.automaticCapture, isTrue);
        expect(camera.continuous, isFalse);
        expect(camera.multipleCards, isFalse);
        expect(camera.session, isNull);
        expect(camera.onUnidentifiedPhotoCaptured, isNull);
        expect(drafts.items.single.id, 'original');
        expect(drafts.items.single.crop.imagePath, 'original-crop.jpg');
        expect(queue.count, 0);
        if (captureFails) {
          expect(
            await camera.onCaptured!('fresh-photo.jpg', <List<ScanPoint>>[]),
            isFalse,
          );
          expect(drafts.rescanCameraOwnership, <bool>[true]);
          await tester.pump();
          expect(drafts.items.single.crop.imagePath, 'original-crop.jpg');
        }
        _closeCamera(tester);
        await tester.pumpAndSettle();
        expect(find.byType(ScanCorrectionEditor), findsNothing);
        expect(drafts.items.single.id, 'original');
        expect(drafts.items.single.approval, isNull);
        expect(drafts.items.single.crop.imagePath, 'original-crop.jpg');
        expect(queue.count, 0);
        await _expireUndo(tester);
        expect(writes, isEmpty);
        expect(find.text('Check (1)').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'automatic Rescan rejects a multi-card handoff and replaces one original before review',
    (WidgetTester tester) async {
      final CameraPlatform previous = CameraPlatform.instance;
      CameraPlatform.instance = _UnavailableCamera();
      addTearDown(() => CameraPlatform.instance = previous);
      final _ReplacementRecognizer recognizer = _ReplacementRecognizer();
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async => writes.add(entry),
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('original', path: 'original-crop.jpg'),
      ]);
      await _show(
        tester,
        _screen(queue, drafts: drafts, recognizer: recognizer),
        Brightness.dark,
      );
      await tester.tap(find.text('Check (1)').hitTestable());
      await tester.pumpAndSettle();
      final ScanCrop originalCrop = tester
          .widget<ScanCorrectionEditor>(find.byType(ScanCorrectionEditor))
          .crop;
      await tester.tap(
        find
            .byKey(const ValueKey<String>('scan-correction-rescan'))
            .hitTestable(),
      );
      await tester.pumpAndSettle();
      final GuidedCameraScreen camera = tester.widget<GuidedCameraScreen>(
        find.byType(GuidedCameraScreen),
      );
      const List<ScanPoint> target = <ScanPoint>[
        ScanPoint(.1, .1),
        ScanPoint(.9, .1),
        ScanPoint(.9, .9),
        ScanPoint(.1, .9),
      ];
      expect(
        await camera.onFocusStackCaptured!(
          <String>['fresh-photo.jpg'],
          <List<ScanPoint>>[],
          'replacement',
          <List<ScanPoint>>[target, target],
        ),
        isFalse,
      );
      expect(recognizer.calls, 0);
      expect(drafts.rescanCameraOwnership, isEmpty);
      expect(drafts.items.single.crop.imagePath, 'original-crop.jpg');
      expect(
        await camera.onFocusStackCaptured!(
          <String>['fresh-photo.jpg'],
          <List<ScanPoint>>[],
          'replacement',
          <List<ScanPoint>>[target],
        ),
        isTrue,
      );
      expect(recognizer.calls, 1);
      expect(drafts.rescanCameraOwnership, <bool>[true]);
      expect(drafts.items.single.id, 'original');
      expect(drafts.items.single.crop.imagePath, 'replacement-crop.jpg');
      expect(queue.count, 0);
      _closeCamera(tester);
      await tester.pumpAndSettle();
      final ScanCorrectionEditor review = tester.widget<ScanCorrectionEditor>(
        find.byType(ScanCorrectionEditor),
      );
      expect(review.crop.imagePath, 'replacement-crop.jpg');
      expect(identical(review.crop, originalCrop), isFalse);
      expect(review.initialSelection, isNull);
      expect(drafts.items, hasLength(1));
      expect(queue.count, 0);
      await tester.pump(const Duration(seconds: 2));
      expect(queue.count, 0);
      expect(writes, isEmpty);
      final Finder confirm = find
          .byKey(const ValueKey<String>('printing-confirm'))
          .hitTestable();
      for (
        int attempt = 0;
        attempt < 20 &&
            (confirm.evaluate().isEmpty ||
                tester.widget<PrimaryButton>(confirm).onPressed == null);
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      final ScanCorrectionEditor resolvedReview = tester
          .widget<ScanCorrectionEditor>(find.byType(ScanCorrectionEditor));
      expect(
        confirm,
        findsOneWidget,
        reason:
            'phase=${resolvedReview.phase}, '
            'error=${resolvedReview.lookupError}, '
            'candidates=${resolvedReview.initialResolution?.candidates.length}',
      );
      expect(tester.widget<PrimaryButton>(confirm).onPressed, isNotNull);
      expect(queue.count, 0);
      expect(writes, isEmpty);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(queue.entries.single.operationId, 'original');
      await _expireUndo(tester);
      expect(writes, hasLength(1));
      expect(writes.single.operationId, 'original');
      expect(drafts.items, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'restored pending Rescan blocks a verified old observation and Clear cannot resurrect it',
    (WidgetTester tester) async {
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async => writes.add(entry),
      );
      addTearDown(queue.dispose);
      final ScanDraftItem original = _draft(
        'pending-original',
        path: 'original-crop.jpg',
        exact: true,
      );
      final _Drafts drafts = _Drafts(<ScanDraftItem>[original]);
      drafts.rescans[original.id] = ScanDraftRescan(
        itemId: original.id,
        requestId: 'restored-rescan',
        original: original,
      );
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      expect(find.text('Check (1)').hitTestable(), findsOneWidget);
      expect(drafts.items.single.id, original.id);
      expect(drafts.items.single.approval, isNull);
      await _expireUndo(tester);
      expect(queue.count, 0);
      expect(writes, isEmpty);
      await tester.tap(
        find
            .byKey(const ValueKey<String>('scan-discard-remaining'))
            .hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(drafts.items, isEmpty);
      expect(drafts.rescans, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      await _expireUndo(tester);
      expect(queue.count, 0);
      expect(writes, isEmpty);
      expect(drafts.items, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'restored replacement uses fresh printing with original quantity finish and deck choices',
    (WidgetTester tester) async {
      final MTGDeck deck = MTGDeck(name: 'Retained deck')..id = 'retained-deck';
      final ScanDraftItem fresh = _draft('replacement', exact: true);
      final ScanDraftItem original = ScanDraftItem(
        id: fresh.id,
        photoId: 'old-photo',
        crop: fresh.crop,
        approval: ScanQueueApproval(
          operationId: fresh.id,
          card: cardFromScryfall(
            _printing(),
            finish: Finish.foil,
          ).copyWith(scryfallId: 'old-printing'),
          quantity: 3,
          deckId: deck.id,
          deckSection: DeckSection.sideboard,
        ),
      );
      final _Drafts drafts = _Drafts(<ScanDraftItem>[fresh]);
      drafts.rescans[fresh.id] = ScanDraftRescan(
        itemId: fresh.id,
        requestId: 'completed-replacement',
        original: original,
        complete: true,
      );
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async => writes.add(entry),
      );
      addTearDown(queue.dispose);
      await _show(
        tester,
        _screen(queue, drafts: drafts, decks: <MTGDeck>[deck]),
        Brightness.dark,
      );
      expect(queue.entries.single.operationId, fresh.id);
      expect(queue.entries.single.card.printingId, _printing().id);
      expect(queue.entries.single.card.printingId, isNot('old-printing'));
      expect(queue.entries.single.quantity, 3);
      expect(queue.entries.single.card.finish, Finish.foil);
      expect(queue.entries.single.deckId, deck.id);
      expect(queue.entries.single.deckSection, DeckSection.sideboard);
      expect(writes, isEmpty);
      await _expireUndo(tester);
      expect(writes, hasLength(1));
      expect(drafts.items, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final bool cancel in <bool>[false, true]) {
    testWidgets(
      'container scan queues confirmed cards without closing the continuous session, cancel=$cancel',
      (WidgetTester tester) async {
        final CameraPlatform previous = CameraPlatform.instance;
        CameraPlatform.instance = _UnavailableCamera();
        addTearDown(() => CameraPlatform.instance = previous);
        final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
        final ScanQueue queue = ScanQueue(
          userId: 'fixture',
          now: () => _queueNow,
          storage: _Storage(),
          writer: (ScanQueueEntry entry) async {
            writes.add(entry);
          },
        );
        addTearDown(queue.dispose);
        final MTGDeck binder = MTGDeck(
          name: 'Trade binder',
          kind: CollectionGroupKind.binder,
        )..id = 'binder';
        final _Drafts drafts = _Drafts(<ScanDraftItem>[
          _draft(
            'first',
            uncertain: true,
            defaults: const ScanCaptureDefaults(deckId: 'binder'),
          ),
          _draft(
            'second',
            name: 'Counterspell',
            uncertain: true,
            defaults: const ScanCaptureDefaults(deckId: 'binder'),
          ),
        ]);
        await _show(
          tester,
          Builder(
            builder: (BuildContext context) => Scaffold(
              child: Center(
                child: SecondaryButton(
                  onPressed: () => Arcane.push<void>(
                    context,
                    _screen(queue, drafts: drafts, destination: binder),
                  ),
                  child: const Text('Open binder scanner'),
                ),
              ),
            ),
          ),
          Brightness.dark,
        );
        await tester.tap(find.text('Open binder scanner'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Continue scanning'));
        await tester.pumpAndSettle();
        _closeCamera(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Check (2)'));
        await tester.pumpAndSettle();
        final ScanCorrectionEditor review = tester.widget<ScanCorrectionEditor>(
          find.byType(ScanCorrectionEditor),
        );
        expect(review.preferredDeckId, 'binder');
        expect(review.decks.single.id, 'binder');
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(writes, isEmpty);
        if (cancel) {
          tester
              .widget<ScanCorrectionEditor>(find.byType(ScanCorrectionEditor))
              .onClose();
        } else {
          await tester.tap(find.text('Confirm'));
        }
        await tester.pumpAndSettle();
        if (cancel) {
          expect(find.byType(ScanScreen), findsOneWidget);
          expect(drafts.items, hasLength(2));
          expect(writes, isEmpty);
          expect(queue.count, 1);
          await _expireUndo(tester);
          expect(writes.single.operationId, 'first');
          expect(drafts.items.single.id, 'second');
        } else {
          expect(find.byType(ScanScreen), findsOneWidget);
          expect(queue.count, 2);
          await _expireUndo(tester);
          expect(drafts.items, isEmpty);
          expect(writes, hasLength(2));
          expect(
            writes.map((ScanQueueEntry entry) => entry.deckId),
            everyElement('binder'),
          );
          expect(
            writes.map((ScanQueueEntry entry) => entry.deckSection),
            everyElement(DeckSection.mainboard),
          );
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets('a container removed during review cannot receive the approval', (
    WidgetTester tester,
  ) async {
    final CameraPlatform previous = CameraPlatform.instance;
    CameraPlatform.instance = _UnavailableCamera();
    addTearDown(() => CameraPlatform.instance = previous);
    final StreamController<List<MTGDeck>> groups =
        StreamController<List<MTGDeck>>();
    addTearDown(groups.close);
    final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
    final ScanQueue queue = ScanQueue(
      userId: 'fixture',
      now: () => _queueNow,
      storage: _Storage(),
      writer: (ScanQueueEntry entry) async {
        writes.add(entry);
      },
    );
    addTearDown(queue.dispose);
    final MTGDeck binder = MTGDeck(
      name: 'Trade binder',
      kind: CollectionGroupKind.binder,
    )..id = 'binder';
    final _Drafts drafts = _Drafts(<ScanDraftItem>[
      _draft(
        'first',
        uncertain: true,
        defaults: const ScanCaptureDefaults(deckId: 'binder'),
      ),
    ]);
    await _show(
      tester,
      ScanScreen(
        userId: 'fixture',
        queue: queue,
        draftStore: drafts,
        resolver: ScanResolver(catalog: _Catalog()),
        decks: groups.stream,
        destination: binder,
      ),
      Brightness.dark,
    );
    groups.add(<MTGDeck>[binder]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue scanning'));
    await tester.pumpAndSettle();
    _closeCamera(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check (1)'));
    await tester.pumpAndSettle();
    groups.add(<MTGDeck>[]);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ScanCorrectionEditor>(find.byType(ScanCorrectionEditor))
          .decks,
      isEmpty,
    );
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Choose an available destination'), findsOneWidget);
    expect(writes, isEmpty);
    expect(drafts.items, hasLength(1));
    await tester.tap(
      find.byKey(const ValueKey<String>('scan-correction-remove')),
    );
    await tester.pumpAndSettle();
    expect(drafts.items, isEmpty);
    expect(writes, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'review destination changes never reroute another captured card',
    (WidgetTester tester) async {
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async {
          writes.add(entry);
        },
      );
      addTearDown(queue.dispose);
      final MTGDeck binder = MTGDeck(
        name: 'Trade binder',
        kind: CollectionGroupKind.binder,
      )..id = 'binder';
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('first', uncertain: true),
        _draft('second', name: 'Counterspell', uncertain: true),
      ]);
      await _show(
        tester,
        _screen(queue, drafts: drafts, decks: <MTGDeck>[binder]),
        Brightness.dark,
      );
      await tester.tap(find.text('Check (2)'));
      await tester.pumpAndSettle();
      await _choose<String>(tester, 'Binder: Trade binder');
      await tester.tap(find.byKey(const ValueKey<String>('printing-confirm')));
      await tester.pumpAndSettle();
      final ScanCorrectionEditor second = tester.widget<ScanCorrectionEditor>(
        find.byType(ScanCorrectionEditor),
      );
      expect(second.preferredDeckId, isNull);
      expect(writes, isEmpty);
      expect(find.text('Confirm').hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('printing-confirm')));
      await tester.pumpAndSettle();
      expect(queue.count, 2);
      expect(writes, isEmpty);
      await _expireUndo(tester);
      expect(writes.map((ScanQueueEntry entry) => entry.operationId), <String>[
        'first',
        'second',
      ]);
      expect(writes.first.deckId, 'binder');
      expect(writes.last.deckId, isNull);
      expect(drafts.items, isEmpty);
      expect(queue.count, 0);
      expect(find.byType(ScanCorrectionEditor), findsNothing);
      expect(find.text('Continue scanning').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'partial review keeps both actions and never replaces an old collection approval',
    (WidgetTester tester) async {
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async {
          writes.add(entry);
        },
      );
      addTearDown(queue.dispose);
      final MTGDeck binder = MTGDeck(
        name: 'Trade binder',
        kind: CollectionGroupKind.binder,
      )..id = 'binder';
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('first', uncertain: true),
        _draft('second', name: 'Counterspell', uncertain: true),
        _draft('old', name: 'Doom Blade', reviewed: true),
      ]);
      await _show(
        tester,
        _screen(queue, drafts: drafts, decks: <MTGDeck>[binder]),
        Brightness.dark,
      );
      await tester.tap(find.text('Check (2)'));
      await tester.pumpAndSettle();
      await _choose<String>(tester, 'Binder: Trade binder');
      await tester.tap(find.byKey(const ValueKey<String>('printing-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('scan-correction-close')),
      );
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      expect(find.text('Check (1)').hitTestable(), findsOneWidget);
      expect(find.text('Undo').hitTestable(), findsOneWidget);
      if (_capturedArtwork('Doom Blade').hitTestable().evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey<String>('scan-tray-next')));
        await tester.pumpAndSettle();
      }
      await tester.tap(_capturedArtwork('Doom Blade').hitTestable());
      await tester.pumpAndSettle();
      final ScanCorrectionEditor old = tester.widget<ScanCorrectionEditor>(
        find.byType(ScanCorrectionEditor),
      );
      expect(old.initialSelection!.destinationId, isNull);
      expect(old.preferredDeckId, isNull);
      expect(find.text('Collection').hitTestable(), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('scan-correction-close')),
      );
      await tester.pumpAndSettle();
      await _expireUndo(tester);
      expect(writes.single.operationId, 'first');
      expect(writes.single.deckId, 'binder');
      expect(
        drafts.items
            .singleWhere((ScanDraftItem item) => item.id == 'old')
            .approval!
            .deckId,
        isNull,
      );
      expect(
        drafts.items
            .singleWhere((ScanDraftItem item) => item.id == 'second')
            .approval,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final Brightness brightness in Brightness.values) {
    for (final double scale in <double>[1, 2]) {
      testWidgets(
        'scan batch fits without scroll ${brightness.name} scale$scale',
        (WidgetTester tester) async {
          final ScanQueue queue = ScanQueue(
            userId: 'fixture',
            now: () => _queueNow,
            storage: _Storage(),
            writer: (ScanQueueEntry _) async {},
          );
          addTearDown(queue.dispose);
          final _Drafts drafts = _Drafts(<ScanDraftItem>[
            _draft('first', reviewed: true),
            _draft('second', name: 'Counterspell', reviewed: true),
          ]);
          await _show(
            tester,
            _screen(queue, drafts: drafts),
            brightness,
            scale: scale,
          );
          expect(find.byType(Scrollable), findsNothing);
          expect(find.text('Lightning Bolt').hitTestable(), findsOneWidget);
          expect(find.text('Continue scanning').hitTestable(), findsOneWidget);
          expect(
            _capturedArtwork('Lightning Bolt').hitTestable(),
            findsOneWidget,
          );
          expect(
            find.bySemanticsLabel('Select captured card').hitTestable(),
            scale == 1 ? findsNWidgets(2) : findsOneWidget,
          );
          if (scale > 1) {
            await tester.tap(
              find.byKey(const ValueKey<String>('scan-tray-next')),
            );
            await tester.pumpAndSettle();
          }
          expect(find.text('Counterspell').hitTestable(), findsOneWidget);
          expect(
            find
                .byKey(const ValueKey<String>('scan-discard-remaining'))
                .hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      );
    }
    testWidgets(
      'empty scan is compact and imports are secondary ${brightness.name}',
      (WidgetTester tester) async {
        final ScanQueue queue = ScanQueue(
          userId: 'fixture',
          now: () => _queueNow,
          storage: _Storage(),
          writer: (ScanQueueEntry _) async {},
        );
        addTearDown(queue.dispose);
        await _show(tester, _screen(queue), brightness, scale: 2);
        expect(find.byType(Scrollable), findsNothing);
        expect(find.text('Continue scanning').hitTestable(), findsOneWidget);
        expect(find.text('Select photos'), findsNothing);
        expect(find.text('Enter card details'), findsNothing);
        await _more(tester);
        expect(find.text('Select photos').hitTestable(), findsOneWidget);
        expect(find.text('Enter card details').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'tray paging survives removing its last page and leaves approvals untouched',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        final ScanQueue queue = ScanQueue(
          userId: 'fixture',
          now: () => _queueNow,
          storage: _Storage(),
          writer: (ScanQueueEntry _) async {},
        );
        addTearDown(queue.dispose);
        final _Drafts drafts = _Drafts(<ScanDraftItem>[
          for (int index = 0; index < 7; index++)
            _draft('card-$index', name: 'Card $index', uncertain: true),
        ]);
        await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
        for (
          int page = 0;
          page < 7 && find.text('Card 6').hitTestable().evaluate().isEmpty;
          page++
        ) {
          await tester.tap(
            find.byKey(const ValueKey<String>('scan-tray-next')),
          );
          await tester.pumpAndSettle();
        }
        expect(find.text('Card 6').hitTestable(), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey<String>('scan-card-card-6')),
            matching: find.bySemanticsLabel('Discard capture'),
          ),
        );
        await tester.pumpAndSettle();
        expect(drafts.removed, <String>['card-6']);
        expect(drafts.items, hasLength(6));
        expect(
          find
              .byKey(const ValueKey<String>('scan-tray-previous'))
              .hitTestable(),
          findsOneWidget,
        );
        expect(find.textContaining('/ 6'), findsOneWidget);
        expect(
          drafts.items.every((ScanDraftItem item) => item.approval == null),
          isTrue,
        );
        expect(queue.count, 0);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'one captured card has no redundant tray pager and remains reviewable',
    (WidgetTester tester) async {
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry _) async {},
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('single', uncertain: true),
      ]);
      await _show(
        tester,
        _screen(queue, drafts: drafts),
        Brightness.dark,
        size: const Size(320, 568),
      );
      expect(
        find.byKey(const ValueKey<String>('scan-tray-previous')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('scan-tray-next')),
        findsNothing,
      );
      expect(find.text('1–1 / 1'), findsNothing);
      await tester.tap(_capturedArtwork('Lightning Bolt').hitTestable());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('printing-confirm')).hitTestable(),
        findsOneWidget,
      );
      expect(drafts.items.single.id, 'single');
      expect(queue.count, 0);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'compact tray opens its own review and cancel preserves every capture',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        final ScanQueue queue = ScanQueue(
          userId: 'fixture',
          now: () => _queueNow,
          storage: _Storage(),
          writer: (ScanQueueEntry _) async {},
        );
        addTearDown(queue.dispose);
        final _Drafts drafts = _Drafts(<ScanDraftItem>[
          _draft('first', uncertain: true),
          _draft('second', name: 'Counterspell', uncertain: true),
        ]);
        await _show(
          tester,
          _screen(queue, drafts: drafts),
          Brightness.light,
          scale: 2,
          size: const Size(320, 400),
        );
        await tester.tap(find.byKey(const ValueKey<String>('scan-tray-next')));
        await tester.pumpAndSettle();
        final Finder name = find.text('Counterspell');
        await tester.ensureVisible(name);
        await tester.pumpAndSettle();
        await tester.tap(name.hitTestable());
        await tester.pumpAndSettle();
        final ScanCorrectionEditor review = tester.widget<ScanCorrectionEditor>(
          find.byType(ScanCorrectionEditor),
        );
        expect(
          review.initialResolution!.candidates.single.card.name,
          'Counterspell',
        );
        expect(review.confirmLabel, 'Confirm');
        await tester.tap(
          find.byKey(const ValueKey<String>('scan-correction-close')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ScanCorrectionEditor), findsNothing);
        expect(drafts.removed, isEmpty);
        expect(drafts.items, hasLength(2));
        expect(queue.count, 0);
        expect(
          find
              .byKey(const ValueKey<String>('scan-discard-remaining'))
              .hitTestable(),
          findsOneWidget,
        );
        expect(find.text('Continue scanning').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'selecting a retained explicit review queues only that card and Undo restores its declined choice',
    (WidgetTester tester) async {
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async => writes.add(entry),
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('chosen', reviewed: true),
        _draft('retained', name: 'Counterspell', reviewed: true),
      ]);
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      expect(queue.count, 0);
      await tester.tap(find.bySemanticsLabel('Select captured card').first);
      await tester.pumpAndSettle();
      expect(queue.entries.single.operationId, 'chosen');
      expect(queue.entries.single.quantity, 2);
      expect(writes, isEmpty);
      await tester.tap(find.byKey(const ValueKey<String>('scan-undo')));
      await tester.pumpAndSettle();
      expect(queue.count, 0);
      expect(
        drafts.items
            .firstWhere((ScanDraftItem item) => item.id == 'chosen')
            .selected,
        isFalse,
      );
      await tester.tap(find.bySemanticsLabel('Select captured card').first);
      await tester.pumpAndSettle();
      await _expireUndo(tester);
      expect(writes, hasLength(1));
      expect(writes.single.operationId, 'chosen');
      expect(writes.single.quantity, 2);
      expect(writes.single.card.finish, Finish.nonfoil);
      expect(drafts.removed, <String>['chosen']);
      expect(drafts.items.single.id, 'retained');
      expect(find.text('Counterspell').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('bulk finish never changes an individual review', (
    WidgetTester tester,
  ) async {
    int writes = 0;
    final ScanQueue queue = ScanQueue(
      userId: 'fixture',
      now: () => _queueNow,
      storage: _Storage(),
      writer: (ScanQueueEntry _) async {
        writes++;
      },
    );
    addTearDown(queue.dispose);
    final _Drafts drafts = _Drafts(<ScanDraftItem>[
      _draft('reviewed', reviewed: true, selected: true),
    ]);
    final MTGDeck deck = MTGDeck(name: 'Test deck')..id = 'deck';
    await _show(
      tester,
      _screen(queue, drafts: drafts, decks: <MTGDeck>[deck]),
      Brightness.dark,
    );
    await _more(tester);
    await tester.tap(find.text('Batch options').hitTestable());
    await tester.pumpAndSettle();
    await _choose<Finish>(tester, 'foil');
    await _choose<String>(tester, 'Collection + Test deck');
    await _choose<DeckSection>(tester, 'sideboard');
    await tester.tap(find.text('Done').hitTestable());
    await tester.pumpAndSettle();
    expect(drafts.items.single.approval!.card.finish, Finish.nonfoil);
    expect(drafts.items.single.approval!.deckId, isNull);
    expect(drafts.items.single.selected, isTrue);
    expect(writes, 0);
    expect(queue.entries.single.card.finish, Finish.nonfoil);
    expect(queue.entries.single.deckId, isNull);
    await _expireUndo(tester);
    expect(writes, 1);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'verified Normal queues durably, Undo retains the capture and prevents replay after restart',
    (WidgetTester tester) async {
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => _queueNow,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async => writes.add(entry),
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[
        _draft('exact', exact: true),
      ]);
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      expect(queue.count, 1);
      expect(queue.canUndo('exact'), isTrue);
      expect(queue.entries.single.card.finish, Finish.nonfoil);
      expect(drafts.items.single.approval!.card.finish, Finish.nonfoil);
      expect(writes, isEmpty);
      expect(find.textContaining('Add ('), findsNothing);
      expect(find.textContaining('Check ('), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('scan-undo')));
      await tester.pumpAndSettle();
      expect(queue.count, 0);
      expect(drafts.items.single.approval!.card.finish, Finish.nonfoil);
      expect(drafts.items.single.selected, isFalse);
      await _expireUndo(tester);
      expect(writes, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
      expect(queue.count, 0);
      expect(drafts.items.single.selected, isFalse);
      await tester.tap(_capturedArtwork('Lightning Bolt').hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(ScanCorrectionEditor), findsOneWidget);
      expect(
        tester
            .widget<ScanCorrectionEditor>(find.byType(ScanCorrectionEditor))
            .initialSelection!
            .card
            .finish,
        Finish.nonfoil,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('scan-correction-close')),
      );
      await tester.pumpAndSettle();
      expect(queue.count, 0);
      expect(writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final bool failPersistence in <bool>[false, true]) {
    testWidgets(
      'Undo claims the addition before ${failPersistence ? 'failed' : 'slow'} draft persistence',
      (WidgetTester tester) async {
        final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
        final _Storage storage = _Storage();
        final ScanQueue queue = ScanQueue(
          userId: 'fixture',
          now: () => _queueNow,
          storage: storage,
          writer: (ScanQueueEntry entry) async => writes.add(entry),
        );
        addTearDown(queue.dispose);
        final _HeldUndoDrafts drafts = _HeldUndoDrafts(<ScanDraftItem>[
          _draft('undo-held', exact: true),
        ], failPersistence: failPersistence);
        addTearDown(() {
          if (!drafts.release.isCompleted) drafts.release.complete();
        });
        await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
        expect(queue.canUndo('undo-held'), isTrue);
        if (!failPersistence) {
          _queueNow = _queueNow.add(const Duration(milliseconds: 9900));
          await tester.pump(const Duration(milliseconds: 9900));
        }
        final Finder undo = find
            .byKey(const ValueKey<String>('scan-undo'))
            .hitTestable();
        expect(undo, findsOneWidget);
        await tester.tap(undo);
        await tester.pump();
        expect(drafts.started.isCompleted, isTrue);
        expect(queue.canUndo('undo-held'), isFalse);
        expect(storage.entries.single.operationId, 'undo-held');
        expect(drafts.items.single.selected, isTrue);
        if (!failPersistence) {
          _queueNow = _queueNow.add(const Duration(seconds: 2));
          await tester.pump(const Duration(seconds: 2));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();
          expect(writes, isEmpty);
          expect(queue.count, 1);
        }
        drafts.release.complete();
        await tester.pumpAndSettle();
        if (failPersistence) {
          expect(queue.count, 1);
          expect(queue.canUndo('undo-held'), isTrue);
          expect(drafts.items.single.selected, isTrue);
          expect(writes, isEmpty);
          drafts.failPersistence = false;
          await tester.tap(
            find.byKey(const ValueKey<String>('scan-undo')).hitTestable(),
          );
          await tester.pumpAndSettle();
        }
        expect(queue.count, 0);
        expect(storage.entries, isEmpty);
        expect(drafts.items.single.selected, isFalse);
        await _expireUndo(tester);
        expect(writes, isEmpty);
        expect(drafts.items.single.id, 'undo-held');
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets('pending uploads remain controllable without page scroll', (
    WidgetTester tester,
  ) async {
    final Completer<void> upload = Completer<void>();
    int writes = 0;
    final ScanQueueEntry entry = ScanQueueEntry(
      operationId: 'pending',
      card: cardFromScryfall(_printing(), finish: Finish.foil),
      quantity: 2,
      createdAt: DateTime.utc(2026),
    );
    final ScanQueue queue = ScanQueue(
      userId: 'fixture',
      now: () => _queueNow,
      storage: _Storage(<ScanQueueEntry>[entry]),
      writer: (ScanQueueEntry _) {
        writes++;
        return upload.future;
      },
    );
    addTearDown(queue.dispose);
    await _show(tester, _screen(queue), Brightness.dark);
    await tester.tap(find.text('Added 2'));
    await tester.pumpAndSettle();
    expect(find.text('Pause uploads').hitTestable(), findsOneWidget);
    expect(writes, 1);
    expect(
      tester
          .widget<GhostButton>(
            find
                .widgetWithText(GhostButton, 'Remove pending addition')
                .hitTestable(),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Pause uploads').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Resume uploads').hitTestable(), findsOneWidget);
    upload.complete();
    await tester.pumpAndSettle();
    expect(queue.count, 0);
    expect(find.text('All additions uploaded.').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('capture options do not change approvals or delete photos', (
    WidgetTester tester,
  ) async {
    final ScanQueue queue = ScanQueue(
      userId: 'fixture',
      now: () => _queueNow,
      storage: _Storage(),
      writer: (ScanQueueEntry _) async {},
    );
    addTearDown(queue.dispose);
    final _Drafts drafts = _Drafts(<ScanDraftItem>[
      _draft('retained', uncertain: true),
    ]);
    await _show(tester, _screen(queue, drafts: drafts), Brightness.dark);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.sliders));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch).at(1)).value, isTrue);
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch).at(1)).value, isFalse);
    await tester.tap(find.text('Done').hitTestable());
    await tester.pumpAndSettle();
    expect(drafts.items.single.approval, isNull);
    expect(drafts.removed, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
