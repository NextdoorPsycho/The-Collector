// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import XCTest

@testable import camera_avfoundation

/// Includes test cases related to the `start` method of the Camera class.
final class CameraStartTests: XCTestCase {
  func testStart_capsPhotoDimensionsWithoutChangingPreviewOrCamera() throws {
    guard #available(iOS 16.0, *) else {
      throw XCTSkip("maxPhotoDimensions requires iOS 16.")
    }

    let activeFormatMock = MockCaptureDeviceFormat()
    activeFormatMock.supportedMaxPhotoDimensions = [
      CMVideoDimensions(width: 1920, height: 1080),
      CMVideoDimensions(width: 4032, height: 3024),
      CMVideoDimensions(width: 3264, height: 2448),
      CMVideoDimensions(width: 8064, height: 6048),
    ]
    let captureDeviceMock = MockCaptureDevice()
    captureDeviceMock.activeFormatStub = { activeFormatMock }

    let configuration = CameraTestUtils.createTestCameraConfiguration()
    configuration.videoCaptureDeviceFactory = { _ in captureDeviceMock }
    let cam = CameraTestUtils.createTestCamera(configuration)

    let mockOutput = MockCapturePhotoOutput()
    cam.capturePhotoOutput = mockOutput
    let previewDimensions: CMVideoDimensions = CMVideoFormatDescriptionGetDimensions(
      cam.captureDevice.flutterActiveFormat.formatDescription)

    cam.start()

    XCTAssertEqual(mockOutput.maxPhotoDimensions.width, 4032)
    XCTAssertEqual(mockOutput.maxPhotoDimensions.height, 3024)
    let currentPreviewDimensions: CMVideoDimensions = CMVideoFormatDescriptionGetDimensions(
      cam.captureDevice.flutterActiveFormat.formatDescription)
    XCTAssertEqual(currentPreviewDimensions.width, previewDimensions.width)
    XCTAssertEqual(currentPreviewDimensions.height, previewDimensions.height)
    XCTAssertTrue(cam.captureDevice === captureDeviceMock)
  }

  func testBoundedPhotoDimensions_includesExactPixelLimitAndPreservesAdvertisedOrientation() {
    let selected: CMVideoDimensions? = FormatUtils.boundedPhotoDimensions([
      CMVideoDimensions(width: 3000, height: 4201),
      CMVideoDimensions(width: 2448, height: 3264),
      CMVideoDimensions(width: 3000, height: 4200),
    ])
    XCTAssertEqual(selected?.width, 3000)
    XCTAssertEqual(selected?.height, 4200)
  }

  func testBoundedPhotoDimensions_usesSmallestAdvertisedSizeWhenAllExceedLimit() {
    let selected: CMVideoDimensions? = FormatUtils.boundedPhotoDimensions([
      CMVideoDimensions(width: 8064, height: 6048),
      CMVideoDimensions(width: 5712, height: 4284),
      CMVideoDimensions(width: 6000, height: 4000),
    ])
    XCTAssertEqual(selected?.width, 6000)
    XCTAssertEqual(selected?.height, 4000)
  }

  func testBoundedPhotoDimensions_emptyOrInvalidDimensionsLeaveOutputUnconfigured() {
    XCTAssertNil(FormatUtils.boundedPhotoDimensions([]))
    XCTAssertNil(FormatUtils.boundedPhotoDimensions([
      CMVideoDimensions(width: 0, height: 3024),
      CMVideoDimensions(width: 4032, height: -1),
    ]))
    let selected: CMVideoDimensions? = FormatUtils.boundedPhotoDimensions([
      CMVideoDimensions(width: 0, height: 3024),
      CMVideoDimensions(width: 1920, height: 1080),
    ])
    XCTAssertEqual(selected?.width, 1920)
    XCTAssertEqual(selected?.height, 1080)
  }
}
