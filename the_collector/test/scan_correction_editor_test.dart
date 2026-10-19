import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:arcane/arcane.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:scryfall_api/scryfall_api.dart' hide Color;
import 'package:the_collector/pages/collection/card/card_add_dialog.dart';
import 'package:the_collector/pages/scanning/scan_camera_drawer.dart';
import 'package:the_collector/pages/scanning/scan_correction_editor.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_session.dart';

MtgCard _printing() {
  final Map<String, Object?> map = Map<String, Object?>.from(
    jsonDecode(
      File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
    ) as Map<Object?, Object?>,
  )..['finishes'] = <String>['nonfoil', 'foil'];
  map.remove('image_uris');
  map['card_faces'] = (map['card_faces'] as List<Object?>).map((Object? value) {
    return Map<String, Object?>.from(value as Map<Object?, Object?>)
      ..remove('image_uris');
  }).toList();
  return MtgCard.fromJson(map);
}

const ScanCrop _crop = ScanCrop(
  imagePath: '',
  width: 630,
  height: 880,
  rectified: true,
  sourceCorners: <ScanPoint>[],
  lines: <ScanTextLine>[],
);

ScanResolution _resolution(MtgCard card) => ScanResolution(
  candidates: <ScanCandidate>[
    ScanCandidate(card, <ScanEvidence>{ScanEvidence.nameMatch}),
  ],
  hints: ScanHints(names: <String>[card.name]),
  status: ScanResolutionStatus.needsReview,
);

class _Catalog extends CardCatalog {
  final MtgCard card = _printing();
  int calls = 0;
  @override
  Future<PaginableList<MtgCard>> search(
    String query, {
    int page = 1,
    bool allPrintings = false,
  }) async {
    calls++;
    return PaginableList<MtgCard>(data: <MtgCard>[card], hasMore: false);
  }
}

