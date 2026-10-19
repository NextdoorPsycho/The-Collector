import 'package:arcane/arcane.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/pages/scanning/guided_camera_screen.dart';
import 'package:the_collector/pages/scanning/live_capture_overlay.dart';
import 'package:the_collector/theme/theme.dart';

import 'helpers/camera_ui_fixture.dart';
import 'helpers/load_collector_fonts.dart';

void main() {
  setUpAll(loadCollectorFonts);

  testWidgets('inactive workspace releases camera and keeps scan owner', (
    WidgetTester tester,
  ) async {
    final CameraPlatform previous = CameraPlatform.instance;
    final CameraUiPlatform camera = CameraUiPlatform();
    final CameraUiSession session = CameraUiSession();
    final ValueNotifier<bool> active = ValueNotifier<bool>(true);
    CameraPlatform.instance = camera;
    camera.installNativeFocusStub();
    try {
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (BuildContext context, bool value, Widget? child) =>
                GuidedCameraScreen(active: value, session: session),
          ),
        ),
      );
      await waitForCameraUi(tester, camera);
      final State<StatefulWidget> owner = tester.state(
        find.byType(GuidedCameraScreen),
      );
      final int creations = camera.operations
          .where((String entry) => entry.startsWith('create:'))
          .length;
      active.value = false;
      await tester.pumpAndSettle();
      for (int attempt = 0; attempt < 100 && camera.disposals == 0; attempt++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(camera.disposals, 1);
      expect(tester.state(find.byType(GuidedCameraScreen)), same(owner));
      expect(session.pendingPhotoCaptures, 3);
      active.value = true;
      await waitForCameraUi(tester, camera);
      expect(
        camera.operations
            .where((String entry) => entry.startsWith('create:'))
            .length,
        creations + 1,
      );
      expect(tester.state(find.byType(GuidedCameraScreen)), same(owner));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      session.dispose();
      active.dispose();
      await camera.close();
      CameraPlatform.instance = previous;
    }
  });

  testWidgets('result rail stays below the camera and controls report Paused', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final CameraPlatform previous = CameraPlatform.instance;
    final CameraUiPlatform camera = CameraUiPlatform();
    final CameraUiSession session = CameraUiSession();
    CameraPlatform.instance = camera;
    camera.installNativeFocusStub();
    try {
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: GuidedCameraScreen(
            session: session,
            captureDrawerBuilder: (BuildContext context) => const SizedBox(
              key: ValueKey<String>('result-rail'),
              height: 68,
              child: Text('Reading'),
            ),
          ),
        ),
      );
      await waitForCameraUi(tester, camera);
      expect(
        tester.getRect(find.byType(LiveCaptureOverlay)).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const ValueKey<String>('result-rail'))).top,
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('camera-adjustments')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey<String>('camera-auto-status')),
            )
            .data,
        'Paused',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      session.dispose();
      await camera.close();
      CameraPlatform.instance = previous;
    }
  });
}
