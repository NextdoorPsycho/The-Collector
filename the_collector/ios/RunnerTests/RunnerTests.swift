import XCTest
import CoreGraphics
import CoreImage
import Darwin
import Foundation
@testable import Runner

final class ScanCropCacheTests: XCTestCase {
  private func temporaryRoot() throws -> URL {
    let root: URL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  @discardableResult
  private func crop(in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file: URL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
    try Data([1, 2, 3]).write(to: file)
    return file
  }

  private func drain(_ cache: ScanCropCache) {
    for _: Int in 0..<100 {
      if !cache.removeAbandonedBatch() { return }
    }
    XCTFail("Cleanup did not finish within the fixture's bounded entry count.")
  }

  func testCropCacheRemovesPriorGenerationsAndLegacyCropsButPreservesCurrentPixels() throws {
    let root: URL = try temporaryRoot()
    let cache: ScanCropCache = ScanCropCache(root: root, generation: UUID())
    let current: URL = try cache.nextCropURL()
    try Data([4, 5, 6]).write(to: current)
    let oldDirectory: URL = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let old: URL = try crop(in: oldDirectory)
    let legacy: URL = try crop(in: root)

    drain(cache)

    XCTAssertEqual(try Data(contentsOf: current), Data([4, 5, 6]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldDirectory.path))
    XCTAssertEqual(current.deletingLastPathComponent().deletingLastPathComponent(), root)
    XCTAssertTrue(current.path.contains("/\(root.lastPathComponent)/"))
    let next: URL = try cache.nextCropURL()
    XCTAssertEqual(current.deletingLastPathComponent(), next.deletingLastPathComponent())
    XCTAssertNotEqual(current, next)
  }

  func testCropCachePreservesUnknownEntriesAndNeverTraversesSymbolicLinks() throws {
    let root: URL = try temporaryRoot()
    let outside: URL = try temporaryRoot()
    let external: URL = try crop(in: outside)
    let cache: ScanCropCache = ScanCropCache(root: root, generation: UUID())
    let oldDirectory: URL = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let old: URL = try crop(in: oldDirectory)
    let unknown: URL = oldDirectory.appendingPathComponent("notes.txt")
    try Data([7]).write(to: unknown)
    let nested: URL = try crop(in: oldDirectory.appendingPathComponent("evidence", isDirectory: true))
    let unknownDirectory: URL = try crop(in: root.appendingPathComponent("other-cache", isDirectory: true))
    let unknownRootFile: URL = root.appendingPathComponent("manual.jpg")
    try Data([8]).write(to: unknownRootFile)
    let directoryLink: URL = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: outside)
    let fileLink: URL = oldDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
    try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: external)

    drain(cache)

    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    for file: URL in [unknown, nested, unknownDirectory, unknownRootFile, external] {
      XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path)
    }
    XCTAssertEqual(try directoryLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
    XCTAssertEqual(try fileLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
  }

  func testCropCacheLimitsEachCleanupBatchAndDoesNotRestartFinishedEnumeration() throws {
    let root: URL = try temporaryRoot()
    let cache: ScanCropCache = ScanCropCache(root: root, generation: UUID())
    let files: [URL] = try (0..<70).map { _ in try crop(in: root) }

    XCTAssertTrue(cache.removeAbandonedBatch())
    XCTAssertEqual(files.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 6)
    XCTAssertFalse(cache.removeAbandonedBatch())
    XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

    let later: URL = try crop(in: root)
    XCTAssertFalse(cache.removeAbandonedBatch())
    XCTAssertTrue(FileManager.default.fileExists(atPath: later.path))
  }

  func testCropCachePreparationPreservesCurrentGenerationAcrossRepeatedCalls() throws {
    let root: URL = try temporaryRoot()
    let cache: ScanCropCache = ScanCropCache(root: root, generation: UUID())
    let current: URL = try cache.nextCropURL()
    try Data([9]).write(to: current)
    let old: URL = try crop(in: root)
    cache.prepare()
    cache.prepare()
    let removed: NSPredicate = NSPredicate { _, _ in
      !FileManager.default.fileExists(atPath: old.path)
    }
    let completed: XCTestExpectation = expectation(for: removed, evaluatedWith: nil)
    wait(for: [completed], timeout: 5)
    cache.prepare()
    XCTAssertEqual(try Data(contentsOf: current), Data([9]))
  }

  func testCropCacheDoesNotTraverseASymbolicLinkRootOrWriteThroughIt() throws {
    let directory: URL = try temporaryRoot()
    let outside: URL = try temporaryRoot()
    let external: URL = try crop(in: outside)
    let root: URL = directory.appendingPathComponent("ScanCrops", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
    let cache: ScanCropCache = ScanCropCache(root: root, generation: UUID())

    XCTAssertFalse(cache.removeAbandonedBatch())
    XCTAssertThrowsError(try cache.nextCropURL())
    XCTAssertEqual(try Data(contentsOf: external), Data([1, 2, 3]))
  }

  func testCropCacheRetriesFailedDeletesOnTheNextProcess() throws {
    try XCTSkipIf(geteuid() == 0, "Root bypasses directory write permissions.")
    let root: URL = try temporaryRoot()
    let oldDirectory: URL = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let old: URL = try crop(in: oldDirectory)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: oldDirectory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: oldDirectory.path) }
    let first: ScanCropCache = ScanCropCache(root: root, generation: UUID())

    drain(first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: oldDirectory.path)
    let restarted: ScanCropCache = ScanCropCache(root: root, generation: UUID())
    drain(restarted)

    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldDirectory.path))
  }
}

final class RunnerTests: XCTestCase {
  func testArtworkRegionRejectsInvalidCoordinates() {
    let scanner = LocalCardScanner()
    XCTAssertEqual(scanner.artworkQueryRegion(nil), CGRect(x: 0.08, y: 0.14, width: 0.84, height: 0.38))
    XCTAssertEqual(scanner.artworkQueryRegion(["x": 0.07, "y": 0.10, "width": 0.86, "height": 0.65]),
      CGRect(x: 0.07, y: 0.10, width: 0.86, height: 0.65))
    XCTAssertNil(scanner.artworkQueryRegion(["x": -0.01, "y": 0.10, "width": 0.86, "height": 0.65]))
    XCTAssertNil(scanner.artworkQueryRegion(["x": 0.07, "y": 0.10, "width": 0.96, "height": 0.65]))
    XCTAssertNil(scanner.artworkQueryRegion(["x": Double.nan, "y": 0.10, "width": 0.86, "height": 0.65]))
    XCTAssertNil(scanner.artworkQueryRegion(["x": 0.07, "y": 0.10, "width": 0.86, "height": 0.0]))
  }

