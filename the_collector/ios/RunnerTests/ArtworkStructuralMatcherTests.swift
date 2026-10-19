import XCTest
@testable import Runner

final class ArtworkStructuralMatcherTests: XCTestCase {
  private func pattern() -> [UInt8] {
    (0..<48 * 48).map { index in
      let x = index % 48
      let y = index / 48
      return UInt8(20 + (x * x * 13 + y * y * 7 + x * y * 3) % 120)
    }
  }

  func testIdenticalMeasuredPixelsMatchWithoutAnIdentityClaim() throws {
    let pixels = pattern()
    let result = try XCTUnwrap(ArtworkStructuralMatcher.match(query: pixels, reference: pixels))
    XCTAssertGreaterThan(result.correlation, 0.9999)
    XCTAssertEqual(result.fields["schema"] as? String, "gray-alignment-v1")
    XCTAssertNil(result.fields["confidence"])
    XCTAssertNil(result.fields["identity"])
    XCTAssertGreaterThanOrEqual(result.coverage, 0.35)
  }

  func testBrightnessAndContrastChangesRetainActualSpatialContent() throws {
    let reference = pattern()
    let observed = reference.map { UInt8((Double($0) * 1.2 + 30).rounded()) }
    let result = try XCTUnwrap(ArtworkStructuralMatcher.match(query: observed, reference: reference))
    XCTAssertGreaterThan(result.correlation, 0.998)
  }

  func testOccludedHalfReportsOnlyTheMatchingCoverage() throws {
    let reference = pattern()
    let observed = reference.enumerated().map { index, value in index % 48 < 24 ? value : 255 }
    let result = try XCTUnwrap(ArtworkStructuralMatcher.match(query: observed, reference: reference))
    XCTAssertGreaterThan(result.correlation, 0.99)
    XCTAssertEqual(result.patch, "left")
    XCTAssertLessThan(result.coverage, 0.6)
    XCTAssertGreaterThanOrEqual(result.coverage, 0.35)
  }

  func testQuantizedFullFramePrefersCompleteCoverageOverANearTiedHalf() throws {
    let reference = pattern()
    let observed: [UInt8] = reference.enumerated().map { index, value in
      let adjustment: Int
      if index % 128 == 0 { adjustment = index % 256 == 0 ? 2 : -2 }
      else if index % 8 == 0 { adjustment = index % 16 == 0 ? 1 : -1 }
      else { adjustment = 0 }
      return UInt8(Int(value) + adjustment)
    }
    let result = try XCTUnwrap(ArtworkStructuralMatcher.match(query: observed, reference: reference))
    XCTAssertGreaterThan(result.correlation, 0.9998)
    XCTAssertEqual(result.patch, "full")
    XCTAssertEqual(result.coverage, 1)
  }

  func testUnrelatedTextureCannotBecomePerfectCorrespondence() throws {
    let unrelated: [UInt8] = (0..<2304).map { (index: Int) -> UInt8 in
      let row: Int = index / 48
      let positionValue: Int = index * 67
      let value: Int = (positionValue + row * 113) % 251
      return UInt8(value)
    }
    let result = try XCTUnwrap(ArtworkStructuralMatcher.match(query: unrelated, reference: pattern()))
    XCTAssertLessThan(result.correlation, 0.8)
  }

  func testFlatAndMalformedPixelsDeclineStructuralEvidence() {
    XCTAssertNil(ArtworkStructuralMatcher.match(query: [UInt8](repeating: 100, count: 48 * 48), reference: pattern()))
    XCTAssertNil(ArtworkStructuralMatcher.match(query: pattern(), reference: [UInt8](repeating: 100, count: 48 * 48)))
    XCTAssertNil(ArtworkStructuralMatcher.match(query: [1, 2, 3], reference: pattern()))
  }
}
