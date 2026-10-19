import 'package:arcane/arcane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/pages/dock/hub.dart';
import 'package:the_collector/pages/dock/hub_more.dart';
import 'package:the_collector/theme/components/collector_dock.dart';
import 'package:the_collector/theme/theme.dart';

import 'helpers/load_collector_fonts.dart';

Future<void> _tapDock(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(ValueKey<String>('dock-$label')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadCollectorFonts);
  for (final ThemeMode theme in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'one dock preserves workspace state around keyboard ${theme.name}',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewInsets);
        final TextEditingController search = TextEditingController();
        addTearDown(search.dispose);
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(theme),
            home: CollectorHub(
              cards: const Text('Stored cards'),
              containers: TextField(
                key: const ValueKey<String>('container-query'),
                controller: search,
                placeholder: const Text('Search containers'),
              ),
              scanner: const Text('Capture session'),
              tabletop: const Text('Tabletop tools'),
              more: const Text('Utilities'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final Rect dock = tester.getRect(find.byType(CollectorDock));
        expect(find.byType(CollectorDock), findsOneWidget);
        expect(dock.bottom, lessThanOrEqualTo(534));
        expect(tester.getRect(find.text('Stored cards')).top, 24);
        await _tapDock(tester, 'Containers');
        await tester.enterText(
          find.byKey(const ValueKey<String>('container-query')),
          'Trades',
        );
        tester.view.padding = const FakeViewPadding(top: 24);
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pumpAndSettle();
        expect(find.byType(CollectorDock), findsNothing);
        expect(search.text, 'Trades');
        FocusManager.instance.primaryFocus?.unfocus();
        tester.view.viewInsets = const FakeViewPadding();
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byType(CollectorDock)), dock);
        await _tapDock(tester, 'Tabletop');
        expect(find.text('Tabletop tools'), findsOneWidget);
        await _tapDock(tester, 'Containers');
        expect(search.text, 'Trades');
        expect(
          find.byKey(const ValueKey<String>('container-query')).hitTestable(),
          findsOneWidget,
        );
        for (final (String, String) destination in <(String, String)>[
          ('Scan', 'Capture session'),
          ('More', 'Utilities'),
          ('Cards', 'Stored cards'),
        ]) {
          await _tapDock(tester, destination.$1);
          expect(find.text(destination.$2), findsOneWidget);
          expect(find.byType(CollectorDock), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'More opens and closes every utility without losing the workspace',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: const CollectorHub(
            initialWorkspace: CollectorWorkspace.more,
            cards: SizedBox(),
            containers: SizedBox(),
            scanner: SizedBox(),
            tabletop: SizedBox(),
            more: HubMore(
              rules: Text('Rules content'),
              settings: Text('Settings content'),
              privacy: Text('Privacy content'),
              shops: Text('Shops content'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final (String, String) item in <(String, String)>[
        ('Rules', 'Rules content'),
        ('Settings', 'Settings content'),
        ('Privacy & data', 'Privacy content'),
        ('Shops', 'Shops content'),
      ]) {
        await tester.tap(find.byKey(ValueKey<String>('more-${item.$1}')));
        await tester.pumpAndSettle();
        expect(find.text(item.$2), findsOneWidget);
        await tester.tap(find.bySemanticsLabel('Close'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey<String>('more-${item.$1}')).hitTestable(),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );
}