  func testSavedTargetRegionsPreserveObservedSkewAndDeduplicateWithoutRotating() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let points: [[String: Double]] = [["x": 0.12, "y": 0.43], ["x": 0.48, "y": 0.39],
      ["x": 0.58, "y": 0.61], ["x": 0.08, "y": 0.64]]
    let regions: [[CGPoint]] = try scanner.savedTargetRegions([points, points])
    XCTAssertEqual(regions.count, 1)
    XCTAssertEqual(regions[0], points.map { CGPoint(x: $0["x"]!, y: 1 - $0["y"]!) })
    XCTAssertEqual(try scanner.savedTargetRegions(nil), [])
    XCTAssertEqual(try scanner.savedTargetRegions([[[String: Double]]]()), [])
    XCTAssertFalse(scanner.savedTargetNeedsProposal(regions[0], among: regions))
    let neighbor: [[CGPoint]] = try scanner.savedTargetRegions([[
      ["x": 0.65, "y": 0.42], ["x": 0.90, "y": 0.46],
      ["x": 0.87, "y": 0.80], ["x": 0.61, "y": 0.77]]])
    XCTAssertTrue(scanner.savedTargetNeedsProposal(neighbor[0], among: regions))
    let contained: [[CGPoint]] = try scanner.savedTargetRegions([[
      ["x": 0.20, "y": 0.46], ["x": 0.40, "y": 0.46],
      ["x": 0.40, "y": 0.57], ["x": 0.20, "y": 0.57]]])
    XCTAssertTrue(scanner.savedTargetNeedsProposal(contained[0], among: regions),
      "A large background outline must not suppress a smaller observed card.")
    XCTAssertTrue(scanner.savedTargetNeedsProposal(regions[0], among: contained),
      "An internal art outline must not suppress an observed outside border.")
  }

  func testSavedTargetRegionsRejectMalformedUnboundedAndSelfIntersectingGuides() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let points: [[String: Double]] = [["x": 0.1, "y": 0.1], ["x": 0.4, "y": 0.1],
      ["x": 0.4, "y": 0.6], ["x": 0.1, "y": 0.6]]
    XCTAssertThrowsError(try scanner.savedTargetRegions("invalid"))
    XCTAssertThrowsError(try scanner.savedTargetRegions(Array(repeating: points, count: 9)))
    XCTAssertThrowsError(try scanner.savedTargetRegions([Array(points.prefix(3))]))
    XCTAssertThrowsError(try scanner.savedTargetRegions([Array(points.reversed())]))
    XCTAssertThrowsError(try scanner.savedTargetRegions([[points[0], points[2], points[1], points[3]]]))
    XCTAssertThrowsError(try scanner.savedTargetRegions([[points[0], points[1], points[0], points[3]]]))
    for invalid: Double in [-0.01, 1.01, .nan, .infinity] {
      var invalidPoints: [[String: Double]] = points
      invalidPoints[0]["x"] = invalid
      XCTAssertThrowsError(try scanner.savedTargetRegions([invalidPoints]))
    }
    XCTAssertThrowsError(try scanner.savedTargetRegions([[
      ["x": 0.10, "y": 0.10], ["x": 0.11, "y": 0.10],
      ["x": 0.11, "y": 0.11], ["x": 0.10, "y": 0.11]]]))
  }

  func testSavedTargetAppearancesSampleOriginalQuadsInLiveRGBOrder() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let red: CIImage = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
      .cropped(to: CGRect(x: 0, y: 0, width: 800, height: 1200))
    let blue: CIImage = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
      .cropped(to: CGRect(x: 400, y: 0, width: 400, height: 1200))
    let photo: CIImage = blue.composited(over: red)
    let requested: [[[String: Double]]] = [
      [["x": 0.10, "y": 0.20], ["x": 0.40, "y": 0.25],
        ["x": 0.36, "y": 0.80], ["x": 0.12, "y": 0.75]],
      [["x": 0.60, "y": 0.20], ["x": 0.90, "y": 0.25],
        ["x": 0.86, "y": 0.80], ["x": 0.62, "y": 0.75]]]
    let regions: [[CGPoint]] = try scanner.savedTargetRegions(requested)
    let samples: [[String: Any]] = scanner.savedTargetAppearances(photo, regions: regions)
    XCTAssertEqual(samples.count, 2)
    for index: Int in samples.indices {
      XCTAssertEqual(samples[index]["present"] as? Bool, true)
      let values: [Double] = try XCTUnwrap(samples[index]["values"] as? [Double])
      XCTAssertEqual(values.count, 8 * 12 * 3)
      XCTAssertTrue(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
      let center: Int = (5 * 8 + 4) * 3
      XCTAssertGreaterThan(values[center + (index == 0 ? 0 : 2)], 0.95)
      XCTAssertLessThan(values[center + 1], 0.05)
      XCTAssertLessThan(values[center + (index == 0 ? 2 : 0)], 0.05)
      let corners: [[String: Double]] = try XCTUnwrap(samples[index]["corners"] as? [[String: Double]])
      XCTAssertEqual(corners.count, 4)
      for corner: Int in corners.indices {
        XCTAssertEqual(try XCTUnwrap(corners[corner]["x"]), requested[index][corner]["x"]!, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(corners[corner]["y"]), requested[index][corner]["y"]!, accuracy: 1e-12)
      }
    }
  }

  func testSavedTargetAppearancesRejectInvalidGeometryImagesAndUnboundedWork() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let unbounded: CIImage = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
    let photo: CIImage = unbounded.cropped(to: CGRect(x: 0, y: 0, width: 800, height: 1200))
    let regions: [[CGPoint]] = try scanner.savedTargetRegions([[
      ["x": 0.1, "y": 0.1], ["x": 0.4, "y": 0.1],
      ["x": 0.4, "y": 0.6], ["x": 0.1, "y": 0.6]]])
    XCTAssertTrue(scanner.savedTargetAppearances(photo, regions: []).isEmpty)
    XCTAssertTrue(scanner.savedTargetAppearances(unbounded, regions: regions).isEmpty)
    XCTAssertTrue(scanner.savedTargetAppearances(photo.cropped(to: .zero), regions: regions).isEmpty)
    XCTAssertTrue(scanner.savedTargetAppearances(photo, regions: Array(repeating: regions[0], count: 9)).isEmpty)
    XCTAssertTrue(scanner.savedTargetAppearances(photo, regions: [Array(regions[0].prefix(3))]).isEmpty)
    XCTAssertTrue(scanner.savedTargetAppearances(photo,
      regions: [[regions[0][0], regions[0][2], regions[0][1], regions[0][3]]]).isEmpty)
    for invalid: CGFloat in [-0.01, 1.01, .nan, .infinity] {
      var invalidPoints: [CGPoint] = regions[0]
      invalidPoints[0].x = invalid
      XCTAssertTrue(scanner.savedTargetAppearances(photo, regions: [invalidPoints]).isEmpty)
    }
  }

  private final class ConfirmationPlayer: CaptureConfirmationPlaying {
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 9
    var starts: Int = 0
    var acceptsPlayback: Bool = true
    func play() -> Bool {
      starts += 1
      isPlaying = acceptsPlayback
      return acceptsPlayback
    }
  }

  func testCaptureConfirmationStartsImmediatelyWithoutQueuingRepeatedOrBusyRequests() {
    let player: ConfirmationPlayer = ConfirmationPlayer()
    var now: TimeInterval = 10
    let scanner: LocalCardScanner = LocalCardScanner(confirmationPlayer: player, confirmationClock: { now })
    XCTAssertTrue(scanner.confirmCapture())
    XCTAssertEqual(player.currentTime, 0)
    XCTAssertEqual(player.starts, 1)
    now = 11.6
    XCTAssertFalse(scanner.confirmCapture(), "An active sound must never restart or queue.")
    player.isPlaying = false
    now = 11.499
    XCTAssertFalse(scanner.confirmCapture())
    XCTAssertEqual(player.starts, 1)
    now = 11.5
    XCTAssertTrue(scanner.confirmCapture())
    XCTAssertEqual(player.starts, 2)
    player.isPlaying = false
    now = 13
    XCTAssertEqual(player.starts, 2, "Rejected requests must not replay after time advances.")
  }

  func testCaptureConfirmationRejectsUnavailableFailedAndInvalidClockWithoutDeferredPlayback() {
    XCTAssertFalse(LocalCardScanner().confirmCapture())
    let player: ConfirmationPlayer = ConfirmationPlayer()
    var now: TimeInterval = 1
    let scanner: LocalCardScanner = LocalCardScanner(confirmationPlayer: player, confirmationClock: { now })
    for invalid: TimeInterval in [.nan, .infinity, -1] {
      now = invalid
      XCTAssertFalse(scanner.confirmCapture())
    }
    XCTAssertEqual(player.starts, 0)
    now = 1
    player.acceptsPlayback = false
    XCTAssertFalse(scanner.confirmCapture())
    player.acceptsPlayback = true
    XCTAssertTrue(scanner.confirmCapture(), "Failed playback must not consume successful-play cooldown.")
    player.isPlaying = false
    now = 0.5
    XCTAssertFalse(scanner.confirmCapture(), "A backward clock must not bypass the cooldown.")
    XCTAssertEqual(player.starts, 2)
  }

  private func rgba(_ red: UInt8, _ green: UInt8, _ blue: UInt8, count: Int) -> [UInt8] {
    (0..<count).flatMap { _ in [red, green, blue, 255] }
  }

  func testLightingHistogramIsBoundedFiniteAndRejectsInvalidOrTransparentSamples() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    XCTAssertNil(scanner.lightingSummary([]))
    XCTAssertNil(scanner.lightingSummary([255, 255, 255]))
    XCTAssertNil(scanner.lightingSummary([255, 255, 255, 0]))
    XCTAssertNil(scanner.lightingSummary(rgba(255, 255, 255, count: 128 * 128 + 1)))
    let lighting = try XCTUnwrap(scanner.lightingSummary(rgba(248, 248, 248, count: 70)
      + rgba(230, 230, 230, count: 30)))
    XCTAssertEqual(lighting.sampleCount, 100)
    XCTAssertEqual(lighting.highlightFraction, 0.70, accuracy: 0.000001)
    XCTAssertEqual(lighting.shadowFraction, 0)
    XCTAssertEqual(lighting.contrast, 18.0 / 255, accuracy: 0.000001)
    for value: Double in [lighting.highlightFraction, lighting.shadowFraction,
      lighting.meanLuminance, lighting.contrast] {
      XCTAssertTrue(value.isFinite)
      XCTAssertGreaterThanOrEqual(value, 0)
      XCTAssertLessThanOrEqual(value, 1)
    }
    XCTAssertTrue(scanner.washedTextRecoveryAllowed(lighting))
  }

  func testLightingDoesNotCallWhitePaperSaturatedColorShadowsOrTinySamplesRecoverableGlare() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let cases: [[UInt8]] = [rgba(245, 245, 245, count: 92) + rgba(32, 32, 32, count: 8),
      rgba(220, 220, 220, count: 65) + rgba(20, 20, 20, count: 35),
      rgba(255, 255, 0, count: 100), rgba(0, 0, 0, count: 100),
      rgba(248, 248, 248, count: 45) + rgba(230, 230, 230, count: 18)]
    for (index, pixels): (Int, [UInt8]) in cases.enumerated() {
      let lighting = try XCTUnwrap(scanner.lightingSummary(pixels))
      XCTAssertFalse(scanner.washedTextRecoveryAllowed(lighting), "negative \(index)")
    }
    let clipped = try XCTUnwrap(scanner.lightingSummary(rgba(255, 255, 255, count: 100)))
    XCTAssertTrue(clipped.washedOut)
    XCTAssertEqual(clipped.highlightFraction, 1)
    XCTAssertFalse(scanner.washedTextRecoveryAllowed(clipped))
  }

  func testAdaptiveLightingMapStretchesObservedGrayRangeWithoutExceedingGainBound() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let washed = try XCTUnwrap(scanner.lightingSummary(rgba(248, 248, 248, count: 70)
      + rgba(230, 230, 230, count: 30)))
    let parameters = try XCTUnwrap(scanner.lightingContrastParameters(washed))
    XCTAssertEqual(washed.darkPoint * parameters.gain + parameters.bias, 0, accuracy: 0.000001)
    XCTAssertEqual(washed.lightPoint * parameters.gain + parameters.bias, 1, accuracy: 0.000001)
    XCTAssertLessThanOrEqual(parameters.gain, 16)
    let narrow = try XCTUnwrap(scanner.lightingSummary(rgba(250, 250, 250, count: 90)
      + rgba(246, 246, 246, count: 10)))
    let capped = try XCTUnwrap(scanner.lightingContrastParameters(narrow))
    XCTAssertEqual(capped.gain, 16)
    XCTAssertEqual(narrow.lightPoint * capped.gain + capped.bias, 1, accuracy: 0.000001)
    let clean = try XCTUnwrap(scanner.lightingSummary(rgba(220, 220, 220, count: 100)))
    let clipped = try XCTUnwrap(scanner.lightingSummary(rgba(255, 255, 255, count: 100)))
    XCTAssertNil(scanner.lightingContrastParameters(clean))
    XCTAssertNil(scanner.lightingContrastParameters(clipped))
  }

  func testSoftwareContrastRecoverySupportsUnclippedWashWithoutChangingHardwareGate() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let washed = try XCTUnwrap(scanner.lightingSummary(rgba(244, 244, 244, count: 70)
      + rgba(220, 220, 220, count: 30)))
    XCTAssertEqual(washed.highlightFraction, 0)
    XCTAssertFalse(washed.washedOut)
    XCTAssertTrue(scanner.washedTextRecoveryAllowed(washed))
    XCTAssertNotNil(scanner.lightingContrastParameters(washed))
    for mean: Double in [2, -1, .nan, .infinity] {
      let invalid: LocalCardScanner.CardLighting = LocalCardScanner.CardLighting(
        highlightFraction: 0.2, shadowFraction: 0, meanLuminance: mean,
        contrast: 0.10, sampleCount: 100, darkPoint: 0.86, lightPoint: 0.96)
      XCTAssertFalse(invalid.washedOut)
      XCTAssertFalse(scanner.washedTextRecoveryAllowed(invalid))
      XCTAssertNil(scanner.lightingContrastParameters(invalid))
    }
  }

  func testProcessedTitleKeepsLiteralConflictAndOriginalConfidenceForReview() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let original: [String: Any] = line("Circle of Procection: Blue", y: 0.035)
    let processed: [String: Any] = line("Circle of Protection: Blue", y: 0.035)
    let merged: [[String: Any]] = scanner.mergingLightingTitleLines([processed], into: [original])
    XCTAssertEqual(merged.count, 2)
    XCTAssertEqual(merged[0]["text"] as? String, original["text"] as? String)
    XCTAssertEqual(merged[0]["confidence"] as? Double, 1)
    XCTAssertEqual(merged[0]["bounds"] as? [String: Double], original["bounds"] as? [String: Double])
    XCTAssertEqual(merged[1]["text"] as? String, processed["text"] as? String)
    XCTAssertEqual(merged[1]["confidence"] as? Double, 1)
    XCTAssertEqual(merged[1]["lightingTitleConflict"] as? Bool, true)
    XCTAssertEqual(scanner.mergingLightingTitleLines([processed], into: [processed]).count, 1)
    let weak: [[String: Any]] = scanner.mergingLightingTitleLines([
      line("Circle of Protection: Blue", y: 0.035, confidence: 0.84)], into: [original])
    XCTAssertNil(weak.last?["lightingTitleConflict"])
    let disjoint: [[String: Any]] = scanner.mergingLightingTitleLines([
      line("Circle of Protection: Blue", y: 0.095)], into: [original])
    XCTAssertNil(disjoint.last?["lightingTitleConflict"])
  }

  func testAWashedTitleCannotBeConcealedByADarkFooterAndArtworkIsNotSampled() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let washed: [UInt8] = rgba(248, 248, 248, count: 70) + rgba(230, 230, 230, count: 30)
    let dark: [UInt8] = rgba(25, 25, 25, count: 100)
    let selected = try XCTUnwrap(scanner.selectingTextBandLighting([washed, dark]))
    XCTAssertTrue(selected.washedOut)
    XCTAssertEqual(selected.sampleCount, 100)
    let clean: [UInt8] = rgba(245, 245, 245, count: 92) + rgba(32, 32, 32, count: 8)
    let combined = try XCTUnwrap(scanner.selectingTextBandLighting([clean, dark]))
    XCTAssertEqual(combined.sampleCount, 200)
    XCTAssertFalse(combined.washedOut)
    let card: CIImage = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1))
      .cropped(to: CGRect(x: 0, y: 0, width: 630, height: 880))
    let whiteArt: CIImage = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
      .cropped(to: CGRect(x: 0, y: 880 * 0.15, width: 630, height: 880 * 0.72))
    let lighting = try XCTUnwrap(scanner.textBandLighting(whiteArt.composited(over: card)))
    XCTAssertEqual(lighting.highlightFraction, 0)
    XCTAssertFalse(lighting.washedOut)
  }

  private func line(_ text: String, y: Double, x: Double = 0.16,
      width: Double = 0.65, height: Double = 0.05,
      confidence: Double = 1) -> [String: Any] {
    ["text": text, "confidence": confidence,
      "bounds": ["x": x, "y": y, "width": width, "height": height]]
  }

  private var actualRules: [[String: Any]] {
    [line("1; Prevent all damage against you", y: 0.598277),
      line("from one blue source. If a source", y: 0.631757),
      line("deals damage to you more than", y: 0.665055),
      line("once in a turn, you may pay 1", y: 0.697265),
      line("each time to prevent the damage.", y: 0.735057)]
  }

  private var observedType: [String: Any] {
    var row: [String: Any] = line("Enchantment", y: 0.496222579,
      x: 0.105993141, width: 0.276644597, height: 0.045955059)
    row["glyphHeight"] = 0.027540675
    row["alternatives"] = ["Enchantmenr", "Enchartment"]
    row["alternativeConfidences"] = [1.0, 1.0]
    return row
  }

  func testStrongUprightOldCardLayoutDoesNotRequireACollectorNumberToAvoidReverseOCR() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let upright: [[String: Any]] = [line("Circle of Protection: Blue", y: 0.035), observedType] + actualRules
    XCTAssertTrue(scanner.liveUprightLayoutSupported(upright))
    XCTAssertTrue(scanner.liveUprightLayoutSupported(upright + [line("Illus. Pete Venters", y: 0.92)]))
    XCTAssertTrue(scanner.liveUprightLayoutSupported(upright + [line("C 0013", y: 0.92)]))
  }

  func testLiveNamedOrientationAcceptsOneRulesRowWithoutRequiringRulesOnlyProof() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let rows: [[String: Any]] = [line("Observed Name", y: 0.035),
      line("Instant", y: 0.54, width: 0.14, height: 0.03),
      line("Target creature gains flying.", y: 0.65, height: 0.04)]
    XCTAssertTrue(scanner.liveNamedLayoutSupported(rows))
    XCTAssertFalse(scanner.liveUprightLayoutSupported(rows))
    XCTAssertFalse(scanner.liveNamedLayoutSupported(Array(rows.dropFirst())))
    XCTAssertFalse(scanner.liveNamedLayoutSupported(Array(rows.dropLast())))
    XCTAssertFalse(scanner.liveNamedLayoutSupported([rows[0], rows[2]]))
    for index: Int in rows.indices {
      var weak: [[String: Any]] = rows
      weak[index]["confidence"] = 0.84
      XCTAssertFalse(scanner.liveNamedLayoutSupported(weak))
    }
    for turns: Int in 1...3 {
      let rotated: [[String: Any]] = rows.map { row in
        var transformed: [String: Any] = row
        let bounds: [String: Double] = row["bounds"] as! [String: Double]
        var x: Double = bounds["x"]!, y: Double = bounds["y"]!
        var width: Double = bounds["width"]!, height: Double = bounds["height"]!
        for _: Int in 0..<turns {
          let previousX: Double = x, previousWidth: Double = width
          x = 1 - y - height
          y = previousX
          width = height
          height = previousWidth
        }
        transformed["bounds"] = ["x": x, "y": y, "width": width, "height": height]
        XCTAssertEqual(transformed["confidence"] as? Double, row["confidence"] as? Double)
        return transformed
      }
      XCTAssertFalse(scanner.liveNamedLayoutSupported(rotated), "rotation \(turns)")
    }
  }

  func testSavedTargetRequiresFreshCardTextInsteadOfGeometryOrTitleAlone() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let title: [String: Any] = line("Observed Name", y: 0.035)
    let type: [String: Any] = line("Instant", y: 0.54, width: 0.14, height: 0.03)
    let rules: [String: Any] = line("Target creature gains flying.", y: 0.65, height: 0.04)
    XCTAssertTrue(scanner.savedTargetTextSupported([title, type, rules]))
    XCTAssertFalse(scanner.savedTargetTextSupported([]))
    XCTAssertFalse(scanner.savedTargetTextSupported([title]))
    XCTAssertFalse(scanner.savedTargetTextSupported([title, rules]))
    XCTAssertFalse(scanner.savedTargetTextSupported([title, type]))
    XCTAssertFalse(scanner.savedTargetTextSupported([line("Operating instructions", y: 0.035),
      line("Menu", y: 0.54), line("Place the equipment on the wooden desk.", y: 0.65)]))
    XCTAssertFalse(scanner.savedTargetTextSupported([title,
      line("Instant", y: 0.54, width: 0.14, height: 0.03, confidence: 0.5), rules]))
  }

  func testSupportedGuidanceRemovesContainedSameCardFragmentsWithoutDroppingNeighbors() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let title: [String: Any] = line("Observed Name", y: 0.035)
    let rules: [[String: Any]] = [line("Whenever you cast a creature spell", y: 0.65, height: 0.04),
      line("this turn, draw a card.", y: 0.70, height: 0.04)]
    let full: [[String: Double]] = [["x": 0.1, "y": 0.1], ["x": 0.5, "y": 0.1],
      ["x": 0.5, "y": 0.8], ["x": 0.1, "y": 0.8]]
    let inner: [[String: Double]] = [["x": 0.2, "y": 0.3], ["x": 0.4, "y": 0.3],
      ["x": 0.4, "y": 0.65], ["x": 0.2, "y": 0.65]]
    let neighbor: [[String: Double]] = [["x": 0.6, "y": 0.1], ["x": 0.9, "y": 0.1],
      ["x": 0.9, "y": 0.8], ["x": 0.6, "y": 0.8]]
    let guide: [String: Any] = ["sourceCorners": full, "geometrySource": "live_outline",
      "lines": [title, line("Sorcery", y: 0.54, width: 0.14, height: 0.03)] + rules]
    let fragment: [String: Any] = ["sourceCorners": inner, "lines": rules]
    let separateCopy: [String: Any] = ["sourceCorners": neighbor, "lines": [title] + rules]
    let unrelated: [String: Any] = ["sourceCorners": inner,
      "lines": [line("Another observed name", y: 0.035), line("Target creature gains flying.", y: 0.65)]]
    XCTAssertEqual(scanner.savedGuidedDuplicateIndices([fragment, guide, separateCopy, unrelated]), [0])
    var rejected: [String: Any] = guide
    rejected["lines"] = [title]
    XCTAssertEqual(scanner.savedGuidedDuplicateIndices([fragment, rejected]), [])
    var ordinary: [String: Any] = guide
    ordinary.removeValue(forKey: "geometrySource")
    XCTAssertEqual(scanner.savedGuidedDuplicateIndices([fragment, ordinary]), [])
  }

  private var observedJapaneseRules: [[String: Any]] {
    [line("他の黒のクリーチャーは＋1/+1の修正を", y: 0.64, x: 0.12, height: 0.035),
      line("黒でないクリーチャーは-1/-1の修正を受ける。", y: 0.72, x: 0.12, height: 0.035)]
  }

  func testJapaneseRulesAndTypeSupportOrientationWithoutSpaceDelimitedWords() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let rows: [[String: Any]] = [line("観測されたカード名", y: 0.035),
      line("クリーチャー レジェンド", y: 0.54, x: 0.12, height: 0.035)] + observedJapaneseRules
    XCTAssertTrue(scanner.japaneseCardLayout(rows))
    XCTAssertTrue(scanner.savedCardLayout(rows))
    XCTAssertTrue(scanner.savedUprightTextSupported(rows))
    XCTAssertTrue(scanner.liveUprightLayoutSupported(rows))
    for turns: Int in 1...3 {
      let rotated: [[String: Any]] = rows.map { row in
        var transformed: [String: Any] = row
        let bounds: [String: Double] = row["bounds"] as! [String: Double]
        var x: Double = bounds["x"]!, y: Double = bounds["y"]!
        var width: Double = bounds["width"]!, height: Double = bounds["height"]!
        for _: Int in 0..<turns {
          let previousX: Double = x
          let previousWidth: Double = width
          x = 1 - y - height
          y = previousX
          width = height
          height = previousWidth
        }
        transformed["bounds"] = ["x": x, "y": y, "width": width, "height": height]
        return transformed
      }
      XCTAssertFalse(scanner.japaneseCardLayout(rotated), "rotation \(turns)")
      XCTAssertFalse(scanner.liveUprightLayoutSupported(rotated), "rotation \(turns)")
    }
  }

  func testJapaneseOrientationRejectsWeakRepeatedUnrelatedAndMisplacedRules() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let type: [String: Any] = line("クリーチャー レジェンド", y: 0.54, x: 0.12, height: 0.035)
    XCTAssertFalse(scanner.japaneseCardLayout([type, observedJapaneseRules[0], observedJapaneseRules[0]]))
    XCTAssertFalse(scanner.japaneseCardLayout([line("クリーチャー レジェンド", y: 0.54,
      x: 0.12, height: 0.035, confidence: 0.84)] + observedJapaneseRules))
    XCTAssertFalse(scanner.japaneseCardLayout([type,
      line("机の上には本が置いてあります", y: 0.64), line("部屋は明るく照らされています", y: 0.72)]))
    XCTAssertFalse(scanner.japaneseCardLayout([line("クリーチャー レジェンド", y: 0.91)] + observedJapaneseRules))
  }

  func testSavedLowerBodyRetainsObservedJapaneseRulesWithoutPromotingConfidence() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let text: String = "黒でないクリーチャーは-1/-1の修正を受"
    var observed: [String: Any] = line(text, y: 0.71266, x: 0.1519,
      width: 0.68808, height: 0.03087, confidence: 0.5)
    observed["alternatives"] = ["黒でないクリーチャーは-1/-1の修正を受ける"]
    observed["alternativeConfidences"] = [0.3]
    let retained: [[String: Any]] = scanner.savedLowerBodyLines([observed,
      line("机の上には本が置いてあります", y: 0.72, confidence: 1),
      line(text, y: 0.90, height: 0.03, confidence: 0.5),
      line(text, y: 0.72, width: 0.03, height: 0.40, confidence: 0.5),
      line(text, y: 0.72, height: 0.03, confidence: 0.29),
      line("Prevent all damage from one source", y: 0.72, height: 0.03, confidence: 0.5)])
    XCTAssertEqual(retained.count, 1)
    XCTAssertTrue(NSDictionary(dictionary: retained[0]).isEqual(to: observed))
    XCTAssertFalse(scanner.japaneseCardLayout([line("クリーチャー レジェンド", y: 0.54),
      observedJapaneseRules[0]] + retained))
    XCTAssertEqual(scanner.savedLowerBodyLines([
      line("Prevent all damage from one source", y: 0.72, height: 0.03, confidence: 0.85)]).count, 1)
  }

  func testFooterRetryCannotReplaceObservedJapaneseRulesWithLatinNoiseOrIncidentalNumbers() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let observed: [String: Any] = line("黒でないクリーチャーは-1/-1の修正を受",
      y: 0.71266, x: 0.1519, width: 0.68808, height: 0.03087, confidence: 0.5)
    let footer: [String: Any] = line("51/143", y: 0.90, x: 0.16,
      width: 0.12, height: 0.025, confidence: 1)
    for text: String in ["krT-1/1 Ti", "1/1"] {
      let retry: [String: Any] = line(text, y: 0.71266, x: 0.1519,
        width: 0.68808, height: 0.03087, confidence: 1)
      let merged: [[String: Any]] = scanner.mergingFooterLines([retry, footer], into: [observed])
      XCTAssertEqual(merged.count, 2)
      XCTAssertTrue(NSDictionary(dictionary: merged[0]).isEqual(to: observed))
      XCTAssertTrue(NSDictionary(dictionary: merged[1]).isEqual(to: footer))
    }
  }

  func testAdjacentJapaneseTypeFragmentsJoinWithoutChangingObservedTextOrConfidence() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let first: [String: Any] = line("クリーチャ", y: 0.55088, x: 0.12046,
      width: 0.20677, height: 0.02892, confidence: 0.5)
    let second: [String: Any] = line("ーーレジェンド", y: 0.55092, x: 0.32103,
      width: 0.33907, height: 0.03204, confidence: 0.5)
    let joined: [[String: Any]] = scanner.joiningObservedTypeFragments([first, second])
    XCTAssertEqual(joined.count, 3)
    XCTAssertEqual(joined.last?["text"] as? String, "クリーチャーーレジェンド")
    XCTAssertEqual(joined.last?["confidence"] as? Double, 0.5)
    XCTAssertEqual(joined.last?["joinedFragments"] as? [String], ["クリーチャ", "ーーレジェンド"])
    XCTAssertEqual(joined.first?["text"] as? String, "クリーチャ")
    XCTAssertFalse(scanner.japaneseCardLayout(joined + observedJapaneseRules), "Joining must not promote weak OCR.")
    XCTAssertEqual(scanner.joiningObservedTypeFragments([first,
      line("ーーレジェンド", y: 0.65, x: 0.32103, width: 0.33907, height: 0.03204)]).count, 2)
    XCTAssertEqual(scanner.joiningObservedTypeFragments([first,
      line("ーーレジェンド", y: 0.55092, x: 0.60, width: 0.33907, height: 0.03204)]).count, 2)
  }

  func testSacrificeRulesSupportCardOrientationWithTheirObservedInflection() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let rows: [[String: Any]] = [line("Pick Your Poison", y: 0.035),
      line("Sorcery", y: 0.689, x: 0.196, width: 0.141, height: 0.0296),
      line("Each opponent sacrifices an artifact", y: 0.7586, x: 0.2199, width: 0.7186, height: 0.0754),
      line("of their choice.", y: 0.8204, x: 0.2496, width: 0.2929, height: 0.0425)]
    XCTAssertTrue(scanner.liveUprightLayoutSupported(rows))
  }

  func testForeshortenedCardSceneRowsKeepTheirObservedReadingAxis() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let corners: [CGPoint] = [CGPoint(x: 0.207157597, y: 1 - 0.408168197),
      CGPoint(x: 0.485251158, y: 1 - 0.413770556),
      CGPoint(x: 0.508152962, y: 1 - 0.605670422),
      CGPoint(x: 0.094778493, y: 1 - 0.607521176)]
    let projection: LocalCardScanner.SavedCardProjection = try XCTUnwrap(.init(corners: corners))
    let rows: [[String: Any]] = [line("観測されたカード名", y: 0.035),
      line("クリーチャー レジェンド", y: 0.54, x: 0.12, height: 0.035)] + observedJapaneseRules
    let mapped: [[String: Any]] = try rows.map { row in
      let bounds: [String: Double] = try XCTUnwrap(row["bounds"] as? [String: Double])
      let x: Double = try XCTUnwrap(bounds["x"]), y: Double = try XCTUnwrap(bounds["y"])
      let width: Double = try XCTUnwrap(bounds["width"]), height: Double = try XCTUnwrap(bounds["height"])
      let glyph: [CGPoint] = try XCTUnwrap(projection.unmap([
        CGPoint(x: x, y: y), CGPoint(x: x + width, y: y),
        CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)]))
      return try XCTUnwrap(scanner.mappedSavedSceneLine(row, quad: glyph, glyph: glyph,
        corners: corners, imageAspect: 1405.0 / 1297.0))
    }
    XCTAssertTrue(scanner.savedUprightTextSupported(mapped))
    XCTAssertTrue(scanner.japaneseCardLayout(mapped))
    XCTAssertEqual(try XCTUnwrap((mapped[0]["bounds"] as? [String: Double])?["y"]),
      0.035, accuracy: 0.000001)
  }

  func testMissingWeakMisplacedOrUpsideDownLayoutCannotSkipReverseOCR() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let title: [String: Any] = line("Circle of Protection: Blue", y: 0.035)
    var weakType: [String: Any] = observedType
    weakType["confidence"] = 0.84
    var misspelledType: [String: Any] = observedType
    misspelledType["text"] = "Enchanament"
    misspelledType["alternatives"] = ["Enchantment"]
    misspelledType["alternativeConfidences"] = [1.0]
    let cases: [[[String: Any]]] = [
      [title, observedType],
      [observedType] + actualRules,
      [line("Circle of Protection: Blue", y: 0.035, confidence: 0.84), observedType] + actualRules,
      [line("Circle of Protection: Blue", y: 0.91), observedType] + actualRules,
      [title, weakType] + actualRules,
      [title, misspelledType] + actualRules,
      [title, observedType, actualRules[0], actualRules[0]],
      [title, observedType] + actualRules.map { row in
        var weak: [String: Any] = row
        weak["confidence"] = 0.84
        return weak
      },
      [title, observedType, line("The wooden desk holds three books", y: 0.62),
        line("A bright lamp illuminates this room", y: 0.67)],
      [title, line("Enchantment", y: 0.91), line("Prevent all damage from one source", y: 0.30),
        line("Each time to prevent the damage", y: 0.35)]
    ]
    for (index, rows): (Int, [[String: Any]]) in cases.enumerated() {
      XCTAssertFalse(scanner.liveUprightLayoutSupported(rows), "negative \(index)")
    }
  }

  func testActualHorizontalRulesPermitLiteralTypeBandProofWithoutChangingGlyphGeometry() {
    let scanner: LocalCardScanner = LocalCardScanner()
    XCTAssertTrue(scanner.liveTypeBandBodySupported(actualRules))
    let verified: [[String: Any]] = scanner.verifiedLiveTypeBandLines([observedType], bodyLines: actualRules)
    XCTAssertEqual(verified.count, 1)
    XCTAssertEqual(verified.first?["text"] as? String, "Enchantment")
    XCTAssertEqual(verified.first?["bounds"] as? [String: Double], observedType["bounds"] as? [String: Double])
    XCTAssertEqual(verified.first?["glyphHeight"] as? Double, 0.027540675)
    XCTAssertEqual(verified.first?["orientationCorroboration"] as? Bool, true)
  }

  func testLiteralObservedAlternativeMayVerifyButMisspellingAloneCannot() {
    let scanner: LocalCardScanner = LocalCardScanner()
    var raw: [String: Any] = observedType
    raw["text"] = "Enchanament"
    raw["alternatives"] = ["Enchanument", "Enchanment"]
    XCTAssertTrue(scanner.verifiedLiveTypeBandLines([raw], bodyLines: actualRules).isEmpty)
    raw["alternatives"] = ["Enchantment"]
    raw["alternativeConfidences"] = [0.84]
    XCTAssertTrue(scanner.verifiedLiveTypeBandLines([raw], bodyLines: actualRules).isEmpty)
    raw["alternativeConfidences"] = [1.0]
    XCTAssertEqual(scanner.verifiedLiveTypeBandLines([raw], bodyLines: actualRules).first?["text"] as? String, "Enchantment")
  }

  func testDeskMathFlavorDuplicateRowsAndVerticalFragmentsCannotGrantTypeBandProbe() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let negatives: [[[String: Any]]] = [
      Array(actualRules.prefix(2)),
      [actualRules[0], actualRules[0], actualRules[0]],
      [line("1; Prevent all damage against you", y: 0.60),
        line("from one blue source. If a source", y: 0.60),
        line("deals damage to you more than", y: 0.60)],
      [line("1; Prevent all damage against you", y: 0.60, width: 0.05, height: 0.60),
        line("from one blue source. If a source", y: 0.64, width: 0.05, height: 0.60),
        line("deals damage to you more than", y: 0.68, width: 0.05, height: 0.60)],
      [line("The answer equals twenty four", y: 0.60),
        line("Multiply both sides by five", y: 0.64),
        line("Calculate the final square root", y: 0.68)],
      [line("The wooden desk holds three books", y: 0.60),
        line("A bright lamp illuminates this room", y: 0.64),
        line("The paper lies near the keyboard", y: 0.68)],
      [line("\"Prevent all damage against you", y: 0.60),
        line("\"Draw a creature from your graveyard", y: 0.64),
        line("\"Each opponent loses one life", y: 0.68)],
      actualRules.map { row in
        var changed: [String: Any] = row
        changed["confidence"] = 0.84
        return changed
      }
    ]
    for (index, rows) in negatives.enumerated() {
      XCTAssertFalse(scanner.liveTypeBandBodySupported(rows), "negative \(index)")
      XCTAssertTrue(scanner.verifiedLiveTypeBandLines([observedType], bodyLines: rows).isEmpty, "negative \(index)")
    }
  }

  func testMisplacedConflictingUnsupportedOrUnreliableTypesCannotVerify() {
    let scanner: LocalCardScanner = LocalCardScanner()
    var unreliable: [String: Any] = observedType
    unreliable["confidence"] = 0.84
    unreliable["alternatives"] = []
    let cases: [[[String: Any]]] = [
      [line("Enchantment", y: 0.10)],
      [line("Enchantment", y: 0.70)],
      [line("Enchantment", y: 0.49, x: 0.80)],
      [line("Enchantment", y: 0.49, height: 0.20)],
      [line("Equation", y: 0.49)],
      [line("Enchanament", y: 0.49)],
      [unreliable],
      [observedType, line("Creature", y: 0.49, x: 0.10)]
    ]
    for (index, types) in cases.enumerated() {
      XCTAssertTrue(scanner.verifiedLiveTypeBandLines(types, bodyLines: actualRules).isEmpty, "negative \(index)")
    }
  }

  func testSavedBorderExpansionPreservesPerspectiveAndRejectsOutOfImageProbes() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let corners: [CGPoint] = [CGPoint(x: 0.20, y: 0.80), CGPoint(x: 0.40, y: 0.78),
      CGPoint(x: 0.42, y: 0.30), CGPoint(x: 0.18, y: 0.32)]
    let expanded: [CGPoint]? = scanner.expandedSavedCardCorners(corners,
      top: 0.08, bottom: 0.12, horizontal: 0.04)
    XCTAssertNotNil(expanded)
    XCTAssertEqual(expanded![0].x, 0.1936, accuracy: 0.000001)
    XCTAssertEqual(expanded![0].y, 0.8392, accuracy: 0.000001)
    XCTAssertEqual(expanded![2].x, 0.432, accuracy: 0.000001)
    XCTAssertEqual(expanded![2].y, 0.2416, accuracy: 0.000001)
    XCTAssertNil(scanner.expandedSavedCardCorners(corners, top: 0.11, bottom: 0, horizontal: 0))
    XCTAssertNil(scanner.expandedSavedCardCorners([], top: 0.08, bottom: 0.12, horizontal: 0.04))
    let edge: [CGPoint] = [CGPoint(x: 0, y: 1), CGPoint(x: 0.2, y: 1),
      CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0, y: 0.5)]
    XCTAssertNil(scanner.expandedSavedCardCorners(edge, top: 0.08, bottom: 0.12, horizontal: 0.04))
  }

  func testSavedRecoveryNeedsClippedCardEvidenceRatherThanAnEnergyGlyphOrBlankPaper() {
    let scanner: LocalCardScanner = LocalCardScanner()
    XCTAssertFalse(scanner.savedBorderRecoveryNeeded([]))
    XCTAssertFalse(scanner.savedBorderRecoveryNeeded([line("4", y: 0.76, width: 0.04)]))
    let clipped: [[String: Any]] = [line("Artifact Renewal", y: 0.04),
      line("Sorcery", y: 0.58), line("Return target artifact from your graveyard", y: 0.68),
      line("Cycling 2 (2, Discard this card: Draw", y: 0.89)]
    XCTAssertTrue(scanner.savedBorderRecoveryNeeded(clipped))
    XCTAssertFalse(scanner.savedBorderRecoveryNeeded(clipped + [line("C 0509", y: 0.95, width: 0.12),
      line("SET EN", y: 0.97, width: 0.12, height: 0.02)]))
    XCTAssertTrue(scanner.savedBorderRecoveryNeeded([line("Target creature gains banding", y: 0.65)]))
  }

  func testLiteralLegacyEnchantTypeRequiresCoherentObservedRulesAndRejectsConflicts() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let rules: [[String: Any]] = [line("Target creature gains banding", y: 0.65)]
    let literal: [String: Any] = line("Enchant Creature", y: 0.55, x: 0.08)
    XCTAssertEqual(scanner.verifiedSavedTypeBandLines([literal], bodyLines: rules).first?["text"] as? String,
      "Enchant Creature")
    XCTAssertTrue(scanner.verifiedSavedTypeBandLines([line("Enchan Creature", y: 0.55)], bodyLines: rules).isEmpty)
    XCTAssertTrue(scanner.verifiedSavedTypeBandLines([literal], bodyLines: []).isEmpty)
    XCTAssertTrue(scanner.verifiedSavedTypeBandLines([line("Enchant Creature", y: 0.05)], bodyLines: rules).isEmpty)
    XCTAssertTrue(scanner.verifiedSavedTypeBandLines([literal, line("Sorcery", y: 0.55)], bodyLines: rules).isEmpty)
    XCTAssertTrue(scanner.verifiedSavedTypeBandLines([literal],
      bodyLines: [line("The wooden desk holds three books", y: 0.65)]).isEmpty)
  }

  func testSavedBodylessBasicLandRequiresNameLiteralTypeAndPhysicalFooter() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let land: [[String: Any]] = [line("Snow-Covered Field", y: 0.04),
      line("Basic Snow Land", y: 0.84), line("252/254", y: 0.95, width: 0.15)]
    XCTAssertTrue(scanner.savedCardLayout(land))
    XCTAssertFalse(scanner.savedCardLayout(Array(land.prefix(2))))
    XCTAssertFalse(scanner.savedCardLayout([land[0], land[1], line("4", y: 0.76, width: 0.04)]))
    XCTAssertFalse(scanner.savedCardLayout([land[0], line("Basic Snow Lard", y: 0.84), land[2]]))
    XCTAssertFalse(scanner.savedCardLayout([line("Snow-Covered Field", y: 0.30), land[1], land[2]]))
  }

  func testSavedBorderCannotEnterNeighborIncludingAnAlreadyOverlappingCard() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let card: [CGPoint] = [CGPoint(x: 0.20, y: 0.80), CGPoint(x: 0.40, y: 0.80),
      CGPoint(x: 0.40, y: 0.30), CGPoint(x: 0.20, y: 0.30)]
    let touching: [CGPoint] = [CGPoint(x: 0.40, y: 0.80), CGPoint(x: 0.60, y: 0.80),
      CGPoint(x: 0.60, y: 0.30), CGPoint(x: 0.40, y: 0.30)]
    XCTAssertNil(scanner.expandedSavedCardCorners(card, top: 0, bottom: 0.12,
      horizontal: 0.04, neighboringCorners: [touching]))
    let overlapping: [CGPoint] = touching.map { CGPoint(x: $0.x - 0.02, y: $0.y) }
    XCTAssertNil(scanner.expandedSavedCardCorners(card, top: 0, bottom: 0.12,
      horizontal: 0.04, neighboringCorners: [overlapping]))
    XCTAssertNotNil(scanner.expandedSavedCardCorners(card, top: 0, bottom: 0.12,
      horizontal: 0, neighboringCorners: [touching]))
    let above: [CGPoint] = [CGPoint(x: 0.20, y: 0.98), CGPoint(x: 0.40, y: 0.98),
      CGPoint(x: 0.40, y: 0.80), CGPoint(x: 0.20, y: 0.80)]
    XCTAssertNil(scanner.expandedSavedCardCorners(card, top: 0.08, bottom: 0,
      horizontal: 0, neighboringCorners: [above]))
  }

  func testPresenceMarginPaddingStaysInsideFrameAndAlreadyPaddedNeighbors() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let card: [CGPoint] = [CGPoint(x: 0.20, y: 0.80), CGPoint(x: 0.40, y: 0.80),
      CGPoint(x: 0.40, y: 0.30), CGPoint(x: 0.20, y: 0.30)]
    let expanded: [CGPoint] = try XCTUnwrap(scanner.expandedSavedCardCorners(card,
      top: 0.04, bottom: 0.04, horizontal: 0.02))
    XCTAssertEqual(expanded[0].x, 0.196, accuracy: 0.000001)
    XCTAssertEqual(expanded[0].y, 0.82, accuracy: 0.000001)
    XCTAssertEqual(expanded[2].x, 0.404, accuracy: 0.000001)
    XCTAssertEqual(expanded[2].y, 0.28, accuracy: 0.000001)
    let edge: [CGPoint] = card.map { CGPoint(x: $0.x - 0.20, y: $0.y) }
    XCTAssertNil(scanner.expandedSavedCardCorners(edge, top: 0.04, bottom: 0.04, horizontal: 0.02))
    let neighbor: [CGPoint] = card.map { CGPoint(x: $0.x + 0.206, y: $0.y) }
    XCTAssertNotNil(scanner.expandedSavedCardCorners(card, top: 0.04, bottom: 0.04,
      horizontal: 0.02, neighboringCorners: [neighbor]))
    XCTAssertNil(scanner.expandedSavedCardCorners(neighbor, top: 0.04, bottom: 0.04,
      horizontal: 0.02, neighboringCorners: [expanded]))
  }

  func testAcceptedRetryKeepsBorderProvenanceWithoutStaleReadFailures() {
    let scanner: LocalCardScanner = LocalCardScanner()
    XCTAssertEqual(scanner.mergingSavedRecoveryWarnings(["border_recovered", "incomplete_card", "no_text"],
      into: ["orientation_ensemble"]), ["orientation_ensemble", "border_recovered"])
    XCTAssertEqual(scanner.mergingSavedRecoveryWarnings(["border_recovered"], into: ["border_recovered"]),
      ["border_recovered"])
  }

  func testBrightBackgroundEvidenceRejectsUnreadDarkAndStructuredCardPixels() {
    let scanner: LocalCardScanner = LocalCardScanner()
    func pixels(_ value: UInt8) -> [UInt8] {
      (0..<(8 * 12)).flatMap { _ in [value, value, value, UInt8(255)] }
    }
    XCTAssertTrue(scanner.uniformBrightBackgroundPixels(pixels(235)))
    XCTAssertTrue(scanner.uniformBrightBackgroundPixels((0..<(8 * 12)).flatMap { _ in
      [UInt8(185), UInt8(205), UInt8(235), UInt8(255)]
    }))
    XCTAssertFalse(scanner.uniformBrightBackgroundPixels(pixels(40)))
    XCTAssertFalse(scanner.uniformBrightBackgroundPixels([]))
    var whiteBorderedCard: [UInt8] = pixels(240)
    for row: Int in 2..<9 {
      for column: Int in 1..<7 {
        let offset: Int = (row * 8 + column) * 4
        whiteBorderedCard[offset] = 60
        whiteBorderedCard[offset + 1] = 90
        whiteBorderedCard[offset + 2] = 50
      }
    }
    XCTAssertFalse(scanner.uniformBrightBackgroundPixels(whiteBorderedCard))
    var faintCardBorder: [UInt8] = pixels(240)
    for row: Int in 0..<12 {
      for column: Int in [0, 7] {
        let offset: Int = (row * 8 + column) * 4
        faintCardBorder[offset] = 120
        faintCardBorder[offset + 1] = 120
        faintCardBorder[offset + 2] = 120
      }
    }
    XCTAssertFalse(scanner.uniformBrightBackgroundPixels(faintCardBorder))
  }

  func testWeakClippedFooterCanRequestGeometryButCannotBecomePrintingEvidence() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let anchored: [[String: Any]] = [line("Artifact Renewal", y: 0.04), line("Sorcery", y: 0.58),
      line("Return target artifact from your graveyard", y: 0.68),
      line("Cycling 2 (2, Discard this card: Draw", y: 0.878, confidence: 0.50)]
    let weak: [String: Any] = line("C 0500", y: 0.978, x: 0.03, width: 0.11,
      height: 0.02, confidence: 0.30)
    XCTAssertFalse(scanner.savedBorderRecoveryNeeded(anchored))
    XCTAssertTrue(scanner.savedBorderRecoveryNeeded(anchored + [weak]))
    XCTAssertEqual(weak["confidence"] as? Double, 0.30)
    XCTAssertEqual(weak["text"] as? String, "C 0500")
    XCTAssertFalse(scanner.savedBorderRecoveryNeeded(anchored + [line("4", y: 0.978,
      width: 0.04, height: 0.02, confidence: 0.30)]))
    XCTAssertFalse(scanner.savedBorderRecoveryNeeded(anchored + [line("C 0500", y: 0.94,
      width: 0.11, height: 0.02, confidence: 0.30)]))
    XCTAssertFalse(scanner.savedBorderRecoveryNeeded(anchored + [line("C 0500", y: 0.978,
      width: 0.11, height: 0.02, confidence: 0.29)]))
  }

  func testBackgroundMetricsExposeTransparentEdgesWithoutClassifyingThemAsPaper() {
    let scanner: LocalCardScanner = LocalCardScanner()
    var pixels: [UInt8] = (0..<(8 * 12)).flatMap { _ in
      [UInt8(235), UInt8(235), UInt8(235), UInt8(255)]
    }
    let opaque: [String: Any] = scanner.backgroundPixelEvidence(pixels)
    XCTAssertEqual(opaque["background"] as? Bool, true)
    XCTAssertEqual(opaque["minimumAlpha"] as? Int, 255)
    XCTAssertEqual(opaque["minimumLuminance"] as? Double ?? 0, 235.0 / 255.0, accuracy: 0.000001)
    pixels[3] = 254
    let transparent: [String: Any] = scanner.backgroundPixelEvidence(pixels)
    XCTAssertEqual(transparent["background"] as? Bool, false)
    XCTAssertEqual(transparent["minimumAlpha"] as? Int, 254)
  }

  func testCompleteWeakFooterObservationRequiresBothPhysicalRowsAwayFromTheEdge() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let number: [String: Any] = line("C 0509", y: 0.91, x: 0.04, width: 0.14,
      height: 0.02, confidence: 0.30)
    let code: [String: Any] = line("SET EN", y: 0.95, x: 0.04, width: 0.14,
      height: 0.02, confidence: 0.30)
    XCTAssertTrue(scanner.completeSavedFooterObserved([number, code]))
    XCTAssertTrue(scanner.completeSavedFooterObserved([line("C 0509", y: 0.873, x: 0.04,
      width: 0.14, height: 0.02, confidence: 0.30), code]))
    XCTAssertFalse(scanner.completeSavedFooterObserved([line("C 0509", y: 0.83, x: 0.04,
      width: 0.14, height: 0.02, confidence: 0.30), code]))
    XCTAssertEqual(number["confidence"] as? Double, 0.30)
    XCTAssertFalse(scanner.completeSavedFooterObserved([number]))
    XCTAssertFalse(scanner.completeSavedFooterObserved([code]))
    XCTAssertFalse(scanner.completeSavedFooterObserved([line("C 0509", y: 0.978, x: 0.04,
      width: 0.14, height: 0.02, confidence: 0.30), code]))
    XCTAssertFalse(scanner.completeSavedFooterObserved([line("4", y: 0.91, x: 0.04,
      width: 0.04, height: 0.02, confidence: 0.30), code]))
  }

  func testSavedUprightRulesCanAvoidRotationWithoutInventingMissingType() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let title: [String: Any] = line("Observed Name", y: 0.04, confidence: 0.50)
    let rules: [String: Any] = line("Target creature gains banding", y: 0.65)
    XCTAssertTrue(scanner.savedUprightTextSupported([title, rules]))
    XCTAssertFalse(scanner.savedCardLayout([title, rules]))
    XCTAssertEqual(title["confidence"] as? Double, 0.50)
    XCTAssertTrue(scanner.savedUprightTextSupported([title] + actualRules))
    let negatives: [[[String: Any]]] = [
      [line("Observed Name", y: 0.85), rules],
      [title, line("Target creature gains banding", y: 0.15)],
      [title, line("Target creature gains banding", y: 0.65, width: 0.04, height: 0.40)],
      [title, line("Target creature gains banding", y: 0.65, confidence: 0.84)],
      [title, line("\"Target creature gains banding", y: 0.65)],
      [title, line("The creatures of legend await their fate", y: 0.65)],
      [title, line("Draw a line beside the creature", y: 0.65)],
      [title, line("The wooden desk holds three books", y: 0.65)],
      [title, line("Draw from the ancient well", y: 0.60), line("Draw from the ancient well", y: 0.65)]
    ]
    for (index, evidence) in negatives.enumerated() {
      XCTAssertFalse(scanner.savedUprightTextSupported(evidence), "negative \(index)")
    }
  }

  func testActualConflictingFooterReadsRemainSeparateWithoutOverwritingConfidence() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let original: [String: Any] = line("C 0123", y: 0.91, x: 0.04, width: 0.14,
      height: 0.02, confidence: 1)
    let alternate: [String: Any] = line("C 0128", y: 0.91, x: 0.04, width: 0.14,
      height: 0.02, confidence: 0.30)
    let merged: [[String: Any]] = scanner.mergingFooterLines([alternate], into: [original])
    XCTAssertEqual(merged.count, 2)
    XCTAssertEqual(merged[0]["text"] as? String, "C 0123")
    XCTAssertEqual(merged[0]["confidence"] as? Double, 1)
    XCTAssertEqual(merged[1]["text"] as? String, "C 0128")
    XCTAssertEqual(merged[1]["confidence"] as? Double, 0.30)
    XCTAssertEqual(scanner.mergingFooterLines([original], into: [original]).count, 1)
    XCTAssertEqual(scanner.mergingFooterLines([line("noise", y: 0.91, x: 0.04,
      width: 0.14, height: 0.02, confidence: 0.30)], into: [original]).count, 1)
  }

  func testAlternateFooterReadRequiresActualNumericFooterAndStopsForStrongLatinCode() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let number: [String: Any] = line("C 0123", y: 0.91, x: 0.04, width: 0.14,
      height: 0.02, confidence: 0.30)
    XCTAssertTrue(scanner.savedFooterNeedsAlternateRead([number]))
    XCTAssertFalse(scanner.savedFooterNeedsAlternateRead([]))
    XCTAssertFalse(scanner.savedFooterNeedsAlternateRead([line("4", y: 0.91, x: 0.04,
      width: 0.04, height: 0.02, confidence: 0.30)]))
    XCTAssertFalse(scanner.savedFooterNeedsAlternateRead([line("C 0123", y: 0.60, x: 0.04,
      width: 0.14, height: 0.02, confidence: 0.30)]))
    XCTAssertFalse(scanner.savedFooterNeedsAlternateRead([number, line("SET EN", y: 0.95,
      x: 0.04, width: 0.14, height: 0.02, confidence: 1)]))
  }

  func testIndependentNumericAndCopyrightRowsCanSupportGeometryWithoutASetCode() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let number: [String: Any] = line("0123", y: 0.876, x: 0.04, width: 0.14,
      height: 0.02, confidence: 0.30)
    let copyright: [String: Any] = line("© 2024 Rights reserved", y: 0.89,
      x: 0.60, width: 0.35, height: 0.02, confidence: 0.30)
    XCTAssertTrue(scanner.independentSavedFooterRowsObserved([number, copyright]))
    XCTAssertFalse(scanner.completeSavedFooterObserved([number, copyright]))
    XCTAssertFalse(scanner.independentSavedFooterRowsObserved([number]))
    XCTAssertFalse(scanner.independentSavedFooterRowsObserved([copyright]))
    XCTAssertFalse(scanner.independentSavedFooterRowsObserved([number,
      line("Discard this card: Draw a card", y: 0.89)]))
    XCTAssertFalse(scanner.independentSavedFooterRowsObserved([number,
      line("© 2024 Rights reserved", y: 0.10)]))
    XCTAssertFalse(scanner.independentSavedFooterRowsObserved([line("4", y: 0.876,
      x: 0.04, width: 0.04, height: 0.02, confidence: 0.30), copyright]))
  }

  func testNumericFooterProbeUsesObservedFieldAndRequiresIndependentCompleteContext() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let number: [String: Any] = line("C 0123", y: 0.88, x: 0.04, width: 0.14,
      height: 0.02, confidence: 0.30)
    let copyright: [String: Any] = line("© 2024 Rights reserved", y: 0.89,
      x: 0.60, width: 0.35, height: 0.02, confidence: 0.30)
    let region: CGRect? = scanner.savedNumericFooterRegion([number, copyright])
    XCTAssertNotNil(region)
    XCTAssertEqual(region!.minX, 0.028, accuracy: 0.000001)
    XCTAssertEqual(region!.minY, 0.092, accuracy: 0.000001)
    XCTAssertEqual(region!.width, 0.164, accuracy: 0.000001)
    XCTAssertEqual(region!.height, 0.036, accuracy: 0.000001)
    XCTAssertNil(scanner.savedNumericFooterRegion([number]))
    XCTAssertNil(scanner.savedNumericFooterRegion([line("4", y: 0.88, x: 0.04,
      width: 0.04, height: 0.02, confidence: 0.30), copyright]))
    XCTAssertNil(scanner.savedNumericFooterRegion([line("C 0123", y: 0.978, x: 0.04,
      width: 0.14, height: 0.02, confidence: 0.30), copyright]))
    XCTAssertNil(scanner.savedNumericFooterRegion([number,
      line("0124", y: 0.88, x: 0.45, width: 0.10, height: 0.02, confidence: 0.30), copyright]))
    XCTAssertEqual(number["text"] as? String, "C 0123")
    XCTAssertEqual(number["confidence"] as? Double, 0.30)
  }

  func testSavedJobsOverlapWithinTwoWorkersAndKeepInputOrder() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let lock: NSLock = NSLock()
    let barrier: DispatchSemaphore = DispatchSemaphore(value: 0)
    var active: Int = 0
    var peak: Int = 0
    var entered: Int = 0
    var workers: Set<Int> = []
    let results: [Result<Int, Error>] = scanner.boundedSavedJobs(count: 7, maximumWorkers: 99) { index, worker in
      lock.lock()
      active += 1
      peak = max(peak, active)
      entered += 1
      workers.insert(worker)
      if entered == 2 { for _ in 0..<2 { barrier.signal() } }
      lock.unlock()
      defer {
        lock.lock()
        active -= 1
        lock.unlock()
      }
      if index < 2 && barrier.wait(timeout: .now() + 3) != .success {
        throw NSError(domain: "saved-job-test", code: 1)
      }
      return index
    }
    XCTAssertEqual(try results.map { try $0.get() }, Array(0..<7))
    XCTAssertEqual(peak, 2)
    XCTAssertEqual(active, 0)
    XCTAssertEqual(workers, Set([0, 1]))
  }

  func testSavedWorkersAdmitNextJobWhenAnotherWorkerIsStillBusy() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let firstEntered: DispatchSemaphore = DispatchSemaphore(value: 0)
    let thirdEntered: DispatchSemaphore = DispatchSemaphore(value: 0)
    let lock: NSLock = NSLock()
    var workerByIndex: [Int: Int] = [:]
    let results: [Result<Int, Error>] = scanner.boundedSavedJobs(count: 3) { index, worker in
      lock.lock()
      workerByIndex[index] = worker
      lock.unlock()
      if index == 0 {
        firstEntered.signal()
        guard thirdEntered.wait(timeout: .now() + 3) == .success else {
          throw NSError(domain: "dynamic-saved-admission", code: 1)
        }
      } else if index == 1 {
        guard firstEntered.wait(timeout: .now() + 3) == .success else {
          throw NSError(domain: "dynamic-saved-admission", code: 2)
        }
      } else {
        thirdEntered.signal()
      }
      return index
    }
    XCTAssertEqual(try results.map { try $0.get() }, [0, 1, 2])
    XCTAssertEqual(workerByIndex[1], workerByIndex[2])
    XCTAssertNotEqual(workerByIndex[0], workerByIndex[2])
  }

  func testSavedOptionalReadsRequireMissingOrWeakLiteralEvidence() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let title: [String: Any] = line("Observed card title", y: 0.035, confidence: 0.90)
    let weakTitle: [String: Any] = line("Observed card title", y: 0.035, confidence: 0.50)
    let rules: [String: Any] = line("Target creature draws a card.", y: 0.65, confidence: 1)
    let type: [String: Any] = line("Enchantment", y: 0.50, confidence: 1)
    let copyright: [String: Any] = line("© 1997 Wizards of the Coast", y: 0.94,
      x: 0.12, height: 0.02, confidence: 0.50)
    let number: [String: Any] = line("0123/300", y: 0.93, x: 0.04,
      height: 0.02, confidence: 1)
    let weakNumber: [String: Any] = line("0123", y: 0.88, x: 0.04,
      height: 0.02, confidence: 0.50)
    XCTAssertFalse(scanner.savedNameplateNeedsRead([title, rules]))
    XCTAssertTrue(scanner.savedNameplateNeedsRead([weakTitle, rules]))
    XCTAssertTrue(scanner.savedNameplateNeedsRead([rules]))
    XCTAssertTrue(scanner.savedNameplateNeedsRead([weakTitle,
      line("Desk notes for tomorrow", y: 0.65)]))
    XCTAssertTrue(scanner.savedIdentityTextSupported([title, type, rules]))
    XCTAssertFalse(scanner.savedIdentityTextSupported([weakTitle, type, rules]))
    XCTAssertFalse(scanner.savedIdentityTextSupported([title, rules]))
    XCTAssertTrue(scanner.savedIdentityTextSupported([number]))
    XCTAssertFalse(scanner.savedIdentityTextSupported([weakNumber]))
    XCTAssertFalse(scanner.savedStrongCollectorObserved([line("4", y: 0.93,
      x: 0.04, height: 0.02)]))
    XCTAssertFalse(scanner.savedStrongCollectorObserved([line("0123", y: 0.978,
      x: 0.04, height: 0.02)]))
    XCTAssertFalse(scanner.savedStrongCollectorObserved([line("0123", y: 0.65,
      x: 0.04, height: 0.02)]))
    XCTAssertFalse(scanner.savedFooterNeedsLiteralRetry([title, rules, copyright]))
    XCTAssertFalse(scanner.savedFooterNeedsLiteralRetry([number]))
    XCTAssertTrue(scanner.savedFooterNeedsLiteralRetry([title, type, rules, weakNumber, copyright]))
    XCTAssertTrue(scanner.savedFooterNeedsLiteralRetry([copyright]))
    XCTAssertTrue(scanner.savedFooterNeedsLiteralRetry([]))
    XCTAssertEqual(weakNumber["text"] as? String, "0123")
    XCTAssertEqual(weakNumber["confidence"] as? Double, 0.50)
  }

  func testSavedNameplateRetriesRetainDifferingLiteralReadingsWithoutConfidenceChanges() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let first: [String: Any] = line("Light Keeper", y: 0.035, confidence: 0.50)
    let alternative: [String: Any] = line("Night Keeper", y: 0.035, confidence: 0.50)
    let merged: [[String: Any]] = scanner.mergingSavedNameplateLines([alternative], into: [first])
    XCTAssertEqual(merged.compactMap { $0["text"] as? String }, ["Light Keeper", "Night Keeper"])
    XCTAssertEqual(merged.compactMap { $0["confidence"] as? Double }, [0.50, 0.50])
    XCTAssertEqual(merged[0]["bounds"] as? [String: Double], first["bounds"] as? [String: Double])
    let duplicate: [[String: Any]] = scanner.mergingSavedNameplateLines([alternative], into: merged)
    XCTAssertEqual(duplicate.count, 2)
    let weaker: [String: Any] = line("Light Keeper", y: 0.035, confidence: 0.30)
    let confidenceVariants: [[String: Any]] = scanner.mergingSavedNameplateLines([weaker], into: [first])
    XCTAssertEqual(confidenceVariants.compactMap { $0["confidence"] as? Double }, [0.50, 0.30])
    let stronger: [String: Any] = line("Light Keeper", y: 0.035, confidence: 0.90)
    let improved: [[String: Any]] = scanner.mergingSavedNameplateLines([stronger], into: merged)
    XCTAssertEqual(improved.count, 3)
    XCTAssertEqual(improved.last?["text"] as? String, "Light Keeper")
    XCTAssertEqual(improved.compactMap { $0["confidence"] as? Double }, [0.50, 0.50, 0.90])
    XCTAssertEqual(improved.first?["text"] as? String, "Light Keeper")
    let separate: [String: Any] = line("Light Keeper", y: 0.075, x: 0.75, width: 0.15, confidence: 0.50)
    XCTAssertEqual(scanner.mergingSavedNameplateLines([separate], into: [first]).count, 2)
  }

  private func sceneCard(_ rect: CGRect) -> [CGPoint] {
    [CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
      CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.minY)]
  }

  private func sceneText(_ rect: CGRect, in card: CGRect) -> [CGPoint] {
    sceneCard(CGRect(x: card.minX + rect.minX * card.width,
      y: card.maxY - rect.maxY * card.height, width: rect.width * card.width, height: rect.height * card.height))
  }

  func testSavedProjectionInvertsPerspectiveWithoutAxisAlignedApproximation() throws {
    func forward(_ u: Double, _ v: Double) -> CGPoint {
      let denominator: Double = 1 + 0.10 * u + 0.20 * v
      return CGPoint(x: (0.12 + 0.58 * u + 0.03 * v) / denominator,
        y: (0.88 - 0.04 * u - 0.67 * v) / denominator)
    }
    let corners: [CGPoint] = [forward(0, 0), forward(1, 0), forward(1, 1), forward(0, 1)]
    let projection: LocalCardScanner.SavedCardProjection = try XCTUnwrap(
      LocalCardScanner.SavedCardProjection(corners: corners))
    for position: CGPoint in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1),
        CGPoint(x: 0.27, y: 0.43), CGPoint(x: 0.89, y: 0.92)] {
      let mapped: CGPoint = try XCTUnwrap(projection.map(forward(Double(position.x), Double(position.y))))
      XCTAssertEqual(mapped.x, position.x, accuracy: 0.00000001)
      XCTAssertEqual(mapped.y, position.y, accuracy: 0.00000001)
      let source: CGPoint = try XCTUnwrap(projection.unmap(mapped))
      XCTAssertEqual(source.x, forward(Double(position.x), Double(position.y)).x, accuracy: 0.00000001)
      XCTAssertEqual(source.y, forward(Double(position.x), Double(position.y)).y, accuracy: 0.00000001)
    }
    let rotated: LocalCardScanner.SavedCardProjection = try XCTUnwrap(
      LocalCardScanner.SavedCardProjection(corners: corners, rotateRight: true))
    let right: CGPoint = try XCTUnwrap(rotated.map(forward(0.20, 0.30)))
    XCTAssertEqual(right.x, 0.70, accuracy: 0.00000001)
    XCTAssertEqual(right.y, 0.20, accuracy: 0.00000001)
    let unrotated: CGPoint = try XCTUnwrap(rotated.unmap(right))
    XCTAssertEqual(unrotated.x, forward(0.20, 0.30).x, accuracy: 0.00000001)
    XCTAssertEqual(unrotated.y, forward(0.20, 0.30).y, accuracy: 0.00000001)
    XCTAssertNil(projection.map(CGPoint(x: CGFloat.infinity, y: 0)))
    XCTAssertNil(projection.unmap(CGPoint(x: CGFloat.nan, y: 0)))
    XCTAssertNil(LocalCardScanner.SavedCardProjection(corners: [CGPoint](repeating: .zero, count: 4)))
    XCTAssertNil(LocalCardScanner.SavedCardProjection(corners: [corners[0], corners[2], corners[1], corners[3]]))
    XCTAssertNil(LocalCardScanner.SavedCardProjection(corners: [corners[0], corners[1], corners[2],
      CGPoint(x: CGFloat.nan, y: 0)]))
  }

  func testAcceptedBorderRepairRetainsOnlyOwnedLiteralAmbiguousSceneFooterForReview() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let card: CGRect = CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.60)
    let corners: [CGPoint] = sceneCard(card)
    let expanded: [CGPoint] = try XCTUnwrap(scanner.expandedSavedCardCorners(corners,
      top: 0, bottom: 0.12, horizontal: 0.02))
    let source: [CGPoint] = sceneText(CGRect(x: 0.04, y: 0.975, width: 0.14, height: 0.02), in: card)
    var literal: [String: Any] = try XCTUnwrap(scanner.mappedSavedSceneLine(
      line("C 05G9", y: 0.975, x: 0.04, width: 0.14, height: 0.02),
      quad: source, glyph: source, corners: corners, imageAspect: 0.50))
    literal["alternatives"] = ["C 05G0"]
    literal["alternativeConfidences"] = [0.50]
    let body: [[String: Any]] = [line("Observed card title", y: 0.04), observedType] + actualRules
    let retained: [[String: Any]] = scanner.retainedSavedSceneFooterGuides(body + [literal],
      repairedLines: body, originalCorners: corners, repairedCorners: expanded,
      imageAspect: 0.50, acceptedRepair: true)
    XCTAssertEqual(retained.count, 1)
    let row: [String: Any] = try XCTUnwrap(retained.first)
    XCTAssertEqual(row["text"] as? String, "C 05G9")
    XCTAssertEqual(row["confidence"] as? Double, 1)
    XCTAssertEqual(row["alternatives"] as? [String], ["C 05G0"])
    XCTAssertEqual(row["alternativeConfidences"] as? [Double], [0.50])
    XCTAssertEqual(row["sceneFooterGuide"] as? Bool, true)
    XCTAssertEqual(row["sceneSourceGlyphCorners"] as? [[String: Double]], literal["sceneSourceGlyphCorners"] as? [[String: Double]])
    let projection: LocalCardScanner.SavedCardProjection = try XCTUnwrap(LocalCardScanner.SavedCardProjection(corners: expanded))
    let projected: [CGPoint] = try XCTUnwrap(projection.map(source))
    let bounds: [String: Double] = try XCTUnwrap(row["bounds"] as? [String: Double])
    XCTAssertEqual(bounds["y"]!, Double(projected.map({ $0.y }).min()!), accuracy: 0.00000001)
    XCTAssertLessThan(bounds["y"]!, 0.975)
    XCTAssertFalse(scanner.savedStrongCollectorObserved(retained))
    XCTAssertFalse(scanner.completeSavedFooterObserved(retained))
    XCTAssertTrue(scanner.retainedSavedSceneFooterGuides(body + [literal], repairedLines: body,
      originalCorners: corners, repairedCorners: expanded, imageAspect: 0.50, acceptedRepair: false).isEmpty)
    XCTAssertTrue(scanner.retainedSavedSceneFooterGuides(body + [literal], repairedLines: body,
      originalCorners: corners, repairedCorners: expanded,
      neighboringCorners: [sceneCard(CGRect(x: 0.11, y: 0.20, width: 0.10, height: 0.05))],
      imageAspect: 0.50, acceptedRepair: true).isEmpty)
  }

  func testSceneFooterReviewRetentionRejectsMissingProvenanceInvalidTokensAndContradictedCardBody() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let card: CGRect = CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.60)
    let corners: [CGPoint] = sceneCard(card)
    let expanded: [CGPoint] = try XCTUnwrap(scanner.expandedSavedCardCorners(corners,
      top: 0, bottom: 0.12, horizontal: 0.02))
    let source: [CGPoint] = sceneText(CGRect(x: 0.04, y: 0.975, width: 0.14, height: 0.02), in: card)
    let body: [[String: Any]] = [line("Observed card title", y: 0.04), observedType] + actualRules
    let scene: [String: Any] = try XCTUnwrap(scanner.mappedSavedSceneLine(
      line("C 05G9", y: 0.975, x: 0.04, width: 0.14, height: 0.02),
      quad: source, glyph: source, corners: corners, imageAspect: 0.50))
    for text: String in ["C 0509", "C 050A", "C A509", "C 05GG", "C 4", "MH3 EN"] {
      var malformed: [String: Any] = scene
      malformed["text"] = text
      XCTAssertTrue(scanner.retainedSavedSceneFooterGuides(body + [malformed], repairedLines: body,
        originalCorners: corners, repairedCorners: expanded, imageAspect: 0.50, acceptedRepair: true).isEmpty, text)
    }
    var missing: [String: Any] = scene
    missing.removeValue(forKey: "sceneSourceGlyphCorners")
    var invalid: [String: Any] = scene
    invalid["sceneSourceGlyphCorners"] = [["x": Double.nan, "y": 0.50]]
    var weak: [String: Any] = scene
    weak["confidence"] = 0.84
    var nonscene: [String: Any] = scene
    nonscene.removeValue(forKey: "ocrSource")
    for row: [String: Any] in [missing, invalid, weak, nonscene] {
      XCTAssertTrue(scanner.retainedSavedSceneFooterGuides(body + [row], repairedLines: body,
        originalCorners: corners, repairedCorners: expanded, imageAspect: 0.50, acceptedRepair: true).isEmpty)
    }
    let changedIdentity: [[String: Any]] = [line("Another observed card", y: 0.04), observedType] + actualRules
    XCTAssertTrue(scanner.retainedSavedSceneFooterGuides(body + [scene], repairedLines: changedIdentity,
      originalCorners: corners, repairedCorners: expanded, imageAspect: 0.50, acceptedRepair: true).isEmpty)
    let unrelatedBody: [[String: Any]] = [line("Observed card title", y: 0.04), observedType,
      line("Target creature draws a card.", y: 0.65)]
    XCTAssertTrue(scanner.retainedSavedSceneFooterGuides(body + [scene], repairedLines: unrelatedBody,
      originalCorners: corners, repairedCorners: expanded, imageAspect: 0.50, acceptedRepair: true).isEmpty)
    XCTAssertTrue(scanner.retainedSavedSceneFooterGuides(body + [scene], repairedLines: body + [
      line("0509", y: 0.88, x: 0.04, width: 0.14, height: 0.02)],
      originalCorners: corners, repairedCorners: expanded, imageAspect: 0.50, acceptedRepair: true).isEmpty)
  }

  func testAmbiguousFooterGeometryProjectsActualGlyphWithoutChangingItsTextOrConfidence() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let card: CGRect = CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.60)
    let corners: [CGPoint] = sceneCard(card)
    let expanded: [CGPoint] = try XCTUnwrap(scanner.expandedSavedCardCorners(corners,
      top: 0, bottom: 0.12, horizontal: 0.02))
    let footprint: CGRect = CGRect(x: 0.04, y: 0.975, width: 0.14, height: 0.02)
    let source: [CGPoint] = sceneText(footprint, in: card)
    let observed: [String: Any] = try XCTUnwrap(scanner.mappedSavedSceneLine(
      line("C05G9", y: 0.975, x: 0.04, width: 0.14, height: 0.02),
      quad: source, glyph: source, corners: corners, imageAspect: 0.50))
    let body: [[String: Any]] = [line("Observed card title", y: 0.04), observedType] + actualRules
    let lines: [[String: Any]] = body + [observed]
    let region: CGRect = try XCTUnwrap(scanner.savedAmbiguousFooterGeometryRegion(lines,
      originalCorners: corners, repairedCorners: expanded))
    let projection: LocalCardScanner.SavedCardProjection = try XCTUnwrap(
      LocalCardScanner.SavedCardProjection(corners: expanded))
    let mapped: [CGPoint] = try XCTUnwrap(projection.map(source))
    for point: CGPoint in mapped {
      XCTAssertTrue(region.contains(CGPoint(x: point.x, y: 1 - point.y)))
    }
    XCTAssertLessThanOrEqual(region.width, 0.35)
    XCTAssertLessThanOrEqual(region.height, 0.08)
    XCTAssertEqual(observed["text"] as? String, "C05G9")
    XCTAssertEqual(observed["confidence"] as? Double, 1)
    XCTAssertEqual((observed["sceneSourceGlyphCorners"] as? [[String: Double]])?.count, 4)
    XCTAssertFalse(scanner.savedStrongCollectorObserved([observed]))
    XCTAssertFalse(scanner.completeSavedFooterObserved([observed]))
    let context: CGRect = try XCTUnwrap(scanner.savedGuidedFooterRetryRegion(body, guide: region))
    XCTAssertTrue(context.contains(region))
    XCTAssertGreaterThan(context.width, region.width)
    XCTAssertGreaterThan(context.height, region.height)
    XCTAssertLessThanOrEqual(context.width, 0.35)
    XCTAssertLessThanOrEqual(context.height, 0.08)
    XCTAssertGreaterThanOrEqual(context.minX, 0)
    XCTAssertLessThanOrEqual(context.maxX, 0.65)
    XCTAssertGreaterThanOrEqual(context.minY, 0)
    XCTAssertLessThanOrEqual(context.maxY, 0.18)
    for guide: CGRect in [CGRect(x: 0, y: 0, width: 0.10, height: 0.02),
        CGRect(x: 0.50, y: 0.12, width: 0.14, height: 0.04)] {
      let edgeContext: CGRect = try XCTUnwrap(scanner.savedGuidedFooterRetryRegion(body, guide: guide))
      XCTAssertTrue(edgeContext.contains(guide))
      XCTAssertGreaterThanOrEqual(edgeContext.minX, 0)
      XCTAssertLessThanOrEqual(edgeContext.maxX, 0.65)
      XCTAssertGreaterThanOrEqual(edgeContext.minY, 0)
      XCTAssertLessThanOrEqual(edgeContext.maxY, 0.18)
    }
    XCTAssertNil(scanner.savedGuidedFooterRetryRegion(body + [line("C 0509", y: 0.88,
      x: 0.04, width: 0.14, height: 0.02)], guide: region))
    XCTAssertNil(scanner.savedGuidedFooterRetryRegion([observed], guide: region))
    XCTAssertNil(scanner.savedGuidedFooterRetryRegion(body, guide: nil))
    XCTAssertNil(scanner.savedGuidedFooterRetryRegion(body,
      guide: CGRect(x: 0.10, y: 0.40, width: 0.14, height: 0.02)))
  }

  func testAmbiguousFooterGuideRejectsBodyGlyphsMalformedOrDisjointFootersAndInvalidSourceGeometry() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let corners: [CGPoint] = sceneCard(CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.60))
    let expanded: [CGPoint] = try XCTUnwrap(scanner.expandedSavedCardCorners(corners,
      top: 0, bottom: 0.12, horizontal: 0.02))
    let body: [[String: Any]] = [line("Observed card title", y: 0.04), observedType] + actualRules
    for text: String in ["C0509", "C05GG", "4 4", "C 4", "0500", "MH3 EN", "Card059"] {
      XCTAssertNil(scanner.savedAmbiguousFooterGeometryRegion(body + [line(text,
        y: 0.975, x: 0.04, width: 0.14, height: 0.02)],
        originalCorners: corners, repairedCorners: expanded), text)
    }
    for invalid: [String: Any] in [
      line("C05G9", y: 0.76, x: 0.04, width: 0.14, height: 0.02),
      line("C05G9", y: 0.975, x: 0.70, width: 0.14, height: 0.02),
      line("C05G9", y: 0.975, x: 0.04, width: 0.14, height: 0.08),
      line("C05G9", y: 0.975, x: 0.04, width: 0.14, height: 0.02, confidence: 0.29),
      line("C05G9", y: 0.975, x: 0.04, width: 0.14, height: 0.02, confidence: Double.nan),
    ] {
      XCTAssertNil(scanner.savedAmbiguousFooterGeometryRegion(body + [invalid],
        originalCorners: corners, repairedCorners: expanded))
    }
    var malformed: [String: Any] = line("C05G9", y: 0.975, x: 0.04, width: 0.14, height: 0.02)
    malformed["sceneSourceGlyphCorners"] = [["x": Double.nan, "y": 0.50]]
    XCTAssertNil(scanner.savedAmbiguousFooterGeometryRegion(body + [malformed],
      originalCorners: corners, repairedCorners: expanded))
    let first: [String: Any] = line("C05G9", y: 0.975, x: 0.04, width: 0.14, height: 0.02)
    let other: [String: Any] = line("C07H0", y: 0.975, x: 0.42, width: 0.14, height: 0.02)
    XCTAssertNil(scanner.savedAmbiguousFooterGeometryRegion(body + [first, other],
      originalCorners: corners, repairedCorners: expanded))
    XCTAssertNil(scanner.savedAmbiguousFooterGeometryRegion(body + [first],
      originalCorners: corners, repairedCorners: [CGPoint](repeating: .zero, count: 4)))
    XCTAssertNil(scanner.savedAmbiguousFooterGeometryRegion([first],
      originalCorners: corners, repairedCorners: expanded))
  }

  func testSavedSceneOwnershipRejectsRowsSpanningOrOverlappingNeighbors() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let first: CGRect = CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.60)
    let second: CGRect = CGRect(x: 0.40, y: 0.20, width: 0.30, height: 0.60)
    let cards: [[CGPoint]] = [sceneCard(first), sceneCard(second)]
    let number: [CGPoint] = sceneText(CGRect(x: 0.06, y: 0.91, width: 0.18, height: 0.025), in: first)
    XCTAssertEqual(scanner.savedSceneQuadOwner(number, cards: cards), 0)
    XCTAssertEqual(scanner.savedSceneQuadOwner(sceneText(CGRect(x: 0.06, y: 0.91,
      width: 0.18, height: 0.025), in: second), cards: cards), 1)
    XCTAssertNil(scanner.savedSceneQuadOwner(sceneCard(CGRect(x: 0.35, y: 0.23,
      width: 0.10, height: 0.02)), cards: cards))
    let overlapping: [[CGPoint]] = [sceneCard(first), sceneCard(CGRect(x: 0.35,
      y: 0.20, width: 0.30, height: 0.60))]
    XCTAssertNil(scanner.savedSceneQuadOwner(sceneCard(CGRect(x: 0.36, y: 0.23,
      width: 0.02, height: 0.02)), cards: overlapping))
    XCTAssertNil(scanner.savedSceneQuadOwner(sceneCard(CGRect(x: 0.32, y: 0.23,
      width: 0.06, height: 0.02)), cards: overlapping))
    XCTAssertNil(scanner.savedSceneQuadOwner([CGPoint](repeating: .zero, count: 4), cards: cards))
    XCTAssertNil(scanner.savedSceneQuadOwner([CGPoint(x: CGFloat.nan, y: 0), number[1], number[2], number[3]], cards: cards))
  }

  func testSavedSceneMappingPreservesActualFooterTextConfidenceAndGlyphGeometry() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let card: CGRect = CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.60)
    let footprint: CGRect = CGRect(x: 0.06, y: 0.91, width: 0.18, height: 0.025)
    let quad: [CGPoint] = sceneText(footprint, in: card)
    var observed: [String: Any] = line("C 0123", y: 0.50, confidence: 0.30)
    observed["alternatives"] = ["C 0128"]
    observed["alternativeConfidences"] = [0.20]
    let mapped: [String: Any] = try XCTUnwrap(scanner.mappedSavedSceneLine(observed,
      quad: quad, glyph: quad, corners: sceneCard(card), imageAspect: 0.50))
    XCTAssertEqual(mapped["text"] as? String, "C 0123")
    XCTAssertEqual(mapped["confidence"] as? Double, 0.30)
    XCTAssertEqual(mapped["alternatives"] as? [String], ["C 0128"])
    XCTAssertEqual(mapped["alternativeConfidences"] as? [Double], [0.20])
    let bounds: [String: Double] = try XCTUnwrap(mapped["bounds"] as? [String: Double])
    XCTAssertEqual(bounds["x"]!, Double(footprint.minX), accuracy: 0.00000001)
    XCTAssertEqual(bounds["y"]!, Double(footprint.minY), accuracy: 0.00000001)
    XCTAssertEqual(bounds["height"]!, Double(footprint.height), accuracy: 0.00000001)
    XCTAssertEqual(try XCTUnwrap(mapped["glyphHeight"] as? Double), Double(footprint.height), accuracy: 0.00000001)
    XCTAssertEqual(mapped["ocrSource"] as? String, "scene")
    XCTAssertNil(scanner.mappedSavedSceneLine(observed, quad: sceneText(CGRect(x: 0.06,
      y: 0.985, width: 0.18, height: 0.025), in: card), glyph: quad,
      corners: sceneCard(card), imageAspect: 0.50))
  }

  func testSavedSceneMappingRejectsRotatedGlyphsAndNonfiniteConfidence() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let card: CGRect = CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.60)
    let quad: [CGPoint] = sceneText(CGRect(x: 0.10, y: 0.04, width: 0.70, height: 0.04), in: card)
    let title: [String: Any] = line("Observed card", y: 0.04)
    XCTAssertNil(scanner.mappedSavedSceneLine(title, quad: quad,
      glyph: [quad[2], quad[3], quad[0], quad[1]], corners: sceneCard(card), imageAspect: 0.50))
    XCTAssertNil(scanner.mappedSavedSceneLine(title, quad: quad,
      glyph: [quad[3], quad[0], quad[1], quad[2]], corners: sceneCard(card), imageAspect: 0.50))
    XCTAssertNil(scanner.mappedSavedSceneLine(title, quad: quad, glyph: quad,
      corners: sceneCard(card), rotateRight: true, imageAspect: 0.50))
    XCTAssertNil(scanner.mappedSavedSceneLine(line("Observed card", y: 0.04, confidence: Double.nan),
      quad: quad, glyph: quad, corners: sceneCard(card), imageAspect: 0.50))
  }

  func testSavedSceneRoutesWeakMissingAndRotatedLayoutsToIndependentRecovery() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let title: [String: Any] = line("Observed card title", y: 0.035, confidence: 0.90)
    let type: [String: Any] = line("Enchantment", y: 0.50)
    let body: [String: Any] = line("Target creature draws a card.", y: 0.65)
    XCTAssertEqual(scanner.savedSceneSeed([title, type, body]), .supported)
    XCTAssertEqual(scanner.savedSceneSeed([line("Observed card title", y: 0.035,
      confidence: 0.50), type, body]), .nameplate)
    XCTAssertEqual(scanner.savedSceneSeed([type, body]), .borderProbe)
    XCTAssertEqual(scanner.savedSceneSeed([title, type,
      line("Target creature draws a card.", y: 0.65, confidence: 0.50)]), .unsupported)
    XCTAssertEqual(scanner.savedSceneSeed([title]), .unsupported)
    XCTAssertEqual(scanner.savedSceneSeed([line("Observed card title", y: 0.90),
      line("Target creature draws a card.", y: 0.25)]), .unsupported)
    XCTAssertEqual(scanner.savedSceneSeed([title,
      line("Desk notes for another day", y: 0.65)]), .unsupported)
    XCTAssertEqual(scanner.savedSceneSeed([title,
      line("Basic Snow Land", y: 0.79, height: 0.04),
      line("0123/300", y: 0.93, x: 0.04, height: 0.02)]), .supported)
    XCTAssertEqual(scanner.savedSceneSeed([title,
      line("Basic Snow Land", y: 0.79, height: 0.04)]), .footer)
  }

  func testSavedSceneWeakVisibleTitleFallsBackWithoutClaimingTheBorderIsMissing() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let weakTitle: [String: Any] = line("Observed weak title", y: 0.035, confidence: 0.30)
    let body: [String: Any] = line("Target creature draws a card.", y: 0.65)
    XCTAssertTrue(scanner.savedSceneHasTitleGlyph([weakTitle]))
    XCTAssertEqual(scanner.savedSceneSeed([weakTitle, body]), .unsupported)
    XCTAssertEqual(scanner.savedSceneSeed([body]), .borderProbe)
    XCTAssertFalse(scanner.savedSceneHasTitleGlyph([line("Observed weak title", y: 0.35, confidence: 0.30)]))
    XCTAssertFalse(scanner.savedSceneHasTitleGlyph([line("1", y: 0.035, confidence: 1)]))
    XCTAssertFalse(scanner.savedSceneHasTitleGlyph([line("© 2024 Wizards", y: 0.035, confidence: 1)]))
    XCTAssertEqual(weakTitle["text"] as? String, "Observed weak title")
    XCTAssertEqual(weakTitle["confidence"] as? Double, 0.30)
  }

  func testSavedSceneBodylessLandRequiresIndependentStrongLiteralFooterVerification() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let title: [String: Any] = line("Observed land title", y: 0.035, confidence: 1)
    let type: [String: Any] = line("Basic Snow Land", y: 0.79, height: 0.04, confidence: 1)
    let sceneNumber: [String: Any] = line("0123/300", y: 0.93, x: 0.04, height: 0.02, confidence: 0.30)
    let scene: [[String: Any]] = [title, type, sceneNumber]
    let literal: [String: Any] = line("0128/300", y: 0.93, x: 0.04, height: 0.02, confidence: 1)
    XCTAssertEqual(scanner.savedSceneSeed(scene), .footer)
    XCTAssertTrue(scanner.savedSceneFooterVerified(scene, by: [literal]))
    XCTAssertFalse(scanner.savedSceneFooterVerified(scene, by: []))
    XCTAssertFalse(scanner.savedSceneFooterVerified(scene, by: [sceneNumber]))
    XCTAssertFalse(scanner.savedSceneFooterVerified(scene, by: [line("SET EN", y: 0.95,
      x: 0.04, height: 0.02, confidence: 1)]))
    XCTAssertFalse(scanner.savedSceneFooterVerified(scene, by: [line("0128/300", y: 0.978,
      x: 0.04, height: 0.02, confidence: 1)]))
    XCTAssertFalse(scanner.savedSceneFooterVerified([title, line("Basic Snow Land", y: 0.79,
      height: 0.04, confidence: 0.50)], by: [literal]))
    XCTAssertFalse(scanner.savedSceneFooterVerified([line("Observed land title", y: 0.035,
      confidence: 0.50), type], by: [literal]))
    XCTAssertEqual(sceneNumber["text"] as? String, "0123/300")
    XCTAssertEqual(sceneNumber["confidence"] as? Double, 0.30)
    XCTAssertEqual(literal["text"] as? String, "0128/300")
    XCTAssertEqual(literal["confidence"] as? Double, 1)
  }

  func testSavedSceneKeepsDistantFifthCardSeparateAndVisibleToOutsideRecovery() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let cards: [CGRect] = [CGRect(x: 0.05, y: 0.45, width: 0.15, height: 0.40),
      CGRect(x: 0.23, y: 0.45, width: 0.15, height: 0.40),
      CGRect(x: 0.41, y: 0.45, width: 0.15, height: 0.40),
      CGRect(x: 0.59, y: 0.45, width: 0.15, height: 0.40)]
    let distant: CGRect = CGRect(x: 0.80, y: 0.08, width: 0.07, height: 0.14)
    let row: [CGPoint] = sceneText(CGRect(x: 0.08, y: 0.55, width: 0.80, height: 0.035), in: distant)
    XCTAssertNil(scanner.savedSceneQuadOwner(row, cards: cards.map(sceneCard)))
    XCTAssertEqual(scanner.savedSceneQuadOwner(row, cards: (cards + [distant]).map(sceneCard)), 4)
    let actualGlobalRow: [String: Any] = line("Target creature draws a card.",
      y: Double(1 - row[0].y), x: Double(row[0].x), width: Double(row[1].x - row[0].x),
      height: Double(row[0].y - row[3].y), confidence: 0.90)
    XCTAssertTrue(scanner.outsideSavedCardTextNeedsRecovery([actualGlobalRow], covered: cards))
    XCTAssertFalse(scanner.outsideSavedCardTextNeedsRecovery([actualGlobalRow], covered: cards + [distant]))
  }

  func testSavedSceneTileAffineMappingKeepsOriginalFooterOwnership() throws {
    let scanner: LocalCardScanner = LocalCardScanner()
    let region: CGRect = CGRect(x: 0.40, y: 0.20, width: 0.40, height: 0.60)
    let center: CGPoint = try XCTUnwrap(scanner.savedScenePoint(CGPoint(x: 0.25, y: 0.75), in: region))
    XCTAssertEqual(center.x, 0.50, accuracy: 0.00000001)
    XCTAssertEqual(center.y, 0.65, accuracy: 0.00000001)
    let card: CGRect = CGRect(x: 0.45, y: 0.25, width: 0.25, height: 0.50)
    let actual: [CGPoint] = sceneText(CGRect(x: 0.10, y: 0.92, width: 0.20, height: 0.02), in: card)
    let tile: [CGPoint] = actual.map {
      CGPoint(x: ($0.x - region.minX) / region.width, y: ($0.y - region.minY) / region.height)
    }
    let restored: [CGPoint] = try tile.map { try XCTUnwrap(scanner.savedScenePoint($0, in: region)) }
    for index: Int in 0..<4 {
      XCTAssertEqual(restored[index].x, actual[index].x, accuracy: 0.00000001)
      XCTAssertEqual(restored[index].y, actual[index].y, accuracy: 0.00000001)
    }
    XCTAssertEqual(scanner.savedSceneQuadOwner(restored, cards: [sceneCard(card)]), 0)
    let mapped: [String: Any] = try XCTUnwrap(scanner.mappedSavedSceneLine(
      line("C 0123", y: 0, confidence: 0.30), quad: restored, glyph: restored,
      corners: sceneCard(card), imageAspect: 0.50))
    let bounds: [String: Double] = try XCTUnwrap(mapped["bounds"] as? [String: Double])
    XCTAssertEqual(bounds["y"]!, 0.92, accuracy: 0.00000001)
    XCTAssertEqual(mapped["text"] as? String, "C 0123")
    XCTAssertEqual(mapped["confidence"] as? Double, 0.30)
    XCTAssertNil(scanner.savedScenePoint(CGPoint(x: -0.01, y: 0), in: region))
    XCTAssertNil(scanner.savedScenePoint(CGPoint(x: CGFloat.nan, y: 0), in: region))
    XCTAssertNil(scanner.savedScenePoint(.zero, in: CGRect(x: 0.90, y: 0, width: 0.20, height: 1)))
    XCTAssertNil(scanner.savedScenePoint(.zero, in: CGRect(x: 0, y: 0, width: 0, height: 1)))
  }

  func testSavedSceneTilesIncreaseCardCoverageWithoutDeletingTinyDistantGeometry() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let close: [CGRect] = [CGRect(x: 0.05, y: 0.35, width: 0.15, height: 0.40),
      CGRect(x: 0.23, y: 0.35, width: 0.15, height: 0.40),
      CGRect(x: 0.41, y: 0.35, width: 0.15, height: 0.40),
      CGRect(x: 0.59, y: 0.35, width: 0.15, height: 0.40)]
    let distant: CGRect = CGRect(x: 0.90, y: 0.04, width: 0.04, height: 0.08)
    let geometry: [[CGPoint]] = (close + [distant]).map(sceneCard)
    let regions: [CGRect] = scanner.savedSceneRegions(geometry, imageSize: CGSize(width: 5712, height: 3213))
    XCTAssertEqual(regions.count, 2)
    XCTAssertTrue(regions.allSatisfy { $0.width < 0.40 })
    for card: CGRect in close {
      XCTAssertTrue(regions.contains { $0.contains(card) })
    }
    XCTAssertFalse(regions.contains { $0.contains(CGPoint(x: distant.midX, y: distant.midY)) })
    let number: [CGPoint] = sceneText(CGRect(x: 0.10, y: 0.91, width: 0.25, height: 0.025), in: distant)
    XCTAssertEqual(scanner.savedSceneQuadOwner(number, cards: geometry), 4)
    XCTAssertEqual(geometry.count, 5)
    XCTAssertTrue(scanner.savedSceneRegions([], imageSize: CGSize(width: 5712, height: 3213)).isEmpty)
    XCTAssertTrue(scanner.savedSceneRegions(geometry, imageSize: .zero).isEmpty)
  }

  func testSavedSceneTilePaddingStaysWithinOriginalImage() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let card: CGRect = CGRect(x: 0, y: 0, width: 0.20, height: 0.40)
    let regions: [CGRect] = scanner.savedSceneRegions([sceneCard(card)], imageSize: CGSize(width: 1000, height: 800))
    XCTAssertEqual(regions.count, 1)
    XCTAssertEqual(regions[0].minX, 0)
    XCTAssertEqual(regions[0].minY, 0)
    XCTAssertTrue(regions[0].contains(card))
    XCTAssertLessThanOrEqual(regions[0].maxX, 1)
    XCTAssertLessThanOrEqual(regions[0].maxY, 1)
    XCTAssertNotNil(scanner.savedScenePoint(CGPoint(x: 1, y: 1), in: regions[0]))
  }

  func testMissingBasicLandRectangleProbeRequiresActualAlignedNameTypeAndFooter() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let title: [String: Any] = line("Observed land name", y: 0.20, x: 0.10, width: 0.14,
      height: 0.02, confidence: 1)
    let type: [String: Any] = line("Basic Snow Land", y: 0.54, x: 0.10, width: 0.10,
      height: 0.016, confidence: 1)
    let footer: [String: Any] = line("0123/300", y: 0.60, x: 0.10, width: 0.05,
      height: 0.012, confidence: 0.30)
    let size: CGSize = CGSize(width: 1800, height: 1200)
    let regions: [CGRect] = scanner.savedBasicLandGuideRegions([title, type, footer], imageSize: size, covered: [])
    XCTAssertEqual(regions.count, 1)
    XCTAssertTrue(regions[0].contains(CGPoint(x: 0.15, y: 0.79)))
    XCTAssertTrue(regions[0].contains(CGPoint(x: 0.15, y: 0.452)))
    XCTAssertTrue(regions[0].contains(CGPoint(x: 0.125, y: 0.394)))
    XCTAssertTrue(scanner.savedBasicLandGuideRegions([title, type], imageSize: size, covered: []).isEmpty)
    XCTAssertTrue(scanner.savedBasicLandGuideRegions([title, footer], imageSize: size, covered: []).isEmpty)
    XCTAssertTrue(scanner.savedBasicLandGuideRegions([title, type, footer], imageSize: .zero, covered: []).isEmpty)
    let covered: [CGRect] = [CGRect(x: 0.05, y: 0.35, width: 0.30, height: 0.50)]
    XCTAssertTrue(scanner.savedBasicLandGuideRegions([title, type, footer], imageSize: size, covered: covered).isEmpty)
    XCTAssertTrue(scanner.savedBasicLandGuideRegions([line("Observed land name", y: 0.20,
      x: 0.10, width: 0.14, height: 0.02, confidence: 0.50), type, footer], imageSize: size, covered: []).isEmpty)
    XCTAssertTrue(scanner.savedBasicLandGuideRegions([title, line("Basic Snow Land", y: 0.54,
      x: 0.10, width: 0.10, height: 0.016, confidence: 0.50), footer], imageSize: size, covered: []).isEmpty)
    XCTAssertTrue(scanner.savedBasicLandGuideRegions([title, type, line("0123/300", y: 0.60,
      x: 0.90, width: 0.05, height: 0.012)], imageSize: size, covered: []).isEmpty)
    XCTAssertTrue(scanner.savedBasicLandGuideRegions([title, type, line("0123/300", y: 0.40,
      x: 0.10, width: 0.05, height: 0.012)], imageSize: size, covered: []).isEmpty)
    XCTAssertEqual(footer["confidence"] as? Double, 0.30)
    XCTAssertEqual(footer["text"] as? String, "0123/300")
  }

  func testRecoveredBasicLandNeedsIndependentStrongCompleteCropEvidence() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let title: [String: Any] = line("Observed land name", y: 0.035, confidence: 1)
    let type: [String: Any] = line("Basic Snow Land", y: 0.79, height: 0.04, confidence: 1)
    let number: [String: Any] = line("0123/300", y: 0.93, x: 0.04, height: 0.02, confidence: 1)
    XCTAssertTrue(scanner.savedRecoveredBasicLandSupported([title, type, number]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([title, type]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([title, number]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([type, number]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([title, type,
      line("0123/300", y: 0.93, x: 0.04, height: 0.02, confidence: 0.50)]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([title,
      line("Basic Snow Land", y: 0.79, height: 0.04, confidence: 0.50), number]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([title, type,
      line("4", y: 0.93, x: 0.04, height: 0.02, confidence: 1)]))
    XCTAssertTrue(scanner.savedRecoveredBasicLandSupported([title, type,
      line("SET EN", y: 0.95, x: 0.04, height: 0.02, confidence: 1)]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([title,
      line("Enchantment", y: 0.50), number]))
  }

  func testBasicLandFooterExpansionRequiresObservedFooterOutsideClippedTypeBar() {
    let scanner = LocalCardScanner()
    let corners: [CGPoint] = [CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.6, y: 0.8),
      CGPoint(x: 0.6, y: 0.3), CGPoint(x: 0.2, y: 0.3)]
    let title = line("Observed land name", y: 0.035, confidence: 1)
    let clipped = line("Basic Snow Land", y: 0.91, height: 0.04, confidence: 1)
    let footer = line("32//254", y: 0.725, x: 0.23, width: 0.06, height: 0.015, confidence: 0.30)
    let recovered = scanner.savedBasicLandFooterExpansion([title, clipped], scene: [footer],
      corners: corners, occupied: [])
    XCTAssertNotNil(recovered)
    XCTAssertLessThan(recovered![2].y, 0.26)
    XCTAssertEqual(recovered![0], corners[0])
    XCTAssertNil(scanner.savedBasicLandFooterExpansion([title, clipped], scene: [], corners: corners, occupied: []))
    XCTAssertNil(scanner.savedBasicLandFooterExpansion([clipped], scene: [footer], corners: corners, occupied: []))
    XCTAssertNil(scanner.savedBasicLandFooterExpansion([title, line("Basic Snow Land", y: 0.79)],
      scene: [footer], corners: corners, occupied: []))
    XCTAssertNil(scanner.savedBasicLandFooterExpansion([title, clipped],
      scene: [line("32//254", y: 0.725, x: 0.75, width: 0.06, height: 0.015, confidence: 1)],
      corners: corners, occupied: []))
    XCTAssertNil(scanner.savedBasicLandFooterExpansion([title, clipped], scene: [footer], corners: corners,
      occupied: [CGRect(x: 0.2, y: 0.24, width: 0.4, height: 0.04)]))
  }

  func testBasicLandIdentityDoesNotRequireAConfidentPrintingNumber() {
    let scanner = LocalCardScanner()
    let title = line("Observed land name", y: 0.04, confidence: 1)
    let type = line("Basic Snow Land", y: 0.83, height: 0.03, confidence: 1)
    let weakFooter = line("282//204 4", y: 0.96, x: 0.04, height: 0.025, confidence: 0.30)
    XCTAssertTrue(scanner.savedBasicLandIdentitySupported([title, type, weakFooter]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([title, type, weakFooter]))
    XCTAssertFalse(scanner.savedBasicLandIdentitySupported([title, weakFooter]))
    XCTAssertFalse(scanner.savedBasicLandIdentitySupported([type, weakFooter]))
    XCTAssertFalse(scanner.savedBasicLandIdentitySupported([title, type]))
    XCTAssertFalse(scanner.savedBasicLandIdentitySupported([title, type,
      line("282//204 4", y: 0.60, x: 0.04, height: 0.025, confidence: 1)]))
  }

  func testFastBasicLandRecoveryDoesNotScanGeometryWithoutActualTitleTypeAndFooterGuide() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let image: CIImage = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
      .cropped(to: CGRect(x: 0, y: 0, width: 1800, height: 1200))
    let title: [String: Any] = line("Observed land name", y: 0.20, x: 0.10,
      width: 0.14, height: 0.02, confidence: 1)
    let type: [String: Any] = line("Basic Snow Land", y: 0.54, x: 0.10,
      width: 0.10, height: 0.016, confidence: 1)
    for observations: [[String: Any]] in [[], [title, type], [
      title, type, line("0123/300", y: 0.60, x: 0.90, width: 0.05, height: 0.012, confidence: 0.30),
    ]] {
      var diagnostic: [String: Any] = [:]
      let crops: [[String: Any]] = scanner.savedBasicLandCrops(image, observations: observations,
        covered: [], limit: 2, presenceOnly: true, diagnostics: { diagnostic = $0 })
      XCTAssertTrue(crops.isEmpty)
      XCTAssertEqual(diagnostic["mode"] as? String, "no_text_guide")
      XCTAssertEqual((diagnostic["guides"] as? [[String: Double]])?.count, 0)
      XCTAssertEqual((diagnostic["detections"] as? [[String: Any]])?.count, 0)
      XCTAssertEqual((diagnostic["attempts"] as? [[String: Any]])?.count, 0)
    }
  }

  func testPresenceCapacityPrioritizesRecoveredCardsWithoutRemovingUsableNeighbors() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let complete: [String: Any] = ["warnings": ["details_pending"]]
    let unread: [String: Any] = ["warnings": ["details_pending", "no_text"]]
    let partial: [String: Any] = ["warnings": ["details_pending", "incomplete_card"]]
    let actualBasic: [String: Any] = [
      "warnings": ["details_pending", "incomplete_card"],
      "lines": [
        line("Observed land name", y: 0.04, confidence: 1),
        line("Basic Snow Land", y: 0.83, height: 0.03, confidence: 1),
        line("282//204", y: 0.96, x: 0.04, height: 0.025, confidence: 0.30),
      ],
    ]
    let crops: [[String: Any]] = [partial, complete, complete, unread,
      complete, complete, actualBasic, unread]
    XCTAssertEqual(scanner.presenceCapacityDiscardIndices(crops, incomingCount: 1), [3])
    XCTAssertEqual(scanner.presenceCapacityDiscardIndices(crops, incomingCount: 2), [7, 3])
    XCTAssertEqual(scanner.presenceCapacityDiscardIndices(crops, incomingCount: 3), [7, 3, 0])
    XCTAssertEqual(scanner.presenceCapacityDiscardIndices(crops, incomingCount: 4), [7, 3, 0])
    XCTAssertTrue(scanner.presenceCapacityDiscardIndices(crops, incomingCount: 0).isEmpty)
    XCTAssertTrue(scanner.presenceCapacityDiscardIndices(Array(crops.prefix(7)), incomingCount: 1).isEmpty)
    XCTAssertTrue(scanner.presenceCapacityDiscardIndices(Array(repeating: actualBasic, count: 8), incomingCount: 1).isEmpty)
    XCTAssertTrue(scanner.presenceCapacityDiscardIndices(Array(repeating: complete, count: 8), incomingCount: 1).isEmpty)
  }

  func testRecoveredBasicLandCanRetainIdentityWithUnreadCollectorForReview() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let title: [String: Any] = line("Observed land name", y: 0.035, confidence: 1)
    let type: [String: Any] = line("Basic Snow Land", y: 0.83, height: 0.03, confidence: 1)
    let unread: [String: Any] = line("2527254", y: 0.945, x: 0.04, height: 0.02, confidence: 1)
    let context: [String: Any] = line("MHI•EN D OBSERVED ARTIST", y: 0.96, x: 0.04, height: 0.02, confidence: 1)
    XCTAssertFalse(scanner.savedStrongCollectorObserved([unread]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([title, type, unread]))
    XCTAssertTrue(scanner.savedRecoveredBasicLandSupported([title, type, unread, context]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([title, type, unread,
      line("MHI•EN D OBSERVED ARTIST", y: 0.96, x: 0.04, height: 0.02, confidence: 0.50)]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([title, type, unread,
      line("MHI•EN D OBSERVED ARTIST", y: 0.70, x: 0.04, height: 0.02, confidence: 1)]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([title, type, unread,
      line("MHI•EN D OBSERVED ARTIST", y: 0.985, x: 0.04, height: 0.02, confidence: 1)]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([title, unread, context]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([type, unread, context]))
    XCTAssertFalse(scanner.savedRecoveredBasicLandSupported([line("Observed land name", y: 0.035,
      confidence: 0.50), type, unread, context]))
    XCTAssertEqual(unread["text"] as? String, "2527254")
    XCTAssertEqual(context["text"] as? String, "MHI•EN D OBSERVED ARTIST")
  }

  func testBasicLandGeometryFallbackDoesNotRequireAnyGlobalText() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let landscape: [CGRect] = scanner.savedBasicLandGeometryRegions(imageSize: CGSize(width: 5712, height: 3213))
    XCTAssertEqual(landscape, [CGRect(x: 0, y: 0, width: 0.60, height: 1),
      CGRect(x: 0.40, y: 0, width: 0.60, height: 1)])
    let portrait: [CGRect] = scanner.savedBasicLandGeometryRegions(imageSize: CGSize(width: 3213, height: 5712))
    XCTAssertEqual(portrait, [CGRect(x: 0, y: 0, width: 1, height: 0.60),
      CGRect(x: 0, y: 0.40, width: 1, height: 0.60)])
    XCTAssertTrue(scanner.savedBasicLandGuideRegions([], imageSize: CGSize(width: 5712, height: 3213), covered: []).isEmpty)
    XCTAssertFalse(landscape.isEmpty)
    XCTAssertTrue(scanner.savedBasicLandGeometryRegions(imageSize: .zero).isEmpty)
    XCTAssertTrue(scanner.savedBasicLandGeometryRegions(imageSize: CGSize(width: CGFloat.nan, height: 3213)).isEmpty)
  }

  func testBasicLandGeometryRetryRejectsKnownCardsAndArtificialTileEdges() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let left: CGRect = CGRect(x: 0, y: 0, width: 0.60, height: 1)
    let right: CGRect = CGRect(x: 0.40, y: 0, width: 0.60, height: 1)
    let candidate: [CGPoint] = sceneCard(CGRect(x: 0.10, y: 0.20, width: 0.35, height: 0.60))
    XCTAssertTrue(scanner.savedBasicLandRetryCandidateAllowed(candidate, region: left, occupied: []))
    XCTAssertTrue(scanner.savedBasicLandRetryCandidateAllowed(candidate, region: left,
      occupied: [CGRect(x: 0.40, y: 0.20, width: 0.20, height: 0.60)]))
    XCTAssertFalse(scanner.savedBasicLandRetryCandidateAllowed(candidate, region: left,
      occupied: [CGRect(x: 0.06, y: 0.20, width: 0.21, height: 0.60)]))
    XCTAssertFalse(scanner.savedBasicLandRetryCandidateAllowed(sceneCard(CGRect(x: 0.70, y: 0.20,
      width: 0.30, height: 0.60)), region: left, occupied: []))
    XCTAssertFalse(scanner.savedBasicLandRetryCandidateAllowed(sceneCard(CGRect(x: 0, y: 0.20,
      width: 0.30, height: 0.60)), region: right, occupied: []))
    XCTAssertTrue(scanner.savedBasicLandRetryCandidateAllowed(sceneCard(CGRect(x: 0, y: 0.20,
      width: 0.30, height: 0.60)), region: left, occupied: []))
    XCTAssertFalse(scanner.savedBasicLandRetryCandidateAllowed([CGPoint](repeating: .zero, count: 4),
      region: left, occupied: []))
    XCTAssertFalse(scanner.savedBasicLandRetryCandidateAllowed([CGPoint(x: CGFloat.nan, y: 0),
      candidate[1], candidate[2], candidate[3]], region: left, occupied: []))
    let bottom: CGRect = CGRect(x: 0, y: 0, width: 1, height: 0.60)
    XCTAssertFalse(scanner.savedBasicLandRetryCandidateAllowed(sceneCard(CGRect(x: 0.20, y: 0.60,
      width: 0.30, height: 0.40)), region: bottom, occupied: []))
  }

  func testSavedJobFailureDrainsOtherJobsAndEmptyInputDoesNotRun() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let lock: NSLock = NSLock()
    var finished: Set<Int> = []
    let results: [Result<Int, Error>] = scanner.boundedSavedJobs(count: 6) { index, _ in
      defer {
        lock.lock()
        finished.insert(index)
        lock.unlock()
      }
      if index == 1 { throw NSError(domain: "saved-job-test", code: 7) }
      return index
    }
    XCTAssertEqual(results.count, 6)
    XCTAssertEqual(finished, Set(0..<6))
    XCTAssertThrowsError(try results[1].get())
    XCTAssertEqual(try? results[5].get(), 5)
    let empty: [Result<Int, Error>] = scanner.boundedSavedJobs(count: 0) { _, _ in
      XCTFail("Empty input must not start a worker.")
      return 0
    }
    XCTAssertTrue(empty.isEmpty)
  }

  func testOutsideProbeFindsAnAdditionalCardWithoutReReadingCoveredCards() {
    let scanner: LocalCardScanner = LocalCardScanner()
    let covered: [CGRect] = [CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.40)]
    XCTAssertFalse(scanner.outsideSavedCardTextNeedsRecovery([
      line("Enchantment", y: 0.50, x: 0.15, width: 0.20)
    ], covered: covered))
    XCTAssertTrue(scanner.outsideSavedCardTextNeedsRecovery([
      line("Enchantment", y: 0.50, x: 0.65, width: 0.20, confidence: 0.30)
    ], covered: covered))
    XCTAssertTrue(scanner.outsideSavedCardTextNeedsRecovery([
      line("Target creature gains banding", y: 0.65, x: 0.65, width: 0.25)
    ], covered: covered))
    XCTAssertFalse(scanner.outsideSavedCardTextNeedsRecovery([
      line("Enchantment", y: 0.50, x: 0.65, width: 0.20, confidence: 0.29),
      line("The keyboard uses shift control command", y: 0.15),
      line("252/254", y: 0.95)
    ], covered: covered))
    XCTAssertFalse(scanner.outsideSavedCardTextNeedsRecovery([], covered: covered))
  }
}
