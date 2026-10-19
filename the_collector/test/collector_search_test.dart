import 'package:arcane/arcane.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, TextInputAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/theme/components/collector_search.dart';
import 'package:the_collector/theme/theme.dart';

import 'helpers/load_collector_fonts.dart';

Future<TextEditingController> _mount(
  WidgetTester tester, {
  int rows = 1,
  double scale = 1,
  ScrollController? scroll,
  ValueChanged<String>? onChanged,
}) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final TextEditingController controller = TextEditingController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(ThemeMode.light),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(375, 667),
          textScaler: TextScaler.linear(scale),
        ),
        child: CollectorSearch(
          controller: controller,
          label: 'Search cards',
          fieldKey: const ValueKey<String>('search-field'),
          onChanged: onChanged ?? (String _) {},
          builder: (BuildContext context, Widget button, Widget? field) =>
              Scaffold(
                headers: <Widget>[
                  Align(alignment: Alignment.centerRight, child: button),
                  ?field,
                ],
                child: ListView(
                  key: const ValueKey<String>('search-list'),
                  controller: scroll,
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  children: <Widget>[
                    for (int index = 0; index < rows; index++)
                      SizedBox(height: 80, child: Text('Card $index')),
                  ],
                ),
              ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  setUpAll(loadCollectorFonts);
  for (final int rows in <int>[0, 1, 30]) {
    testWidgets('pull at list start reveals search with $rows rows', (
      WidgetTester tester,
    ) async {
      await _mount(tester, rows: rows);
      expect(find.byType(TextField), findsNothing);
      await tester.drag(
        find.byKey(const ValueKey<String>('search-list')),
        const Offset(0, 180),
      );
      await tester.pumpAndSettle();
      final TextField field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue);
      expect(
        tester.getSize(find.byType(TextField)).height,
        inInclusiveRange(44, 52),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('ordinary scrolling and a small tug do not open the keyboard', (
    WidgetTester tester,
  ) async {
    final ScrollController scroll = ScrollController(initialScrollOffset: 600);
    addTearDown(scroll.dispose);
    await _mount(tester, rows: 30, scroll: scroll);
    await tester.drag(
      find.byKey(const ValueKey<String>('search-list')),
      const Offset(0, 120),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey<String>('search-list')),
      const Offset(0, 25),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('search button and Escape restore the unfiltered list', (
    WidgetTester tester,
  ) async {
    final List<String> changes = <String>[];
    final TextEditingController controller = await _mount(
      tester,
      onChanged: changes.add,
    );
    final Finder button = find.byIcon(Icons.magnifying_glass);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Glimpse');
    expect(changes, <String>['Glimpse']);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.text, isEmpty);
    expect(changes, <String>['Glimpse', '']);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text search and close stay reachable', (
    WidgetTester tester,
  ) async {
    await _mount(tester, scale: 2.35);
    await tester.tap(find.byIcon(Icons.magnifying_glass));
    await tester.pumpAndSettle();
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Pick Your Poison');
    await tester.tap(find.byIcon(Icons.x).last);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final LogicalKeyboardKey modifier in <LogicalKeyboardKey>[
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.controlLeft,
  ]) {
    testWidgets(
      'find shortcut opens idle search after submit and close with $modifier',
      (WidgetTester tester) async {
        await _mount(tester);
        Future<void> findShortcut() async {
          await tester.sendKeyDownEvent(modifier);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
          await tester.sendKeyUpEvent(modifier);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<TextField>(find.byType(TextField))
                .focusNode!
                .hasFocus,
            isTrue,
          );
        }

        await findShortcut();
        await tester.enterText(find.byType(TextField), 'Nevermore');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          isFalse,
        );
        await findShortcut();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        await findShortcut();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
