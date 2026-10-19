import 'package:arcane/arcane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/pages/dock/hub.dart';
import 'package:the_collector/theme/components/collector_dock.dart';
import 'package:the_collector/theme/theme.dart';

import 'helpers/load_collector_fonts.dart';

void main() {
  setUpAll(loadCollectorFonts);
  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    for (final double scale in <double>[1, 2.35]) {
      testWidgets(
        'five workspaces fit one dock at 320px ${mode.name} text $scale',
        (WidgetTester tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            ArcaneApp(
              theme: MyThemeData.themeData(mode),
              builder: (BuildContext context, Widget? child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const CollectorHub(
                cards: Text('Owned printings'),
                containers: Text('Saved containers'),
                scanner: Text('Scan workspace'),
                tabletop: Text('Table tools'),
                more: Text('Utilities'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final List<Rect> targets = <Rect>[];
          for (final (String, String) item in <(String, String)>[
            ('Cards', 'Owned printings'),
            ('Containers', 'Saved containers'),
            ('Scan', 'Scan workspace'),
            ('Tabletop', 'Table tools'),
            ('More', 'Utilities'),
          ]) {
            final Finder target = find.byKey(
              ValueKey<String>('dock-${item.$1}'),
            );
            final Rect bounds = tester.getRect(target);
            expect(bounds.width, greaterThanOrEqualTo(44));
            expect(bounds.height, greaterThanOrEqualTo(44));
            expect(bounds.left, greaterThanOrEqualTo(0));
            expect(bounds.right, lessThanOrEqualTo(320));
            for (final Rect other in targets) {
              expect(bounds.left, greaterThanOrEqualTo(other.right - .01));
            }
            targets.add(bounds);
            await tester.tap(target);
            await tester.pumpAndSettle();
            expect(find.text(item.$2).hitTestable(), findsOneWidget);
            expect(find.byType(CollectorDock), findsOneWidget);
          }
          expect(
            targets.map((Rect bounds) => bounds.top).toSet(),
            hasLength(1),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
