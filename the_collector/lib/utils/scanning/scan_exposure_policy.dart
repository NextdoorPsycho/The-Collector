import 'dart:math' as math;

import 'scan_card_lighting.dart';

class ScanExposurePolicy {
  DateTime? _lastObservation;
  DateTime? _lastAdjustment;
  DateTime? _cleanSince;
  int _washedFrames = 0;
  int _cleanFrames = 0;

  void reset() {
    _lastObservation = null;
    _lastAdjustment = null;
    _cleanSince = null;
    _washedFrames = 0;
    _cleanFrames = 0;
  }

  double? observe({
    required DateTime now,
    required Iterable<ScanCardLighting> lighting,
    required bool readable,
    required double currentExposure,
    required double minExposure,
    required double maxExposure,
    required double exposureStep,
  }) {
    if (!currentExposure.isFinite ||
        !minExposure.isFinite ||
        !maxExposure.isFinite ||
        minExposure >= maxExposure ||
        currentExposure < minExposure ||
        currentExposure > maxExposure ||
        !exposureStep.isFinite ||
        exposureStep < 0 ||
        (_lastObservation != null && !now.isAfter(_lastObservation!))) {
      return null;
    }
    if (_lastObservation != null &&
        now.difference(_lastObservation!) > const Duration(seconds: 3)) {
      _washedFrames = 0;
      _cleanFrames = 0;
      _cleanSince = null;
    }
    _lastObservation = now;
    final List<ScanCardLighting> samples = lighting.toList(growable: false);
    if (samples.any((ScanCardLighting sample) => !sample.isValid)) {
      _washedFrames = 0;
      _cleanFrames = 0;
      _cleanSince = null;
      return null;
    }
    final bool washed =
        !readable &&
        samples.any((ScanCardLighting sample) => sample.isWashedOut);
    final bool clean =
        samples.isEmpty ||
        samples.every((ScanCardLighting sample) => sample.canRestoreExposure);
    _washedFrames = washed ? math.min(2, _washedFrames + 1) : 0;
    if (clean) {
      _cleanFrames = math.min(3, _cleanFrames + 1);
      _cleanSince ??= now;
    } else {
      _cleanFrames = 0;
      _cleanSince = null;
    }
    if (_lastAdjustment != null &&
        now.difference(_lastAdjustment!) < const Duration(milliseconds: 800)) {
      return null;
    }
    final double neutral = 0.0.clamp(minExposure, maxExposure);
    final double minimum = math.max(minExposure, neutral - 1.5);
    final double step = exposureStep > 0
        ? (.3 / exposureStep).ceil() * exposureStep
        : .3;
    double? next;
    if (_washedFrames >= 2 && currentExposure > minimum) {
      next = math.max(minimum, currentExposure - step);
    } else if (_cleanFrames >= 3 &&
        _cleanSince != null &&
        now.difference(_cleanSince!) >= const Duration(seconds: 2) &&
        currentExposure < neutral) {
      next = math.min(neutral, currentExposure + step);
    }
    if (next == null || (next - currentExposure).abs() < .000001) return null;
    _lastAdjustment = now;
    _washedFrames = 0;
    _cleanFrames = 0;
    _cleanSince = null;
    return next;
  }
}
