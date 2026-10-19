import 'package:arcane/arcane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/pages/dock/hub.dart';
import 'package:the_collector/theme/components/collector_dock.dart';
import 'package:the_collector/theme/theme.dart';

import 'helpers/load_collector_fonts.dart';

void main() {
  setUpAll(loadCollectorFonts);

  testWidgets('one dock exposes all five primary workspaces', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        home: const CollectorHub(
          cards: Text('Inventory'),
          containers: SizedBox(),
          scanner: SizedBox(),
          tabletop: Text('Tools'),
          more: SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final CollectorDock dock = tester.widget<CollectorDock>(
      find.byType(CollectorDock),
    );
    expect(
      dock.items.map((CollectorDockItem item) => item.label).toList(),
      <String>['Cards', 'Containers', 'Scan', 'Tabletop', 'More'],
    );
  });
}
