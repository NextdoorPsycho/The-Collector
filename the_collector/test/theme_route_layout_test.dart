import 'package:arcane/arcane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/theme/theme.dart';

import 'helpers/load_collector_fonts.dart';

class _ThemeProbe extends StatelessWidget {
  const _ThemeProbe();

  @override
  Widget build(BuildContext context) => Text(
    Theme.of(context).brightness.name,
    key: const ValueKey<String>('theme-probe'),
  );
}

void main() {
  setUpAll(loadCollectorFonts);

  testWidgets(
    'mounted home receives saved theme and later preference changes',
    (WidgetTester tester) async {
      final ValueNotifier<ThemeMode> mode = ValueNotifier<ThemeMode>(
        ThemeMode.light,
      );
      addTearDown(mode.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<ThemeMode>(
          valueListenable: mode,
          builder: (BuildContext context, ThemeMode value, Widget? child) =>
              ArcaneApp(
                theme: MyThemeData.themeData(value),
                home: const Scaffold(child: _ThemeProbe()),
              ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('light'), findsOneWidget);
      mode.value = ThemeMode.dark;
      await tester.pumpAndSettle();
      expect(find.text('dark'), findsOneWidget);
      mode.value = ThemeMode.light;
      await tester.pumpAndSettle();
      expect(find.text('light'), findsOneWidget);
    },
  );

  testWidgets('pushed scaffold respects notch and home indicator insets', (
    WidgetTester tester,
  ) async {
    const Size size = Size(393, 852);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: const MediaQueryData(
            size: size,
            padding: EdgeInsets.only(top: 59, bottom: 34),
            viewPadding: EdgeInsets.only(top: 59, bottom: 34),
          ),
          child: child!,
        ),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            child: PrimaryButton(
              onPressed: () => Arcane.push(
                context,
                const Scaffold(
                  headers: <Widget>[AppBar(title: Text('Card Details'))],
                  child: SizedBox.expand(key: ValueKey<String>('route-body')),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Card Details')).dy,
      greaterThanOrEqualTo(59),
    );
    expect(
      tester
          .getBottomRight(find.byKey(const ValueKey<String>('route-body')))
          .dy,
      lessThanOrEqualTo(size.height - 34),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested pane and footer consume portrait insets once', (
    WidgetTester tester,
  ) async {
    const Size size = Size(393, 852);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: const MediaQueryData(
            size: size,
            padding: EdgeInsets.only(top: 59, bottom: 34),
            viewPadding: EdgeInsets.only(top: 59, bottom: 34),
          ),
          child: child!,
        ),
        home: const Scaffold(
          footers: <Widget>[
            SizedBox(height: 44, key: ValueKey<String>('footer')),
          ],
          child: Scaffold(
            headers: <Widget>[AppBar(title: Text('Games'))],
            child: SizedBox.expand(key: ValueKey<String>('nested-body')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final double headerY = tester.getTopLeft(find.text('Games')).dy;
    expect(headerY, greaterThanOrEqualTo(59));
    expect(headerY, lessThan(100), reason: 'No second notch-height padding.');
    final Rect footer = tester.getRect(
      find.byKey(const ValueKey<String>('footer')),
    );
    expect(footer.bottom, size.height - 34);
    expect(
      tester
          .getBottomRight(find.byKey(const ValueKey<String>('nested-body')))
          .dy,
      footer.top,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('headerless route respects landscape cutout edges', (
    WidgetTester tester,
  ) async {
    const Size size = Size(852, 393);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: const MediaQueryData(
            size: size,
            padding: EdgeInsets.only(left: 59, right: 59, bottom: 21),
            viewPadding: EdgeInsets.only(left: 59, right: 59, bottom: 21),
          ),
          child: child!,
        ),
        home: const Scaffold(
          child: SizedBox.expand(key: ValueKey<String>('landscape-body')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('landscape-body'))),
      const Rect.fromLTRB(59, 0, 793, 372),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard hides footer and reserves its inset for body', (
    WidgetTester tester,
  ) async {
    const Size size = Size(375, 667);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: const MediaQueryData(
            size: size,
            padding: EdgeInsets.only(top: 20),
            viewPadding: EdgeInsets.only(top: 20, bottom: 34),
            viewInsets: EdgeInsets.only(bottom: 250),
          ),
          child: child!,
        ),
        home: const Scaffold(
          footers: <Widget>[SizedBox(height: 44, child: Text('Footer'))],
          child: SizedBox.expand(key: ValueKey<String>('keyboard-body')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Footer').hitTestable(), findsNothing);
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('keyboard-body'))),
      const Rect.fromLTRB(0, 20, 375, 417),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty bars support a zero-height scaffold', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        home: const Center(
          child: SizedBox(
            width: 320,
            height: 0,
            child: Scaffold(
              child: SizedBox.expand(key: ValueKey<String>('zero-body')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('zero-body'))).height,
      0,
    );
    expect(tester.takeException(), isNull);
  });
}
