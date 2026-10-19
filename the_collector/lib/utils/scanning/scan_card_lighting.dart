import 'package:flutter/foundation.dart';

@immutable
class ScanCardLighting {
  final double highlightFraction;
  final double shadowFraction;
  final double meanLuminance;
  final double contrast;
  final int sampleCount;

  const ScanCardLighting({
    required this.highlightFraction,
    required this.shadowFraction,
    required this.meanLuminance,
    required this.contrast,
    required this.sampleCount,
  });

  bool get isValid =>
      sampleCount >= 32 &&
      sampleCount <= 16384 &&
      <double>[
        highlightFraction,
        shadowFraction,
        meanLuminance,
        contrast,
      ].every((double value) => value.isFinite && value >= 0 && value <= 1) &&
      highlightFraction + shadowFraction <= 1.000001;

  bool get isWashedOut =>
      isValid &&
      meanLuminance >= .78 &&
      highlightFraction >= .10 &&
      contrast <= .28 &&
      shadowFraction <= .04;

  bool get canRestoreExposure =>
      isValid &&
      highlightFraction < .03 &&
      (meanLuminance < .45 ||
          (contrast > .30 && meanLuminance < .85 && shadowFraction < .20));

  static ScanCardLighting? tryFromMap(Object? value) {
    if (value is! Map<Object?, Object?>) return null;
    final Object? highlights = value['highlightFraction'];
    final Object? shadows = value['shadowFraction'];
    final Object? luminance = value['meanLuminance'];
    final Object? range = value['contrast'];
    final Object? count = value['sampleCount'];
    if (highlights is! num ||
        shadows is! num ||
        luminance is! num ||
        range is! num ||
        count is! int) {
      return null;
    }
    final ScanCardLighting lighting = ScanCardLighting(
      highlightFraction: highlights.toDouble(),
      shadowFraction: shadows.toDouble(),
      meanLuminance: luminance.toDouble(),
      contrast: range.toDouble(),
      sampleCount: count,
    );
    return lighting.isValid ? lighting : null;
  }
}
