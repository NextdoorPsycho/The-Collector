import 'dart:async';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart'
    show CameraImageData, CameraImageFormat, CameraImagePlane;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/scanning/live_scan_detector.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';

CameraImage _frame() => CameraImage.fromPlatformInterface(
  CameraImageData(
    format: const CameraImageFormat(ImageFormatGroup.bgra8888, raw: 1111970369),
    planes: <CameraImagePlane>[
      CameraImagePlane(bytes: Uint8List(16), bytesPerRow: 8, bytesPerPixel: 4),
    ],
    width: 2,
    height: 2,
  ),
);

const CameraDescription _camera = CameraDescription(
  name: 'rear',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);

Map<String, Object> _response() => <String, Object>{
  'width': 2,
  'height': 2,
  'rectanglesSupported': true,
  'cards': <Object>[],
};

const List<ScanPoint> _completedCorners = <ScanPoint>[
  ScanPoint(.20, .10),
  ScanPoint(.60, .12),
  ScanPoint(.58, .72),
  ScanPoint(.18, .70),
];

Map<String, Object> _appearance({bool present = true}) => <String, Object>{
  ...const LiveScanExcludedRegion(
    id: 'card-2',
    corners: _completedCorners,
  ).toMap(),
  'present': present,
  'values': List<double>.generate(288, (int index) => index / 288),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('completed appearances retain RGB order and top-left geometry', () {
    final LiveScanFrame frame = LiveScanFrame.fromMap(<Object?, Object?>{
      ..._response(),
      'appearanceSamplingSupported': true,
      'appearanceSamples': <Object?>[_appearance()],
    }, orientationToken: 'rear:portraitUp');
    expect(frame.appearanceSamplingSupported, isTrue);
    final LiveCardAppearanceSample sample = frame.appearanceSamples.single;
    expect(sample.id, 'card-2');
    expect(sample.present, isTrue);
    expect(sample.corners.first.x, .20);
    expect(sample.corners.first.y, .10);
    expect(sample.corners.last.y, .70);
    expect(sample.values, hasLength(288));
    expect(sample.values.take(3), <double>[0, 1 / 288, 2 / 288]);
    expect(() => sample.values.add(0), throwsUnsupportedError);
    expect(
      () => sample.corners.add(const ScanPoint(0, 0)),
      throwsUnsupportedError,
    );
    expect(() => frame.appearanceSamples.add(sample), throwsUnsupportedError);
  });

  test('appearance remains available across missing Vision rectangles', () {
    final LiveCardAppearanceSample sample = LiveCardAppearanceSample.fromMap(
      _appearance(present: false),
    );
    expect(sample.present, isFalse);
    expect(sample.values, hasLength(288));
    final LiveCardAppearanceSample unavailable =
        LiveCardAppearanceSample.fromMap(<Object?, Object?>{
          ..._appearance(present: false),
          'values': <double>[],
        });
    expect(unavailable.present, isFalse);
    expect(unavailable.values, isEmpty);
    final LiveScanFrame unsupported = LiveScanFrame.fromMap(
      _response(),
      orientationToken: 'rear:portraitUp',
    );
    expect(unsupported.appearanceSamplingSupported, isFalse);
    expect(unsupported.appearanceSamples, isEmpty);
  });

  test('malformed appearances cannot become completed-card evidence', () {
    for (final Object? values in <Object?>[
      null,
      <double>[],
      List<double>.filled(287, .5),
      List<double>.filled(288, double.nan),
      List<double>.filled(288, double.infinity),
      List<double>.filled(288, -0.01),
      List<double>.filled(288, 1.01),
      List<Object>.filled(288, '0.5'),
    ]) {
      expect(
        () => LiveCardAppearanceSample.fromMap(<Object?, Object?>{
          ..._appearance(),
          'values': values,
        }),
        throwsFormatException,
      );
    }
    expect(
      () => LiveScanFrame.fromMap(<Object?, Object?>{
        ..._response(),
        'appearanceSamples': <Object?>[_appearance(), _appearance()],
      }, orientationToken: 'rear:portraitUp'),
      throwsFormatException,
    );
    expect(
      () => LiveScanFrame.fromMap(<Object?, Object?>{
        ..._response(),
        'appearanceSamples': List<Object>.filled(9, _appearance()),
      }, orientationToken: 'rear:portraitUp'),
      throwsFormatException,
    );
  });

  test('completed footprints reject invalid IDs and crossed polygons', () {
    for (final String id in <String>[
      '',
      ' card-2',
      'card-2 ',
      'card\u0000two',
    ]) {
      expect(
        () =>
            LiveScanExcludedRegion(id: id, corners: _completedCorners).toMap(),
        throwsFormatException,
      );
    }
    for (final List<ScanPoint> corners in <List<ScanPoint>>[
      const <ScanPoint>[],
      <ScanPoint>[
        _completedCorners[0],
        _completedCorners[2],
        _completedCorners[1],
        _completedCorners[3],
      ],
      const <ScanPoint>[
        ScanPoint(-.01, .1),
        ScanPoint(.6, .1),
        ScanPoint(.6, .7),
        ScanPoint(.2, .7),
      ],
      const <ScanPoint>[
        ScanPoint(double.nan, .1),
        ScanPoint(.6, .1),
        ScanPoint(.6, .7),
        ScanPoint(.2, .7),
      ],
      const <ScanPoint>[
        ScanPoint(.2, .1),
        ScanPoint(.2, .1),
        ScanPoint(.6, .7),
        ScanPoint(.2, .7),
      ],
    ]) {
      expect(
        () => LiveScanExcludedRegion(id: 'card-2', corners: corners).toMap(),
        throwsFormatException,
      );
    }
  });

  test(
    'iOS sends exclusions unchanged; Android keeps sparse OCR available',
    () async {
      final List<Map<Object?, Object?>> calls = <Map<Object?, Object?>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, (
            MethodCall call,
          ) async {
            calls.add(call.arguments as Map<Object?, Object?>);
            return _response();
          });
      try {
        for (final TargetPlatform platform in <TargetPlatform>[
          TargetPlatform.iOS,
          TargetPlatform.android,
        ]) {
          debugDefaultTargetPlatformOverride = platform;
          final NativeLiveCardDetector detector = NativeLiveCardDetector();
          await detector.analyze(
            _frame(),
            camera: _camera,
            orientation: DeviceOrientation.portraitUp,
            includeText: true,
            excludedRegions: const <LiveScanExcludedRegion>[
              LiveScanExcludedRegion(id: 'card-2', corners: _completedCorners),
            ],
            appearanceRegions: const <LiveScanExcludedRegion>[
              LiveScanExcludedRegion(id: 'card-2', corners: _completedCorners),
              LiveScanExcludedRegion(id: 'card-3', corners: _completedCorners),
            ],
          );
        }
        expect(calls, hasLength(2));
        expect(calls[0]['excludedRegions'], <Object?>[
          const LiveScanExcludedRegion(
            id: 'card-2',
            corners: _completedCorners,
          ).toMap(),
        ]);
        expect(calls[0]['includeText'], isTrue);
        expect(calls[0]['appearanceRegions'], <Object?>[
          const LiveScanExcludedRegion(
            id: 'card-2',
            corners: _completedCorners,
          ).toMap(),
          const LiveScanExcludedRegion(
            id: 'card-3',
            corners: _completedCorners,
          ).toMap(),
        ]);
        expect(calls[1].containsKey('excludedRegions'), isFalse);
        expect(calls[1].containsKey('appearanceRegions'), isFalse);
        expect(calls[1]['includeText'], isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
      }
    },
  );

  test(
    'appearance regions validate the unique bounded union before native work',
    () async {
      int calls = 0;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, (
            MethodCall call,
          ) async {
            calls++;
            return _response();
          });
      try {
        final NativeLiveCardDetector detector = NativeLiveCardDetector();
        final List<LiveScanExcludedRegion> completed =
            List<LiveScanExcludedRegion>.generate(
              5,
              (int index) => LiveScanExcludedRegion(
                id: 'card-$index',
                corners: _completedCorners,
              ),
            );
        await expectLater(
          detector.analyze(
            _frame(),
            camera: _camera,
            orientation: DeviceOrientation.portraitUp,
            excludedRegions: completed,
            appearanceRegions: List<LiveScanExcludedRegion>.generate(
              4,
              (int index) => LiveScanExcludedRegion(
                id: 'card-${index + 5}',
                corners: _completedCorners,
              ),
            ),
          ),
          throwsFormatException,
        );
        await expectLater(
          detector.analyze(
            _frame(),
            camera: _camera,
            orientation: DeviceOrientation.portraitUp,
            appearanceRegions: const <LiveScanExcludedRegion>[
              LiveScanExcludedRegion(id: 'same', corners: _completedCorners),
              LiveScanExcludedRegion(id: 'same', corners: _completedCorners),
            ],
          ),
          throwsFormatException,
        );
        await expectLater(
          detector.analyze(
            _frame(),
            camera: _camera,
            orientation: DeviceOrientation.portraitUp,
            excludedRegions: const <LiveScanExcludedRegion>[
              LiveScanExcludedRegion(id: 'same', corners: _completedCorners),
            ],
            appearanceRegions: const <LiveScanExcludedRegion>[
              LiveScanExcludedRegion(
                id: 'same',
                corners: <ScanPoint>[
                  ScanPoint(.21, .10),
                  ScanPoint(.60, .12),
                  ScanPoint(.58, .72),
                  ScanPoint(.18, .70),
                ],
              ),
            ],
          ),
          throwsFormatException,
        );
        await expectLater(
          detector.analyze(
            _frame(),
            camera: _camera,
            orientation: DeviceOrientation.portraitUp,
            appearanceRegions: const <LiveScanExcludedRegion>[
              LiveScanExcludedRegion(id: '', corners: _completedCorners),
            ],
          ),
          throwsFormatException,
        );
        expect(calls, 0);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
      }
    },
  );

  test(
    'duplicate or excessive footprints never enter the native queue',
    () async {
      int calls = 0;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, (
            MethodCall call,
          ) async {
            calls++;
            return _response();
          });
      try {
        final NativeLiveCardDetector detector = NativeLiveCardDetector();
        for (final int count in <int>[2, 9]) {
          await expectLater(
            detector.analyze(
              _frame(),
              camera: _camera,
              orientation: DeviceOrientation.portraitUp,
              excludedRegions: List<LiveScanExcludedRegion>.filled(
                count,
                const LiveScanExcludedRegion(
                  id: 'card-2',
                  corners: _completedCorners,
                ),
              ),
            ),
            throwsFormatException,
          );
        }
        expect(calls, 0);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
      }
    },
  );

  test('geometry focus targets remain outside detected card results', () {
    final LiveScanFrame frame = LiveScanFrame.fromMap(<Object?, Object?>{
      ..._response(),
      'focusCandidates': <Object?>[
        <Object?, Object?>{
          'corners': <Object?>[
            <String, double>{'x': .60, 'y': .35},
            <String, double>{'x': .86, 'y': .35},
            <String, double>{'x': .86, 'y': .47},
            <String, double>{'x': .60, 'y': .47},
          ],
          'confidence': 1.0,
          'sharpness': .54,
          'warnings': <String>['geometry_only'],
        },
      ],
    }, orientationToken: 'rear:portraitUp');
    expect(frame.cards, isEmpty);
    expect(frame.focusCandidates, hasLength(1));
    expect(frame.focusCandidates.single.sharpness, .54);
    expect(frame.focusCandidates.single.lines, isEmpty);
    expect(frame.focusCandidates.single.warnings, contains('geometry_only'));
    expect(frame.focusCandidates.single.corners.first.y, .35);
    expect(
      () => frame.focusCandidates.add(frame.focusCandidates.single),
      throwsUnsupportedError,
    );
  });

  test(
    'platforms without focus or image quality metadata stay unspecified',
    () {
      final LiveScanFrame frame = LiveScanFrame.fromMap(
        _response(),
        orientationToken: 'rear:portraitUp',
      );
      expect(frame.focusCandidates, isEmpty);
      expect(frame.geometryOnly, isFalse);
      final LiveCardDetection card = LiveCardDetection.fromMap(
        <Object?, Object?>{'corners': <Object?>[], 'confidence': 1.0},
      );
      expect(card.sharpness, isNull);
    },
  );

  test('busy geometry responses do not report a completed text pass', () {
    final LiveScanFrame frame = LiveScanFrame.fromMap(<Object?, Object?>{
      ..._response(),
      'geometryOnly': true,
    }, orientationToken: 'rear:portraitUp');
    expect(frame.geometryOnly, isTrue);
    expect(frame.cards, isEmpty);
  });

  test('BGRA plane padding is excluded without changing row orientation', () {
    final Map<String, Object> pixels =
        NativeLiveCardDetector.boundedFramePixels(
          width: 2,
          height: 2,
          bytes: Uint8List.fromList(<int>[
            1,
            2,
            3,
            255,
            4,
            5,
            6,
            255,
            90,
            90,
            90,
            90,
            7,
            8,
            9,
            255,
            10,
            11,
            12,
            255,
            90,
            90,
            90,
            90,
          ]),
          bytesPerRow: 12,
          bytesPerPixel: 4,
          bgra: true,
        );
    expect(pixels['bytesPerRow'], 8);
    expect(pixels['bytes'], <int>[
      1,
      2,
      3,
      255,
      4,
      5,
      6,
      255,
      7,
      8,
      9,
      255,
      10,
      11,
      12,
      255,
    ]);
  });

  test('luminance pixel stride skips interleaved values', () {
    final Map<String, Object> pixels =
        NativeLiveCardDetector.boundedFramePixels(
          width: 2,
          height: 1,
          bytes: Uint8List.fromList(<int>[30, 99, 60, 99]),
          bytesPerRow: 6,
          bytesPerPixel: 2,
          bgra: false,
        );
    expect(pixels['bytes'], <int>[30, 60]);
    expect(pixels['format'], 'luminance');
  });

  test('analysis pixels are bounded while preserving aspect ratio', () {
    final Map<String, Object> pixels =
        NativeLiveCardDetector.boundedFramePixels(
          width: 2400,
          height: 1200,
          bytes: Uint8List(2400 * 1200),
          bytesPerRow: 2400,
          bytesPerPixel: 1,
          bgra: false,
        );
    expect(pixels['width'], 960);
    expect(pixels['height'], 480);
    expect((pixels['bytes'] as Uint8List).length, 960 * 480);
  });

  test('text frames retain detail without changing camera identity', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final List<Map<Object?, Object?>> requests = <Map<Object?, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeCardRecognizer.channel, (
          MethodCall call,
        ) async {
          requests.add(call.arguments as Map<Object?, Object?>);
          return _response();
        });
    try {
      final CameraImage frame = CameraImage.fromPlatformInterface(
        CameraImageData(
          format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
          planes: <CameraImagePlane>[
            CameraImagePlane(
              bytes: Uint8List(2400 * 1200),
              bytesPerRow: 2400,
              bytesPerPixel: 1,
            ),
          ],
          width: 2400,
          height: 1200,
        ),
      );
      final NativeLiveCardDetector detector = NativeLiveCardDetector(
        interval: Duration.zero,
        geometryInterval: Duration.zero,
      );
      await detector.analyze(
        frame,
        camera: _camera,
        orientation: DeviceOrientation.portraitUp,
      );
      await detector.analyze(
        frame,
        camera: _camera,
        orientation: DeviceOrientation.portraitUp,
        includeText: true,
      );
      expect(requests, hasLength(2));
      expect(requests.first['width'], 960);
      expect(requests.first['height'], 480);
      expect(requests.last['width'], 1920);
      expect(requests.last['height'], 960);
      for (final Map<Object?, Object?> request in requests) {
        expect(request['sourceWidth'], 2400);
        expect(request['sourceHeight'], 1200);
        expect(request['cameraName'], 'rear');
        expect(request['rotation'], 0);
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
    }
  });

  test('background preparation preserves padded BGRA and YUV bytes', () async {
    final List<Map<Object?, Object?>> requests = <Map<Object?, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeCardRecognizer.channel, (
          MethodCall call,
        ) async {
          requests.add(call.arguments as Map<Object?, Object?>);
          return _response();
        });
    try {
      for (final bool bgra in <bool>[true, false]) {
        debugDefaultTargetPlatformOverride = bgra
            ? TargetPlatform.iOS
            : TargetPlatform.android;
        final int pixelStride = bgra ? 4 : 2;
        final int rowStride = 1924 * pixelStride + 8;
        final Uint8List bytes = Uint8List.fromList(
          List<int>.generate(rowStride * 6, (int index) => index % 251),
        );
        final CameraImage frame = CameraImage.fromPlatformInterface(
          CameraImageData(
            format: CameraImageFormat(
              bgra ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
              raw: bgra ? 1111970369 : 35,
            ),
            planes: <CameraImagePlane>[
              CameraImagePlane(
                bytes: bytes,
                bytesPerRow: rowStride,
                bytesPerPixel: pixelStride,
              ),
            ],
            width: 1924,
            height: 6,
          ),
        );
        final NativeLiveCardDetector detector = NativeLiveCardDetector();
        final Future<LiveScanFrame?> prepared = detector.analyze(
          frame,
          camera: _camera,
          orientation: DeviceOrientation.portraitUp,
        );
        expect(requests, hasLength(bgra ? 0 : 1));
        expect(await prepared, isNotNull);
        final Map<Object?, Object?> request = requests.last;
        final Map<String, Object> expected =
            NativeLiveCardDetector.boundedFramePixels(
              width: 1924,
              height: 6,
              bytes: bytes,
              bytesPerRow: rowStride,
              bytesPerPixel: pixelStride,
              bgra: bgra,
            );
        expect(request['width'], 960);
        expect(request['height'], 3);
        expect(request['bytes'], orderedEquals(expected['bytes'] as Uint8List));
        expect(request['bytesPerRow'], bgra ? 3840 : 960);
        expect(request['format'], bgra ? 'bgra8888' : 'luminance');
        expect(request['sourceWidth'], 1924);
        expect(request['sourceHeight'], 6);
        expect(request['rotation'], bgra ? 0 : 90);
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
    }
  });

  test('reset during preparation prevents stale native work', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    int calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeCardRecognizer.channel, (
          MethodCall call,
        ) async {
          calls++;
          return _response();
        });
    try {
      final NativeLiveCardDetector detector = NativeLiveCardDetector(
        interval: Duration.zero,
        geometryInterval: Duration.zero,
      );
      final Future<LiveScanFrame?> preparing = detector.analyze(
        _frame(),
        camera: _camera,
        orientation: DeviceOrientation.portraitUp,
      );
      detector.reset();
      expect(
        await detector.analyze(
          _frame(),
          camera: _camera,
          orientation: DeviceOrientation.portraitUp,
        ),
        isNull,
      );
      expect(await preparing, isNull);
      expect(calls, 0);
      expect(
        await detector.analyze(
          _frame(),
          camera: _camera,
          orientation: DeviceOrientation.portraitUp,
        ),
        isNotNull,
      );
      expect(calls, 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
    }
  });

  test('failed background preparation releases the analysis slot', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    int calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeCardRecognizer.channel, (
          MethodCall call,
        ) async {
          calls++;
          return _response();
        });
    try {
      final CameraImage malformed = CameraImage.fromPlatformInterface(
        CameraImageData(
          format: const CameraImageFormat(
            ImageFormatGroup.bgra8888,
            raw: 1111970369,
          ),
          planes: <CameraImagePlane>[
            CameraImagePlane(
              bytes: Uint8List(15),
              bytesPerRow: 8,
              bytesPerPixel: 4,
            ),
          ],
          width: 2,
          height: 2,
        ),
      );
      final NativeLiveCardDetector detector = NativeLiveCardDetector(
        interval: Duration.zero,
        geometryInterval: Duration.zero,
      );
      await expectLater(
        detector.analyze(
          malformed,
          camera: _camera,
          orientation: DeviceOrientation.portraitUp,
        ),
        throwsFormatException,
      );
      expect(calls, 0);
      expect(
        await detector.analyze(
          _frame(),
          camera: _camera,
          orientation: DeviceOrientation.portraitUp,
        ),
        isNotNull,
      );
      expect(calls, 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
    }
  });

  test('malformed plane dimensions fail before native transport', () {
    expect(
      () => NativeLiveCardDetector.boundedFramePixels(
        width: 2,
        height: 2,
        bytes: Uint8List(15),
        bytesPerRow: 8,
        bytesPerPixel: 4,
        bgra: true,
      ),
      throwsFormatException,
    );
  });

  test('rear Android rotation compensates every device orientation', () {
    expect(
      NativeLiveCardDetector.rearFrameRotation(
        90,
        DeviceOrientation.portraitUp,
      ),
      90,
    );
    expect(
      NativeLiveCardDetector.rearFrameRotation(
        90,
        DeviceOrientation.landscapeLeft,
      ),
      0,
    );
    expect(
      NativeLiveCardDetector.rearFrameRotation(
        90,
        DeviceOrientation.portraitDown,
      ),
      270,
    );
    expect(
      NativeLiveCardDetector.rearFrameRotation(
        90,
        DeviceOrientation.landscapeRight,
      ),
      180,
    );
  });

  test(
    'one native request is admitted and reset invalidates its result',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final Completer<Map<String, Object>> pending =
          Completer<Map<String, Object>>();
      final Completer<void> admitted = Completer<void>();
      int calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, (
            MethodCall call,
          ) async {
            calls++;
            expect(call.method, 'detectFrame');
            expect((call.arguments as Map<Object?, Object?>)['rotation'], 0);
            admitted.complete();
            return pending.future;
          });
      try {
        final NativeLiveCardDetector detector = NativeLiveCardDetector();
        final Future<LiveScanFrame?> first = detector.analyze(
          _frame(),
          camera: _camera,
          orientation: DeviceOrientation.portraitUp,
        );
        expect(
          await detector.analyze(
            _frame(),
            camera: _camera,
            orientation: DeviceOrientation.portraitUp,
          ),
          isNull,
        );
        await admitted.future;
        detector.reset();
        pending.complete(_response());
        expect(await first, isNull);
        expect(calls, 1);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
      }
    },
  );

  test(
    'geometry cadence admits stable observations at 100 ms without early work',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      DateTime now = DateTime(2026);
      int calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, (
            MethodCall call,
          ) async {
            calls++;
            return _response();
          });
      try {
        final NativeLiveCardDetector detector = NativeLiveCardDetector(
          now: () => now,
        );
        final LiveScanFrame? first = await detector.analyze(
          _frame(),
          camera: _camera,
          orientation: DeviceOrientation.portraitUp,
        );
        expect(first?.orientationToken, 'rear:portraitUp');
        now = now.add(const Duration(milliseconds: 99));
        expect(
          await detector.analyze(
            _frame(),
            camera: _camera,
            orientation: DeviceOrientation.portraitUp,
          ),
          isNull,
        );
        now = now.add(const Duration(milliseconds: 1));
        expect(
          await detector.analyze(
            _frame(),
            camera: _camera,
            orientation: DeviceOrientation.portraitUp,
          ),
          isNotNull,
        );
        expect(calls, 2);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
      }
    },
  );

  test(
    'text cadence stays at 400 ms without being postponed by geometry frames',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      DateTime now = DateTime(2026);
      final List<bool> requests = <bool>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, (
            MethodCall call,
          ) async {
            requests.add(
              (call.arguments as Map<Object?, Object?>)['includeText'] == true,
            );
            return _response();
          });
      try {
        final NativeLiveCardDetector detector = NativeLiveCardDetector(
          now: () => now,
        );
        Future<LiveScanFrame?> analyze({bool text = false}) => detector.analyze(
          _frame(),
          camera: _camera,
          orientation: DeviceOrientation.portraitUp,
          includeText: text,
        );
        expect(await analyze(text: true), isNotNull);
        now = now.add(const Duration(milliseconds: 100));
        expect(await analyze(), isNotNull);
        now = now.add(const Duration(milliseconds: 100));
        expect(await analyze(), isNotNull);
        now = now.add(const Duration(milliseconds: 199));
        expect(await analyze(text: true), isNull);
        now = now.add(const Duration(milliseconds: 1));
        expect(await analyze(text: true), isNotNull);
        expect(requests, <bool>[true, false, false, true]);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
      }
    },
  );
}
