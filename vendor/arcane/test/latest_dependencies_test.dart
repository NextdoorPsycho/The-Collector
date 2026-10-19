import 'package:arcane/arcane.dart';
import 'package:country_flags/country_flags.dart' as flags;
import 'package:flutter/widgets.dart' as widgets show Table, TableRow;
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:measure_size/measure_size.dart';

class _Tiles extends Fake implements QuiltTileFaucet<int> {}

Iterable<InlineSpan> _spans(InlineSpan span) sync* {
  yield span;
  if (span is TextSpan) {
    for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
      yield* _spans(child);
    }
  }
}

void main() {
  for (final bool force in <bool>[false, true]) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets(
        '${force ? 'ForceMarkdown' : 'Markdown'} code stays selectable at 320px in ${brightness.name}',
        (WidgetTester tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final ThemeData theme = brightness == Brightness.dark
              ? ThemeData.dark()
              : ThemeData();
          const String code = '''void identifyCard() {
  print('aVeryLongUnbrokenCollectorIdentifierToCheckNarrowScreens');
}''';
          const String markdown = '```dart\n$code\n```';
          await tester.pumpWidget(
            ShadcnApp(
              theme: theme,
              builder: (BuildContext context, Widget? child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2.35)),
                child: child!,
              ),
              home: Scaffold(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: force
                        ? const ForceMarkdown(markdown)
                        : const Markdown(markdown),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final SelectableText selectable = tester.widget<SelectableText>(
            find.byType(SelectableText),
          );
          expect(selectable.data, contains(code));
          expect(selectable.enableInteractiveSelection, isTrue);
          final EditableText editable = tester.widget<EditableText>(
            find.byType(EditableText),
          );
          expect(editable.style.fontFamily, theme.typography.mono.fontFamily);
          expect(
            tester.getRect(find.byType(SelectableText)).left,
            greaterThanOrEqualTo(0),
          );
          expect(
            tester.getRect(find.byType(SelectableText)).right,
            lessThanOrEqualTo(320),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final bool force in <bool>[false, true]) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets(
        '${force ? 'ForceMarkdown' : 'Markdown'} modern tables keep empty cells and inline formatting in ${brightness.name}',
        (WidgetTester tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final ThemeData theme = brightness == Brightness.dark
              ? ThemeData.dark()
              : ThemeData();
          const String markdown = '''| Card | Count | Notes |
| :--- | ---: | --- |
| **Nevermore** | 3 | |
| Circle of Protection: Blue | | [Ice Age](https://example.test/ice) |''';
          await tester.pumpWidget(
            ShadcnApp(
              theme: theme,
              home: Scaffold(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: force
                      ? const ForceMarkdown(markdown)
                      : const Markdown(markdown),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final widgets.Table table = tester.widget<widgets.Table>(
            find.byType(widgets.Table),
          );
          expect(table.children, hasLength(3));
          for (final widgets.TableRow row in table.children) {
            expect(row.children, hasLength(3));
          }
          expect(table.border!.top.color, theme.colorScheme.border);
          expect(table.border!.top, table.border!.bottom);
          expect(table.border!.top, table.border!.left);
          expect(table.border!.top, table.border!.right);
          final List<InlineSpan> spans = tester
              .widgetList<RichText>(
                find.byWidgetPredicate((Widget widget) => widget is RichText),
              )
              .expand((RichText text) => _spans(text.text))
              .toList();
          expect(
            spans.whereType<TextSpan>().any(
              (TextSpan span) =>
                  span.text == 'Nevermore' &&
                  span.style?.fontWeight == FontWeight.bold,
            ),
            isTrue,
          );
          expect(
            spans.whereType<LinkTextSpan>().any(
              (LinkTextSpan span) => span.url == 'https://example.test/ice',
            ),
            isTrue,
          );
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        '${force ? 'ForceMarkdown' : 'Markdown'} long links wrap and quotes use Arcane surfaces in ${brightness.name}',
        (WidgetTester tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const String label =
              'Read the complete printing identification and collector number reference';
          const String markdown =
              '[$label](https://example.test/reference)\n\n> Keep each card in its own group.';
          await tester.pumpWidget(
            ShadcnApp(
              theme: brightness == Brightness.dark
                  ? ThemeData.dark()
                  : ThemeData(),
              builder: (BuildContext context, Widget? child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2.35)),
                child: child!,
              ),
              home: Scaffold(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: force
                        ? const ForceMarkdown(markdown)
                        : const Markdown(markdown),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final Finder linkText = find.byWidgetPredicate(
            (Widget widget) =>
                widget is RichText && widget.text.toPlainText() == label,
          );
          expect(linkText, findsOneWidget);
          expect(tester.getRect(linkText).right, lessThanOrEqualTo(320));
          expect(tester.getSize(linkText).height, greaterThan(40));
          final RichText richText = tester.widget<RichText>(linkText);
          final LinkTextSpan link = _spans(richText.text)
              .whereType<LinkTextSpan>()
              .single;
          expect(link.onTap, isNotNull);
          expect(find.byType(HoverCard), findsNothing);
          expect(find.byType(SurfaceCard), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final Brightness brightness in Brightness.values) {
    testWidgets(
      'Markdown math remains readable at 320px with large text in ${brightness.name}',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final SemanticsHandle semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            ShadcnApp(
              theme: brightness == Brightness.dark
                  ? ThemeData.dark()
                  : ThemeData(),
              builder: (BuildContext context, Widget? child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2.35)),
                child: child!,
              ),
              home: const Scaffold(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Markdown(r'''Life totals use \(x_i^2\).

\[
\begin{aligned}
L_1 &= 20 \\
L_2 &= 40
\end{aligned}
\]

Each player keeps a separate total.'''),
                        SizedBox(height: 24),
                        Text('End of rules', key: Key('rules-end')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.bySemanticsLabel(RegExp('squared')), findsWidgets);
          expect(
            find.textContaining('Life totals', findRichText: true),
            findsWidgets,
          );
          await tester.ensureVisible(find.byKey(const Key('rules-end')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('rules-end')).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  for (final DashedBorderShape shape in DashedBorderShape.values) {
    testWidgets(
      'dashed ${shape.name} keeps its complete perimeter and bounds',
      (WidgetTester tester) async {
        const Color border = Color(0xff737373);
        const Radius radius = Radius.circular(12);
        await tester.pumpWidget(
          ShadcnApp(
            theme: ThemeData(),
            home: Center(
              child: DashBorderMode(
                signal: DashedBorderSignal(
                  shape: shape,
                  borderStyle: const <double>[7, 3],
                ),
                builder: (BuildContext context) => const OutlinedContainer(
                  borderColor: border,
                  borderWidth: 2,
                  borderRadius: BorderRadius.all(radius),
                  child: SizedBox(width: 140, height: 80),
                ),
              ),
            ),
          ),
        );
        final DottedBorder dotted = tester.widget<DottedBorder>(
          find.byType(DottedBorder),
        );
        final DottedBorderOptions options = dotted.options;
        switch (shape) {
          case DashedBorderShape.rectangle:
            expect(options, isA<RectDottedBorderOptions>());
          case DashedBorderShape.roundedRectangle:
            expect(options, isA<RoundedRectDottedBorderOptions>());
            expect((options as RoundedRectDottedBorderOptions).radius, radius);
          case DashedBorderShape.circle:
            expect(options, isA<CircularDottedBorderOptions>());
          case DashedBorderShape.oval:
            expect(options, isA<OvalDottedBorderOptions>());
        }
        expect(options.color, border);
        expect(options.strokeWidth, 4);
        expect(options.dashPattern, <double>[7, 3]);
        expect(options.padding, EdgeInsets.zero);
        expect(options.borderPadding, EdgeInsets.zero);
        expect(options.strokeCap, StrokeCap.round);
        expect(options.stackFit, StackFit.passthrough);
        expect(tester.getSize(find.byType(DottedBorder)), const Size(140, 80));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'skeleton follows Arcane brightness and preserves pulse overrides',
    (WidgetTester tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final ThemeData theme = ThemeData.dark();
      SkeletonizerConfigData? configuration;
      await tester.pumpWidget(
        ShadcnApp(
          theme: theme,
          home: ShadcnSkeletonizerConfigLayer(
            theme: theme,
            duration: const Duration(milliseconds: 800),
            fromColor: const Color(0xff222222),
            toColor: const Color(0xff666666),
            enableSwitchAnimation: false,
            child: Builder(
              builder: (BuildContext context) {
                configuration = SkeletonizerConfig.of(context);
                return const Text('Loading a card');
              },
            ),
          ),
        ),
      );
      expect(configuration!.brightness, Brightness.dark);
      final PulseEffect effect =
          configuration!.resolveEffect(Brightness.light) as PulseEffect;
      expect(effect.duration, const Duration(milliseconds: 800));
      expect(effect.from, const Color(0xff222222));
      expect(effect.to, const Color(0xff666666));
      expect(configuration!.enableSwitchAnimation, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone selector and popup preserve configured image flag geometry',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        ShadcnApp(
          theme: ThemeData(),
          home: Scaffold(
            child: Center(
              child: ComponentTheme<PhoneInputTheme>(
                data: const PhoneInputTheme(
                  flagWidth: 32,
                  flagHeight: 20,
                  flagShape: flags.RoundedRectangle(6),
                ),
                child: const PhoneInput(
                  countries: <Country>[Country.unitedStates, Country.canada],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      void checkFlags() {
        for (final flags.CountryFlag flag
            in tester.widgetList<flags.CountryFlag>(
              find.byType(flags.CountryFlag),
            )) {
          final flags.ImageTheme image = flag.theme as flags.ImageTheme;
          expect(image.width, 32);
          expect(image.height, 20);
          expect((image.shape as flags.RoundedRectangle).borderRadius, 6);
        }
      }

      expect(find.byType(flags.CountryFlag), findsOneWidget);
      checkFlags();
      await tester.tap(find.text('+1').hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(flags.CountryFlag), findsNWidgets(3));
      checkFlags();
      await tester.tap(find.text('Canada').hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(flags.CountryFlag), findsOneWidget);
      checkFlags();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'open mobile phone selector completes safely when its page is removed',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        ShadcnApp(
          theme: ThemeData(),
          home: const Scaffold(
            child: Center(
              child: PhoneInput(
                countries: <Country>[Country.unitedStates, Country.canada],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('+1').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('Canada').hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  test('measured quilt unwraps a required child and rejects a missing one', () {
    final QuiltFaucet<int> faucet = QuiltFaucet<int>(
      style: const CarpetStyle(),
      tileFaucet: _Tiles(),
      tileBuilder: (int tile) => const SizedBox.shrink(),
    );
    final StaggeredGrid grid = StaggeredGrid.count(
      crossAxisCount: 2,
      children: const <Widget>[],
    );
    expect(
      faucet.getStaggeredGrid(
        MeasureSize(onChange: (Size size) {}, child: grid),
      ),
      same(grid),
    );
    expect(
      () => faucet.getStaggeredGrid(
        MeasureSize(onChange: (Size size) {}, child: null),
      ),
      throwsStateError,
    );
  });

  testWidgets('measurement emits concrete sizes when quilt layout changes', (
    WidgetTester tester,
  ) async {
    final List<Size> sizes = <Size>[];
    Future<void> layout(double height) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: MeasureSize(
              key: const Key('measured-quilt'),
              onChange: sizes.add,
              child: SizedBox(width: 120, height: height),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await layout(60);
    await layout(90);
    expect(sizes, <Size>[const Size(120, 60), const Size(120, 90)]);
    expect(tester.takeException(), isNull);
  });
}
