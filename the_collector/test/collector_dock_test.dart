import 'dart:ui' show SemanticsAction;

import 'package:arcane/arcane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/theme/components/collector_dock.dart';
import 'package:the_collector/theme/theme.dart';

import 'helpers/load_collector_fonts.dart';

void main() {
  setUpAll(loadCollectorFonts);
  for (final int count in <int>[4, 6]) {
    for (final double scale in <double>[1, 2.35]) {
      testWidgets('$count dock actions stay reachable at 320px scale $scale', (
        WidgetTester tester,
      ) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final List<String> pressed = <String>[];
        final List<String> labels = count == 4
            ? <String>['Collection', 'Dice', 'Rules', 'Settings']
            : <String>['Home', 'Cards', 'Organize', 'Scan', 'Prices', 'Shops'];
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(ThemeMode.dark),
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 568),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                footers: <Widget>[
                  CollectorDock(
                    selectedIndex: 1,
                    items: labels
                        .map(
                          (String label) => CollectorDockItem(
                            icon: Icons.cards,
                            label: label,
                            onPressed: () => pressed.add(label),
                          ),
                        )
                        .toList(),
                  ),
                ],
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byType(CollectorDock)).height,
          lessThanOrEqualTo(60),
        );
        final SemanticsHandle semantics = tester.ensureSemantics();
        try {
          for (final String label in labels) {
            final Finder action = find.bySemanticsLabel(label).hitTestable();
            expect(action, findsOneWidget);
            expect(
              tester
                  .getSemantics(action)
                  .getSemanticsData()
                  .hasAction(SemanticsAction.tap),
              isTrue,
            );
            final Rect box = tester.getRect(action);
            expect(box.width, greaterThanOrEqualTo(44));
            expect(box.height, greaterThanOrEqualTo(44));
            expect(box.left, greaterThanOrEqualTo(0));
            expect(box.right, lessThanOrEqualTo(320));
            await tester.tap(action);
          }
          expect(pressed, labels);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
