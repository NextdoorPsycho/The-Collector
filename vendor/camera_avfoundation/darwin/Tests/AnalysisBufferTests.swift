import AVFoundation
import XCTest

@testable import camera_avfoundation

final class AnalysisBufferTests: XCTestCase {
  func testBoundedBuffersPreserveAspectAndOrientation() throws {
    for orientation: AVCaptureVideoOrientation in [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight] {
      let size = try XCTUnwrap(DefaultCamera.analysisBufferDimensions(
        source: CMVideoDimensions(width: 4032, height: 3024), orientation: orientation))
      let portrait = orientation == .portrait || orientation == .portraitUpsideDown
      XCTAssertEqual(size.width, portrait ? 1440 : 1920)
      XCTAssertEqual(size.height, portrait ? 1920 : 1440)
    }
    let wide = try XCTUnwrap(DefaultCamera.analysisBufferDimensions(
      source: CMVideoDimensions(width: 3840, height: 2160), orientation: .landscapeRight))
    XCTAssertEqual(wide.width, 1920)
    XCTAssertEqual(wide.height, 1080)
    let small = try XCTUnwrap(DefaultCamera.analysisBufferDimensions(
      source: CMVideoDimensions(width: 640, height: 480), orientation: .portrait))
    XCTAssertEqual(small.width, 480)
    XCTAssertEqual(small.height, 640)
    XCTAssertNil(DefaultCamera.analysisBufferDimensions(
      source: CMVideoDimensions(width: 0, height: 480), orientation: .portrait))
    XCTAssertNil(DefaultCamera.analysisBufferDimensions(
      source: CMVideoDimensions(width: 4032, height: 3024), orientation: .portrait, edge: 2))
  }

  func testVideoSettingsFollowOrientationWithoutChangingPhotoMaximum() throws {
    guard #available(iOS 16.0, *) else { return }
    let configuration = CameraTestUtils.createTestCameraConfiguration()
    configuration.videoDimensionsConverter = { _ in CMVideoDimensions(width: 4032, height: 3024) }
    let camera = CameraTestUtils.createTestCamera(configuration)
    let video = MockCaptureVideoDataOutput()
    let connection = MockCaptureConnection()
    connection.isVideoOrientationSupported = true
    video.connectionWithMediaTypeStub = { _ in connection }
    let photo = MockCapturePhotoOutput()
    photo.maxPhotoDimensions = CMVideoDimensions(width: 8064, height: 6048)
    camera.captureVideoOutput = video
    camera.capturePhotoOutput = photo
    camera.videoFormat = kCVPixelFormatType_32BGRA
    XCTAssertTrue(video.automaticallyConfiguresOutputBufferDimensions)
    XCTAssertNil(video.videoSettings[kCVPixelBufferWidthKey as String])
    let started = expectation(description: "Analysis stream started")
    camera.startImageStream(with: MockFlutterBinaryMessenger(), imageStreamHandler: MockImageStreamHandler()) { _ in
      started.fulfill()
    }
    waitForExpectations(timeout: 30)
    XCTAssertFalse(video.automaticallyConfiguresOutputBufferDimensions)
    XCTAssertFalse(video.deliversPreviewSizedOutputBuffers)
    XCTAssertEqual(video.videoSettings[kCVPixelBufferWidthKey as String] as? Int32, 1440)
    XCTAssertEqual(video.videoSettings[kCVPixelBufferHeightKey as String] as? Int32, 1920)
    camera.deviceOrientation = .landscapeLeft
    XCTAssertEqual(video.videoSettings[kCVPixelBufferWidthKey as String] as? Int32, 1920)
    XCTAssertEqual(video.videoSettings[kCVPixelBufferHeightKey as String] as? Int32, 1440)
    camera.videoFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    XCTAssertEqual(video.videoSettings[kCVPixelBufferWidthKey as String] as? Int32, 1920)
    XCTAssertEqual(video.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] as? FourCharCode,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    XCTAssertEqual(photo.maxPhotoDimensions.width, 8064)
    XCTAssertEqual(photo.maxPhotoDimensions.height, 6048)
    camera.stopImageStream()
    XCTAssertTrue(video.automaticallyConfiguresOutputBufferDimensions)
    XCTAssertFalse(video.deliversPreviewSizedOutputBuffers)
    XCTAssertNil(video.videoSettings[kCVPixelBufferWidthKey as String])
    XCTAssertNil(video.videoSettings[kCVPixelBufferHeightKey as String])
  }
}
