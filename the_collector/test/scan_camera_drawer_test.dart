import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/pages/scanning/scan_camera_drawer.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_session.dart';

ScanSessionItem _item(String id) =>
    ScanSessionItem(
        const ScanCrop(
          imagePath: '',
          width: 630,
          height: 880,
          rectified: true,
          sourceCorners: <ScanPoint>[],
          lines: <ScanTextLine>[],
        ),
        id: id,
      )
      ..resolution = const ScanResolution(
        candidates: <ScanCandidate>[],
        hints: ScanHints(names: <String>[]),
        status: ScanResolutionStatus.noMatch,
      );

Future<void> _show(
  WidgetTester tester,
  Widget child, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(ThemeMode.light),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        child: Align(alignment: Alignment.bottomCenter, child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ScanCameraDrawer _drawer({
  List<ScanSessionItem> items = const <ScanSessionItem>[],
  int pending = 0,
  String? addedId,
  bool busy = false,
  bool Function(String)? canUndo,
  Future<void> Function(String)? onUndo,
  Future<void> Function(ScanSessionItem)? onEdit,
  Future<void> Function(ScanSessionItem)? onRemove,
  Set<String> submittedIds = const <String>{},
}) => ScanCameraDrawer(
  items: items,
  submittedIds: submittedIds,
  pendingPhotos: pending,
  busy: busy,
  error: null,
  lastAddedName: addedId == null ? null : 'Lightning Bolt',
  lastAddedId: addedId,
  canUndo: canUndo ?? (_) => false,
  onUndo: onUndo ?? (_) async {},
  onEdit: onEdit ?? (_) async {},
  onRemove: onRemove ?? (_) async {},
);

void main() {
  testWidgets(
    'remove targets one capture, serializes taps, and retries failure',
    (WidgetTester tester) async {
      final ScanSessionItem first = _item('first');
      final ScanSessionItem second = _item('second');
      final ValueNotifier<List<ScanSessionItem>> items =
          ValueNotifier<List<ScanSessionItem>>(<ScanSessionItem>[
            first,
            second,
          ]);
      addTearDown(items.dispose);
      final Completer<void> held = Completer<void>();
      final List<String> removed = <String>[];
      int attempts = 0;
      await _show(
        tester,
        ValueListenableBuilder<List<ScanSessionItem>>(
          valueListenable: items,
          builder: (_, List<ScanSessionItem> values, _) => _drawer(
            items: values,
            onRemove: (ScanSessionItem item) async {
              attempts++;
              if (attempts == 1) {
                await held.future;
                throw StateError('Disk full');
              }
              removed.add(item.id);
              items.value = values
                  .where((ScanSessionItem current) => current != item)
                  .toList();
            },
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('camera-drawer-needs-check')),
      );
      await tester.pumpAndSettle();
      final Finder remove = find.byKey(
        const ValueKey<String>('camera-drawer-remove-first'),
      );
      expect(tester.getSize(remove), const Size(44, 44));
      await tester.tap(remove);
      await tester.pump();
      expect(tester.widget<IconButton>(remove).onPressed, isNull);
      held.complete();
      await tester.pumpAndSettle();
      expect(find.text('Could not remove'), findsOneWidget);
      expect(items.value, <ScanSessionItem>[first, second]);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(removed, <String>['first']);
      expect(items.value, <ScanSessionItem>[second]);
      expect(
        find.byKey(const ValueKey<String>('camera-drawer-check-second')),
        findsOneWidget,
      );
      expect(find.text('Could not remove'), findsNothing);
    },
  );

  testWidgets('stale remove cannot delete a replacement or submitted capture', (
    WidgetTester tester,
  ) async {
    final ScanSessionItem old = _item('one');
    final ValueNotifier<List<ScanSessionItem>> items =
        ValueNotifier<List<ScanSessionItem>>(<ScanSessionItem>[old]);
    addTearDown(items.dispose);
    final Set<String> submitted = <String>{};
    int removals = 0;
    await _show(
      tester,
      ValueListenableBuilder<List<ScanSessionItem>>(
        valueListenable: items,
        builder: (_, List<ScanSessionItem> values, _) => _drawer(
          items: values,
          submittedIds: submitted,
          onRemove: (_) async => removals++,
        ),
      ),
    );
    final VoidCallback stale = tester
        .widget<IconButton>(
          find.byKey(const ValueKey<String>('camera-drawer-remove-one')),
        )
        .onPressed!;
    items.value = <ScanSessionItem>[_item('one')];
    await tester.pumpAndSettle();
    stale();
    await tester.pumpAndSettle();
    expect(removals, 0);
    final VoidCallback pending = tester
        .widget<IconButton>(
          find.byKey(const ValueKey<String>('camera-drawer-remove-one')),
        )
        .onPressed!;
    submitted.add('one');
    items.value = List<ScanSessionItem>.of(items.value);
    await tester.pumpAndSettle();
    pending();
    await tester.pumpAndSettle();
    expect(removals, 0);
    expect(
      find.byKey(const ValueKey<String>('camera-drawer-remove-one')),
      findsNothing,
    );
  });

  testWidgets('empty rail distinguishes pending identification from idle', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<int> pending = ValueNotifier<int>(2);
    addTearDown(pending.dispose);
    await _show(
      tester,
      ValueListenableBuilder<int>(
        valueListenable: pending,
        builder: (_, int count, _) => _drawer(pending: count),
      ),
    );
    expect(find.text('Reading 2'), findsOneWidget);
    pending.value = 0;
    await tester.pumpAndSettle();
    expect(find.text('Ready'), findsOneWidget);
  });

  testWidgets(
    'stale same-ID row cannot edit a replacement or removed capture',
    (WidgetTester tester) async {
      final ScanSessionItem old = _item('one');
      final ValueNotifier<List<ScanSessionItem>> items =
          ValueNotifier<List<ScanSessionItem>>(<ScanSessionItem>[old]);
      addTearDown(items.dispose);
      int edits = 0;
      await _show(
        tester,
        ValueListenableBuilder<List<ScanSessionItem>>(
          valueListenable: items,
          builder: (_, List<ScanSessionItem> values, _) =>
              _drawer(items: values, onEdit: (_) async => edits++),
        ),
      );
      final VoidCallback callback = tester
          .widget<GhostButton>(
            find.byKey(const ValueKey<String>('camera-drawer-latest-one')),
          )
          .onPressed!;
      items.value = <ScanSessionItem>[_item('one')];
      await tester.pumpAndSettle();
      callback();
      await tester.pumpAndSettle();
      expect(edits, 0);
      items.value = <ScanSessionItem>[];
      await tester.pumpAndSettle();
      callback();
      expect(edits, 0);
    },
  );

  testWidgets('undo serializes taps and keeps a failed receipt retryable', (
    WidgetTester tester,
  ) async {
    final Completer<void> held = Completer<void>();
    int attempts = 0;
    await _show(
      tester,
      _drawer(
        addedId: 'one',
        canUndo: (_) => true,
        onUndo: (_) async {
          attempts++;
          if (attempts == 1) {
            await held.future;
            throw StateError('Offline');
          }
        },
      ),
    );
    final Finder undo = find.byKey(
      const ValueKey<String>('camera-drawer-undo'),
    );
    await tester.tap(undo);
    await tester.pump();
    expect(tester.widget<TextButton>(undo).onPressed, isNull);
    held.complete();
    await tester.pumpAndSettle();
    expect(find.text('Could not undo'), findsOneWidget);
    await tester.tap(undo);
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Could not undo'), findsNothing);
  });

  for (final double scale in <double>[1, 2.35]) {
    testWidgets(
      'bounded needs-check page keeps its place as new cards arrive at scale $scale',
      (WidgetTester tester) async {
        final ValueNotifier<List<ScanSessionItem>> items =
            ValueNotifier<List<ScanSessionItem>>(
              List<ScanSessionItem>.generate(
                20,
                (int index) => _item('$index'),
              ),
            );
        addTearDown(items.dispose);
        await _show(
          tester,
          ValueListenableBuilder<List<ScanSessionItem>>(
            valueListenable: items,
            builder: (_, List<ScanSessionItem> values, _) =>
                _drawer(items: values),
          ),
          scale: scale,
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-drawer-needs-check')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-drawer-next')),
        );
        await tester.pumpAndSettle();
        final String first = scale == 1 ? '3' : '1';
        final Finder row = find.byKey(
          ValueKey<String>('camera-drawer-check-$first'),
        );
        expect(row, findsOneWidget);
        items.value = <ScanSessionItem>[...items.value, _item('new')];
        await tester.pumpAndSettle();
        expect(row, findsOneWidget);
        expect(tester.getSize(row).height, greaterThanOrEqualTo(44));
        expect(
          tester
              .getSize(find.byKey(const ValueKey<String>('camera-drawer')))
              .height,
          lessThanOrEqualTo(300),
        );
        expect(find.byType(Scrollable), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
