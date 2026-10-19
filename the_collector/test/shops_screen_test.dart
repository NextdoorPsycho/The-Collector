import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/pages/collection/collection_shops.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/external_links.dart';

import 'helpers/load_collector_fonts.dart';

void main() {
  setUpAll(loadCollectorFonts);
  testWidgets(
    'shop search preserves the location and recovers from a failed launch',
    (WidgetTester tester) async {
      final List<Uri> opened = <Uri>[];
      final Completer<void> pending = Completer<void>();
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: CollectionShops(
            openLink: (Uri uri) {
              opened.add(uri);
              return opened.length == 1 ? pending.future : Future<void>.value();
            },
          ),
        ),
      );
      await tester.enterText(find.byType(EditableText), 'New York 10001');
      await tester.tap(find.text('Find card shops'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed,
        isNull,
      );
      expect(opened, <Uri>[shopSearchUri('New York 10001')]);
      pending.completeError(StateError('private details'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not open the shop search. Try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('private details'), findsNothing);
      await tester.tap(find.text('Find card shops'));
      await tester.pumpAndSettle();
      expect(opened, <Uri>[
        shopSearchUri('New York 10001'),
        shopSearchUri('New York 10001'),
      ]);
      expect(
        find.text('Could not open the shop search. Try again.'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Wizards locator remains reachable with large text and keyboard',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final List<Uri> opened = <Uri>[];
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.light),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(375, 667),
              textScaler: TextScaler.linear(2.35),
              viewInsets: EdgeInsets.only(bottom: 260),
            ),
            child: CollectionShops(
              openLink: (Uri uri) async => opened.add(uri),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Wizards Store & Event Locator'));
      await tester.tap(
        find.text('Wizards Store & Event Locator').hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(opened, <Uri>[Uri.parse('https://locator.wizards.com/')]);
      expect(tester.takeException(), isNull);
    },
  );
}
