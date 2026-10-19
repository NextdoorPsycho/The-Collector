import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arcane/arcane.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/dock/hub_rules.dart';
import 'package:the_collector/pages/dock/hub_settings.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/rules_reference.dart';

import 'helpers/load_collector_fonts.dart';

class _Catalog extends Fake implements CardCatalog {
  final List<(String, int, Completer<sf.PaginableList<sf.MtgCard>>)> requests =
      <(String, int, Completer<sf.PaginableList<sf.MtgCard>>)>[];
  final List<String> opened = <String>[];

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

  @override
  Future<List<sf.Ruling>> rulings(String cardId) async {
    opened.add(cardId);
    return <sf.Ruling>[];
  }
}

sf.MtgCard _card(String name, String id) => sf.MtgCard.fromJson(
  Map<String, Object?>.from(
      jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<Object?, Object?>,
    )
    ..['name'] = name
    ..['id'] = id,
);

Future<void> _show(
  WidgetTester tester,
  Widget child, {
  double scale = 1,
  double keyboard = 0,
}) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(ThemeMode.dark),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQueryData(
          size: const Size(375, 667),
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: child!,
      ),
      home: child,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadCollectorFonts);

  testWidgets('rules shows matching cards together and opens the chosen card', (
    WidgetTester tester,
  ) async {
    final _Catalog catalog = _Catalog();
    await _show(tester, HubRules(catalog: catalog));
    await tester.enterText(find.byType(EditableText), 'Bolt');
    await tester.tap(find.text('Search'));
    catalog.requests.single.$3.complete(
      sf.PaginableList<sf.MtgCard>(
        data: <sf.MtgCard>[
          _card('Lightning Bolt', 'bolt'),
          _card('Firebolt', 'fire'),
        ],
        hasMore: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Lightning Bolt').hitTestable(), findsOneWidget);
    expect(find.text('Firebolt').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Firebolt'));
    await tester.pumpAndSettle();
    expect(catalog.opened, <String>['fire']);
    expect(find.text('Published rulings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rules lists matches and opens selected full rule directly', (
    WidgetTester tester,
  ) async {
    await _show(
      tester,
      HubRules(
        catalog: _Catalog(),
        rulesLoader: ({bool refresh = false}) async => RulesReference(
          '100. General\n\n100.1 Players draw one card.\n\n100.2 Players draw two cards.',
          Uri.parse('https://example.test/rules'),
          DateTime.utc(2026, 10, 1),
        ),
      ),
    );
    await tester.tap(find.text('Game rules'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'Players');
    await tester.pumpAndSettle();
    expect(find.text('Players draw one card.').hitTestable(), findsOneWidget);
    expect(find.text('Players draw two cards.').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Players draw two cards.'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is SelectableText &&
            widget.data == 'Players draw two cards.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings opens bounded topics and returns to index', (
    WidgetTester tester,
  ) async {
    await _show(
      tester,
      Provider<AppUser?>.value(
        value: AppUser(),
        child: const HubSettings(cloudRecognitionEnabled: false),
      ),
    );
    expect(find.text('Appearance').hitTestable(), findsOneWidget);
    expect(find.text('Tabletop').hitTestable(), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    await tester.tap(find.text('Tabletop'));
    await tester.pumpAndSettle();
    expect(find.text('Commander').hitTestable(), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(find.text('Light theme'), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('settings-topics')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    expect(find.text('Sign Out').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