Future<void> _show(
  WidgetTester tester,
  Widget child, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(ThemeMode.dark),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(child: child),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'inline correction paints readable ${mode.name} surface without a scaffold',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final GlobalKey boundary = GlobalKey();
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(mode),
            home: RepaintBoundary(
              key: boundary,
              child: ScanCorrectionEditor(
                crop: _crop,
                onConfirmed: (_) {},
                onClose: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final BuildContext context = tester.element(
          find.byType(ScanCorrectionEditor),
        );
        final Color surface = Theme.of(context).colorScheme.background;
        final Rect search = tester.getRect(
          find.byKey(const ValueKey<String>('printing-search')),
        );
        final Color foreground = Theme.of(context).colorScheme.foreground;
        await tester.runAsync(() async {
          final ui.Image image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          try {
            final ByteData bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final int offset = (300 * image.width + 1) * 4;
            expect(
              bytes.getUint8(offset + 3),
              255,
              reason: 'Inline editor must paint an opaque surface',
            );
            expect(bytes.getUint8(offset), closeTo(surface.r * 255, 1));
            expect(bytes.getUint8(offset + 1), closeTo(surface.g * 255, 1));
            expect(bytes.getUint8(offset + 2), closeTo(surface.b * 255, 1));
            final int inputOffset =
                ((search.top.toInt() + 8) * image.width +
                    search.right.toInt() -
                    8) *
                4;
            final Color input = Color.fromARGB(
              bytes.getUint8(inputOffset + 3),
              bytes.getUint8(inputOffset),
              bytes.getUint8(inputOffset + 1),
              bytes.getUint8(inputOffset + 2),
            );
            final double ink = foreground.computeLuminance();
            final double fill = input.computeLuminance();
            final double contrast = ink > fill
                ? (ink + .05) / (fill + .05)
                : (fill + .05) / (ink + .05);
            expect(
              contrast,
              greaterThanOrEqualTo(4.5),
              reason:
                  'Search text must contrast with the actual composited fill',
            );
          } finally {
            image.dispose();
          }
        });
      },
    );
  }

  testWidgets(
    'correction uses shared selector and preserves typed capture choices',
    (WidgetTester tester) async {
      final _Catalog catalog = _Catalog();
      addTearDown(catalog.close);
      final MTGDeck deck = MTGDeck(name: 'Deck')..id = 'deck';
      PrintingSelection? saved;
      await _show(
        tester,
        ScanCorrectionEditor(
          crop: _crop,
          catalog: catalog,
          decks: <MTGDeck>[deck],
          initialResolution: _resolution(catalog.card),
          initialSelection: PrintingSelection(
            card: cardFromScryfall(catalog.card, finish: Finish.foil),
            printing: catalog.card,
            quantity: 4,
            destinationId: 'deck',
            deckSection: DeckSection.sideboard,
          ),
          onConfirmed: (PrintingSelection value) => saved = value,
          onClose: () {},
        ),
      );
      expect(find.byType(CardPrintingSelector), findsOneWidget);
      expect(catalog.calls, 0);
      final CardPrintingSelector selector = tester.widget<CardPrintingSelector>(
        find.byType(CardPrintingSelector),
      );
      expect(selector.addToCollection, isFalse);
      expect(selector.initialQuantity, 4);
      expect(selector.initialFinish, Finish.foil);
      expect(selector.initialDestinationId, 'deck');
      expect(selector.initialDeckSection, DeckSection.sideboard);
      await tester.tap(find.byKey(const ValueKey<String>('printing-confirm')));
      await tester.pumpAndSettle();
      expect(saved!.card.finish, Finish.foil);
      expect(saved!.quantity, 4);
      expect(saved!.destinationId, 'deck');
      expect(saved!.deckSection, DeckSection.sideboard);
      expect(find.byType(ScanCorrectionEditor), findsOneWidget);
    },
  );

  testWidgets(
    'unknown capture exposes search and recovery actions without another route',
    (WidgetTester tester) async {
      int retries = 0;
      int rescans = 0;
      int closes = 0;
      await _show(
        tester,
        ScanCorrectionEditor(
          crop: _crop,
          phase: ScanItemPhase.noIdentity,
          onConfirmed: (_) {},
          onClose: () => closes++,
          onRetry: () async => retries++,
          onRescan: () => rescans++,
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('printing-search')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('scan-correction-retry')),
      );
      await tester.pumpAndSettle();
      expect(retries, 1);
      await tester.tap(
        find.byKey(const ValueKey<String>('scan-correction-rescan')),
      );
      expect(rescans, 1);
      expect(closes, 0);
      await tester.tap(
        find.byKey(const ValueKey<String>('scan-correction-close')),
      );
      expect(closes, 1);
    },
  );

  for (final bool retry in <bool>[false, true]) {
    testWidgets(
      '${retry ? 'retry' : 'reading'} result reaches the same correction editor',
      (WidgetTester tester) async {
        final MtgCard card = _printing();
        final ValueNotifier<ScanResolution?> resolution =
            ValueNotifier<ScanResolution?>(null);
        addTearDown(resolution.dispose);
        await _show(
          tester,
          ValueListenableBuilder<ScanResolution?>(
            valueListenable: resolution,
            builder:
                (BuildContext context, ScanResolution? value, Widget? child) =>
                    ScanCorrectionEditor(
                      crop: _crop,
                      initialResolution: value,
                      phase: value == null
                          ? (retry
                                ? ScanItemPhase.lookupFailed
                                : ScanItemPhase.processing)
                          : ScanItemPhase.needsReview,
                      onConfirmed: (_) {},
                      onClose: () {},
                      onRetry: retry
                          ? () async => resolution.value = _resolution(card)
                          : null,
                    ),
          ),
        );
        if (retry) {
          await tester.tap(
            find.byKey(const ValueKey<String>('scan-correction-retry')),
          );
        } else {
          resolution.value = _resolution(card);
        }
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey<String>('printing-choice-${card.id}')),
          findsOneWidget,
        );
        final CardPrintingSelector selector = tester
            .widget<CardPrintingSelector>(find.byType(CardPrintingSelector));
        expect(selector.initialPrinting!.id, card.id);
      },
    );
  }

  testWidgets(
    'background resolution preserves typed correction and current choices',
    (WidgetTester tester) async {
      final MtgCard card = _printing();
      final ValueNotifier<ScanResolution?> resolution =
          ValueNotifier<ScanResolution?>(_resolution(card));
      addTearDown(resolution.dispose);
      PrintingSelection? saved;
      await _show(
        tester,
        ValueListenableBuilder<ScanResolution?>(
          valueListenable: resolution,
          builder:
              (BuildContext context, ScanResolution? value, Widget? child) =>
                  ScanCorrectionEditor(
                    crop: _crop,
                    initialResolution: value,
                    preferredFinish: Finish.foil,
                    preferredQuantity: 3,
                    onConfirmed: (PrintingSelection value) => saved = value,
                    onClose: () {},
                  ),
        ),
      );
      final Element selector = tester.element(
        find.byType(CardPrintingSelector),
      );
      final Finder search = find.descendant(
        of: find.byKey(const ValueKey<String>('printing-search')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(search, 'Circle of Protection: Blue');
      FocusManager.instance.primaryFocus?.unfocus();
      resolution.value = const ScanResolution(
        candidates: <ScanCandidate>[],
        hints: ScanHints(names: <String>[]),
        status: ScanResolutionStatus.noMatch,
      );
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(CardPrintingSelector)), same(selector));
      expect(
        tester.widget<EditableText>(search).controller.text,
        'Circle of Protection: Blue',
      );
      await tester.tap(find.byKey(const ValueKey<String>('printing-confirm')));
      await tester.pumpAndSettle();
      expect(saved!.card.printingId, card.id);
      expect(saved!.card.finish, Finish.foil);
      expect(saved!.quantity, 3);
    },
  );

  testWidgets(
    'evidence flip reports ranking instead of a fabricated probability',
    (WidgetTester tester) async {
      final MtgCard card = _printing();
      await _show(
        tester,
        ScanCorrectionEditor(
          crop: _crop,
          initialResolution: _resolution(card),
          onConfirmed: (_) {},
          onClose: () {},
        ),
      );
      final CardPrintingSelector selector = tester.widget<CardPrintingSelector>(
        find.byType(CardPrintingSelector),
      );
      selector.onPrintingArtworkTap!(card);
      await tester.pumpAndSettle();
      expect(find.textContaining('Match score'), findsWidgets);
      expect(find.textContaining('not probabilities'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('scan-correction-artwork')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CardPrintingSelector).hitTestable(), findsOneWidget);
    },
  );

  testWidgets('remove failure retains the editor and retry removes once', (
    WidgetTester tester,
  ) async {
    int attempts = 0;
    int closes = 0;
    await _show(
      tester,
      ScanCorrectionEditor(
        crop: _crop,
        onConfirmed: (_) {},
        onClose: () => closes++,
        onRemove: () async {
          attempts++;
          if (attempts == 1) throw StateError('Storage full');
        },
      ),
    );
    final Finder remove = find.text('Remove').hitTestable();
    expect(remove, findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('scan-correction-remove')))
          .height,
      greaterThanOrEqualTo(44),
    );
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(find.text('Could not remove'), findsOneWidget);
    expect(closes, 0);
    await tester.tap(
      find.byKey(const ValueKey<String>('scan-correction-remove')),
    );
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(closes, 1);
  });

  testWidgets('a replacement capture rejects a stale selector confirmation', (
    WidgetTester tester,
  ) async {
    final MtgCard card = _printing();
    final ValueNotifier<ScanCrop> crop = ValueNotifier<ScanCrop>(_crop);
    addTearDown(crop.dispose);
    int confirmations = 0;
    await _show(
      tester,
      ValueListenableBuilder<ScanCrop>(
        valueListenable: crop,
        builder: (BuildContext context, ScanCrop value, Widget? child) =>
            ScanCorrectionEditor(
              crop: value,
              initialResolution: _resolution(card),
              onConfirmed: (_) => confirmations++,
              onClose: () {},
            ),
      ),
    );
    final CardPrintingSelector old = tester.widget<CardPrintingSelector>(
      find.byType(CardPrintingSelector),
    );
    crop.value = const ScanCrop(
      imagePath: 'replacement.jpg',
      width: 630,
      height: 880,
      rectified: true,
      sourceCorners: <ScanPoint>[],
      lines: <ScanTextLine>[],
    );
    await tester.pumpAndSettle();
    old.onSelected(
      PrintingSelection(
        card: cardFromScryfall(card, finish: Finish.nonfoil),
        printing: card,
        quantity: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(confirmations, 0);
    expect(find.text('Capture replaced'), findsOneWidget);
  });

  testWidgets(
    'saved reviewed printing is never replaced by an unrelated suggestion',
    (WidgetTester tester) async {
      final MtgCard card = _printing();
      final PrintingSelection reviewed = PrintingSelection(
        card: cardFromScryfall(
          card,
          finish: Finish.nonfoil,
        ).copyWith(scryfallId: 'missing-reviewed-printing'),
        quantity: 7,
      );
      await _show(
        tester,
        ScanCorrectionEditor(
          crop: _crop,
          initialResolution: _resolution(card),
          initialSelection: reviewed,
          onConfirmed: (_) {},
          onClose: () {},
        ),
      );
      final CardPrintingSelector selector = tester.widget<CardPrintingSelector>(
        find.byType(CardPrintingSelector),
      );
      expect(selector.initialPrinting, isNull);
      expect(selector.initialQuantity, 7);
      expect(
        tester
            .widget<PrimaryButton>(
              find.byKey(const ValueKey<String>('printing-confirm')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('needs-check rail stays bounded and edits a stable item', (
    WidgetTester tester,
  ) async {
    final MtgCard card = _printing();
    final List<ScanSessionItem> items = List<ScanSessionItem>.generate(
      20,
      (int index) =>
          ScanSessionItem(_crop, id: 'card-$index')
            ..resolution = _resolution(card),
    );
    String? edited;
    await _show(
      tester,
      Align(
        alignment: Alignment.bottomCenter,
        child: ScanCameraDrawer(
          items: items,
          submittedIds: <String>{},
          pendingPhotos: 0,
          busy: false,
          error: null,
          lastAddedName: null,
          lastAddedId: null,
          canUndo: (_) => false,
          onUndo: (_) async {},
          onEdit: (ScanSessionItem item) async => edited = item.id,
          onRemove: (_) async {},
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('camera-drawer-needs-check')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('camera-drawer-check-card-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('camera-drawer-check-card-3')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('camera-drawer-check-card-1')),
    );
    expect(edited, 'card-1');
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('camera-drawer')))
          .height,
      lessThanOrEqualTo(300),
    );
    expect(find.byType(Scrollable), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
