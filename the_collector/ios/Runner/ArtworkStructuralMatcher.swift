import Foundation

struct ArtworkStructuralMatch {
  let correlation: Double
  let coverage: Double
  let patch: String
  let scaleX: Double
  let scaleY: Double
  let offsetX: Int
  let offsetY: Int

  var fields: [String: Any] {
    ["schema": "gray-alignment-v1", "correlation": correlation,
      "coverage": coverage, "patch": patch, "scaleX": scaleX,
      "scaleY": scaleY, "offsetX": offsetX, "offsetY": offsetY]
  }
}

enum ArtworkStructuralMatcher {
  static let edge = 48

  static func match(query: [UInt8], reference: [UInt8]) -> ArtworkStructuralMatch? {
    guard query.count == edge * edge, reference.count == edge * edge else { return nil }
    let queryPixels = smoothed(query)
    let referencePixels = smoothed(reference)
    var best: ArtworkStructuralMatch?
    for scaleX in [0.9, 1.0, 1.1] {
      let width = Int((Double(edge) * scaleX).rounded())
      for scaleY in [0.9, 1.0, 1.1] {
        let height = Int((Double(edge) * scaleY).rounded())
        let scaled = resized(queryPixels, width: width, height: height)
        let originX = Int(floor(Double(edge - width) / 2))
        let originY = Int(floor(Double(edge - height) / 2))
        for offsetX in stride(from: -4, through: 4, by: 2) {
          for offsetY in stride(from: -4, through: 4, by: 2) {
            let x = originX + offsetX
            let y = originY + offsetY
            let left = max(0, x)
            let top = max(0, y)
            let right = min(edge, x + width)
            let bottom = min(edge, y + height)
            let overlap = (right - left) * (bottom - top)
            let referenceCoverage = Double(overlap) / Double(edge * edge)
            let queryCoverage = Double(overlap) / Double(width * height)
            guard referenceCoverage >= 0.75, queryCoverage >= 0.75 else { continue }
            let split = left + (right - left) / 2
            var full = Moments()
            var firstHalf = Moments()
            var secondHalf = Moments()
            for row in top..<bottom {
              for column in left..<right {
                let observed = scaled[(row - y) * width + column - x]
                let expected = referencePixels[row * edge + column]
                full.add(observed, expected)
                if column < split - 1 { firstHalf.add(observed, expected) }
                else if column > split { secondHalf.add(observed, expected) }
              }
            }
            for (name, values, fraction) in [
              ("full", full, 1.0),
              ("left", firstHalf, Double(split - left - 1) / Double(right - left)),
              ("right", secondHalf, Double(right - split - 1) / Double(right - left)),
            ] {
              guard let correlation = values.correlation else { continue }
              let coverage = min(referenceCoverage, queryCoverage) * fraction
              if let previous = best {
                let difference = correlation - previous.correlation
                guard difference > 0.0001 ||
                  (abs(difference) <= 0.0001 && coverage > previous.coverage) else { continue }
              }
              best = ArtworkStructuralMatch(correlation: correlation,
                coverage: coverage,
                patch: name, scaleX: scaleX, scaleY: scaleY,
                offsetX: offsetX, offsetY: offsetY)
            }
          }
        }
      }
    }
    return best
  }

  private struct Moments {
    var count = 0
    var sumQuery = 0.0
    var sumReference = 0.0
    var squaredQuery = 0.0
    var squaredReference = 0.0
    var product = 0.0

    mutating func add(_ query: Double, _ reference: Double) {
      count += 1
      sumQuery += query
      sumReference += reference
      squaredQuery += query * query
      squaredReference += reference * reference
      product += query * reference
    }

    var correlation: Double? {
      guard count >= 512 else { return nil }
      let size = Double(count)
      let queryVariance = squaredQuery - sumQuery * sumQuery / size
      let referenceVariance = squaredReference - sumReference * sumReference / size
      guard queryVariance / size >= 1, referenceVariance / size >= 1 else { return nil }
      let denominator = sqrt(queryVariance * referenceVariance)
      let value = (product - sumQuery * sumReference / size) / denominator
      return value.isFinite ? min(1, max(-1, value)) : nil
    }
  }

  private static func smoothed(_ pixels: [UInt8]) -> [Double] {
    let weights = [1.0, 2.0, 1.0]
    var result = [Double](repeating: 0, count: pixels.count)
    func reflected(_ coordinate: Int) -> Int {
      if coordinate < 0 { return -coordinate }
      if coordinate >= edge { return 2 * edge - coordinate - 2 }
      return coordinate
    }
    for y in 0..<edge {
      for x in 0..<edge {
        var value = 0.0
        for dy in -1...1 {
          for dx in -1...1 {
            value += Double(pixels[reflected(y + dy) * edge + reflected(x + dx)])
              * weights[dy + 1] * weights[dx + 1]
          }
        }
        result[y * edge + x] = value / 16
      }
    }
    return result
  }

  private static func resized(_ pixels: [Double], width: Int, height: Int) -> [Double] {
    if width == edge, height == edge { return pixels }
    var result = [Double](repeating: 0, count: width * height)
    for y in 0..<height {
      let sourceY = max(0, min(Double(edge - 1), (Double(y) + 0.5) * Double(edge) / Double(height) - 0.5))
      let firstY = Int(sourceY)
      let secondY = min(edge - 1, firstY + 1)
      let fractionY = sourceY - Double(firstY)
      for x in 0..<width {
        let sourceX = max(0, min(Double(edge - 1), (Double(x) + 0.5) * Double(edge) / Double(width) - 0.5))
        let firstX = Int(sourceX)
        let secondX = min(edge - 1, firstX + 1)
        let fractionX = sourceX - Double(firstX)
        let upper = pixels[firstY * edge + firstX] * (1 - fractionX) + pixels[firstY * edge + secondX] * fractionX
        let lower = pixels[secondY * edge + firstX] * (1 - fractionX) + pixels[secondY * edge + secondX] * fractionX
        result[y * width + x] = upper * (1 - fractionY) + lower * fractionY
      }
    }
    return result
  }
}
