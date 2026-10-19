import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';

const bool _enabled = bool.fromEnvironment('GLARE_CAMERA_QA');

Future<Map<String, Object?>> _exposureStatus(
  CameraDescription camera, {
  double? expected,
}) async {
  final Stopwatch elapsed = Stopwatch()..start();
  Map<String, Object?>? latest;
  while (elapsed.elapsedMilliseconds < 1000) {
    final int remaining = 1000 - elapsed.elapsedMilliseconds;
    final Map<Object?, Object?>? status = await NativeCardRecognizer.channel
        .invokeMethod<Map<Object?, Object?>>(
          'cameraFocusStatus',
          <String, String>{'cameraName': camera.name},
        )
        .timeout(Duration(milliseconds: remaining < 200 ? remaining : 200));
    if (status != null) {
      latest = <String, Object?>{
        for (final MapEntry<Object?, Object?> entry in status.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
      final Object? bias = status['exposureTargetBias'];
      if (bias is num &&
          bias.toDouble().isFinite &&
          (expected == null || (bias.toDouble() - expected).abs() <= .01)) {
        return latest;
      }
    }
    final int left = 1000 - elapsed.elapsedMilliseconds;
    if (left > 0) {
      await Future<void>.delayed(Duration(milliseconds: left < 40 ? left : 40));
    }
  }
  throw StateError('Native exposure bias did not settle: $latest');
}

double _bias(Map<String, Object?> status, double minimum, double maximum) {
  final Object? value = status['exposureTargetBias'];
  if (value is! num ||
      !value.toDouble().isFinite ||
      value < minimum ||
      value > maximum) {
    throw StateError('Invalid native exposure bias: $value');
  }
  return value.toDouble();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'rear wide exposure round trip restores the observed initial bias',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        final Map<String, Object?> report = <String, Object?>{
          'passed': false,
          'capabilityAvailable': false,
          'restored': false,
        };
        CameraController? controller;
        CameraDescription? camera;
        double? initial;
        double? minimum;
        double? maximum;
        bool attempted = false;
        Object? failure;
        StackTrace? failureStack;
        try {
          final List<CameraDescription> cameras = await availableCameras();
          for (final CameraDescription candidate in cameras) {
            if (candidate.lensDirection == CameraLensDirection.back &&
                candidate.lensType == CameraLensType.wide) {
              camera = candidate;
              break;
            }
          }
          if (camera == null) {
            report['reason'] = 'No rear wide lens is available';
            report['status'] = 'not_tested';
          } else {
            report['camera'] = camera.name;
            controller = CameraController(
              camera,
              ResolutionPreset.max,
              enableAudio: false,
              imageFormatGroup: ImageFormatGroup.bgra8888,
            );
            await controller.initialize().timeout(const Duration(seconds: 10));
            minimum = await controller.getMinExposureOffset();
            maximum = await controller.getMaxExposureOffset();
            final double step = await controller.getExposureOffsetStepSize();
            if (!minimum.isFinite ||
                !maximum.isFinite ||
                minimum > maximum ||
                !step.isFinite ||
                step < 0) {
              throw StateError('Invalid camera exposure limits');
            }
            report['limits'] = <String, double>{
              'min': minimum,
              'max': maximum,
              'step': step,
            };
            final Map<String, Object?> before = await _exposureStatus(camera);
            initial = _bias(before, minimum, maximum);
            report['initial'] = initial;
            report['initialStatus'] = before;
            final double delta = step > .3 ? step : .3;
            double target = (initial - delta).clamp(minimum, maximum);
            if ((target - initial).abs() < .000001) {
              target = (initial + delta).clamp(minimum, maximum);
            }
            report['target'] = target;
            if ((target - initial).abs() < .000001) {
              report['reason'] = 'The camera has no adjustable exposure range';
              report['status'] = 'not_tested';
            } else {
              report['capabilityAvailable'] = true;
              attempted = true;
              final double actual = await controller
                  .setExposureOffset(target)
                  .timeout(const Duration(seconds: 1));
              report['actual'] = actual;
              if (!actual.isFinite || actual < minimum || actual > maximum) {
                throw StateError('Invalid applied exposure offset: $actual');
              }
              if ((actual - initial).abs() < .000001) {
                report['status'] = 'not_tested';
                throw StateError(
                  'The exposure command did not change native bias',
                );
              }
              final Map<String, Object?> status = await _exposureStatus(
                camera,
                expected: actual,
              );
              report['status'] = status;
              _bias(status, minimum, maximum);
              report['passed'] = true;
            }
          }
        } on Object catch (error, stack) {
          failure = error;
          failureStack = stack;
          report['failure'] = error.toString();
        } finally {
          if (attempted &&
              controller != null &&
              camera != null &&
              initial != null &&
              minimum != null &&
              maximum != null) {
            try {
              final double restored = await controller
                  .setExposureOffset(initial)
                  .timeout(const Duration(seconds: 1));
              if (!restored.isFinite || (restored - initial).abs() > .01) {
                throw StateError(
                  'Initial exposure was not restored: $restored instead of $initial',
                );
              }
              final Map<String, Object?> status = await _exposureStatus(
                camera,
                expected: initial,
              );
              _bias(status, minimum, maximum);
              report['restoreActual'] = restored;
              report['restoreStatus'] = status;
              report['restored'] = true;
            } on Object catch (error, stack) {
              report['restoreFailure'] = error.toString();
              failure ??= error;
              failureStack ??= stack;
            }
          }
          try {
            await controller?.dispose();
          } on Object catch (error, stack) {
            report['disposeFailure'] = error.toString();
            failure ??= error;
            failureStack ??= stack;
          }
          report['passed'] = report['passed'] == true && failure == null;
          try {
            await File(
              '${Directory.systemTemp.path}/collector_glare_exposure_report.json',
            ).writeAsString(
              const JsonEncoder.withIndent('  ').convert(report),
              flush: true,
            );
          } on Object catch (error, stack) {
            failure ??= error;
            failureStack ??= stack;
          }
        }
        if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
        if (report['passed'] != true) {
          throw StateError('Physical exposure control was not tested');
        }
      });
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
