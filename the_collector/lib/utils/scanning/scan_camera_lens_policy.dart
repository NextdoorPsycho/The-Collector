import 'package:camera/camera.dart';

CameraDescription? closerScanLens({
  required CameraDescription current,
  required Iterable<CameraDescription> cameras,
  required bool userSelectedLens,
  required bool hasCardEvidence,
  required double? sharpness,
  required double? lensPosition,
}) {
  if (userSelectedLens ||
      !hasCardEvidence ||
      current.lensType != CameraLensType.wide ||
      sharpness == null ||
      lensPosition == null ||
      !sharpness.isFinite ||
      !lensPosition.isFinite ||
      sharpness < 0 ||
      sharpness >= .12 ||
      lensPosition < 0 ||
      lensPosition > .015) {
    return null;
  }
  return cameras
      .where(
        (CameraDescription camera) =>
            camera.lensDirection == CameraLensDirection.back &&
            camera.lensType == CameraLensType.ultraWide,
      )
      .firstOrNull;
}
