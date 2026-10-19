import 'package:arcane/arcane.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/theme/theme.dart';

import 'helpers/load_collector_fonts.dart';

const List<String> _collection = <String>[
  'Cards',
  'Decks',
  'Scan',
  'Prices',
  'Shops',
];
const List<String> _home = <String>['Collection', 'Dice', 'Rules', 'Settings'];

Future<void> _showNavigation(
  WidgetTester tester, {
  required ThemeMode mode,
  required double scale,
  required double width,
  List<String> labels = _collection,
}) async {
  final Size size = Size(width, 667);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  int selected = 0;
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(mode),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(scale),
          padding: const EdgeInsets.only(top: 20, bottom: 34),
          viewPadding: const EdgeInsets.only(top: 20, bottom: 34),
        ),
        child: child!,
      ),
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => Scaffold(
          footers: <Widget>[
            ButtonBar(
              selectedIndex: selected,
              buttons: <IconTab>[
                for (int index = 0; index < labels.length; index++)
                  IconTab(
                    icon: Icons.cards,
                    label: labels[index],
                    onPressed: () => setState(() => selected = index),
                  ),
              ],
            ),
          ],
          child: Center(child: Text('Pane $selected')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectFullLabels(WidgetTester tester, List<String> labels) {
  for (final String label in labels) {
    final Finder text = find.text(label).hitTestable();
    expect(text, findsOneWidget);
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      text,
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(paragraph.overflow, isNot(TextOverflow.ellipsis));
    final Rect bounds = tester.getRect(text);
    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(tester.view.physicalSize.width));
    final Rect target = tester.getRect(find.widgetWithText(IconButton, label));
    expect(target.width, greaterThanOrEqualTo(44));
    expect(target.height, greaterThanOrEqualTo(44));
    expect(target.bottom, lessThanOrEqualTo(667 - 34));
  }
  expect(tester.takeException(), isNull);
  final Rect body = tester.getRect(
    find.ancestor(of: find.text('Pane 0'), matching: find.byType(Center)).first,
  );
  expect(body.bottom, tester.getTopLeft(find.byType(ButtonBar)).dy);
}

void main() {
  setUpAll(loadCollectorFonts);

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'five tabs at 375 and 2.35 text keep full labels in ${mode.name}',
      (WidgetTester tester) async {
        final SemanticsHandle semantics = tester.ensureSemantics();
        try {
          await _showNavigation(tester, mode: mode, scale: 2.35, width: 375);
          _expectFullLabels(tester, _collection);
          expect(
            tester.getTopLeft(find.text('Shops')).dy,
            greaterThan(tester.getTopLeft(find.text('Cards')).dy),
          );
          await tester.tap(find.text('Prices'));
          await tester.pumpAndSettle();
          expect(find.text('Pane 3'), findsOneWidget);
          expect(
            tester.getSemantics(find.bySemanticsLabel('Prices')),
            matchesSemantics(
              label: 'Prices',
              isButton: true,
              isSelected: true,
              hasSelectedState: true,
              hasTapAction: true,
            ),
          );
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          for (int index = 0; index < _collection.length; index++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(find.text('Pane $index'), findsOneWidget);
          }
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets(
      'home labels remain complete at 375 and 2.35 text in ${mode.name}',
      (WidgetTester tester) async {
        await _showNavigation(
          tester,
          mode: mode,
          scale: 2.35,
          width: 375,
          labels: _home,
        );
        _expectFullLabels(tester, _home);
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        expect(find.text('Pane 3'), findsOneWidget);
      },
    );
  }

  testWidgets('normal five tabs retain one row at 320', (
    WidgetTester tester,
  ) async {
    await _showNavigation(tester, mode: ThemeMode.dark, scale: 1, width: 320);
    _expectFullLabels(tester, _collection);
    final double y = tester.getTopLeft(find.text('Cards')).dy;
    for (final String label in _collection) {
      expect(tester.getTopLeft(find.text(label)).dy, y);
    }
  });
}
