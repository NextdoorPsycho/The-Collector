import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/scanning/live_scan_detector.dart';
import 'package:the_collector/utils/scanning/scan_card_lighting.dart';
import 'package:the_collector/utils/scanning/scan_exposure_policy.dart';

const ScanCardLighting _washed = ScanCardLighting(
  highlightFraction: .35,
  shadowFraction: .01,
  meanLuminance: .92,
  contrast: .15,
  sampleCount: 512,
);
const ScanCardLighting _clean = ScanCardLighting(
  highlightFraction: .01,
  shadowFraction: .08,
  meanLuminance: .60,
  contrast: .55,
  sampleCount: 512,
);

void main() {
  final DateTime epoch = DateTime.utc(2026, 10, 12);
  double? observe(
    ScanExposurePolicy policy,
    int milliseconds, {
    List<ScanCardLighting> lighting = const <ScanCardLighting>[_washed],
    double current = 0,
    double minimum = -2,
    double maximum = 2,
    double step = .1,
    bool readable = false,
  }) => policy.observe(
    now: epoch.add(Duration(milliseconds: milliseconds)),
    lighting: lighting,
    readable: readable,
    currentExposure: current,
    minExposure: minimum,
    maxExposure: maximum,
    exposureStep: step,
  );

  test(
    'washed frames reduce exposure gradually with a cooldown and hard bound',
    () {
      final ScanExposurePolicy policy = ScanExposurePolicy();
      expect(observe(policy, 0), isNull);
      expect(observe(policy, 100), closeTo(-.3, .000001));
      expect(observe(policy, 200, current: -.3), isNull);
      expect(observe(policy, 300, current: -.3), isNull);
      expect(observe(policy, 899, current: -.3), isNull);
      expect(observe(policy, 900, current: -.3), closeTo(-.6, .000001));
      expect(observe(policy, 1700, current: -1.4), isNull);
      expect(observe(policy, 1800, current: -1.4), -1.5);
      expect(observe(policy, 2700, current: -1.5), isNull);
      expect(observe(policy, 2800, current: -1.5), isNull);
    },
  );

  test('hardware bounds and exposure step are respected', () {
    final ScanExposurePolicy policy = ScanExposurePolicy();
    expect(observe(policy, 0, minimum: -.2, step: .2), isNull);
    expect(observe(policy, 100, minimum: -.2, step: .2), -.2);
    policy.reset();
    expect(observe(policy, 0, step: .5), isNull);
    expect(observe(policy, 100, step: .5), -.5);
    policy.reset();
    expect(observe(policy, 0, step: 0), isNull);
    expect(observe(policy, 100, step: 0), -.3);
  });

  test(
    'normal and empty scenes restore only after a sustained clean interval',
    () {
      for (final List<ScanCardLighting> lighting in <List<ScanCardLighting>>[
        const <ScanCardLighting>[_clean],
        const <ScanCardLighting>[
          ScanCardLighting(
            highlightFraction: 0,
            shadowFraction: .45,
            meanLuminance: .25,
            contrast: .18,
            sampleCount: 512,
          ),
        ],
        const <ScanCardLighting>[],
      ]) {
        final ScanExposurePolicy policy = ScanExposurePolicy();
        expect(observe(policy, 0, lighting: lighting, current: -.6), isNull);
        expect(observe(policy, 500, lighting: lighting, current: -.6), isNull);
        expect(observe(policy, 1999, lighting: lighting, current: -.6), isNull);
        expect(
          observe(policy, 2000, lighting: lighting, current: -.6),
          closeTo(-.3, .000001),
        );
        expect(observe(policy, 2100, lighting: lighting, current: -.3), isNull);
        expect(observe(policy, 3000, lighting: lighting, current: -.3), isNull);
        expect(
          observe(policy, 4100, lighting: lighting, current: -.3),
          closeTo(0, .000001),
        );
      }
    },
  );

  test('readable cards and isolated bright frames do not cause darkening', () {
    final ScanExposurePolicy policy = ScanExposurePolicy();
    expect(observe(policy, 0, readable: true), isNull);
    expect(observe(policy, 100, readable: true), isNull);
    expect(observe(policy, 200), isNull);
    expect(
      observe(policy, 300, lighting: const <ScanCardLighting>[_clean]),
      isNull,
    );
    expect(observe(policy, 400), isNull);
    expect(observe(policy, 500, readable: true), isNull);
    expect(observe(policy, 600), isNull);
    expect(observe(policy, 700), closeTo(-.3, .000001));
  });

  test('duplicate, stale, reset, and invalid observations cannot complete a streak', () {
    final ScanExposurePolicy policy = ScanExposurePolicy();
    expect(observe(policy, 0), isNull);
    expect(observe(policy, 0), isNull);
    expect(observe(policy, -1), isNull);
    expect(observe(policy, 3100), isNull);
    const ScanCardLighting invalid = ScanCardLighting(
      highlightFraction: double.nan,
      shadowFraction: .01,
      meanLuminance: .92,
      contrast: .15,
      sampleCount: 512,
    );
    expect(
      observe(policy, 3200, lighting: const <ScanCardLighting>[invalid]),
      isNull,
    );
    expect(observe(policy, 3300), isNull);
    policy.reset();
    expect(observe(policy, 3400), isNull);
    expect(observe(policy, 3500), closeTo(-.3, .000001));
  });

  test('unsupported and nonfinite hardware limits never produce a command', () {
    for (int frame = 0; frame < 3; frame++) {
      expect(
        observe(ScanExposurePolicy(), frame, minimum: 0, maximum: 0),
        isNull,
      );
      expect(observe(ScanExposurePolicy(), frame, current: double.nan), isNull);
      expect(
        observe(ScanExposurePolicy(), frame, minimum: double.negativeInfinity),
        isNull,
      );
      expect(
        observe(ScanExposurePolicy(), frame, maximum: double.infinity),
        isNull,
      );
      expect(observe(ScanExposurePolicy(), frame, step: -.1), isNull);
      expect(observe(ScanExposurePolicy(), frame, current: 3), isNull);
    }
  });

  test('lighting maps validate optional native measurements without identity effects', () {
    final Map<String, Object> map = <String, Object>{
      'highlightFraction': .35,
      'shadowFraction': .01,
      'meanLuminance': .92,
      'contrast': .15,
      'sampleCount': 512,
    };
    expect(ScanCardLighting.tryFromMap(map)!.isWashedOut, isTrue);
    expect(ScanCardLighting.tryFromMap(null), isNull);
    for (final Map<String, Object> invalid in <Map<String, Object>>[
      <String, Object>{...map, 'sampleCount': 1},
      <String, Object>{...map, 'sampleCount': 512.0},
      <String, Object>{...map, 'sampleCount': 16385},
      <String, Object>{...map, 'highlightFraction': double.infinity},
      <String, Object>{...map, 'shadowFraction': -.1},
      <String, Object>{...map, 'contrast': '0.15'},
      <String, Object>{...map, 'highlightFraction': .9, 'shadowFraction': .5},
    ]) {
      expect(ScanCardLighting.tryFromMap(invalid), isNull);
    }
    final LiveCardDetection card = LiveCardDetection.fromMap(<String, Object>{
      'corners': <Map<String, double>>[
        <String, double>{'x': .1, 'y': .1},
        <String, double>{'x': .9, 'y': .1},
        <String, double>{'x': .9, 'y': .9},
        <String, double>{'x': .1, 'y': .9},
      ],
      'confidence': .95,
      'lighting': map,
    });
    expect(card.lighting!.isWashedOut, isTrue);
    expect(card.lines, isEmpty);
    expect(card.confidence, .95);
    expect(card.warnings, isEmpty);
  });
}
