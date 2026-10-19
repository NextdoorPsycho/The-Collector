import 'dart:ui' show SemanticsAction;

import 'package:arcane/arcane.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart'
    show DeviceOrientation, LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/pages/scanning/live_capture_overlay.dart';

import 'helpers/camera_ui_fixture.dart';
import 'helpers/load_collector_fonts.dart';

const List<String> _actions = <String>[
  'camera-review',
  'camera-auto-pause',
  'camera-clear-captures',
  'camera-adjustments',
];

void _reachableActions(WidgetTester tester, Size size) {
  for (final String key in _actions) {
    final Finder control = find.byKey(ValueKey<String>(key));
    expect(control.hitTestable(), findsOneWidget);
    final Rect bounds = tester.getRect(control);
    expect(bounds.width, greaterThanOrEqualTo(44));
    expect(bounds.height, greaterThanOrEqualTo(44));
    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(size.width));
    expect(bounds.top, greaterThanOrEqualTo(0));
    expect(bounds.bottom, lessThanOrEqualTo(size.height));
  }
}

void _confirmationFits(WidgetTester tester, double scale) {
  final Finder status = find.byKey(
    const ValueKey<String>('camera-auto-status'),
  );
  final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
    status,
  );
  final Text source = tester.widget<Text>(status);
  final TextStyle style =
      (paragraph.text as TextSpan).style ??
      DefaultTextStyle.of(tester.element(status)).style;
  final TextPainter confirmation = TextPainter(
    text: TextSpan(
      text: 'Next card',
      style: style.copyWith(fontWeight: FontWeight.w600),
    ),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.linear(scale),
    maxLines: source.maxLines,
  )..layout(maxWidth: paragraph.constraints.maxWidth);
  try {
    expect(
      confirmation.didExceedMaxLines,
      isFalse,
      reason: 'The saved-card confirmation fits the actual production banner width.',
    );
    final Finder banner = find
        .ancestor(of: status, matching: find.byType(AnimatedContainer))
        .first;
    expect(
      confirmation.height,
      lessThanOrEqualTo(tester.getSize(banner).height),
    );
  } finally {
    confirmation.dispose();
  }
}

Future<void> _tabToCameraAction(WidgetTester tester, String key) async {
  final Finder action = find.byKey(ValueKey<String>(key));
  bool focused() => tester
      .widgetList<FocusOutline>(
        find.descendant(of: action, matching: find.byType(FocusOutline)),
      )
      .any((FocusOutline outline) => outline.focused);
  for (int step = 0; step < 16 && !focused(); step++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
  }
  expect(focused(), isTrue, reason: '$key has a visible keyboard focus ring.');
  expect(action.hitTestable(), findsOneWidget);
}

