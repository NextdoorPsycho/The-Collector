import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/scanning/scan_camera_lens_policy.dart';

void main() {
  const CameraDescription wide = CameraDescription(
    name: 'wide',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
    lensType: CameraLensType.wide,
  );
  const CameraDescription close = CameraDescription(
    name: 'close',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
    lensType: CameraLensType.ultraWide,
  );
  test(
    'only a blurred card at the wide lens near limit chooses the closer lens',
    () {
      CameraDescription? choose({
        bool manual = false,
        bool card = true,
        double? sharpness = .04,
        double? position = .002,
      }) => closerScanLens(
        current: wide,
        cameras: const <CameraDescription>[wide, close],
        userSelectedLens: manual,
        hasCardEvidence: card,
        sharpness: sharpness,
        lensPosition: position,
      );
      expect(choose(), close);
      expect(choose(manual: true), isNull);
      expect(choose(card: false), isNull);
      expect(choose(sharpness: .6), isNull);
      expect(choose(position: .7), isNull);
      expect(choose(position: .998), isNull);
      expect(choose(position: .015), close);
      expect(choose(position: .016), isNull);
      expect(choose(position: -.01), isNull);
      expect(choose(sharpness: null), isNull);
      expect(choose(position: double.nan), isNull);
      expect(choose(position: 1.01), isNull);
    },
  );
  test(
    'a missing macro lens or an already selected macro lens stays unchanged',
    () {
      expect(
        closerScanLens(
          current: wide,
          cameras: const <CameraDescription>[wide],
          userSelectedLens: false,
          hasCardEvidence: true,
          sharpness: .04,
          lensPosition: 0,
        ),
        isNull,
      );
      expect(
        closerScanLens(
          current: close,
          cameras: const <CameraDescription>[wide, close],
          userSelectedLens: false,
          hasCardEvidence: true,
          sharpness: .04,
          lensPosition: 0,
        ),
        isNull,
      );
    },
  );
}
