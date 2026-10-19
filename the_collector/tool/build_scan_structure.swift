import Foundation
import CoreImage
import CoreGraphics

struct ArtworkReferenceJob: Decodable {
  let id: String
  let imagePath: String
}

enum ArtworkReferenceError: Error {
  case invalidArguments
  case invalidImage(String)
  case renderFailed(String)
}

final class ArtworkReferenceResults {
  private let lock = NSLock()
  private var values: [Data?]
  private var failure: Error?

  init(count: Int) { values = [Data?](repeating: nil, count: count) }

  func put(_ value: Data, at index: Int) {
    lock.lock()
    defer { lock.unlock() }
    values[index] = value
  }

  func fail(_ error: Error) {
    lock.lock()
    defer { lock.unlock() }
    if failure == nil { failure = error }
  }

  func ordered() throws -> [Data] {
    lock.lock()
    defer { lock.unlock() }
    if let failure { throw failure }
    return try values.map { value in
      guard let value else { throw ArtworkReferenceError.invalidArguments }
      return value
    }
  }
}

func referencePixels(path: String, context: CIContext) throws -> Data {
  guard let original = CIImage(contentsOf: URL(fileURLWithPath: path),
      options: [.applyOrientationProperty: true]),
      original.extent.width.isFinite, original.extent.height.isFinite,
      original.extent.width > 0, original.extent.height > 0 else {
    throw ArtworkReferenceError.invalidImage(path)
  }
  var image = original.transformed(by: CGAffineTransform(
    translationX: -original.extent.minX, y: -original.extent.minY))
  let longest = max(image.extent.width, image.extent.height)
  if longest > 512 {
    let scale = 512 / longest
    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
  }
  image = image.transformed(by: CGAffineTransform(
    translationX: -image.extent.minX, y: -image.extent.minY))
  guard let cgImage = context.createCGImage(image, from: image.extent) else {
    throw ArtworkReferenceError.renderFailed(path)
  }
  let edge = 48
  var rgba = [UInt8](repeating: 255, count: edge * edge * 4)
  let success = rgba.withUnsafeMutableBytes { bytes -> Bool in
    guard let canvas = CGContext(data: bytes.baseAddress, width: edge, height: edge,
      bitsPerComponent: 8, bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
    canvas.setFillColor(CGColor(gray: 1, alpha: 1))
    canvas.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
    canvas.interpolationQuality = .high
    canvas.draw(cgImage, in: CGRect(x: 0, y: 0, width: edge, height: edge))
    return true
  }
  guard success else { throw ArtworkReferenceError.renderFailed(path) }
  return Data(stride(from: 0, to: rgba.count, by: 4).map { offset in
    let luma = Double(rgba[offset]) * 0.299 + Double(rgba[offset + 1]) * 0.587
      + Double(rgba[offset + 2]) * 0.114
    return UInt8(min(255, max(0, luma.rounded())))
  })
}

func build() throws {
  let arguments = CommandLine.arguments
  guard arguments.count == 3 else { throw ArtworkReferenceError.invalidArguments }
  let jobs = try JSONDecoder().decode([ArtworkReferenceJob].self,
    from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
  guard !jobs.isEmpty, jobs.count <= 500000,
      Set(jobs.map { $0.id }).count == jobs.count else { throw ArtworkReferenceError.invalidArguments }
  let destination = URL(fileURLWithPath: arguments[2])
  let temporary = destination.appendingPathExtension("pending")
  FileManager.default.createFile(atPath: temporary.path, contents: nil)
  let output = try FileHandle(forWritingTo: temporary)
  var published = false
  defer {
    try? output.close()
    if !published { try? FileManager.default.removeItem(at: temporary) }
  }
  var header = Data("SCGRAY1\0".utf8)
  for value in [UInt32(2304), UInt32(jobs.count)] {
    var encoded = value.littleEndian
    withUnsafeBytes(of: &encoded) { header.append(contentsOf: $0) }
  }
  try output.write(contentsOf: header)
  let contexts = [CIContext(options: [.cacheIntermediates: false]),
    CIContext(options: [.cacheIntermediates: false])]
  let started = Date()
  for start in stride(from: 0, to: jobs.count, by: 32) {
    let count = min(32, jobs.count - start)
    let results = ArtworkReferenceResults(count: count)
    DispatchQueue.concurrentPerform(iterations: 2) { worker in
      for offset in stride(from: worker, to: count, by: 2) {
        autoreleasepool {
          do {
            results.put(try referencePixels(path: jobs[start + offset].imagePath,
              context: contexts[worker]), at: offset)
          } catch { results.fail(error) }
        }
      }
    }
    for pixels in try results.ordered() { try output.write(contentsOf: pixels) }
    if start % 1024 == 0 { print("references \(start + count)/\(jobs.count)") }
  }
  try output.synchronize()
  try output.close()
  if FileManager.default.fileExists(atPath: destination.path) {
    try FileManager.default.removeItem(at: destination)
  }
  try FileManager.default.moveItem(at: temporary, to: destination)
  published = true
  let report: [String: Any] = ["schema": "gray48-bt601-cg-high-v1", "count": jobs.count,
    "elapsedSeconds": Date().timeIntervalSince(started), "bytesPerReference": 2304,
    "workers": 2]
  try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: destination.appendingPathExtension("json"), options: .atomic)
}

do { try build() }
catch {
  FileHandle.standardError.write(Data("Reference build failed: \(error)\n".utf8))
  exit(1)
}