void main() {
  setUpAll(loadCollectorFonts);
  for (final ThemeMode theme in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
    for (final ({Size size, double scale}) config
        in <({Size size, double scale})>[
          (size: const Size(320, 568), scale: 1),
          (size: const Size(375, 667), scale: 1),
          (size: const Size(320, 568), scale: 2.35),
          (size: const Size(667, 375), scale: 2.35),
        ]) {
      testWidgets(
        'camera actions and focus retain preview geometry ${theme.name} ${config.size} ${config.scale}',
        (WidgetTester tester) async {
          tester.view.physicalSize = config.size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final CameraPlatform previous = CameraPlatform.instance;
          final CameraUiPlatform camera = CameraUiPlatform(
            orientation: config.size.width > config.size.height
                ? DeviceOrientation.landscapeLeft
                : DeviceOrientation.portraitUp,
          );
          final CameraUiSession session = CameraUiSession();
          CameraPlatform.instance = camera;
          camera.installNativeFocusStub();
          bool completed = false;
          try {
            await tester.pumpWidget(
              cameraUiApp(theme: theme, scale: config.scale, session: session),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('Open layout camera'));
            await waitForCameraUi(tester, camera);
            final Finder review = find.byKey(
              const ValueKey<String>('camera-review'),
            );
            expect(tester.widget<PrimaryButton>(review).onPressed, isNotNull);
            final SemanticsHandle semantics = tester.ensureSemantics();
            try {
              expect(
                find.bySemanticsLabel(RegExp('Review captures for Collection')),
                findsWidgets,
              );
              expect(
                tester
                    .getSemantics(review)
                    .getSemanticsData()
                    .hasAction(SemanticsAction.tap),
                isTrue,
              );
              if (config.scale <= 1.5) {
                expect(find.text('Review'), findsOneWidget);
              }
            } finally {
              semantics.dispose();
            }
            _reachableActions(tester, config.size);
            _confirmationFits(tester, config.scale);
            final Finder overlay = find.byType(LiveCaptureOverlay);
            final Rect preview = tester.getRect(overlay);
            expect(preview.height, greaterThan(100));
            await tester.tap(
              find.byKey(const ValueKey<String>('camera-auto-pause')),
            );
            await tester.pumpAndSettle();
            expect(
              find.bySemanticsLabel('Resume automatic capture'),
              findsOneWidget,
            );
            await tester.tap(
              find.byKey(const ValueKey<String>('camera-adjustments')),
            );
            await tester.pumpAndSettle();
            expect(tester.getRect(overlay), preview);
            _reachableActions(tester, config.size);
            final Rect panel = tester.getRect(
              find.byKey(const ValueKey<String>('camera-controls-panel')),
            );
            final Offset focus = Offset(preview.center.dx, preview.top + 16);
            expect(panel.contains(focus), isFalse);
            final int priorFocus = camera.focusPoints.length;
            await tester.tapAt(focus);
            await tester.pumpAndSettle();
            expect(camera.focusPoints.length, greaterThan(priorFocus));
            expect(camera.focusPoints.last.x, inInclusiveRange(0, 1));
            expect(camera.focusPoints.last.y, inInclusiveRange(0, 1));
            await tester.tap(
              find.byKey(const ValueKey<String>('camera-adjustments')),
            );
            await tester.pumpAndSettle();
            expect(tester.getRect(overlay), preview);
            await tester.tap(review);
            await tester.pumpAndSettle();
            expect(
              find.text('Open layout camera').hitTestable(),
              findsOneWidget,
            );
            expect(camera.captures, 0);
            expect(tester.takeException(), isNull);
            completed = true;
          } finally {
            await disposeCameraUi(tester, camera, verify: completed);
            CameraPlatform.instance = previous;
            await camera.close();
            session.dispose();
          }
        },
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      );
    }
  }
  testWidgets(
    'camera footer can pause and open controls with Tab and Enter at large text',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final CameraPlatform previous = CameraPlatform.instance;
      final CameraUiPlatform camera = CameraUiPlatform();
      final CameraUiSession session = CameraUiSession();
      CameraPlatform.instance = camera;
      camera.installNativeFocusStub();
      bool completed = false;
      try {
        await tester.pumpWidget(
          cameraUiApp(theme: ThemeMode.dark, scale: 2.35, session: session),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open layout camera'));
        await waitForCameraUi(tester, camera);
        final Rect preview = tester.getRect(find.byType(LiveCaptureOverlay));
        await _tabToCameraAction(tester, 'camera-auto-pause');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('Paused'), findsOneWidget);
        expect(
          find.bySemanticsLabel('Resume automatic capture'),
          findsOneWidget,
        );
        await _tabToCameraAction(tester, 'camera-adjustments');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey<String>('camera-controls-panel')),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel('Close camera controls'), findsOneWidget);
        expect(tester.getRect(find.byType(LiveCaptureOverlay)), preview);
        _reachableActions(tester, const Size(320, 568));
        expect(camera.captures, 0);
        expect(tester.takeException(), isNull);
        completed = true;
      } finally {
        await disposeCameraUi(tester, camera, verify: completed);
        CameraPlatform.instance = previous;
        await camera.close();
        session.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
  testWidgets(
    'clearing queued fixture photos disables Review without taking a picture',
    (WidgetTester tester) async {
      final CameraPlatform previous = CameraPlatform.instance;
      final CameraUiPlatform camera = CameraUiPlatform();
      final CameraUiSession session = CameraUiSession();
      CameraPlatform.instance = camera;
      camera.installNativeFocusStub();
      bool completed = false;
      try {
        await tester.pumpWidget(
          cameraUiApp(theme: ThemeMode.dark, scale: 1, session: session),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open layout camera'));
        await waitForCameraUi(tester, camera);
        await tester.tap(
          find.byKey(const ValueKey<String>('camera-clear-captures')),
        );
        await waitForCameraUiClear(tester, session);
        expect(session.pendingPhotoCaptures, 0);
        expect(
          tester
              .widget<PrimaryButton>(
                find.byKey(const ValueKey<String>('camera-review')),
              )
              .onPressed,
          isNull,
        );
        expect(camera.captures, 0);
        expect(tester.takeException(), isNull);
        completed = true;
      } finally {
        await disposeCameraUi(tester, camera, verify: completed);
        CameraPlatform.instance = previous;
        await camera.close();
        session.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
