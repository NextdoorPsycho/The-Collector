import 'package:arcane/arcane.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/pages/scanning/guided_camera_screen.dart';
import 'package:the_collector/pages/scanning/live_capture_overlay.dart';

import 'helpers/camera_ui_fixture.dart';
import 'helpers/load_collector_fonts.dart';

void main() {
  setUpAll(loadCollectorFonts);
  for (final double scale in <double>[1, 2.35]) {
    testWidgets(
      'camera drawer keeps the preview and controls mounted at scale $scale',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final CameraPlatform previous = CameraPlatform.instance;
        final CameraUiPlatform camera = CameraUiPlatform();
        final CameraUiSession session = CameraUiSession();
        final ValueNotifier<bool> expanded = ValueNotifier<bool>(false);
        CameraPlatform.instance = camera;
        camera.installNativeFocusStub();
        try {
          await tester.pumpWidget(
            cameraUiApp(
              theme: ThemeMode.dark,
              scale: scale,
              session: session,
              captureDrawerBuilder: (BuildContext context) =>
                  ValueListenableBuilder<bool>(
                    valueListenable: expanded,
                    builder: (BuildContext context, bool open, Widget? child) =>
                        SizedBox(
                          key: const ValueKey<String>('drawer-fixture'),
                          height: open ? 250 : 120,
                          child: PrimaryButton(
                            onPressed: () => expanded.value = !open,
                            child: const Text('Cards'),
                          ),
                        ),
                  ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Open layout camera'));
          await waitForCameraUi(tester, camera);
          final Rect preview = tester.getRect(find.byType(LiveCaptureOverlay));
          final State<StatefulWidget> cameraState = tester.state(
            find.byType(GuidedCameraScreen),
          );
          expect(
            find.byKey(const ValueKey<String>('camera-review')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey<String>('drawer-fixture')).hitTestable(),
            findsOneWidget,
          );
          await tester.tap(find.text('Cards'));
          await tester.pumpAndSettle();
          final Rect expandedPreview = tester.getRect(
            find.byType(LiveCaptureOverlay),
          );
          final Rect expandedRail = tester.getRect(
            find.byKey(const ValueKey<String>('drawer-fixture')),
          );
          expect(expandedPreview.left, preview.left);
          expect(expandedPreview.width, preview.width);
          expect(expandedPreview.height, greaterThan(100));
          expect(expandedPreview.bottom, lessThanOrEqualTo(expandedRail.top));
          expect(
            tester
                .widget<LiveCaptureOverlay>(find.byType(LiveCaptureOverlay))
                .transform
                .viewportSize,
            expandedPreview.size,
          );
          expect(
            tester.state(find.byType(GuidedCameraScreen)),
            same(cameraState),
          );
          expect(find.byType(GuidedCameraScreen), findsOneWidget);
          expect(camera.disposals, 0);
          expect(camera.frames.hasListener, isTrue);
          await tester.tap(
            find.byKey(const ValueKey<String>('camera-adjustments')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey<String>('drawer-fixture')).hitTestable(),
            findsNothing,
          );
          await tester.tap(
            find.byKey(const ValueKey<String>('camera-adjustments')),
          );
          await tester.pumpAndSettle();
          expect(expanded.value, isTrue);
          expect(
            find.byKey(const ValueKey<String>('drawer-fixture')).hitTestable(),
            findsOneWidget,
          );
          await tester.tap(find.text('Cards'));
          await tester.pumpAndSettle();
          expect(expanded.value, isFalse);
          expect(tester.getRect(find.byType(LiveCaptureOverlay)), preview);
          expect(tester.takeException(), isNull);
        } finally {
          await disposeCameraUi(tester, camera);
          CameraPlatform.instance = previous;
          await camera.close();
          session.dispose();
          expanded.dispose();
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
