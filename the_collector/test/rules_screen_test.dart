import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arcane/arcane.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/dock/hub_rules.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/rules_reference.dart';

import 'helpers/load_collector_fonts.dart';

class _Catalog extends Fake implements CardCatalog {
  final List<(String, int, Completer<sf.PaginableList<sf.MtgCard>>)> requests =
      <(String, int, Completer<sf.PaginableList<sf.MtgCard>>)>[];
  @override
  Future<List<sf.Ruling>> rulings(String cardId) async => <sf.Ruling>[];
  @override
  Future<sf.PaginableList<sf.MtgCard>> search(
    String query, {
    int page = 1,
    bool allPrintings = false,
  }) {
    final Completer<sf.PaginableList<sf.MtgCard>> pending =
        Completer<sf.PaginableList<sf.MtgCard>>();
    requests.add((query, page, pending));
    return pending.future;
  }
}

sf.MtgCard _namedCard(String name) => sf.MtgCard.fromJson(
  Map<String, Object?>.from(
    jsonDecode(
      File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
    ) as Map<Object?, Object?>,
  )..['name'] = name,
);

Future<void> _render(
  WidgetTester tester,
  Widget child, {
  ThemeMode mode = ThemeMode.dark,
  double scale = 1,
  Size size = const Size(320, 568),
  double keyboardInset = 0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(mode),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboardInset),
        ),
        child: child!,
      ),
      home: child,
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadCollectorFonts);

  testWidgets('search opens split-card Oracle text directly', (
    WidgetTester tester,
  ) async {
    final _Catalog catalog = _Catalog();
    final sf.MtgCard card = _namedCard('Dusk // Dawn');
    await _render(tester, HubRules(catalog: catalog));
    expect(
      find.text('Search a card for Oracle text and rulings.'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(EditableText), 'Dusk');
    await tester.tap(find.text('Search'));
    catalog.requests.single.$3.complete(
      sf.PaginableList<sf.MtgCard>(data: <sf.MtgCard>[card], hasMore: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(card.name));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(card.cardFaces!.first.oracleText!),
      findsOneWidget,
    );
    expect(find.text('Published rulings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
    for (final double scale in <double>[1, 2.35]) {
      testWidgets('rules results and reader reflow in ${mode.name} at $scale', (
        WidgetTester tester,
      ) async {
        await _render(
          tester,
          HubRules(
            catalog: _Catalog(),
            rulesLoader: ({bool refresh = false}) async => RulesReference(
              '1. Game Concepts\n\n100. General\n\n100.1 Players choose a card.\n\n100.2 Players draw a card.',
              Uri.parse('https://media.wizards.com/rules.txt'),
              DateTime.utc(2026, 10, 1),
            ),
          ),
          mode: mode,
          scale: scale,
          keyboardInset: scale > 1 ? 260 : 0,
        );
        await tester.tap(find.text('Game rules'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(EditableText), 'Players');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Players draw a card.'),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(
          tester.element(find.text('Players draw a card.')),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Players draw a card.').hitTestable());
        await tester.pumpAndSettle();
        expect(
          find.byWidgetPredicate(
            (Widget widget) =>
                widget is SelectableText &&
                widget.data == 'Players draw a card.',
          ),
          findsOneWidget,
        );
        expect(find.byType(AppBar), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('pagination and retry keep submitted query while input changes', (
    WidgetTester tester,
  ) async {
    final _Catalog catalog = _Catalog();
    await _render(tester, HubRules(catalog: catalog));
    await tester.enterText(find.byType(EditableText), 'Dusk');
    await tester.tap(find.text('Search'));
    await tester.enterText(find.byType(EditableText), 'Shock');
    catalog.requests.first.$3.complete(
      sf.PaginableList<sf.MtgCard>(
        data: <sf.MtgCard>[_namedCard('First'), _namedCard('Second')],
        hasMore: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    await tester.tap(find.text('Next page'));
    await tester.pump();
    expect(catalog.requests.last.$1, 'Dusk');
    expect(catalog.requests.last.$2, 2);
    catalog.requests.last.$3.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not search “Dusk”. Check your connection.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry search'));
    expect(catalog.requests.last.$1, 'Dusk');
    expect(catalog.requests.last.$2, 2);
    catalog.requests.last.$3.complete(
      sf.PaginableList<sf.MtgCard>(
        data: <sf.MtgCard>[_namedCard('Third')],
        hasMore: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Previous page'));
    await tester.pump();
    expect(catalog.requests.last.$2, 1);
    final Completer<sf.PaginableList<sf.MtgCard>> replaced =
        catalog.requests.last.$3;
    await tester.enterText(find.byType(EditableText), 'Shock');
    await tester.tap(find.text('Search'));
    catalog.requests.last.$3.complete(
      sf.PaginableList<sf.MtgCard>(
        data: <sf.MtgCard>[_namedCard('Shock')],
        hasMore: false,
      ),
    );
    await tester.pumpAndSettle();
    replaced.complete(
      sf.PaginableList<sf.MtgCard>(
        data: <sf.MtgCard>[_namedCard('Stale card')],
        hasMore: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Stale card'), findsNothing);
    expect(find.text('Shock'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty catalogue results remain searchable', (
    WidgetTester tester,
  ) async {
    final _Catalog catalog = _Catalog();
    await _render(tester, HubRules(catalog: catalog));
    await tester.enterText(find.byType(EditableText), 'Missing');
    await tester.tap(find.text('Search'));
    catalog.requests.single.$3.complete(
      sf.PaginableList<sf.MtgCard>(data: <sf.MtgCard>[], hasMore: false),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('No cards found for “Missing”. Try another name or query.'),
      findsOneWidget,
    );
    expect(find.text('Search').hitTestable(), findsOneWidget);
  });

  testWidgets(
    'offline rules preserve number boundaries and disclose saved source',
    (WidgetTester tester) async {
      await _render(
        tester,
        HubRules(
          catalog: _Catalog(),
          rulesLoader: ({bool refresh = false}) async => RulesReference(
            '1. Game Concepts\n\n100. General\n\n100.1 Players play.\nThis continues.\n\n100.1a Players choose.\n\n100.10 Other rule.',
            Uri.parse('https://media.wizards.com/rules.txt'),
            DateTime.utc(2026, 10, 1),
            fromCache: true,
            updateFailed: true,
          ),
        ),
      );
      await tester.tap(find.text('Game rules'));
      await tester.pumpAndSettle();
      expect(find.text('Game Concepts'), findsOneWidget);
      expect(find.text('Official rules · Offline'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('rules-source')));
      await tester.pumpAndSettle();
      expect(
        find.text('Wizards of the Coast · Saved 2026-10-01'),
        findsOneWidget,
      );
      expect(
        find.text('Update unavailable. Showing the saved rules.'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(EditableText), '100.1');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(find.text('2 results'), findsOneWidget);
      expect(find.text('100.10'), findsNothing);
      await tester.ensureVisible(find.text('Players play.\nThis continues.'));
      await tester.tap(
        find.text('Players play.\nThis continues.').hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is SelectableText &&
              widget.data == 'Players play.\nThis continues.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed download retries and refresh keeps saved rules visible', (
    WidgetTester tester,
  ) async {
    final List<(bool, Completer<RulesReference>)> requests =
        <(bool, Completer<RulesReference>)>[];
    final RulesReference reference = RulesReference(
      '1. Game Concepts\n\n100.1 Exact official paragraph.',
      Uri.parse('https://media.wizards.com/rules.txt'),
      DateTime.utc(2026),
    );
    await _render(
      tester,
      HubRules(
        catalog: _Catalog(),
        rulesLoader: ({bool refresh = false}) {
          final Completer<RulesReference> pending = Completer<RulesReference>();
          requests.add((refresh, pending));
          return pending.future;
        },
      ),
    );
    await tester.tap(find.text('Game rules'));
    await tester.pump();
    requests.first.$2.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry download'));
    await tester.pump();
    expect(requests.last.$1, isTrue);
    requests.last.$2.complete(reference);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('rules-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    expect(find.text('Game Concepts'), findsOneWidget);
    expect(find.text('Checking for updates…'), findsOneWidget);
    requests.last.$2.complete(
      RulesReference(
        reference.text,
        reference.source,
        reference.fetchedAt,
        fromCache: true,
        updateFailed: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Game Concepts'), findsOneWidget);
    expect(
      find.text('Update unavailable. Showing the saved rules.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('named rulings back control returns to card search', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      final sf.MtgCard card = sf.MtgCard.fromJson(
        Map<String, Object?>.from(
          jsonDecode(
            File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
          ) as Map<Object?, Object?>,
        ),
      );
      await _render(
        tester,
        Builder(
          builder: (BuildContext context) => Center(
            child: PrimaryButton(
              onPressed: () => Arcane.push(
                context,
                CardRulingsScreen(
                  card: card,
                  rulingsLoader: (String id) async => <sf.Ruling>[],
                ),
              ),
              child: const Text('Read rulings'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Read rulings'));
      await tester.pumpAndSettle();
      final Finder back = find
          .bySemanticsLabel('Back to card search')
          .hitTestable();
      expect(back, findsOneWidget);
      expect(
        tester.getSemantics(back).getSemanticsData().flagsCollection.isButton,
        isTrue,
      );
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.text('Read rulings'), findsOneWidget);
      expect(find.byType(CardRulingsScreen), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
  testWidgets('iOS rulings has an accessible close without a title bar', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final TargetPlatform? previousPlatform = debugDefaultTargetPlatformOverride;
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final sf.MtgCard card = sf.MtgCard.fromJson(
        Map<String, Object?>.from(
          jsonDecode(
            File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
          ) as Map<Object?, Object?>,
        ),
      );
      await _render(
        tester,
        CardRulingsScreen(
          card: card,
          rulingsLoader: (String id) async => <sf.Ruling>[],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Back to card search'), findsOneWidget);
      expect(find.text('Rulings'), findsNothing);
      expect(find.byType(AppBar), findsNothing);
      expect(find.text(card.name), findsOneWidget);
      expect(find.text('Oracle text'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });

  testWidgets('filled card and game queries retain accessible names', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await _render(
        tester,
        HubRules(
          catalog: _Catalog(),
          rulesLoader: ({bool refresh = false}) async => RulesReference(
            '100. General\n\n100.1 Players play.',
            Uri.parse('https://media.wizards.com/rules.txt'),
            DateTime.utc(2026, 10, 1),
          ),
        ),
      );
      await tester.enterText(
        find.byType(EditableText).hitTestable(),
        'Lightning Bolt',
      );
      await tester.pumpAndSettle();
      final SemanticsNode card = tester.getSemantics(
        find.bySemanticsLabel('Card name or Scryfall query').first,
      );
      expect(card.label, 'Card name or Scryfall query');
      expect(card.value, 'Lightning Bolt');
      expect(card.getSemanticsData().flagsCollection.isTextField, isTrue);
      final SemanticsNode clearCard = tester.getSemantics(
        find.bySemanticsLabel('Clear card search').first,
      );
      expect(clearCard.getSemanticsData().flagsCollection.isButton, isTrue);
      await tester.tap(find.bySemanticsLabel('Clear card search').first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).hitTestable())
            .controller
            .text,
        isEmpty,
      );
      await tester.tap(find.text('Game rules'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).hitTestable(), '100.1');
      await tester.pumpAndSettle();
      final SemanticsNode rule = tester.getSemantics(
        find.bySemanticsLabel('Rule number or keyword').first,
      );
      expect(rule.label, 'Rule number or keyword');
      expect(rule.value, '100.1');
      expect(rule.getSemanticsData().flagsCollection.isTextField, isTrue);
      final SemanticsNode clearRule = tester.getSemantics(
        find.bySemanticsLabel('Clear rule search').first,
      );
      expect(clearRule.getSemanticsData().flagsCollection.isButton, isTrue);
      await tester.tap(find.bySemanticsLabel('Clear rule search').first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).hitTestable())
            .controller
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
  testWidgets(
    'card Oracle text stays readable while failed rulings are retried',
    (WidgetTester tester) async {
      final sf.MtgCard card = sf.MtgCard.fromJson(
        Map<String, Object?>.from(
          jsonDecode(
            File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
          ) as Map<Object?, Object?>,
        ),
      );
      final List<Completer<List<sf.Ruling>>> requests =
          <Completer<List<sf.Ruling>>>[];
      await _render(
        tester,
        CardRulingsScreen(
          card: card,
          rulingsLoader: (String id) {
            expect(id, card.id);
            final Completer<List<sf.Ruling>> pending =
                Completer<List<sf.Ruling>>();
            requests.add(pending);
            return pending.future;
          },
        ),
      );
      requests[0].completeError(StateError('offline'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Could not load rulings. Retry'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('Could not load rulings. Retry')),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('Could not load rulings. Retry').hitTestable(),
      );
      await tester.pump();
      expect(requests, hasLength(2));
      requests[1].complete(<sf.Ruling>[]);
      await tester.pumpAndSettle();
      expect(find.text('No published rulings for this card.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('next rule starts at the beginning after reading a long rule', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      final String longBody = List<String>.filled(
        90,
        'Players read the complete first rule.',
      ).join(' ');
      await _render(
        tester,
        HubRules(
          catalog: _Catalog(),
          rulesLoader: ({bool refresh = false}) async => RulesReference(
            '100. General\n\n100.1 $longBody\n\n'
            '100.2 Players read the second rule from its beginning.',
            Uri.parse('https://media.wizards.com/rules.txt'),
            DateTime.utc(2026),
          ),
        ),
      );
      await tester.tap(find.text('Game rules'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(EditableText).hitTestable(),
        'Players',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text(longBody));
      await tester.pumpAndSettle();
      final Finder scroll = find.byType(SingleChildScrollView).hitTestable();
      final ScrollController controller = tester
          .widget<SingleChildScrollView>(scroll)
          .controller!;
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(controller.offset, greaterThan(0));
      await tester.tap(find.bySemanticsLabel('Next rule').hitTestable());
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(
        find
            .byWidgetPredicate(
              (Widget widget) =>
                  widget is SelectableText &&
                  widget.data ==
                      'Players read the second rule from its beginning.',
            )
            .hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('submitting a rule search dismisses the keyboard', (
    WidgetTester tester,
  ) async {
    await _render(
      tester,
      HubRules(
        catalog: _Catalog(),
        rulesLoader: ({bool refresh = false}) async => RulesReference(
          '100. General\n\n100.1 Players play.',
          Uri.parse('https://media.wizards.com/rules.txt'),
          DateTime.utc(2026),
        ),
      ),
    );
    await tester.tap(find.text('Game rules'));
    await tester.pumpAndSettle();
    final Finder input = find.byType(EditableText).hitTestable();
    await tester.enterText(input, '100.1');
    expect(tester.widget<EditableText>(input).focusNode.hasFocus, isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(input).focusNode.hasFocus, isFalse);
    expect(find.text('Players play.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS rule reading uses the rule identity without a title bar', (
    WidgetTester tester,
  ) async {
    final TargetPlatform? previousPlatform = debugDefaultTargetPlatformOverride;
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await _render(
        tester,
        HubRules(
          catalog: _Catalog(),
          rulesLoader: ({bool refresh = false}) async => RulesReference(
            '100. General\n\n100.1 Players play.',
            Uri.parse('https://media.wizards.com/rules.txt'),
            DateTime.utc(2026),
          ),
        ),
      );
      await tester.tap(find.text('Game rules'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).hitTestable(), '100.1');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Players play.'));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('100.1'), findsOneWidget);
      expect(find.text('100. General'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is SelectableText && widget.data == 'Players play.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });
}
