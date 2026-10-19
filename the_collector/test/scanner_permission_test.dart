import 'package:arcane/arcane.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart'
    as picker;
import 'package:scryfall_api/scryfall_api.dart' show Rarity, SetType;
import 'package:the_collector/pages/scanning/guided_camera_screen.dart';
import 'package:the_collector/pages/scanning/scan_screen.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/scanning/scan_queue.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';

class _DeniedCamera extends CameraPlatform {
  _DeniedCamera(this.code);
  final String code;
  int attempts = 0;

  @override
  Future<List<CameraDescription>> availableCameras() async =>
      const <CameraDescription>[
        CameraDescription(
          name: 'fixture',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
      ];

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream<DeviceOrientationChangedEvent>.empty();

  @override
  Future<int> createCameraWithSettings(
    CameraDescription description,
    MediaSettings settings,
  ) async {
    attempts++;
    throw PlatformException(code: code, message: 'Native permission detail');
  }

  @override
  Future<void> dispose(int cameraId) async {}
}

class _DeniedPhotos extends picker.ImagePickerPlatform {
  int attempts = 0;
  @override
  Future<List<picker.XFile>> getMultiImageWithOptions({
    picker.MultiImagePickerOptions options =
        const picker.MultiImagePickerOptions(),
  }) async {
    attempts++;
    if (attempts == 1) {
      throw PlatformException(
        code: 'photo_access_denied',
        message: 'Native permission detail',
      );
    }
    return <picker.XFile>[];
  }
}

class _SavedQueue implements ScanQueueStorage {
  @override
  Future<List<ScanQueueEntry>> readCompletedEntries(String userId) async =>
      <ScanQueueEntry>[];
  @override
  Future<void> completeEntry(String userId, ScanQueueEntry entry) async =>
      throw StateError('Permission failure must not complete saved additions.');
  @override
  Future<void> removeCompletedEntries(
    String userId,
    List<String> operationIds,
  ) async => throw StateError(
    'Permission failure must not remove completion receipts.',
  );
  final ScanQueueEntry entry = ScanQueueEntry(
    operationId: 'saved-before-denial',
    card: MTGCard(
      name: 'Previously reviewed card',
      setId: 'fixture',
      description: '',
      flavorText: '',
      cmc: 1,
      typeLine: 'Instant',
      rarity: Rarity.common,
      setType: SetType.expansion,
      manaCost: '{R}',
    ),
    quantity: 3,
    createdAt: DateTime.utc(2026),
    error: 'Saved upload is awaiting retry.',
  );
  @override
  Future<List<ScanQueueEntry>> readEntries(String userId) async =>
      <ScanQueueEntry>[entry];
  @override
  Future<void> upsertEntries(
    String userId,
    List<ScanQueueEntry> entries,
  ) async =>
      throw StateError('Permission failure must not change saved additions.');
  @override
  Future<void> removeEntries(String userId, List<String> ids) async =>
      throw StateError('Permission failure must not remove saved additions.');
}

class _UnusedRecognizer implements CardRecognizer {
  int calls = 0;
  @override
  Future<ScanRecognition> recognize(
    String imagePath, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    calls++;
    throw StateError('Permission denial must not start recognition.');
  }
}

Future<void> _show(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(
    ArcaneApp(theme: MyThemeData.themeData(ThemeMode.dark), home: screen),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final String code in <String>[
    'CameraAccessDenied',
    'CameraAccessDeniedWithoutPrompt',
    'CameraAccessRestricted',
  ]) {
    testWidgets(
      '$code presents settings guidance, disables capture, and permits retry',
      (WidgetTester tester) async {
        final CameraPlatform previous = CameraPlatform.instance;
        final _DeniedCamera camera = _DeniedCamera(code);
        CameraPlatform.instance = camera;
        addTearDown(() => CameraPlatform.instance = previous);
        int captured = 0;
        await _show(
          tester,
          GuidedCameraScreen(
            automaticCapture: false,
            onCaptured:
                (String _, List<List<ScanPoint>> excludedRegions) async {
                  captured++;
                  return true;
                },
          ),
        );
        expect(
          find.text('Camera access denied. Enable Camera in Settings.'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<PrimaryButton>(
                find.widgetWithText(PrimaryButton, 'Capture photo'),
              )
              .onPressed,
          isNull,
        );
        expect(camera.attempts, 1);
        await tester.ensureVisible(find.text('Retry camera'));
        await tester.tap(find.text('Retry camera'));
        await tester.pumpAndSettle();
        expect(camera.attempts, 2);
        expect(captured, 0);
        expect(find.text('Native permission detail'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'gallery denial and subsequent cancel preserve saved additions and manual entry',
    (WidgetTester tester) async {
      final picker.ImagePickerPlatform previous =
          picker.ImagePickerPlatform.instance;
      final _DeniedPhotos photos = _DeniedPhotos();
      picker.ImagePickerPlatform.instance = photos;
      addTearDown(() {
        picker.ImagePickerPlatform.instance = previous;
      });
      final _UnusedRecognizer recognizer = _UnusedRecognizer();
      int writes = 0;
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        storage: _SavedQueue(),
        writer: (ScanQueueEntry _) async {
          writes++;
        },
      );
      addTearDown(queue.dispose);
      await _show(
        tester,
        ScanScreen(
          userId: 'fixture',
          queue: queue,
          recognizer: recognizer,
          decks: Stream<List<MTGDeck>>.value(<MTGDeck>[]),
        ),
      );
      await tester.tap(find.widgetWithIcon(IconButton, Icons.dots_three));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select photos').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attention'));
      await tester.pumpAndSettle();
      expect(
        find
            .text('Could not select photos. Try selecting them again.')
            .hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.text('Done').hitTestable());
      await tester.pumpAndSettle();
      expect(queue.count, 1);
      expect(queue.entryAt(0).operationId, 'saved-before-denial');
      expect(queue.entryAt(0).quantity, 3);
      expect(queue.entryAt(0).error, 'Saved upload is awaiting retry.');
      await tester.tap(find.widgetWithIcon(IconButton, Icons.dots_three));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select photos').hitTestable());
      await tester.pumpAndSettle();
      expect(photos.attempts, 2);
      expect(queue.count, 1);
      expect(recognizer.calls, 0);
      expect(writes, 0);
      expect(find.text('Native permission detail'), findsNothing);
      await tester.tap(find.widgetWithIcon(IconButton, Icons.dots_three));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enter card details').hitTestable());
      await tester.pumpAndSettle();
      expect(
        find.text('Correct'),
        defaultTargetPlatform == TargetPlatform.iOS
            ? findsNothing
            : findsOneWidget,
      );
      expect(
        find
            .byKey(const ValueKey<String>('scan-correction-close'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('printing-search')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find
            .byKey(const ValueKey<String>('printing-search-submit'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
