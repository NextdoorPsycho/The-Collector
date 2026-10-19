import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('saved target pixels require a complete bounded native sample', () {
    final Map<String, Object?> response = <String, Object?>{
      'imagePath': '/local/capture.jpg',
      'width': 3024,
      'height': 4032,
      'crops': <Object>[],
      'targetAppearances': <Object>[
        <String, Object?>{
          'corners': <Map<String, double>>[
            <String, double>{'x': .1, 'y': .2},
            <String, double>{'x': .4, 'y': .2},
            <String, double>{'x': .42, 'y': .7},
            <String, double>{'x': .08, 'y': .7},
          ],
          'values': List<double>.generate(288, (int index) => index / 287),
          'present': true,
        },
      ],
    };
    final SavedTargetAppearance sample = ScanRecognition.fromMap(response)
        .targetAppearances
        .single;
    expect(sample.isValid, isTrue);
    expect(sample.corners[2].x, .42);
    expect(sample.values.last, 1);
    for (final List<double> values in <List<double>>[
      sample.values.sublist(1),
      <double>[double.nan, ...sample.values.skip(1)],
      <double>[-.01, ...sample.values.skip(1)],
      <double>[1.01, ...sample.values.skip(1)],
    ]) {
      expect(
        SavedTargetAppearance(
          corners: sample.corners,
          values: values,
          present: true,
        ).isValid,
        isFalse,
      );
    }
    expect(
      SavedTargetAppearance(
        corners: sample.corners,
        values: sample.values,
        present: false,
      ).isValid,
      isFalse,
    );
    response.remove('targetAppearances');
    expect(ScanRecognition.fromMap(response).targetAppearances, isEmpty);
  });

  for (final bool presence in <bool>[false, true]) {
    for (final bool guided in <bool>[false, true]) {
      test(
        '${presence ? 'presence' : 'detail'} recognition '
        '${guided ? 'forwards source guides' : 'omits absent guides'}',
        () async {
          final TargetPlatform? previous = debugDefaultTargetPlatformOverride;
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          final List<MethodCall> calls = <MethodCall>[];
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(NativeCardRecognizer.channel, (
                MethodCall call,
              ) async {
                calls.add(call);
                return <String, Object>{
                  'imagePath': '/local/capture.jpg',
                  'width': 3024,
                  'height': 4032,
                  'crops': <Object>[],
                };
              });
          addTearDown(() {
            debugDefaultTargetPlatformOverride = previous;
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
          });
          final NativeCardRecognizer recognizer = NativeCardRecognizer();
          final List<List<ScanPoint>> targets = guided
              ? const <List<ScanPoint>>[
                  <ScanPoint>[
                    ScanPoint(.1, .2),
                    ScanPoint(.4, .2),
                    ScanPoint(.42, .7),
                    ScanPoint(.08, .7),
                  ],
                ]
              : const <List<ScanPoint>>[];
          if (presence) {
            await recognizer.recognizePresence(
              '/local/capture.jpg',
              multipleCards: true,
              targetRegions: targets,
            );
          } else {
            await recognizer.recognize(
              '/local/capture.jpg',
              multipleCards: true,
              targetRegions: targets,
            );
          }
          expect(calls, hasLength(1));
          expect(
            calls.single.method,
            presence ? 'recognizePresence' : 'recognize',
          );
          expect(calls.single.arguments, <String, Object>{
            'path': '/local/capture.jpg',
            'multipleCards': true,
            if (guided)
              'targetRegions': <List<Map<String, double>>>[
                <Map<String, double>>[
                  <String, double>{'x': .1, 'y': .2},
                  <String, double>{'x': .4, 'y': .2},
                  <String, double>{'x': .42, 'y': .7},
                  <String, double>{'x': .08, 'y': .7},
                ],
              ],
          });
        },
      );
    }
  }
}
