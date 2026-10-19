import AVFoundation
import CoreImage
import CoreML
import CryptoKit
import Darwin
import Flutter
import ImageIO
import UIKit
import Vision

protocol CaptureConfirmationPlaying: AnyObject {
  var isPlaying: Bool { get }
  var currentTime: TimeInterval { get set }
  func play() -> Bool
}

extension AVAudioPlayer: CaptureConfirmationPlaying {}

final class ScanCropCache {
  private let root: URL
  private let generation: UUID
  private let directory: URL
  private let preparationLock: NSLock = NSLock()
  private let cleanupQueue: DispatchQueue = DispatchQueue(
    label: "art.arcane.the_collector.scanner.crop-cleanup", qos: .utility)
  private var prepared: Bool = false
  private var enumeration: FileManager.DirectoryEnumerator?
  private var finished: Bool = false

  init(root: URL, generation: UUID) {
    self.root = root.standardizedFileURL
    self.generation = generation
    directory = root.standardizedFileURL.appendingPathComponent(generation.uuidString, isDirectory: true)
  }

  func nextCropURL() throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    guard isDirectory(root) else { throw CocoaError(.fileWriteNoPermission) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard isDirectory(directory) else { throw CocoaError(.fileWriteNoPermission) }
    return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
  }

  func prepare() {
    preparationLock.lock()
    defer { preparationLock.unlock() }
    guard !prepared else { return }
    prepared = true
    cleanupQueue.async { self.removeNextBatch() }
  }

  private func removeNextBatch() {
    if removeAbandonedBatch() {
      cleanupQueue.async { self.removeNextBatch() }
    }
  }

  func removeAbandonedBatch() -> Bool {
    guard !finished else { return false }
    guard isDirectory(root) else {
      finished = true
      return false
    }
    if enumeration == nil {
      enumeration = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
    }
    guard let entries: FileManager.DirectoryEnumerator = enumeration else {
      finished = true
      return false
    }
    for _: Int in 0..<64 {
      guard let entry: URL = entries.nextObject() as? URL else {
        enumeration = nil
        finished = true
        return false
      }
      guard let values: URLResourceValues = try? entry.resourceValues(
        forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]),
        values.isSymbolicLink != true else {
        entries.skipDescendants()
        continue
      }
      let parent: URL = entry.deletingLastPathComponent()
      if values.isDirectory == true {
        guard parent == root, let owner: UUID = UUID(uuidString: entry.lastPathComponent),
          owner != generation else {
          entries.skipDescendants()
          continue
        }
        if rmdir(entry.path) == 0 { entries.skipDescendants() }
        continue
      }
      guard values.isRegularFile == true, entry.pathExtension == "jpg",
        UUID(uuidString: entry.deletingPathExtension().lastPathComponent) != nil else { continue }
      if parent != root {
        guard parent.deletingLastPathComponent() == root,
          let owner: UUID = UUID(uuidString: parent.lastPathComponent),
          owner != generation, isDirectory(parent) else { continue }
      }
      // Unlink cannot recursively erase an entry that changed into a directory.
      if unlink(entry.path) == 0, parent != root { _ = rmdir(parent.path) }
    }
    return true
  }

  private func isDirectory(_ url: URL) -> Bool {
    guard let values: URLResourceValues = try? url.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
  }
}

final class LocalCardScanner: NSObject, FlutterPlugin {
  private static let cropCache: ScanCropCache = ScanCropCache(
    root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ScanCrops", isDirectory: true),
    generation: UUID())

  static func prepareTemporaryCrops() {
    cropCache.prepare()
  }

  private var confirmationPlayer: CaptureConfirmationPlaying?
  private let confirmationClock: () -> TimeInterval
  private var lastConfirmation: TimeInterval?

  init(confirmationPlayer: CaptureConfirmationPlaying? = nil,
       confirmationClock: @escaping () -> TimeInterval = { CACurrentMediaTime() }) {
    self.confirmationPlayer = confirmationPlayer
    self.confirmationClock = confirmationClock
    super.init()
  }

  func confirmCapture() -> Bool {
    guard Thread.isMainThread, let player = confirmationPlayer, !player.isPlaying else { return false }
    let now: TimeInterval = confirmationClock()
    guard now.isFinite, now >= 0,
      lastConfirmation.map({ now - $0 >= 1.5 }) ?? true else { return false }
    player.currentTime = 0
    guard player.play() else { return false }
    lastConfirmation = now
    return true
  }

  private func prepareCaptureConfirmation(with registrar: FlutterPluginRegistrar) {
    let key: String = registrar.lookupKey(forAsset: "assets/ding.mp3")
    guard let path: String = Bundle.main.path(forResource: key, ofType: nil) else { return }
    do {
      try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [])
      let player: AVAudioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
      player.volume = 0.3
      player.numberOfLoops = 0
      guard player.prepareToPlay() else { return }
      confirmationPlayer = player
    } catch {
      confirmationPlayer = nil
    }
  }
  private let work = DispatchQueue(label: "art.arcane.the_collector.scanner", qos: .userInitiated)
  private let liveWork = DispatchQueue(label: "art.arcane.the_collector.scanner.live", qos: .userInitiated)
  private let presenceWork = DispatchQueue(label: "art.arcane.the_collector.scanner.presence", qos: .userInitiated)
  private lazy var presenceScanner: LocalCardScanner = LocalCardScanner()
  private var pendingPresence: Int = 0
  private let visualWork = DispatchQueue(label: "art.arcane.the_collector.scanner.visual", qos: .userInitiated)
  private lazy var visualScanner: LocalCardScanner = LocalCardScanner()
  private var pendingVisual: Int = 0
  private let savedJobs = DispatchQueue(label: "art.arcane.the_collector.scanner.saved", qos: .userInitiated,
    attributes: .concurrent)
  private let context = CIContext(options: [.cacheIntermediates: false])
  private var busy = false
  private var liveBusy = false
  private struct PendingWork {
    let result: FlutterResult
    let operation: () throws -> Any
  }
  private var foreground: [PendingWork] = []
  private var liveOcrOffset = 0
  private struct LivePartial {
    var observation: VNDetectedObjectObservation
    let seed: CGRect
    let card: [String: Any]
    let verifiedAt: TimeInterval
  }
  struct CardLighting {
    let highlightFraction: Double
    let shadowFraction: Double
    let meanLuminance: Double
    let contrast: Double
    let sampleCount: Int
    let darkPoint: Double
    let lightPoint: Double

    var valid: Bool {
      sampleCount > 0 && sampleCount <= 128 * 128
        && [highlightFraction, shadowFraction, meanLuminance, contrast, darkPoint, lightPoint]
          .allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
        && lightPoint >= darkPoint
    }
    var washedOut: Bool {
      valid && sampleCount >= 64 && meanLuminance >= 0.78 && highlightFraction >= 0.10
        && contrast <= 0.28 && shadowFraction <= 0.04
    }
    var map: [String: Any] {
      ["highlightFraction": highlightFraction, "shadowFraction": shadowFraction,
        "meanLuminance": meanLuminance, "contrast": contrast, "sampleCount": sampleCount]
    }
  }
  private var livePartials: [LivePartial] = []
  private var partialSequence = VNSequenceRequestHandler()
  private var partialFrameKey = ""
  private var lastPartialOCR = -Double.infinity

  private final class SavedJobSlots<Output>: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var values: [Result<Output, Error>?]
    private var nextIndex: Int = 0
    init(count: Int) { values = Array(repeating: nil, count: count) }
    func takeNext() -> Int? {
      lock.lock()
      defer { lock.unlock() }
      guard nextIndex < values.count else { return nil }
      let index: Int = nextIndex
      nextIndex += 1
      return index
    }
    func set(_ result: Result<Output, Error>, at index: Int) {
      lock.lock()
      defer { lock.unlock() }
      values[index] = result
    }
    func completed() -> [Result<Output, Error>] {
      lock.lock()
      defer { lock.unlock() }
      return values.map { $0 ?? .failure(ScanError.unreadableImage) }
    }
  }

  func boundedSavedJobs<Output>(count: Int, maximumWorkers: Int = 2,
      operation: @escaping (Int, Int) throws -> Output) -> [Result<Output, Error>] {
    guard count > 0 else { return [] }
    let workers: Int = min(count, min(2, max(1, maximumWorkers)))
    let slots: SavedJobSlots<Output> = SavedJobSlots(count: count)
    let group: DispatchGroup = DispatchGroup()
    for worker: Int in 0..<workers {
      group.enter()
      savedJobs.async {
        defer { group.leave() }
        while let index: Int = slots.takeNext() {
          let result: Result<Output, Error> = autoreleasepool { Result { try operation(index, worker) } }
          slots.set(result, at: index)
        }
      }
    }
    group.wait()
    return slots.completed()
  }

  private struct SavedCardJob {
    let index: Int
    var crop: [String: Any]?
    var diagnostics: [[String: Any]]
    var timings: [[String: Any]]
  }

  struct SavedCardProjection {
    private let coefficients: [Double]
    private let rotateRight: Bool

    init?(corners: [CGPoint], rotateRight: Bool = false) {
      guard corners.count == 4, corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
      let turns: [CGFloat] = corners.indices.map { index in
        let a: CGPoint = corners[index]
        let b: CGPoint = corners[(index + 1) % 4]
        let c: CGPoint = corners[(index + 2) % 4]
        return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
      }
      guard turns.allSatisfy({ $0 > 0.0000001 }) || turns.allSatisfy({ $0 < -0.0000001 }) else { return nil }
      let destination: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
      var equations: [[Double]] = []
      for index: Int in 0..<4 {
        let x: Double = Double(corners[index].x)
        let y: Double = Double(corners[index].y)
        let u: Double = Double(destination[index].x)
        let v: Double = Double(destination[index].y)
        equations.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
        equations.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
      }
      for column: Int in 0..<8 {
        guard let pivot: Int = (column..<8).max(by: {
          abs(equations[$0][column]) < abs(equations[$1][column])
        }), abs(equations[pivot][column]) > 0.0000000001 else { return nil }
        equations.swapAt(column, pivot)
        let divisor: Double = equations[column][column]
        for entry: Int in column...8 { equations[column][entry] /= divisor }
        for row: Int in 0..<8 where row != column {
          let multiplier: Double = equations[row][column]
          for entry: Int in column...8 { equations[row][entry] -= multiplier * equations[column][entry] }
        }
      }
      let solved: [Double] = equations.map { $0[8] }
      guard solved.allSatisfy({ $0.isFinite }) else { return nil }
      coefficients = solved
      self.rotateRight = rotateRight
    }

    func map(_ point: CGPoint) -> CGPoint? {
      guard point.x.isFinite, point.y.isFinite else { return nil }
      let x: Double = Double(point.x)
      let y: Double = Double(point.y)
      let denominator: Double = coefficients[6] * x + coefficients[7] * y + 1
      guard denominator.isFinite, abs(denominator) > 0.00000001 else { return nil }
      let u: Double = (coefficients[0] * x + coefficients[1] * y + coefficients[2]) / denominator
      let v: Double = (coefficients[3] * x + coefficients[4] * y + coefficients[5]) / denominator
      guard u.isFinite, v.isFinite else { return nil }
      return rotateRight ? CGPoint(x: 1 - v, y: u) : CGPoint(x: u, y: v)
    }

    func map(_ quad: [CGPoint]) -> [CGPoint]? {
      guard quad.count == 4 else { return nil }
      let mapped: [CGPoint] = quad.compactMap { map($0) }
      return mapped.count == 4 ? mapped : nil
    }

    func unmap(_ point: CGPoint) -> CGPoint? {
      guard point.x.isFinite, point.y.isFinite else { return nil }
      let u: Double = Double(rotateRight ? point.y : point.x)
      let v: Double = Double(rotateRight ? 1 - point.x : point.y)
      let a: Double = coefficients[0], b: Double = coefficients[1], c: Double = coefficients[2]
      let d: Double = coefficients[3], e: Double = coefficients[4], f: Double = coefficients[5]
      let g: Double = coefficients[6], h: Double = coefficients[7]
      let denominator: Double = (d * h - e * g) * u + (b * g - a * h) * v + a * e - b * d
      guard denominator.isFinite, abs(denominator) > 0.00000001 else { return nil }
      let x: Double = ((e - f * h) * u + (c * h - b) * v + b * f - c * e) / denominator
      let y: Double = ((f * g - d) * u + (a - c * g) * v + c * d - a * f) / denominator
      return x.isFinite && y.isFinite ? CGPoint(x: x, y: y) : nil
    }

    func unmap(_ quad: [CGPoint]) -> [CGPoint]? {
      guard quad.count == 4 else { return nil }
      let mapped: [CGPoint] = quad.compactMap { unmap($0) }
      return mapped.count == 4 ? mapped : nil
    }
  }

  enum SavedSceneSeed: String, Equatable {
    case supported, nameplate, footer, borderProbe, unsupported
  }

  private struct SavedSceneRow {
    let line: [String: Any]
    let quad: [CGPoint]
    let glyph: [CGPoint]
  }

  private struct SavedSceneCard {
    var lines: [[String: Any]] = []
    var probeTop: Bool = false
    var probeBottom: Bool = false
    var verifyFooter: Bool = false
  }
  private let referenceFeatures: NSCache<NSString, VNFeaturePrintObservation> = {
    let cache = NSCache<NSString, VNFeaturePrintObservation>()
    cache.countLimit = 96
    return cache
  }()
  private enum ArtworkSignal {
    case feature(VNFeaturePrintObservation)
    case descriptor([Double])
  }
  private final class ArtworkQuery: NSObject {
    let signal: ArtworkSignal
    init(_ signal: ArtworkSignal) { self.signal = signal }
  }
  private let artworkQueries: NSCache<NSString, ArtworkQuery> = {
    let cache = NSCache<NSString, ArtworkQuery>()
    cache.countLimit = 32
    return cache
  }()
  private struct StructuralQueryKey: Hashable {
    let path: String
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let rotation: Int
  }
  private var structuralQueryPixels: [StructuralQueryKey: [UInt8]] = [:]
  private var structuralQueryOrder: [StructuralQueryKey] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let scanner = LocalCardScanner()
    scanner.prepareCaptureConfirmation(with: registrar)
    let channel = FlutterMethodChannel(
      name: "art.arcane.the_collector/scanner", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(scanner, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "captureConfirmed" {
      result(confirmCapture())
      return
    }
    guard let arguments = call.arguments as? [String: Any] else {
      result(FlutterError(code: "invalid_image", message: "Image arguments are unavailable.", details: nil))
      return
    }
    switch call.method {
    case "cameraFocusAtPoint":
      guard let name = arguments["cameraName"] as? String, !name.isEmpty,
            let orientation = arguments["previewOrientation"] as? String,
            let x = arguments["x"] as? Double, let y = arguments["y"] as? Double,
            x.isFinite, y.isFinite, x >= 0, x <= 1, y >= 0, y <= 1 else {
        result(FlutterError(code: "invalid_focus_point", message: "The focus point is unavailable.", details: nil))
        return
      }
      let point: CGPoint
      switch orientation {
      case "portraitUp": point = CGPoint(x: y, y: 1 - x)
      case "portraitDown": point = CGPoint(x: 1 - y, y: x)
      case "landscapeRight": point = CGPoint(x: 1 - x, y: 1 - y)
      case "landscapeLeft": point = CGPoint(x: x, y: y)
      default:
        result(FlutterError(code: "invalid_focus_point", message: "The focus point is unavailable.", details: nil))
        return
      }
      guard let device = AVCaptureDevice(uniqueID: name), device.isFocusPointOfInterestSupported else {
        result(FlutterError(code: "focus_unavailable", message: "Camera focus is unavailable.", details: nil))
        return
      }
      let singleShot = arguments["singleShot"] as? Bool ?? true
      let adjustExposure = arguments["adjustExposure"] as? Bool ?? true
      let mode: AVCaptureDevice.FocusMode
      if singleShot && device.isFocusModeSupported(.autoFocus) {
        mode = .autoFocus
      } else if device.isFocusModeSupported(.continuousAutoFocus) {
        mode = .continuousAutoFocus
      } else if device.isFocusModeSupported(.autoFocus) {
        mode = .autoFocus
      } else {
        result(FlutterError(code: "focus_unavailable", message: "Camera focus is unavailable.", details: nil))
        return
      }
      do {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
        device.focusPointOfInterest = point
        device.focusMode = mode
        if adjustExposure && device.isExposurePointOfInterestSupported {
          device.exposurePointOfInterest = point
          if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
          }
        }
        result(true)
      } catch {
        result(FlutterError(code: "focus_unavailable", message: "Camera focus is unavailable.", details: nil))
      }
    case "cameraFocusStatus":
      guard let name = arguments["cameraName"] as? String, !name.isEmpty,
            let device = AVCaptureDevice(uniqueID: name) else {
        result(nil)
        return
      }
      result(["isAdjustingFocus": device.isAdjustingFocus,
        "isAdjustingExposure": device.isAdjustingExposure, "lensPosition": Double(device.lensPosition),
        "exposureTargetBias": Double(device.exposureTargetBias),
        "focusPointX": Double(device.focusPointOfInterest.x),
        "focusPointY": Double(device.focusPointOfInterest.y),
        "focusMode": device.focusMode.rawValue,
        "deviceOrientation": UIDevice.current.orientation.rawValue])
    case "recognize":
      guard let path = arguments["path"] as? String,
            FileManager.default.fileExists(atPath: path) else {
        result(FlutterError(code: "invalid_image", message: "The selected image is unavailable.", details: nil))
        return
      }
      perform(result) {
        try self.recognize(path: path, multiple: arguments["multipleCards"] as? Bool ?? false,
          includePartialDiagnostics: arguments["includePartialDiagnostics"] as? Bool ?? false,
          targetRegions: self.savedTargetRegions(arguments["targetRegions"]))
      }
    case "recognizePresence":
      guard let path: String = arguments["path"] as? String,
        FileManager.default.fileExists(atPath: path) else {
        result(FlutterError(code: "invalid_image", message: "The selected image is unavailable.", details: nil))
        return
      }
      guard pendingPresence < 8 else {
        result(FlutterError(code: "scanner_queue_full", message: "Too many images are waiting for analysis.", details: nil))
        return
      }
      let worker: LocalCardScanner = presenceScanner
      let multiple: Bool = arguments["multipleCards"] as? Bool ?? true
      pendingPresence += 1
      presenceWork.async {
        let output: Any
        do {
          output = try autoreleasepool {
            try worker.recognizePresence(path: path, multiple: multiple,
              targetRegions: worker.savedTargetRegions(arguments["targetRegions"]))
          }
        } catch {
          output = FlutterError(code: "recognition_failed", message: error.localizedDescription, details: nil)
        }
        DispatchQueue.main.async {
          self.pendingPresence -= 1
          result(output)
        }
      }
    case "detectFrame":
      performLiveFrame(arguments, result: result)
    case "artworkDescriptor":
      guard let path = arguments["imagePath"] as? String,
            FileManager.default.fileExists(atPath: path),
            let region = artworkQueryRegion(arguments["queryRegion"]),
            let rotation = (arguments["rotationDegrees"] ?? 0) as? Int,
            rotation == 0 || rotation == 180 else {
        result(FlutterError(code: "invalid_image", message: "Artwork is unavailable.", details: nil))
        return
      }
      performVisual(result) { worker in
        guard let source = CIImage(contentsOf: URL(fileURLWithPath: path),
            options: [.applyOrientationProperty: true]) else { throw ScanError.unreadableImage }
        let upright = worker.normalized(rotation == 180 ? source.oriented(.down) : source)
        let artwork: CIImage
        if arguments["referenceArtwork"] as? Bool == true {
          artwork = upright
        } else {
          let extent = upright.extent
          artwork = upright.cropped(to: CGRect(x: extent.width * region.minX,
            y: extent.height * (1 - region.maxY), width: extent.width * region.width, height: extent.height * region.height))
        }
        return ["schema": "rgb-gradient-8x8-v1", "vector": try worker.artworkDescriptor(artwork)]
      }
    case "compareArtworkStructure":
      guard let query: String = arguments["queryImagePath"] as? String,
        FileManager.default.fileExists(atPath: query),
        let region: CGRect = artworkQueryRegion(arguments["queryRegion"]),
        let rotation: Int = (arguments["rotationDegrees"] ?? 0) as? Int,
        rotation == 0 || rotation == 180 else {
        result(FlutterError(code: "invalid_image", message: "Artwork is unavailable.", details: nil))
        return
      }
      let reference: String? = arguments["referenceImagePath"] as? String
      let raw: FlutterStandardTypedData? = arguments["referencePixels"] as? FlutterStandardTypedData
      let hasPath: Bool = arguments["referenceImagePath"] != nil
      let hasPixels: Bool = arguments["referencePixels"] != nil
      guard hasPath != hasPixels else {
        result(FlutterError(code: "invalid_image", message: "Artwork is unavailable.", details: nil))
        return
      }
      let referencePixels: [UInt8]?
      if hasPixels {
        guard let raw, raw.elementSize == 1, raw.elementCount == UInt32(ArtworkStructuralMatcher.edge * ArtworkStructuralMatcher.edge),
          raw.data.count == ArtworkStructuralMatcher.edge * ArtworkStructuralMatcher.edge,
          arguments["referenceSchema"] as? String == "gray48-bt601-cg-high-v1" else {
          result(FlutterError(code: "invalid_image", message: "Artwork is unavailable.", details: nil))
          return
        }
        referencePixels = [UInt8](raw.data)
      } else {
        guard let reference, FileManager.default.fileExists(atPath: reference) else {
          result(FlutterError(code: "invalid_image", message: "Artwork is unavailable.", details: nil))
          return
        }
        referencePixels = nil
      }
      performVisual(result) { worker in
        try worker.compareArtworkStructure(query: query, reference: reference, referencePixels: referencePixels,
          region: region, rotationDegrees: rotation,
          includePixelDiagnostics: arguments["includePixelDiagnostics"] as? Bool ?? false)
      }
    case "compareArtwork", "compareSetSymbol":
      guard let query = arguments["queryImagePath"] as? String,
            let reference = arguments["referenceImagePath"] as? String,
            FileManager.default.fileExists(atPath: query),
            FileManager.default.fileExists(atPath: reference) else {
        result(FlutterError(code: "invalid_image", message: "Artwork images are unavailable.", details: nil))
        return
      }
      if call.method == "compareSetSymbol" {
        guard let region = arguments["queryRegion"] as? [String: Double],
              let x = region["x"], let y = region["y"],
              let width = region["width"], let height = region["height"],
              x.isFinite && y.isFinite && width.isFinite && height.isFinite,
              x >= 0 && y >= 0 && width > 0 && height > 0,
              x + width <= 1 && y + height <= 1 else {
          result(FlutterError(code: "invalid_image", message: "The symbol region is unavailable.", details: nil))
          return
        }
        performVisual(result) { worker in
          try worker.compareImages(query: query, reference: reference,
            region: CGRect(x: x, y: y, width: width, height: height), monochrome: true)
        }
      } else {
        guard let region = artworkQueryRegion(arguments["queryRegion"]),
              let rotation = (arguments["rotationDegrees"] ?? 0) as? Int,
              rotation == 0 || rotation == 180 else {
          result(FlutterError(code: "invalid_image", message: "The artwork region is unavailable.", details: nil))
          return
        }
        performVisual(result) { worker in
          return try worker.compareImages(query: query, reference: reference, region: region,
            monochrome: false, rotationDegrees: rotation)
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func performVisual(_ result: @escaping FlutterResult,
      operation: @escaping (LocalCardScanner) throws -> Any) {
    guard pendingVisual < 8 else {
      result(FlutterError(code: "scanner_queue_full", message: "Too many images are waiting for analysis.", details: nil))
      return
    }
    let worker: LocalCardScanner = visualScanner
    pendingVisual += 1
    visualWork.async {
      let output: Any
      do {
        output = try autoreleasepool { try operation(worker) }
      } catch VisualError.degenerateFeatures {
        output = NSNull()
      } catch {
        output = FlutterError(code: "recognition_failed", message: error.localizedDescription, details: nil)
      }
      DispatchQueue.main.async {
        self.pendingVisual -= 1
        result(output)
      }
    }
  }

  private func perform(_ result: @escaping FlutterResult,
      operation: @escaping () throws -> Any) {
    let pending = PendingWork(result: result, operation: operation)
    if busy {
      if foreground.count < 8 {
        foreground.append(pending)
      } else {
        result(FlutterError(code: "scanner_queue_full", message: "Too many images are waiting for analysis.", details: nil))
      }
      return
    }
    start(pending)
  }

  private func start(_ pending: PendingWork) {
    busy = true
    work.async {
      do {
        let output = try autoreleasepool { try pending.operation() }
        DispatchQueue.main.async { self.finish(pending, output: output) }
      } catch VisualError.degenerateFeatures {
        DispatchQueue.main.async { self.finish(pending, output: NSNull()) }
      } catch {
        let output = FlutterError(code: "recognition_failed", message: error.localizedDescription, details: nil)
        DispatchQueue.main.async { self.finish(pending, output: output) }
      }
    }
  }

  private func finish(_ pending: PendingWork, output: Any) {
    busy = false
    pending.result(output)
    if !foreground.isEmpty { start(foreground.removeFirst()) }
  }

  private func performLiveFrame(_ arguments: [String: Any], result: @escaping FlutterResult) {
    guard !liveBusy else {
      result(FlutterError(code: "scanner_busy", message: "Image analysis is already running.", details: nil))
      return
    }
    liveBusy = true
    liveWork.async {
      let output: Any
      do {
        output = try autoreleasepool { try self.detectFrame(arguments) }
      } catch {
        output = FlutterError(code: "recognition_failed", message: error.localizedDescription, details: nil)
      }
      DispatchQueue.main.async {
        self.liveBusy = false
        result(output)
      }
    }
  }

  private struct ExcludedRegion {
    let id: String
    let corners: [CGPoint]
  }

  private func frameRegions(_ arguments: [String: Any], key: String) throws -> [ExcludedRegion] {
    guard let raw = arguments[key] else { return [] }
    guard let entries = raw as? [[String: Any]], entries.count <= 8 else {
      throw ScanError.unreadableImage
    }
    var ids = Set<String>()
    return try entries.map { entry in
      guard let id = entry["id"] as? String, !id.isEmpty, id.count <= 128,
            id.trimmingCharacters(in: .whitespacesAndNewlines) == id, ids.insert(id).inserted,
            id.rangeOfCharacter(from: .controlCharacters) == nil,
            let points = entry["corners"] as? [[String: Any]], points.count == 4 else {
        throw ScanError.unreadableImage
      }
      let corners: [CGPoint] = try points.map { point in
        guard let x = point["x"] as? Double, let y = point["y"] as? Double,
              x.isFinite, y.isFinite, x >= 0, x <= 1, y >= 0, y <= 1 else {
          throw ScanError.unreadableImage
        }
        return CGPoint(x: x, y: 1 - y)
      }
      var direction: CGFloat?
      for index in corners.indices {
        let first = corners[index]
        let second = corners[(index + 1) % 4]
        let third = corners[(index + 2) % 4]
        let cross = (second.x - first.x) * (third.y - second.y)
          - (second.y - first.y) * (third.x - second.x)
        guard abs(cross) >= 0.000001,
              direction == nil || cross * direction! > 0 else { throw ScanError.unreadableImage }
        direction = cross
      }
      guard polygonArea(corners) >= 0.0001 else { throw ScanError.unreadableImage }
      return ExcludedRegion(id: id, corners: corners)
    }
  }

  private func sampledRegions(_ arguments: [String: Any], excluded: [ExcludedRegion]) throws -> [ExcludedRegion] {
    let appearances = try frameRegions(arguments, key: "appearanceRegions")
    var combined = excluded
    for region in appearances {
      if let existing = combined.first(where: { $0.id == region.id }) {
        guard existing.corners == region.corners else { throw ScanError.unreadableImage }
      } else {
        combined.append(region)
      }
    }
    guard combined.count <= 8 else { throw ScanError.unreadableImage }
    return combined
  }

  private func rectangleCorners(_ rectangle: VNRectangleObservation) -> [CGPoint] {
    [rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
  }

  private func polygonArea(_ points: [CGPoint]) -> CGFloat {
    guard points.count >= 3 else { return 0 }
    let signed = points.indices.reduce(CGFloat(0)) { value, index in
      let next = points[(index + 1) % points.count]
      return value + points[index].x * next.y - next.x * points[index].y
    }
    return abs(signed) / 2
  }

  private func polygonIntersection(_ subject: [CGPoint], _ clip: [CGPoint]) -> CGFloat {
    guard subject.count >= 3, clip.count == 4 else { return 0 }
    let signed = clip.indices.reduce(CGFloat(0)) { value, index in
      let next = clip[(index + 1) % clip.count]
      return value + clip[index].x * next.y - next.x * clip[index].y
    }
    let direction: CGFloat = signed >= 0 ? 1 : -1
    var polygon = subject
    for index in clip.indices {
      guard !polygon.isEmpty else { return 0 }
      let start = clip[index]
      let end = clip[(index + 1) % clip.count]
      func distance(_ point: CGPoint) -> CGFloat {
        direction * ((end.x - start.x) * (point.y - start.y)
          - (end.y - start.y) * (point.x - start.x))
      }
      var output: [CGPoint] = []
      var previous = polygon.last!
      var previousDistance = distance(previous)
      for point in polygon {
        let currentDistance = distance(point)
        if (currentDistance >= 0) != (previousDistance >= 0) {
          let fraction = previousDistance / (previousDistance - currentDistance)
          output.append(CGPoint(x: previous.x + fraction * (point.x - previous.x),
            y: previous.y + fraction * (point.y - previous.y)))
        }
        if currentDistance >= 0 { output.append(point) }
        previous = point
        previousDistance = currentDistance
      }
      polygon = output
    }
    return polygonArea(polygon)
  }

  private func matchesExcluded(_ corners: [CGPoint], _ region: ExcludedRegion) -> Bool {
    let observed = polygonArea(corners)
    let original = polygonArea(region.corners)
    guard observed > 0, original > 0 else { return false }
    let overlap = polygonIntersection(corners, region.corners)
    let ratio = observed / original
    // Inner artwork/type panels prove current presence without replacing the outside footprint.
    return (ratio >= 0.12 && ratio <= 1.10 && overlap / observed >= 0.90)
      || (ratio >= 0.55 && ratio <= 1.80 && overlap / (observed + original - overlap) >= 0.55)
  }

  private func appearanceSamples(_ image: CIImage, regions: [ExcludedRegion],
      observations: [[CGPoint]]) -> [[String: Any]] {
    regions.map { region in
      let present = observations.contains { matchesExcluded($0, region) }
      let values = appearanceValues(image, corners: region.corners)
      return ["id": region.id, "corners": region.corners.map(pointMap),
        "present": present && values.count == 288, "values": values]
    }
  }

  func savedTargetAppearances(_ image: CIImage, regions: [[CGPoint]]) -> [[String: Any]] {
    guard regions.count <= 8, !image.extent.isEmpty, !image.extent.isInfinite,
          image.extent.width.isFinite, image.extent.height.isFinite else { return [] }
    return regions.compactMap { corners in
      guard corners.count == 4, corners.allSatisfy({
        $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1
      }), polygonArea(corners) >= 0.0004, SavedCardProjection(corners: corners) != nil else { return nil }
      let values: [Double] = appearanceValues(image, corners: corners)
      let valid: Bool = values.count == 288 && values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
      return ["corners": corners.map(pointMap), "present": valid, "values": valid ? values : []]
    }
  }

  private func appearanceValues(_ image: CIImage, corners: [CGPoint]) -> [Double] {
    guard let corrected = image.applyingFilter("CIPerspectiveCorrection", parameters: [
      "inputTopLeft": vector(corners[0], in: image),
      "inputTopRight": vector(corners[1], in: image),
      "inputBottomRight": vector(corners[2], in: image),
      "inputBottomLeft": vector(corners[3], in: image),
    ]).finiteImage else { return [] }
    let crop = normalized(corrected)
    guard crop.extent.width > 0, crop.extent.height > 0 else { return [] }
    let scale = 12 / crop.extent.height
    let small = crop.applyingFilter("CILanczosScaleTransform", parameters: [
      kCIInputScaleKey: scale,
      kCIInputAspectRatioKey: (8 / crop.extent.width) / scale,
    ])
    var pixels = [UInt8](repeating: 0, count: 8 * 12 * 4)
    pixels.withUnsafeMutableBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      context.render(small, toBitmap: base, rowBytes: 8 * 4,
        bounds: CGRect(x: 0, y: 0, width: 8, height: 12), format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB())
    }
    var values: [Double] = []
    values.reserveCapacity(288)
    for row in 0..<12 {
      for column in 0..<8 {
        let offset = (row * 8 + column) * 4
        for channel in 0..<3 { values.append(Double(pixels[offset + channel]) / 255) }
      }
    }
    return values
  }

  private func maskingCompleted(_ image: CIImage, excluded: [ExcludedRegion]) -> CIImage {
    var masked = image
    for region in excluded {
      // A one-pixel mask interpolates its transparent edges across the card.
      let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))
        .samplingNearest()
        .applyingFilter("CIPerspectiveTransform", parameters: [
          "inputTopLeft": vector(region.corners[0], in: image),
          "inputTopRight": vector(region.corners[1], in: image),
          "inputBottomRight": vector(region.corners[2], in: image),
          "inputBottomLeft": vector(region.corners[3], in: image),
        ])
      masked = black.composited(over: masked).cropped(to: image.extent)
    }
    return masked
  }

  private func completedCard(_ card: [String: Any], excluded: [ExcludedRegion]) -> Bool {
    guard let points = card["corners"] as? [[String: Double]], points.count == 4 else { return false }
    let corners: [CGPoint] = points.compactMap { point in
      guard let x = point["x"], let y = point["y"] else { return nil }
      return CGPoint(x: x, y: 1 - y)
    }
    guard corners.count == 4 else { return false }
    return excluded.contains { matchesExcluded(corners, $0) }
  }

  private func frameImage(_ arguments: [String: Any]) throws -> CIImage {
    guard let data = arguments["bytes"] as? FlutterStandardTypedData,
          let width = arguments["width"] as? Int, let height = arguments["height"] as? Int,
          let stride = arguments["bytesPerRow"] as? Int,
          arguments["format"] as? String == "bgra8888",
          width > 0, height > 0, width <= 4096, height <= 4096,
          stride >= width * 4, stride <= data.data.count / height else {
      throw ScanError.unreadableImage
    }
    var image = CIImage(bitmapData: data.data, bytesPerRow: stride,
      size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: .BGRA8,
      colorSpace: CGColorSpaceCreateDeviceRGB())
    let rotation = arguments["rotation"] as? Int ?? 0
    guard [0, 90, 180, 270].contains(rotation) else { throw ScanError.unreadableImage }
    switch rotation {
    case 90: image = image.oriented(.right)
    case 180: image = image.oriented(.down)
    case 270: image = image.oriented(.left)
    default: break
    }
    return normalized(image)
  }

  private func liveRectangles(_ detection: CIImage) throws -> [VNRectangleObservation] {
    let request = VNDetectRectanglesRequest()
    request.minimumAspectRatio = 0.50
    request.maximumAspectRatio = 0.90
    request.minimumConfidence = 0.65
    request.minimumSize = 0.055
    request.quadratureTolerance = 35
    request.maximumObservations = 16
    try VNImageRequestHandler(ciImage: detection, orientation: .up).perform([request])
    let sorted = (request.results ?? []).sorted {
      $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height
    }
    var accepted: [VNRectangleObservation] = []
    for rectangle in sorted {
      let area = rectangle.boundingBox.width * rectangle.boundingBox.height
      guard area > 0.003 else { continue }
      let nested = accepted.contains { existing in
        let overlap = existing.boundingBox.intersection(rectangle.boundingBox)
        return !overlap.isNull && overlap.width * overlap.height / area > 0.65
      }
      if !nested { accepted.append(rectangle) }
      if accepted.count == 8 { break }
    }
    return accepted
  }

  private func detectFrame(_ arguments: [String: Any]) throws -> [String: Any] {
    let started: TimeInterval = ProcessInfo.processInfo.systemUptime
    let image = try frameImage(arguments)
    let excluded = try frameRegions(arguments, key: "excludedRegions")
    let sampled = try sampledRegions(arguments, excluded: excluded)
    let prepared: TimeInterval = ProcessInfo.processInfo.systemUptime
    let detection = bounded(image, edge: 960)
    let accepted = try liveRectangles(detection)
    let detected: TimeInterval = ProcessInfo.processInfo.systemUptime
    let rotation = arguments["rotation"] as? Int ?? 0
    let width = arguments["width"] as? Int ?? 0
    let height = arguments["height"] as? Int ?? 0
    let includeText = arguments["includeText"] as? Bool ?? false
    let includePartialDiagnostics = arguments["includePartialDiagnostics"] as? Bool ?? false
    let lightingRecoveryEnabled: Bool = !(includePartialDiagnostics
      && arguments["disableLightingRecovery"] as? Bool == true)
    var partialDiagnostics: [String: Any] = [:]
    let ocrImage = excluded.isEmpty ? image : maskingCompleted(image, excluded: excluded)
    let readable = accepted.indices.filter { index in
      !excluded.contains { matchesExcluded(rectangleCorners(accepted[index]), $0) }
    }
    let selected = readable.isEmpty ? Set<Int>() : Set((0..<min(2, readable.count)).map {
      readable[(liveOcrOffset + $0) % readable.count]
    })
    if includeText && !readable.isEmpty { liveOcrOffset = (liveOcrOffset + 2) % readable.count }
    var textCardCount: Int = 0
    var orientationRetryCount: Int = 0
    var enhancedRetryCount: Int = 0
    var enhancedRetrySeconds: Double = 0
    let recordRecovery: (String, Double) -> Void = { _, milliseconds in
      enhancedRetryCount += 1
      enhancedRetrySeconds += milliseconds / 1000
    }
    var focusCandidates: [[String: Any]] = []
    var cards: [[String: Any]] = try accepted.enumerated().map { index, rectangle in
      try autoreleasepool {
        let corners = [rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
        var lines: [[String: Any]] = []
        var warnings: [String] = []
        var lighting: CardLighting?
        var lightingAttempted: Bool = false
        let recordCardRecovery: (String, Double) -> Void = { phase, milliseconds in
          lightingAttempted = true
          recordRecovery(phase, milliseconds)
        }
        if let corrected = image.applyingFilter("CIPerspectiveCorrection", parameters: [
             "inputTopLeft": vector(rectangle.topLeft, in: image),
             "inputTopRight": vector(rectangle.topRight, in: image),
             "inputBottomRight": vector(rectangle.bottomRight, in: image),
             "inputBottomLeft": vector(rectangle.bottomLeft, in: image),
           ]).finiteImage {
          let crop: CIImage = normalized(corrected)
          let aspect: CGFloat = crop.extent.width / crop.extent.height
          if aspect >= 0.58 && aspect <= 0.84 { lighting = textBandLighting(crop) }
          if rectangle.boundingBox.width * rectangle.boundingBox.height >= 0.01 {
            var candidate: [String: Any] = ["corners": corners.map(pointMap), "confidence": Double(rectangle.confidence),
              "sharpness": imageSharpness(crop), "warnings": ["geometry_only"]]
            if let lighting { candidate["lighting"] = lighting.map }
            focusCandidates.append(candidate)
          }
          if includeText && selected.contains(index) {
            var textCrop = crop
            if !excluded.isEmpty {
              guard let correctedText = ocrImage.applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": vector(rectangle.topLeft, in: ocrImage),
                "inputTopRight": vector(rectangle.topRight, in: ocrImage),
                "inputBottomRight": vector(rectangle.bottomRight, in: ocrImage),
                "inputBottomLeft": vector(rectangle.bottomLeft, in: ocrImage),
              ]).finiteImage else {
                return ["corners": corners.map(pointMap), "confidence": Double(rectangle.confidence),
                  "lines": lines, "warnings": ["no_text"]]
              }
              textCrop = normalized(correctedText)
            }
            textCardCount += 1
            lines = try liveTextLines(textCrop, recoverLighting: lighting != nil && lightingRecoveryEnabled,
              recordRecovery: recordCardRecovery)
            if (nameplateScore(lines) == 0 || footerScore(lines) == 0 || !hasCardLayout(lines))
                && !liveUprightLayoutSupported(lines) {
              orientationRetryCount += 1
              let alternate = try liveTextLines(normalized(textCrop.oriented(.down)),
                recoverLighting: lighting != nil && lightingRecoveryEnabled && !lightingAttempted,
                recordRecovery: recordCardRecovery)
              if orientationScore(alternate) > orientationScore(lines) {
                lines = alternate
                textCrop = normalized(textCrop.oriented(.down))
              }
            }
            if !(nameplateScore(lines) > 0 && hasCardLayout(lines)), bodyOrientationScore(lines) == 0,
                canProbeLiveOrientation(lines),
                let recovered = try recoveredLiveOrientation(textCrop, seedLines: lines,
                  recoverLighting: lighting != nil && lightingRecoveryEnabled && !lightingAttempted,
                  recordRecovery: recordCardRecovery) {
              lines = recovered.lines
              warnings.append("orientation_ensemble")
              if recovered.geometryAdjusted { warnings.append("geometry_adjusted") }
            }
            if nameplateScore(lines) == 0 { warnings.append("incomplete_card") }
            if crop.extent.height < 500 { warnings.append("small_image") }
            if hasLightingTitleConflict(lines) { warnings.append("lighting_title_conflict") }
          }
        }
        var card: [String: Any] = ["corners": corners.map(pointMap), "confidence": Double(rectangle.confidence),
          "lines": lines, "warnings": warnings]
        if let lighting { card["lighting"] = lighting.map }
        if includePartialDiagnostics {
          card["uprightBodyLayout"] = strongUprightBodyLayout(lines)
          if let corrected = image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": vector(rectangle.topLeft, in: image), "inputTopRight": vector(rectangle.topRight, in: image),
            "inputBottomRight": vector(rectangle.bottomRight, in: image), "inputBottomLeft": vector(rectangle.bottomLeft, in: image)
          ]).finiteImage {
            let upright: CIImage = normalized(corrected)
            card["lightingBands"] = [
              "title": lightingSummary(lightingPixels(upright, region: CGRect(x: 0.04, y: 0.88, width: 0.92, height: 0.10)))?.map ?? [:],
              "footer": lightingSummary(lightingPixels(upright, region: CGRect(x: 0.04, y: 0.02, width: 0.92, height: 0.12)))?.map ?? [:],
            ]
          }
        }
        return card
      }
    }
    let analyzed: TimeInterval = ProcessInfo.processInfo.systemUptime
    let key = "\(arguments["cameraName"] as? String ?? ""):\(arguments["sourceWidth"] as? Int ?? width):\(arguments["sourceHeight"] as? Int ?? height):\(rotation)"
    if includePartialDiagnostics {
      partialDiagnostics["sourceReset"] = key != partialFrameKey
      partialDiagnostics["previousPartialCount"] = livePartials.count
    }
    if key != partialFrameKey {
      partialFrameKey = key
      livePartials.removeAll()
      partialSequence = VNSequenceRequestHandler()
      lastPartialOCR = -Double.infinity
    }
    livePartials.removeAll { partial in
      let corners = [CGPoint(x: partial.observation.boundingBox.minX, y: partial.observation.boundingBox.maxY),
        CGPoint(x: partial.observation.boundingBox.maxX, y: partial.observation.boundingBox.maxY),
        CGPoint(x: partial.observation.boundingBox.maxX, y: partial.observation.boundingBox.minY),
        CGPoint(x: partial.observation.boundingBox.minX, y: partial.observation.boundingBox.minY)]
      return excluded.contains { matchesExcluded(corners, $0) }
    }
    let covered = cards.compactMap { card -> CGRect? in
      let lines = card["lines"] as? [[String: Any]] ?? []
      guard nameplateScore(lines) > 0 && hasCardLayout(lines) else { return nil }
      return cropRegion(card, cornersKey: "corners")
    }
    let now = ProcessInfo.processInfo.systemUptime
    if includePartialDiagnostics {
      partialDiagnostics["now"] = now
      partialDiagnostics["sincePartialOCR"] = lastPartialOCR.isFinite ? now - lastPartialOCR : -1
      partialDiagnostics["coveredCount"] = covered.count
      partialDiagnostics["partialAges"] = livePartials.map { now - $0.verifiedAt }
    }
    if includeText && now - lastPartialOCR >= 2 && covered.count < 8 {
      if includePartialDiagnostics { partialDiagnostics["branch"] = "acquire" }
      lastPartialOCR = now
      do {
        livePartials = try livePartialDetections(ocrImage, covered: covered,
          limit: 8 - covered.count, now: now)
      } catch {
        if includePartialDiagnostics {
          let failure: NSError = error as NSError
          partialDiagnostics["acquisitionError"] = ["domain": failure.domain,
            "code": failure.code, "message": failure.localizedDescription]
        }
        livePartials = []
      }
      livePartials.removeAll { completedCard($0.card, excluded: excluded) }
      partialSequence = VNSequenceRequestHandler()
      mergeLivePartials(livePartials.map { $0.card }, into: &cards)
      let requests = livePartials.map { partial -> VNTrackObjectRequest in
        let request = VNTrackObjectRequest(detectedObjectObservation: partial.observation)
        request.trackingLevel = .accurate
        return request
      }
      if !requests.isEmpty {
        do {
          try partialSequence.perform(requests, on: detection, orientation: .up)
          if includePartialDiagnostics {
            partialDiagnostics["initialTracking"] = requests.map { (request: VNTrackObjectRequest) -> [String: Any] in
              guard let observation = request.results?.first as? VNDetectedObjectObservation else {
                return ["resultCount": request.results?.count ?? 0]
              }
              return ["confidence": Double(observation.confidence), "corners": regionCorners(observation.boundingBox)]
            }
          }
        } catch {
          if includePartialDiagnostics {
            let failure: NSError = error as NSError
            partialDiagnostics["initialTrackingError"] = ["domain": failure.domain,
              "code": failure.code, "message": failure.localizedDescription]
          }
          livePartials.removeAll()
        }
      }
    } else if !livePartials.isEmpty {
      if includePartialDiagnostics { partialDiagnostics["branch"] = "track" }
      mergeLivePartials(trackedPartials(detection, covered: covered, now: now,
        focusCandidates: &focusCandidates, diagnostics: includePartialDiagnostics ? { details in
          partialDiagnostics["tracking"] = details
        } : nil), into: &cards)
    } else if includePartialDiagnostics {
      partialDiagnostics["branch"] = "none"
    }
    for index in cards.indices where completedCard(cards[index], excluded: excluded) {
      cards[index]["lines"] = [[String: Any]]()
    }
    let tracked: TimeInterval = ProcessInfo.processInfo.systemUptime
    let appearances: [[String: Any]] = appearanceSamples(image, regions: sampled,
      observations: accepted.map(rectangleCorners))
    let finished: TimeInterval = ProcessInfo.processInfo.systemUptime
    var output: [String: Any] = ["width": Int(image.extent.width), "height": Int(image.extent.height),
      "rectanglesSupported": true, "geometryOnly": false, "cards": cards, "focusCandidates": focusCandidates,
      "appearanceSamplingSupported": true,
      "appearanceSamples": appearances]
    if includePartialDiagnostics {
      partialDiagnostics["remainingPartialCount"] = livePartials.count
      partialDiagnostics["textCardCount"] = textCardCount
      partialDiagnostics["orientationRetryCount"] = orientationRetryCount
      partialDiagnostics["enhancedRetryCount"] = enhancedRetryCount
      partialDiagnostics["enhancedRetrySeconds"] = enhancedRetrySeconds
      partialDiagnostics["lightingRecoveryEnabled"] = lightingRecoveryEnabled
      partialDiagnostics["partialProcessingSeconds"] = tracked - now
      partialDiagnostics["processingSeconds"] = finished - started
      partialDiagnostics["phaseSeconds"] = ["framePreparation": prepared - started,
        "rectangleDetection": detected - prepared, "cardAnalysis": analyzed - detected,
        "partialAnalysis": tracked - analyzed, "appearanceSampling": finished - tracked]
      output["partialTrackingDiagnostics"] = partialDiagnostics
    }
    return output
  }

  private func mergeLivePartials(_ partials: [[String: Any]], into cards: inout [[String: Any]]) {
    guard !partials.isEmpty else { return }
    let regions = partials.compactMap { cropRegion($0, cornersKey: "corners") }
    cards.removeAll { card in
      let lines = card["lines"] as? [[String: Any]] ?? []
      guard !(nameplateScore(lines) > 0 && hasCardLayout(lines)),
            let region = cropRegion(card, cornersKey: "corners") else { return false }
      return regions.contains { overlapsPartial(region, $0) }
    }
    cards.append(contentsOf: partials.prefix(max(0, 8 - cards.count)))
  }

  private func livePartialDetections(_ image: CIImage, covered: [CGRect], limit: Int,
      now: TimeInterval) throws -> [LivePartial] {
    let anchors = try partialAnchors(image, covered: covered)
    var regions = covered
    var result: [LivePartial] = []
    for anchor in anchors.prefix(3) {
      guard result.count < min(3, limit) else { break }
      guard !regions.contains(where: { overlapsPartial(anchor.region, $0) }) else { continue }
      let region = anchor.region
      let pixels = CGRect(x: region.minX * image.extent.width, y: region.minY * image.extent.height,
        width: region.width * image.extent.width, height: region.height * image.extent.height)
      let crop = normalized(image.cropped(to: pixels))
      guard let lines = try? liveTextLines(crop) else { continue }
      let text = partialText(lines)
      let type: PartialText? = text.first(where: { $0.confidence >= 0.8 && $0.box.minY >= 0.28
          && $0.box.minY < 0.65 && $0.box.height < 0.11 && isCardType($0.text)
          && normalizedCardText($0.text) == normalizedCardText(anchor.type.text) })
      let body: [PartialText] = type.map { (type: PartialText) in
        text.filter { (line: PartialText) in
          line.confidence >= 0.8 && isCardBody(line.text) && line.box.minY >= type.box.maxY
            && line.box.minY < 0.86 && line.box.height < 0.20
            && abs(line.box.minX - type.box.minX) < 0.18 && line.box.width >= type.box.width * 0.60
        }
      } ?? []
      let title: PartialText? = text.first(where: { $0.confidence >= 0.85 && $0.box.minY < 0.13
        && $0.box.minX < 0.6 && $0.box.width >= 0.1 && $0.box.height < 0.07
        && matchesPartialTitle($0, proposed: anchor.title.text, body: body) })
      guard let title, let type, !body.isEmpty, title.box.maxY < type.box.minY else { continue }
      let card: [String: Any] = ["corners": regionCorners(region), "confidence": min(title.confidence, type.confidence),
        "rectified": false, "lines": lines, "sharpness": imageSharpness(crop),
        "warnings": ["partial_card", "incomplete_card", "no_card_rectangle"]]
      result.append(LivePartial(observation: VNDetectedObjectObservation(boundingBox: region),
        seed: region, card: card, verifiedAt: now))
      regions.append(region)
    }
    return result
  }

  private func trackedPartials(_ image: CIImage, covered: [CGRect], now: TimeInterval,
      focusCandidates: inout [[String: Any]], diagnostics: (([String: Any]) -> Void)? = nil) -> [[String: Any]] {
    let beforeExpiry: Int = livePartials.count
    livePartials.removeAll { now - $0.verifiedAt > 3 }
    var details: [String: Any] = ["expiredCount": beforeExpiry - livePartials.count]
    var observations: [[String: Any]] = []
    defer {
      if diagnostics != nil {
        details["observations"] = observations
        diagnostics?(details)
      }
    }
    let requests = livePartials.map { partial -> VNTrackObjectRequest in
      let request = VNTrackObjectRequest(detectedObjectObservation: partial.observation)
      request.trackingLevel = .accurate
      return request
    }
    guard !requests.isEmpty else { return [] }
    do { try partialSequence.perform(requests, on: image, orientation: .up) }
    catch {
      if diagnostics != nil {
        let failure: NSError = error as NSError
        details["error"] = ["domain": failure.domain, "code": failure.code, "message": failure.localizedDescription]
      }
      livePartials.removeAll()
      return []
    }
    var retained: [LivePartial] = []
    var cards: [[String: Any]] = []
    for (index, request) in requests.enumerated() {
      var partial = livePartials[index]
      var evidence: [String: Any] = [:]
      if diagnostics != nil {
        evidence = ["seed": regionCorners(partial.seed),
          "previous": regionCorners(partial.observation.boundingBox), "age": now - partial.verifiedAt]
      }
      guard let observation = request.results?.first as? VNDetectedObjectObservation else {
        if diagnostics != nil {
          evidence["rejected"] = "no_observation"
          evidence["resultCount"] = request.results?.count ?? 0
          observations.append(evidence)
        }
        continue
      }
      if diagnostics != nil {
        evidence["confidence"] = Double(observation.confidence)
        evidence["current"] = regionCorners(observation.boundingBox)
      }
      guard observation.confidence >= 0.85 else {
        if diagnostics != nil { evidence["rejected"] = "confidence"; observations.append(evidence) }
        continue
      }
      let region = observation.boundingBox
      let scale = region.width * region.height / (partial.seed.width * partial.seed.height)
      let dx: CGFloat = abs(region.midX - partial.observation.boundingBox.midX)
      let dy: CGFloat = abs(region.midY - partial.observation.boundingBox.midY)
      let overlap: Bool = covered.contains(where: { overlapsPartial(region, $0) })
      let inside: Bool = region.minX >= 0 && region.minY >= 0 && region.maxX <= 1 && region.maxY <= 1
      let validScale: Bool = scale >= 0.6 && scale <= 1.6
      let validMotion: Bool = dx < 0.12 && dy < 0.12
      let rejected: String? = !inside ? "outside_frame" : !validScale ? "scale"
        : !validMotion ? "motion" : overlap ? "covered" : nil
      if diagnostics != nil {
        evidence["scale"] = Double(scale)
        evidence["dx"] = Double(dx)
        evidence["dy"] = Double(dy)
        evidence["rejected"] = rejected ?? "accepted"
        observations.append(evidence)
      }
      guard rejected == nil else { continue }
      partial.observation = observation
      retained.append(partial)
      focusCandidates.append(["corners": regionCorners(region), "confidence": Double(observation.confidence),
        "lines": [[String: Any]](), "warnings": ["geometry_only", "tracked_partial"]])
      var card = partial.card
      card["corners"] = regionCorners(region)
      card["confidence"] = Double(observation.confidence)
      card["lines"] = [[String: Any]]()
      cards.append(card)
    }
    livePartials = retained
    return cards
  }

  private func regionCorners(_ region: CGRect) -> [[String: Double]] {
    [CGPoint(x: region.minX, y: region.maxY), CGPoint(x: region.maxX, y: region.maxY),
      CGPoint(x: region.maxX, y: region.minY), CGPoint(x: region.minX, y: region.minY)].map(pointMap)
  }

  func liveUprightLayoutSupported(_ lines: [[String: Any]]) -> Bool {
    guard lines.contains(where: { line in
      (line["confidence"] as? Double ?? 0) >= 0.85 && nameplateScore([line]) > 0
    }) else { return false }
    return strongUprightBodyLayout(lines)
  }

  func liveNamedLayoutSupported(_ lines: [[String: Any]]) -> Bool {
    let horizontal: [[String: Any]] = lines.filter { line in
      guard let row: PartialText = partialText([line]).first else { return false }
      return row.confidence >= 0.85 && row.box.height > 0 && row.box.height < 0.10
        && row.box.width >= row.box.height * 2
    }
    return nameplateScore(horizontal) > 0 && hasCardLayout(horizontal)
  }

  private func strongUprightBodyLayout(_ lines: [[String: Any]]) -> Bool {
    let body: [[String: Any]] = lines.filter { orientationTypeMinimumRows($0) == nil }
    return lines.contains { line in
      guard let text: String = line["text"] as? String, isCardType(text),
            (line["confidence"] as? Double ?? 0) >= 0.85 else { return false }
      return bodyOrientationScore([line] + body) > 0
    }
  }

  private func liveTextLines(_ image: CIImage, recoverLighting: Bool = false,
      recordRecovery: ((String, Double) -> Void)? = nil) throws -> [[String: Any]] {
    let text = VNRecognizeTextRequest()
    text.recognitionLevel = .accurate
    text.usesLanguageCorrection = true
    text.minimumTextHeight = 0.008
    configureCardTextLanguages(text)
    try VNImageRequestHandler(ciImage: image, orientation: .up).perform([text])
    let footer = VNRecognizeTextRequest()
    footer.recognitionLevel = .accurate
    footer.usesLanguageCorrection = false
    footer.minimumTextHeight = 0.008
    let region = CGRect(x: 0, y: 0, width: image.extent.width, height: image.extent.height * 0.30)
    try VNImageRequestHandler(ciImage: normalized(image.cropped(to: region)), orientation: .up).perform([footer])
    let names = try nameplateTextLines(image)
    let observations = recognizedLines(text.results ?? [],
      region: CGRect(x: 0, y: 0, width: 1, height: 1), imageAspect: image.extent.width / image.extent.height)
      + recognizedLines(footer.results ?? [], region: CGRect(x: 0, y: 0, width: 1, height: 0.30), imageAspect: image.extent.width / image.extent.height) + names
    var merged: [[String: Any]] = []
    for line in observations {
      guard let text = line["text"] as? String, let box = line["bounds"] as? [String: Double] else { continue }
      merged.removeAll { prior in
        guard let priorText = prior["text"] as? String, let priorBox = prior["bounds"] as? [String: Double] else { return false }
        return normalizedCardText(priorText) == normalizedCardText(text)
          && abs((priorBox["y"] ?? 1) - (box["y"] ?? 0)) < 0.02
          && abs((priorBox["x"] ?? 1) - (box["x"] ?? 0)) < 0.08
      }
      merged.append(line)
    }
    if recoverLighting {
      if let recovered = try? recoverWashedOutText(image, lines: merged, recordTiming: recordRecovery) {
        merged = recovered.lines
      }
    }
    return Array(merged.prefix(64))
  }

  private func recoveredLiveOrientation(_ image: CIImage,
      seedLines: [[String: Any]], recoverLighting: Bool = false,
      recordRecovery: ((String, Double) -> Void)? = nil) throws -> (lines: [[String: Any]], geometryAdjusted: Bool)? {
    var best: (image: CIImage, geometryAdjusted: Bool, typeLines: [[String: Any]])?
    var score = 0
    for orientation: CGImagePropertyOrientation in [.up, .down, .left, .right] {
      var candidate = normalized(image.oriented(orientation))
      let ratio = candidate.extent.width / candidate.extent.height
      let adjusted = ratio < 0.58 || ratio > 0.84
      if adjusted {
        candidate = canonicalCardAspect(candidate)
      }
      let lines = try orientationTextLines(candidate)
      let named: Bool = liveNamedLayoutSupported(lines)
      var observed: [[String: Any]] = lines + rotatedObservedTypeLines(seedLines, orientation: orientation)
      var typeLines: [[String: Any]] = corroboratedActualTypeLines(observed)
      if !named && typeLines.isEmpty && liveTypeBandBodySupported(observed) {
        let verifiedTypes: [[String: Any]] = try liveTypeBandText(candidate, bodyLines: observed)
        observed += verifiedTypes
        typeLines = verifiedTypes
      }
      guard named || !typeLines.isEmpty else { continue }
      let candidateScore: Int = max(named ? orientationScore(lines) : 0, bodyOrientationScore(observed))
      if candidateScore > score { best = (candidate, adjusted, typeLines); score = candidateScore }
    }
    guard let best else { return nil }
    let verified = try liveTextLines(best.image, recoverLighting: recoverLighting,
      recordRecovery: recordRecovery) + best.typeLines
    guard liveNamedLayoutSupported(verified) || !corroboratedActualTypeLines(verified).isEmpty else { return nil }
    return (verified + observedOrientationTypeAlternatives(verified), best.geometryAdjusted)
  }

  func liveTypeBandBodySupported(_ lines: [[String: Any]]) -> Bool {
    let body: [PartialText] = partialText(lines).filter { row in
      row.confidence >= 0.85 && isCardBody(row.text) && !isCardFooter(row.text)
        && row.box.minX < 0.65 && row.box.minY >= 0.50 && row.box.minY < 0.86
        && row.box.height > 0 && row.box.height < 0.10 && row.box.width >= 0.20
        && row.box.width >= row.box.height * 2
    }
    let rulesWords: Set<String> = ["opponent", "opponents", "token", "tokens", "sacrifice", "damage",
      "spell", "spells", "creature", "creatures", "life", "mana", "nonland", "battlefield", "graveyard",
      "prevent", "source", "draw", "discard", "counter"]
    for anchor: PartialText in body {
      var rows: [PartialText] = []
      for row: PartialText in body.filter({ abs($0.box.minX - anchor.box.minX) < 0.18 })
          .sorted(by: { $0.box.midY < $1.box.midY }) {
        if !rows.contains(where: { prior in
          normalizedCardText(prior.text) == normalizedCardText(row.text)
            || abs(prior.box.midY - row.box.midY) < max(0.012, min(prior.box.height, row.box.height) * 0.6)
        }) { rows.append(row) }
      }
      guard rows.count >= 3 else { continue }
      let words: Set<String> = Set(rows.flatMap {
        $0.text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
      })
      if words.intersection(rulesWords).count >= 2 { return true }
    }
    return false
  }

  func verifiedLiveTypeBandLines(_ observations: [[String: Any]],
      bodyLines: [[String: Any]]) -> [[String: Any]] {
    guard liveTypeBandBodySupported(bodyLines) else { return [] }
    var verified: [[String: Any]] = []
    for raw: [String: Any] in observations {
      guard let observed: PartialText = partialText([raw]).first else { continue }
      let alternatives: [String] = raw["alternatives"] as? [String] ?? []
      let confidences: [Double] = raw["alternativeConfidences"] as? [Double] ?? []
      let literal: [(String, Double)] = [(observed.text, observed.confidence)]
        + alternatives.enumerated().compactMap { index, value in
          index < confidences.count ? (value, confidences[index]) : nil
        }
      for (value, confidence): (String, Double) in literal where confidence >= 0.85 && isCardType(value) {
        var type: [String: Any] = raw
        type["text"] = value
        type["confidence"] = confidence
        type["orientationCorroboration"] = true
        guard bodyOrientationScore([type] + bodyLines) > 0 else { continue }
        if !verified.contains(where: { previous in
          previous["text"] as? String == value && (previous["bounds"] as? [String: Double]) == (type["bounds"] as? [String: Double])
        }) { verified.append(type) }
      }
    }
    let identities: Set<String> = Set(verified.compactMap { ($0["text"] as? String).map(normalizedCardText) })
    return identities.count == 1 ? verified : []
  }

  private func liveTypeBandText(_ image: CIImage,
      bodyLines: [[String: Any]]) throws -> [[String: Any]] {
    let region: CGRect = CGRect(x: 0, y: 0.35, width: 1, height: 0.30)
    let pixels: CGRect = CGRect(x: 0, y: image.extent.height * region.minY,
      width: image.extent.width, height: image.extent.height * region.height)
    let band: CIImage = bounded(normalized(image.cropped(to: pixels))
      .transformed(by: CGAffineTransform(scaleX: 2, y: 2)), edge: 4096)
    let request: VNRecognizeTextRequest = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.008
    configureCardTextLanguages(request)
    try VNImageRequestHandler(ciImage: band, orientation: .up).perform([request])
    let observations: [[String: Any]] = recognizedLines(request.results ?? [], region: region,
      imageAspect: image.extent.width / image.extent.height)
    return verifiedLiveTypeBandLines(observations, bodyLines: bodyLines)
  }

  private func nameplateTextLines(_ image: CIImage) throws -> [[String: Any]] {
    let region = CGRect(x: 0, y: image.extent.height * 0.76,
      width: image.extent.width, height: image.extent.height * 0.24)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.008
    configureCardTextLanguages(request)
    try VNImageRequestHandler(ciImage: bounded(normalized(image.cropped(to: region)), edge: 4096),
      orientation: .up).perform([request])
    return recognizedLines(request.results ?? [], region: CGRect(x: 0, y: 0.76, width: 1, height: 0.24), imageAspect: image.extent.width / image.extent.height)
  }

  private func enhancedNameplateTextLines(_ image: CIImage) throws -> [[String: Any]] {
    let region: CGRect = CGRect(x: 0, y: 0.88, width: 0.86, height: 0.12)
    let pixels: CGRect = CGRect(x: image.extent.minX, y: image.extent.minY + image.extent.height * region.minY,
      width: image.extent.width * region.width, height: image.extent.height * region.height)
    let crop: CIImage = bounded(normalized(image.cropped(to: pixels))
      .transformed(by: CGAffineTransform(scaleX: 3, y: 3))
      .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0, "inputContrast": 2.0])
      .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.5]), edge: 4096)
    let request: VNRecognizeTextRequest = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.008
    configureCardTextLanguages(request)
    try VNImageRequestHandler(ciImage: crop, orientation: .up).perform([request])
    return recognizedLines(request.results ?? [], region: region,
      imageAspect: image.extent.width / image.extent.height).filter { line in
        guard let value: String = line["text"] as? String else { return false }
        return isCardTitle(value) && nameplateScore([line]) > 0
    }
  }

  func savedCardLayout(_ lines: [[String: Any]]) -> Bool {
    if hasCardLayout(lines) { return true }
    guard nameplateScore(lines) > 0, savedFooterSupported(lines) else { return false }
    return savedBasicLandTypeSupported(lines)
  }

  private func savedBasicLandTypeSupported(_ lines: [[String: Any]]) -> Bool {
    let basicTypes: [PartialText] = partialText(lines).filter { row in
      row.confidence >= 0.85 && row.box.minX < 0.65 && row.box.minY >= 0.35
        && row.box.minY < 0.90 && row.box.height > 0 && row.box.height < 0.08
        && row.text.range(of: #"^Basic\s+(?:Snow\s+)?Land(?:\s*[—–-]\s*[A-Za-z ]+)?$"#,
          options: [.regularExpression, .caseInsensitive]) != nil
    }
    return Set(basicTypes.map { normalizedCardText($0.text) }).count == 1
  }

  func savedUprightTextSupported(_ lines: [[String: Any]]) -> Bool {
    guard lines.contains(where: { row in
      guard let observed: PartialText = partialText([row]).first else { return false }
      return nameplateScore([row]) > 0 && observed.confidence >= 0.50
        && observed.box.width >= observed.box.height * 2
    }) else { return false }
    return savedHorizontalRulesSupported(lines)
  }

  private func savedHorizontalRulesSupported(_ lines: [[String: Any]]) -> Bool {
    if japaneseCardLayout(lines) { return true }
    let gameplay: String = #"^(?:\d+\s*[:;,.]\s*)?(?:target\s+(?:creature|artifact|land|player|spell|permanent)\b|prevent\b.*\bdamage\b|(?:draw|discard)\b.*\bcards?\b|(?:return|exile|destroy|sacrifice)\b.*\b(?:cards?|creatures?|artifacts?|permanents?)\b|(?:choose|create|put)\b.*\b(?:target|token|card)\b|(?:each|whenever|when|you|your|this|enchanted|equipped)\b.*\b(?:creature|card|damage|life|mana|counter)\b)"#
    let rows: [PartialText] = partialText(lines).filter { row in
      row.confidence >= 0.85 && isCardBody(row.text) && !isCardFooter(row.text)
        && row.box.minX < 0.65 && row.box.minY >= 0.50 && row.box.maxY <= 0.93
        && row.box.height > 0 && row.box.height < 0.08 && row.box.width >= 0.20
        && row.box.width >= row.box.height * 4
        && row.text.range(of: gameplay, options: [.regularExpression, .caseInsensitive]) != nil
    }
    let words: Set<String> = Set(rows.flatMap {
      $0.text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    })
    let rules: Set<String> = ["target", "creature", "creatures", "artifact", "artifacts", "card", "cards",
      "damage", "source", "prevent", "draw", "discard", "mana", "counter", "counters", "graveyard",
      "battlefield", "banding", "opponent", "life", "token"]
    return words.intersection(rules).count >= 2
  }

  func verifiedSavedTypeBandLines(_ observations: [[String: Any]],
      bodyLines: [[String: Any]]) -> [[String: Any]] {
    let body: [PartialText] = partialText(bodyLines).filter { row in
      row.confidence >= 0.65 && isCardBody(row.text) && !isCardFooter(row.text)
        && row.box.minX < 0.65 && row.box.minY >= 0.50 && row.box.minY < 0.90
        && row.box.height > 0 && row.box.height < 0.10 && row.box.width >= 0.20
    }
    let words: Set<String> = Set(body.flatMap {
      $0.text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    })
    let rules: Set<String> = ["target", "creature", "creatures", "damage", "source", "prevent", "draw",
      "discard", "mana", "counter", "counters", "graveyard", "battlefield", "banding", "opponent", "life"]
    guard words.intersection(rules).count >= 2 else { return [] }
    let verified: [[String: Any]] = observations.filter { raw in
      guard let row: PartialText = partialText([raw]).first else { return false }
      return row.confidence >= 0.65 && isCardType(row.text) && row.box.minX < 0.65
        && row.box.minY >= 0.35 && row.box.minY < 0.75 && row.box.height > 0
        && row.box.height < 0.08 && hasCardLayout([raw] + bodyLines)
    }
    return Set(verified.compactMap { ($0["text"] as? String).map(normalizedCardText) }).count == 1 ? verified : []
  }

  private func savedTypeBandText(_ image: CIImage,
      bodyLines: [[String: Any]]) throws -> [[String: Any]] {
    let region: CGRect = CGRect(x: 0, y: 0.30, width: 0.90, height: 0.35)
    let pixels: CGRect = CGRect(x: 0, y: image.extent.height * region.minY,
      width: image.extent.width * region.width, height: image.extent.height * region.height)
    let band: CIImage = bounded(normalized(image.cropped(to: pixels))
      .transformed(by: CGAffineTransform(scaleX: 3, y: 3))
      .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0, "inputContrast": 2.0])
      .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.5]), edge: 4096)
    let request: VNRecognizeTextRequest = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.008
    try VNImageRequestHandler(ciImage: band, orientation: .up).perform([request])
    return verifiedSavedTypeBandLines(recognizedLines(request.results ?? [], region: region,
      imageAspect: image.extent.width / image.extent.height), bodyLines: bodyLines)
  }

  func lightingSummary(_ rgba: [UInt8]) -> CardLighting? {
    guard !rgba.isEmpty, rgba.count % 4 == 0, rgba.count <= 128 * 128 * 4 else { return nil }
    var histogram: [Int] = Array(repeating: 0, count: 256)
    var count: Int = 0
    var highlights: Int = 0
    var shadows: Int = 0
    var sum: Double = 0
    for index: Int in stride(from: 0, to: rgba.count, by: 4) where rgba[index + 3] == 255 {
      let red: Double = Double(rgba[index]) / 255
      let green: Double = Double(rgba[index + 1]) / 255
      let blue: Double = Double(rgba[index + 2]) / 255
      let low: Double = min(red, min(green, blue))
      let high: Double = max(red, max(green, blue))
      let luminance: Double = 0.2126 * red + 0.7152 * green + 0.0722 * blue
      histogram[min(255, max(0, Int((luminance * 255).rounded())))] += 1
      if low >= 0.97 && high - low <= 0.03 { highlights += 1 }
      if luminance <= 0.10 { shadows += 1 }
      sum += luminance
      count += 1
    }
    guard count > 0 else { return nil }
    func percentile(_ fraction: Double) -> Double {
      let target: Int = max(1, Int(ceil(Double(count) * fraction)))
      var total: Int = 0
      for index: Int in histogram.indices {
        total += histogram[index]
        if total >= target { return Double(index) / 255 }
      }
      return 1
    }
    return CardLighting(highlightFraction: Double(highlights) / Double(count),
      shadowFraction: Double(shadows) / Double(count), meanLuminance: min(1, max(0, sum / Double(count))),
      contrast: max(0, percentile(0.90) - percentile(0.10)), sampleCount: count,
      darkPoint: percentile(0.01), lightPoint: percentile(0.99))
  }

  func selectingTextBandLighting(_ bands: [[UInt8]]) -> CardLighting? {
    let washed: [CardLighting] = bands.compactMap(lightingSummary).filter { $0.washedOut }
    if let worst: CardLighting = washed.max(by: { $0.highlightFraction < $1.highlightFraction }) { return worst }
    return lightingSummary(bands.flatMap { $0 })
  }

  func washedTextRecoveryAllowed(_ lighting: CardLighting) -> Bool {
    let range: Double = lighting.lightPoint - lighting.darkPoint
    return lighting.valid && lighting.sampleCount >= 64 && lighting.meanLuminance >= 0.78
      && lighting.contrast <= 0.20 && lighting.shadowFraction <= 0.04
      && lighting.highlightFraction < 0.98 && range > 0 && range <= 1 / 1.5
  }

  func lightingContrastParameters(_ lighting: CardLighting) -> (gain: Double, bias: Double)? {
    guard washedTextRecoveryAllowed(lighting), lighting.lightPoint > lighting.darkPoint else { return nil }
    let gain: Double = min(16, 1 / (lighting.lightPoint - lighting.darkPoint))
    return (gain, 1 - lighting.lightPoint * gain)
  }

  private func lightingPixels(_ image: CIImage, region: CGRect) -> [UInt8] {
    let pixels: CGRect = CGRect(x: image.extent.minX + region.minX * image.extent.width,
      y: image.extent.minY + region.minY * image.extent.height,
      width: region.width * image.extent.width, height: region.height * image.extent.height)
    let thumbnail: CIImage = bounded(normalized(image.cropped(to: pixels)), edge: 128)
    let width: Int = Int(ceil(thumbnail.extent.width))
    let height: Int = Int(ceil(thumbnail.extent.height))
    guard width > 0, height > 0, width <= 128, height <= 128 else { return [] }
    var rgba: [UInt8] = Array(repeating: 0, count: width * height * 4)
    rgba.withUnsafeMutableBytes { bytes in
      guard let base: UnsafeMutableRawPointer = bytes.baseAddress else { return }
      context.render(thumbnail, toBitmap: base, rowBytes: width * 4,
        bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB())
    }
    return rgba
  }

  func textBandLighting(_ image: CIImage) -> CardLighting? {
    selectingTextBandLighting([
      lightingPixels(image, region: CGRect(x: 0.04, y: 0.88, width: 0.92, height: 0.10)),
      lightingPixels(image, region: CGRect(x: 0.04, y: 0.02, width: 0.92, height: 0.12)),
    ])
  }

  private func recoverWashedOutText(_ image: CIImage, lines: [[String: Any]],
      recordTiming: ((String, Double) -> Void)?) throws -> (lines: [[String: Any]], titleAttempted: Bool) {
    let aspect: CGFloat = image.extent.width / image.extent.height
    guard aspect >= 0.58 && aspect <= 0.84 else { return (lines, false) }
    guard strongUprightBodyLayout(lines) else { return (lines, false) }
    let titleRegion: CGRect = CGRect(x: 0.04, y: 0.88, width: 0.92, height: 0.10)
    let footerRegion: CGRect = CGRect(x: 0.04, y: 0.02, width: 0.92, height: 0.12)
    let titleLighting: CardLighting? = lightingSummary(lightingPixels(image, region: titleRegion))
    let titleContrast: (gain: Double, bias: Double)? = titleLighting.flatMap(lightingContrastParameters)
    let titleRetry: Bool = titleContrast != nil
    let region: CGRect = titleRetry ? titleRegion : footerRegion
    guard let contrast = titleContrast ?? lightingSummary(lightingPixels(image, region: footerRegion))
      .flatMap(lightingContrastParameters) else { return (lines, false) }
    let pixels: CGRect = CGRect(x: image.extent.minX + region.minX * image.extent.width,
      y: image.extent.minY + region.minY * image.extent.height,
      width: region.width * image.extent.width, height: region.height * image.extent.height)
    let adjusted: CIImage = bounded(normalized(image.cropped(to: pixels))
      .applyingFilter("CILinearToSRGBToneCurve")
      .applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0.2126 * contrast.gain, y: 0.7152 * contrast.gain, z: 0.0722 * contrast.gain, w: 0),
        "inputGVector": CIVector(x: 0.2126 * contrast.gain, y: 0.7152 * contrast.gain, z: 0.0722 * contrast.gain, w: 0),
        "inputBVector": CIVector(x: 0.2126 * contrast.gain, y: 0.7152 * contrast.gain, z: 0.0722 * contrast.gain, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: contrast.bias, y: contrast.bias, z: contrast.bias, w: 0),
      ])
      .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
      .applyingFilter("CISRGBToneCurveToLinear")
      .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": titleRetry ? 3.0 : 2.0,
        "inputAspectRatio": 1.0])
      .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": titleRetry ? 0.35 : 0]), edge: 2048)
    let observed: [[String: Any]] = try timedSavedPhase("lighting-\(titleRetry ? "title" : "footer")", record: recordTiming) {
      let request: VNRecognizeTextRequest = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = titleRetry
      if titleRetry { configureCardTextLanguages(request) }
      request.minimumTextHeight = 0.008
      try VNImageRequestHandler(ciImage: adjusted, orientation: .up).perform([request])
      return recognizedLines(request.results ?? [], region: region,
        imageAspect: image.extent.width / image.extent.height).map { raw in
          var row: [String: Any] = raw
          row["ocrEnhancement"] = "highlight_contrast"
          return row
        }
    }
    if titleRetry {
      return (mergingLightingTitleLines(observed, into: lines), true)
    }
    return (mergingFooterLines(observed, into: lines), false)
  }

  func mergingLightingTitleLines(_ candidates: [[String: Any]], into lines: [[String: Any]]) -> [[String: Any]] {
    let originalTitles: [[String: Any]] = lines.filter {
        nameplateScore([$0]) > 0 && ($0["confidence"] as? Double ?? 0) >= 0.85
      }
    let titles: [[String: Any]] = candidates.filter { nameplateScore([$0]) > 0 }.map { candidate in
        var row: [String: Any] = candidate
        if let processed: PartialText = partialText([candidate]).first, processed.confidence >= 0.85,
            originalTitles.contains(where: { original in
              guard let prior: PartialText = partialText([original]).first else { return false }
              return normalizedCardText(prior.text) != normalizedCardText(processed.text)
                && overlapsPartial(prior.box, processed.box)
            }) {
          row["lightingTitleConflict"] = true
        }
        return row
      }
    return mergingSavedNameplateLines(titles, into: lines)
  }

  private func hasLightingTitleConflict(_ lines: [[String: Any]]) -> Bool {
    lines.contains { $0["lightingTitleConflict"] as? Bool == true }
  }

  private func imageSharpness(_ source: CIImage) -> Double {
    let center = source.cropped(to: source.extent.insetBy(dx: source.extent.width * 0.08,
      dy: source.extent.height * 0.08))
    let image = bounded(normalized(center), edge: 128)
    let width = Int(ceil(image.extent.width))
    let height = Int(ceil(image.extent.height))
    guard width >= 4, height >= 4 else { return 0 }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      context.render(image, toBitmap: base, rowBytes: width * 4,
        bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB())
    }
    var gray = [Double](repeating: 0, count: width * height)
    for index in gray.indices {
      gray[index] = (0.2126 * Double(pixels[index * 4]) + 0.7152 * Double(pixels[index * 4 + 1])
        + 0.0722 * Double(pixels[index * 4 + 2])) / 255
    }
    var sum = 0.0
    var squares = 0.0
    var laplacianSum = 0.0
    var laplacianSquares = 0.0
    for y in 1..<(height - 1) {
      for x in 1..<(width - 1) {
        let index = y * width + x
        let value = gray[index]
        let laplacian = gray[index - 1] + gray[index + 1] + gray[index - width] + gray[index + width] - 4 * value
        sum += value
        squares += value * value
        laplacianSum += laplacian
        laplacianSquares += laplacian * laplacian
      }
    }
    let count = Double((width - 2) * (height - 2))
    let variance = max(0, squares / count - pow(sum / count, 2))
    let laplacianVariance = max(0, laplacianSquares / count - pow(laplacianSum / count, 2))
    return laplacianVariance / (laplacianVariance + variance * 0.5 + 0.001)
  }

  func artworkQueryRegion(_ value: Any?) -> CGRect? {
    guard let value else { return CGRect(x: 0.08, y: 0.14, width: 0.84, height: 0.38) }
    guard let region = value as? [String: Double],
          let x = region["x"], let y = region["y"],
          let width = region["width"], let height = region["height"],
          x.isFinite && y.isFinite && width.isFinite && height.isFinite,
          x >= 0 && y >= 0 && width > 0 && height > 0,
          x + width <= 1 && y + height <= 1 else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
  }

  private func compareArtworkStructure(query: String, reference: String?, referencePixels: [UInt8]?,
      region: CGRect, rotationDegrees: Int, includePixelDiagnostics: Bool) throws -> [String: Any] {
    func queryKey() throws -> StructuralQueryKey {
      var metadata: stat = stat()
      guard FileManager.default.isReadableFile(atPath: query) else { throw ScanError.unreadableImage }
      let descriptor: Int32 = query.withCString { pointer in
        Darwin.open(pointer, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
      }
      guard descriptor >= 0 else { throw ScanError.unreadableImage }
      defer { _ = Darwin.close(descriptor) }
      guard Darwin.fstat(descriptor, &metadata) == 0,
          metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_size > 0 else {
        throw ScanError.unreadableImage
      }
      return StructuralQueryKey(path: query, device: Int64(metadata.st_dev), inode: UInt64(metadata.st_ino),
        size: Int64(metadata.st_size), modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
        modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec), changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
        changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec), x: Double(region.minX), y: Double(region.minY),
        width: Double(region.width), height: Double(region.height), rotation: rotationDegrees)
    }
    func grayscale(_ image: CIImage) throws -> [UInt8] {
      guard let rgba: [UInt8] = raster(bounded(normalized(image), edge: 512),
        edge: ArtworkStructuralMatcher.edge) else { throw ScanError.unreadableImage }
      return stride(from: 0, to: rgba.count, by: 4).map { offset in
        let luma: Double = Double(rgba[offset]) * 0.299 + Double(rgba[offset + 1]) * 0.587
          + Double(rgba[offset + 2]) * 0.114
        return UInt8(min(255, max(0, luma.rounded())))
      }
    }
    let key: StructuralQueryKey = try queryKey()
    let cacheHit: Bool = structuralQueryPixels[key] != nil
    let measuredQuery: [UInt8]
    if let cached: [UInt8] = structuralQueryPixels[key] {
      measuredQuery = cached
      structuralQueryOrder.removeAll { $0 == key }
      structuralQueryOrder.append(key)
    } else {
      let source: Data = try Data(contentsOf: URL(fileURLWithPath: query))
      guard let queryImage: CIImage = CIImage(data: source,
        options: [.applyOrientationProperty: true]) else { throw ScanError.unreadableImage }
      let card: CIImage = normalized(rotationDegrees == 180 ? queryImage.oriented(.down) : queryImage)
      let pixels: CGRect = CGRect(x: card.extent.width * region.minX,
        y: card.extent.height * (1 - region.maxY),
        width: card.extent.width * region.width, height: card.extent.height * region.height)
      measuredQuery = try grayscale(card.cropped(to: pixels))
      guard try queryKey() == key else { throw ScanError.unreadableImage }
      if structuralQueryOrder.count == 16 {
        structuralQueryPixels.removeValue(forKey: structuralQueryOrder.removeFirst())
      }
      structuralQueryPixels[key] = measuredQuery
      structuralQueryOrder.append(key)
    }
    let measuredReference: [UInt8]
    if let referencePixels {
      measuredReference = referencePixels
    } else {
      guard let reference, let referenceImage: CIImage = CIImage(contentsOf: URL(fileURLWithPath: reference),
        options: [.applyOrientationProperty: true]) else { throw ScanError.unreadableImage }
      measuredReference = try grayscale(referenceImage)
    }
    guard let match: ArtworkStructuralMatch = ArtworkStructuralMatcher.match(
      query: measuredQuery, reference: measuredReference) else {
      throw VisualError.degenerateFeatures
    }
    var fields: [String: Any] = match.fields
    fields["region"] = ["x": Double(region.minX), "y": Double(region.minY),
      "width": Double(region.width), "height": Double(region.height)]
    fields["rotationDegrees"] = rotationDegrees
    fields["referenceSchema"] = "gray48-bt601-cg-high-v1"
    fields["referenceDigest"] = SHA256.hash(data: Data(measuredReference)).map { String(format: "%02x", $0) }.joined()
    if includePixelDiagnostics {
      fields["queryRasterCacheHit"] = cacheHit
      fields["referencePixels"] = FlutterStandardTypedData(bytes: Data(measuredReference))
    }
    return fields
  }

  private func compareImages(query: String, reference: String, region: CGRect, monochrome: Bool,
      rotationDegrees: Int = 0) throws -> Double {
    guard let queryImage = CIImage(contentsOf: URL(fileURLWithPath: query), options: [.applyOrientationProperty: true]),
          let referenceImage = CIImage(contentsOf: URL(fileURLWithPath: reference), options: [.applyOrientationProperty: true]) else {
      throw ScanError.unreadableImage
    }
    let card = normalized(rotationDegrees == 180 ? queryImage.oriented(.down) : queryImage)
    let cropRegion = CGRect(x: card.extent.width * region.minX,
      y: card.extent.height * (1 - region.maxY),
      width: card.extent.width * region.width, height: card.extent.height * region.height)
    var queryCrop = bounded(normalized(card.cropped(to: cropRegion)), edge: 512)
    var referenceCrop = bounded(normalized(referenceImage), edge: 512)
    if monochrome {
      let parameters: [String: Any] = [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.5]
      queryCrop = queryCrop.applyingFilter("CIColorControls", parameters: parameters)
      referenceCrop = referenceCrop.applyingFilter("CIColorControls", parameters: parameters)
      guard let queryMask = glyphMask(queryCrop), let referenceMask = glyphMask(referenceCrop) else {
        throw VisualError.degenerateFeatures
      }
      return glyphDistance(queryMask, referenceMask)
    }
    let queryAttributes = try FileManager.default.attributesOfItem(atPath: query)
    let queryModified = (queryAttributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let querySize = (queryAttributes[.size] as? NSNumber)?.int64Value ?? 0
    let queryKey = "\(query):\(queryModified):\(querySize):\(rotationDegrees):\(region.minX):\(region.minY):\(region.width):\(region.height)" as NSString
    let querySignal: ArtworkSignal
    if let cached = artworkQueries.object(forKey: queryKey) {
      querySignal = cached.signal
    } else {
      #if targetEnvironment(simulator)
      querySignal = .descriptor(try artworkDescriptor(queryCrop))
      #else
      if let generated = try generateFeatures(queryCrop), validFeatures(generated) {
        querySignal = .feature(generated)
      } else {
        querySignal = .descriptor(try artworkDescriptor(queryCrop))
      }
      #endif
      artworkQueries.setObject(ArtworkQuery(querySignal), forKey: queryKey)
    }
    if case .descriptor(let queryDescriptor) = querySignal {
      let referenceDescriptor = try artworkDescriptor(referenceCrop)
      let squared = zip(queryDescriptor, referenceDescriptor).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) }
      return sqrt(squared / Double(queryDescriptor.count))
    }
    guard case .feature(let queryPrint) = querySignal else { throw ScanError.unreadableImage }
    let attributes = try FileManager.default.attributesOfItem(atPath: reference)
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let key = "\(reference):\(monochrome):\(modified):\(size)" as NSString
    let referencePrint: VNFeaturePrintObservation
    if let cached = referenceFeatures.object(forKey: key) {
      referencePrint = cached
    } else {
      guard let generated = try generateFeatures(referenceCrop) else { throw VisualError.degenerateFeatures }
      guard validFeatures(generated) else { throw VisualError.degenerateFeatures }
      referenceFeatures.setObject(generated, forKey: key)
      referencePrint = generated
    }
    var distance: Float = 0
    try queryPrint.computeDistance(&distance, to: referencePrint)
    guard distance.isFinite && distance >= 0 else { throw ScanError.unreadableImage }
    return Double(distance)
  }

  private enum VisualError: Error { case degenerateFeatures }

  private func generateFeatures(_ image: CIImage) throws -> VNFeaturePrintObservation? {
    do {
      let request = VNGenerateImageFeaturePrintRequest()
      request.imageCropAndScaleOption = .scaleFit
      try configureFeaturePrintCompute(request)
      try VNImageRequestHandler(ciImage: image, orientation: .up).perform([request])
      guard let generated = request.results?.first else { throw ScanError.unreadableImage }
      return generated
    } catch let error as NSError {
      var unavailable: Set<Int> = [VNErrorCode.operationFailed.rawValue, VNErrorCode.notImplemented.rawValue,
        VNErrorCode.internalError.rawValue, VNErrorCode.invalidModel.rawValue,
        VNErrorCode.unsupportedRevision.rawValue, VNErrorCode.unsupportedRequest.rawValue]
      if #available(iOS 17.0, *) {
        unavailable.insert(VNErrorCode.unsupportedComputeStage.rawValue)
        unavailable.insert(VNErrorCode.unsupportedComputeDevice.rawValue)
      }
      if error.domain == VNErrorDomain && unavailable.contains(error.code) {
        #if DEBUG
        print("Vision feature backend unavailable: \(error.domain), code \(error.code)")
        #endif
        return nil
      }
      throw error
    }
  }

  private func enhancedBodyTypeTextLines(_ image: CIImage, lines: [[String: Any]],
      recordOrientation: (([String: Any]) -> Void)? = nil) throws -> [[String: Any]] {
    let supportingBody: [[String: Any]] = lines.filter { line in
      guard let value: String = line["text"] as? String else { return false }
      return isCardBody(value) && orientationTypeMinimumRows(line) == nil
    }
    guard let raw: [String: Any] = lines.first(where: { line in
      orientationTypeMinimumRows(line) == 3 && bodyOrientationScore([line] + supportingBody) > 0
    }), let type: PartialText = partialText([raw]).first else { return [] }
    let left: CGFloat = max(0, type.box.minX - 0.04)
    let right: CGFloat = min(1, type.box.maxX + 0.04)
    let top: CGFloat = max(0, type.box.minY - 0.015)
    let bottom: CGFloat = min(1, type.box.maxY + 0.015)
    let region: CGRect = CGRect(x: left, y: 1 - bottom, width: right - left, height: bottom - top)
    let pixels: CGRect = CGRect(x: image.extent.minX + image.extent.width * region.minX,
      y: image.extent.minY + image.extent.height * region.minY,
      width: image.extent.width * region.width, height: image.extent.height * region.height)
    let enhanced: CIImage = bounded(normalized(image.cropped(to: pixels))
      .transformed(by: CGAffineTransform(scaleX: 2, y: 2))
      .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0, "inputContrast": 1.2]), edge: 4096)
    let request: VNRecognizeTextRequest = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.008
    configureCardTextLanguages(request)
    try VNImageRequestHandler(ciImage: enhanced, orientation: .up).perform([request])
    let observations: [[String: Any]] = recognizedLines(request.results ?? [], region: region,
      imageAspect: image.extent.width / image.extent.height)
    recordOrientation?(["phase": "type_roi", "originalType": type.text,
      "width": Int(enhanced.extent.width), "height": Int(enhanced.extent.height), "lines": observations])
    var literal: [[String: Any]] = observations.filter { line in
      guard let value: String = line["text"] as? String else { return false }
      return isCardType(value) && (line["confidence"] as? Double ?? 0) >= 0.85
    }
    literal.append(contentsOf: observedOrientationTypeAlternatives(observations + supportingBody))
    return literal
  }

  private func rotatedObservedTypeLines(_ lines: [[String: Any]],
      orientation: CGImagePropertyOrientation) -> [[String: Any]] {
    var result: [[String: Any]] = []
    for raw: [String: Any] in lines {
      guard let value: String = raw["text"] as? String,
            let box: PartialText = partialText([raw]).first else { continue }
      let alternatives: [String] = raw["alternatives"] as? [String] ?? []
      let confidences: [Double] = raw["alternativeConfidences"] as? [Double] ?? []
      let literal: [(text: String, confidence: Double)] =
        (isCardType(value) && box.confidence >= 0.85 ? [(value, box.confidence)] : [])
        + alternatives.enumerated().compactMap { index, candidate in
          guard index < confidences.count, confidences[index] >= 0.85, isCardType(candidate) else { return nil }
          return (candidate, confidences[index])
        }
      guard !literal.isEmpty else { continue }
      let bounds: CGRect
      switch orientation {
      case .up: bounds = box.box
      case .down:
        bounds = CGRect(x: 1 - box.box.maxX, y: 1 - box.box.maxY,
          width: box.box.width, height: box.box.height)
      case .left:
        bounds = CGRect(x: box.box.minY, y: 1 - box.box.maxX,
          width: box.box.height, height: box.box.width)
      case .right:
        bounds = CGRect(x: 1 - box.box.maxY, y: box.box.minX,
          width: box.box.height, height: box.box.width)
      default: continue
      }
      var mapped: [String: Any] = raw
      mapped["bounds"] = ["x": Double(bounds.minX), "y": Double(bounds.minY),
        "width": Double(bounds.width), "height": Double(bounds.height)]
      mapped.removeValue(forKey: "glyphHeight")
      mapped["orientationCorroboration"] = true
      if !isCardType(value) { result.append(mapped) }
      for candidate in literal {
        var observed: [String: Any] = mapped
        observed["text"] = candidate.text
        observed["confidence"] = candidate.confidence
        observed["alternatives"] = [value]
        observed["alternativeConfidences"] = [box.confidence]
        result.append(observed)
      }
    }
    return result
  }

  private func corroboratedActualTypeLines(_ lines: [[String: Any]]) -> [[String: Any]] {
    let body: [[String: Any]] = lines.filter { line in
      guard let value: String = line["text"] as? String else { return false }
      return isCardBody(value) && orientationTypeMinimumRows(line) == nil
    }
    return rotatedObservedTypeLines(lines, orientation: .up).filter { line in
      guard let value: String = line["text"] as? String, isCardType(value) else { return false }
      return bodyOrientationScore([line] + body) > 0
    }
  }

  private func canProbeLiveOrientation(_ lines: [[String: Any]]) -> Bool {
    let text: [PartialText] = partialText(lines)
    if text.filter({ $0.confidence >= 0.8 && isCardBody($0.text) }).count >= 2 { return true }
    let longTypes: [String] = ["enchantment", "planeswalker"]
    guard let suspected: PartialText = lines.compactMap({ raw -> PartialText? in
      guard let row: PartialText = partialText([raw]).first, row.confidence >= 0.85 else { return nil }
      if orientationTypeMinimumRows(raw) != nil { return row }
      let word: String = row.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return word.count >= 6 && word.count <= 12 && word.allSatisfy({ $0.isLetter })
        && longTypes.contains(where: { word.hasPrefix(String($0.prefix(6))) }) ? row : nil
    }).first else { return false }
    var rows: [PartialText] = []
    for row: PartialText in text {
      guard row.confidence >= 0.85 && row.text.filter({ $0.isLetter }).count >= 3,
            !isCardFooter(row.text), normalizedCardText(row.text) != normalizedCardText(suspected.text),
            row.box.width > 0 && row.box.height > 0 else { continue }
      if !rows.contains(where: { previous in
        normalizedCardText(previous.text) == normalizedCardText(row.text)
          || hypot(Double(previous.box.midX - row.box.midX), Double(previous.box.midY - row.box.midY)) < 0.02
      }) { rows.append(row) }
    }
    return rows.count >= (isCardType(suspected.text) ? 2 : 3)
  }

  private func raster(_ image: CIImage, edge: Int) -> [UInt8]? {
    let image = normalized(image)
    guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
    var pixels = [UInt8](repeating: 255, count: edge * edge * 4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard let canvas = CGContext(data: bytes.baseAddress, width: edge, height: edge,
        bitsPerComponent: 8, bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
      canvas.setFillColor(UIColor.white.cgColor)
      canvas.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
      canvas.interpolationQuality = .high
      canvas.draw(cgImage, in: CGRect(x: 0, y: 0, width: edge, height: edge))
      return true
    }
    return rendered ? pixels : nil
  }

  private func artworkDescriptor(_ image: CIImage) throws -> [Double] {
    let edge = 64
    guard let pixels = raster(image, edge: edge) else { throw ScanError.unreadableImage }
    let variation = (0..<3).map { channel -> Int in
      let values = stride(from: channel, to: pixels.count, by: 4).map { Int(pixels[$0]) }
      return (values.max() ?? 0) - (values.min() ?? 0)
    }.max() ?? 0
    guard variation > 12 else { throw ScanError.unreadableImage }
    var descriptor: [Double] = []
    for cellY in 0..<8 {
      for cellX in 0..<8 {
        var channels = [Double](repeating: 0, count: 3)
        var gradient = 0.0
        for y in (cellY * 8)..<((cellY + 1) * 8) {
          for x in (cellX * 8)..<((cellX + 1) * 8) {
            let offset = (y * edge + x) * 4
            for channel in 0..<3 { channels[channel] += Double(pixels[offset + channel]) / 255 }
            if x + 1 < edge {
              for channel in 0..<3 { gradient += abs(Double(pixels[offset + channel]) - Double(pixels[offset + 4 + channel])) / (255 * 3) }
            }
            if y + 1 < edge {
              for channel in 0..<3 { gradient += abs(Double(pixels[offset + channel]) - Double(pixels[offset + edge * 4 + channel])) / (255 * 3) }
            }
          }
        }
        descriptor.append(contentsOf: channels.map { $0 / 64 })
        descriptor.append(gradient / 128)
      }
    }
    return descriptor
  }

  private func glyphMask(_ image: CIImage) -> [Bool]? {
    let edge = 128
    guard let pixels = raster(image, edge: edge) else { return nil }
    let gray = (0..<(edge * edge)).map { index in
      let offset = index * 4
      return (Double(pixels[offset]) * 0.299 + Double(pixels[offset + 1]) * 0.587
        + Double(pixels[offset + 2]) * 0.114) / 255
    }
    let values = gray.sorted()
    let border = (0..<edge).flatMap { coordinate in
      [gray[coordinate], gray[(edge - 1) * edge + coordinate], gray[coordinate * edge], gray[coordinate * edge + edge - 1]]
    }.sorted()
    let uniformBorder = border[border.count * 3 / 4] - border[border.count / 4] < 0.05
    let background = uniformBorder ? border[border.count / 2] : values[values.count / 2]
    var mask = gray.map { abs($0 - background) > 0.15 }
    // Type-bar outlines crossing the crop edge are not part of the set glyph.
    var visited = [Bool](repeating: false, count: mask.count)
    for start in mask.indices where mask[start] && !visited[start] {
      var component = [start]
      var offset = 0
      var touchesEdge = false
      var componentMinX = edge
      var componentMinY = edge
      var componentMaxX = 0
      var componentMaxY = 0
      visited[start] = true
      while offset < component.count {
        let index = component[offset]
        offset += 1
        let x = index % edge
        let y = index / edge
        componentMinX = min(componentMinX, x)
        componentMinY = min(componentMinY, y)
        componentMaxX = max(componentMaxX, x)
        componentMaxY = max(componentMaxY, y)
        if x == 0 || y == 0 || x == edge - 1 || y == edge - 1 { touchesEdge = true }
        for dy in -1...1 {
          for dx in -1...1 where dx != 0 || dy != 0 {
            let nextX = x + dx
            let nextY = y + dy
            guard nextX >= 0, nextX < edge, nextY >= 0, nextY < edge else { continue }
            let next = nextY * edge + nextX
            if mask[next] && !visited[next] {
              visited[next] = true
              component.append(next)
            }
          }
        }
      }
      if touchesEdge || component.count < 16
          || componentMaxX - componentMinX < 2 || componentMaxY - componentMinY < 2 {
        for index in component { mask[index] = false }
      }
    }
    let foreground = mask.filter { $0 }.count
    guard foreground >= 16, foreground < edge * edge * 3 / 4 else { return nil }
    var minX = edge
    var minY = edge
    var maxX = 0
    var maxY = 0
    for index in mask.indices where mask[index] {
      let x = index % edge
      let y = index / edge
      minX = min(minX, x); maxX = max(maxX, x)
      minY = min(minY, y); maxY = max(maxY, y)
    }
    let width = maxX - minX + 1
    let height = maxY - minY + 1
    guard width >= 4, height >= 4 else { return nil }
    let correctedWidth = Double(width) * image.extent.width / image.extent.height
    let scale = 112.0 / max(correctedWidth, Double(height))
    let targetWidth = max(1, Int((correctedWidth * scale).rounded()))
    let targetHeight = max(1, Int((Double(height) * scale).rounded()))
    let originX = (edge - targetWidth) / 2
    let originY = (edge - targetHeight) / 2
    var normalized = [Bool](repeating: false, count: edge * edge)
    for y in 0..<targetHeight {
      for x in 0..<targetWidth {
        let sourceX = minX + min(width - 1, x * width / targetWidth)
        let sourceY = minY + min(height - 1, y * height / targetHeight)
        normalized[(originY + y) * edge + originX + x] = mask[sourceY * edge + sourceX]
      }
    }
    return normalized
  }

  private func glyphDistance(_ query: [Bool], _ reference: [Bool]) -> Double {
    let edge = 128
    func contours(_ mask: [Bool]) -> [Bool] {
      mask.indices.map { index in
        guard mask[index] else { return false }
        let x = index % edge
        let y = index / edge
        return x == 0 || y == 0 || x == edge - 1 || y == edge - 1
          || !mask[index - 1] || !mask[index + 1]
          || !mask[index - edge] || !mask[index + edge]
      }
    }
    func distances(_ contour: [Bool]) -> [Double] {
      var result = contour.map { $0 ? 0.0 : Double(edge * 2) }
      for y in 0..<edge {
        for x in 0..<edge {
          let index = y * edge + x
          if x > 0 { result[index] = min(result[index], result[index - 1] + 1) }
          if y > 0 { result[index] = min(result[index], result[index - edge] + 1) }
          if x > 0 && y > 0 { result[index] = min(result[index], result[index - edge - 1] + sqrt(2)) }
          if x + 1 < edge && y > 0 { result[index] = min(result[index], result[index - edge + 1] + sqrt(2)) }
        }
      }
      for y in stride(from: edge - 1, through: 0, by: -1) {
        for x in stride(from: edge - 1, through: 0, by: -1) {
          let index = y * edge + x
          if x + 1 < edge { result[index] = min(result[index], result[index + 1] + 1) }
          if y + 1 < edge { result[index] = min(result[index], result[index + edge] + 1) }
          if x + 1 < edge && y + 1 < edge { result[index] = min(result[index], result[index + edge + 1] + sqrt(2)) }
          if x > 0 && y + 1 < edge { result[index] = min(result[index], result[index + edge - 1] + sqrt(2)) }
        }
      }
      return result
    }
    let queryEdges = contours(query)
    let referenceEdges = contours(reference)
    let queryDistances = distances(queryEdges)
    let referenceDistances = distances(referenceEdges)
    let queryMean = queryEdges.indices.filter { queryEdges[$0] }
      .map { referenceDistances[$0] }.reduce(0, +) / Double(queryEdges.filter { $0 }.count)
    let referenceMean = referenceEdges.indices.filter { referenceEdges[$0] }
      .map { queryDistances[$0] }.reduce(0, +) / Double(referenceEdges.filter { $0 }.count)
    return (queryMean + referenceMean) / Double(edge * 2)
  }

  private func validFeatures(_ observation: VNFeaturePrintObservation) -> Bool {
    guard observation.elementType == .float, observation.elementCount > 1,
          observation.data.count >= observation.elementCount * MemoryLayout<Float>.size else { return false }
    let range: (Float, Float)? = observation.data.withUnsafeBytes { bytes in
      var minimum = Float.infinity
      var maximum = -Float.infinity
      for index in 0..<observation.elementCount {
        let value = bytes.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.size, as: Float.self)
        guard value.isFinite else { return nil }
        minimum = min(minimum, value)
        maximum = max(maximum, value)
      }
      return (minimum, maximum)
    }
    #if DEBUG
    if let range { print("Vision feature vector: \(observation.elementCount) elements, range \(range.0)...\(range.1)") }
    #endif
    guard let range else { return false }
    return range.0 < range.1 && (range.0 != 0 || range.1 != 0)
  }

  private func configureFeaturePrintCompute(_ request: VNGenerateImageFeaturePrintRequest) throws {
    #if targetEnvironment(simulator)
    if #available(iOS 17.0, *) {
      for (stage, devices) in try request.supportedComputeStageDevices {
        if let cpu = devices.first(where: { device in
          if case .cpu = device { return true }
          return false
        }) { request.setComputeDevice(cpu, for: stage) }
      }
    } else {
      request.usesCPUOnly = true
    }
    #endif
  }

  private func timedSavedPhase<Output>(_ phase: String, record: ((String, Double) -> Void)?,
      operation: () throws -> Output) rethrows -> Output {
    guard let record else { return try operation() }
    let started: TimeInterval = ProcessInfo.processInfo.systemUptime
    defer { record(phase, (ProcessInfo.processInfo.systemUptime - started) * 1000) }
    return try operation()
  }

  private func cleanupSavedJobs(_ jobs: [Result<SavedCardJob, Error>]) {
    for result: Result<SavedCardJob, Error> in jobs {
      if case .success(let job) = result, let path = job.crop?["imagePath"] as? String {
        try? FileManager.default.removeItem(atPath: path)
      }
    }
  }

  func savedSceneQuadOwner(_ quad: [CGPoint], cards: [[CGPoint]]) -> Int? {
    guard quad.count == 4, quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
          polygonArea(quad) > 0.0000000001 else { return nil }
    let owners: [Int] = cards.indices.filter { index in
      guard let projection: SavedCardProjection = SavedCardProjection(corners: cards[index]),
            let mapped: [CGPoint] = projection.map(quad) else { return false }
      return mapped.allSatisfy { $0.x >= -0.000001 && $0.x <= 1.000001
        && $0.y >= -0.000001 && $0.y <= 1.000001 }
    }
    guard owners.count == 1, let owner: Int = owners.first else { return nil }
    let tolerance: CGFloat = max(0.000000000001, polygonArea(quad) * 0.000001)
    guard cards.indices.allSatisfy({ $0 == owner || polygonIntersection(quad, cards[$0]) <= tolerance }) else { return nil }
    return owner
  }

  func mappedSavedSceneLine(_ line: [String: Any], quad: [CGPoint], glyph: [CGPoint],
      corners: [CGPoint], rotateRight: Bool = false, imageAspect: CGFloat) -> [String: Any]? {
    guard imageAspect.isFinite, imageAspect > 0,
          let confidence: Double = line["confidence"] as? Double, confidence.isFinite,
          confidence >= 0, confidence <= 1,
          let projection: SavedCardProjection = SavedCardProjection(corners: corners, rotateRight: rotateRight),
          let mapped: [CGPoint] = projection.map(quad),
          let letters: [CGPoint] = projection.map(glyph),
          mapped.allSatisfy({ $0.x >= -0.000001 && $0.x <= 1.000001
            && $0.y >= -0.000001 && $0.y <= 1.000001 }),
          letters.allSatisfy({ $0.x >= -0.000001 && $0.x <= 1.000001
            && $0.y >= -0.000001 && $0.y <= 1.000001 }) else { return nil }
    let horizontal: CGPoint = CGPoint(x: letters[1].x - letters[0].x, y: letters[1].y - letters[0].y)
    let vertical: CGPoint = CGPoint(x: letters[3].x - letters[0].x, y: letters[3].y - letters[0].y)
    guard horizontal.x > 0, abs(horizontal.y) <= horizontal.x * 0.30,
          vertical.y > 0, abs(vertical.x) <= vertical.y * 0.50 else { return nil }
    guard let left: CGFloat = mapped.map({ $0.x }).min(), let right: CGFloat = mapped.map({ $0.x }).max(),
          let top: CGFloat = mapped.map({ $0.y }).min(), let bottom: CGFloat = mapped.map({ $0.y }).max(),
          right > left, bottom > top else { return nil }
    func height(_ a: CGPoint, _ b: CGPoint) -> Double {
      hypot(Double((a.x - b.x) * imageAspect), Double(a.y - b.y))
    }
    let glyphHeight: Double = (height(letters[0], letters[3]) + height(letters[1], letters[2])) / 2
    guard glyphHeight.isFinite, glyphHeight > 0, glyphHeight < 0.20 else { return nil }
    var result: [String: Any] = line
    result["bounds"] = ["x": Double(max(0, left)), "y": Double(max(0, top)),
      "width": Double(min(1, right) - max(0, left)), "height": Double(min(1, bottom) - max(0, top))]
    result["glyphHeight"] = glyphHeight
    result["sceneGlyphCorners"] = letters.map { ["x": Double($0.x), "y": Double($0.y)] }
    result["sceneSourceGlyphCorners"] = glyph.map { ["x": Double($0.x), "y": Double($0.y)] }
    result["ocrSource"] = "scene"
    return result
  }

  func savedSceneSeed(_ lines: [[String: Any]]) -> SavedSceneSeed {
    let strongBody: Bool = savedHorizontalRulesSupported(lines)
    if strongBody && savedBorderRecoveryNeeded(lines) {
      if nameplateScore(lines) == 0 && savedSceneHasTitleGlyph(lines) { return .unsupported }
      return .borderProbe
    }
    guard nameplateScore(lines) > 0 else { return .unsupported }
    if !hasCardLayout(lines) && savedBasicLandTypeSupported(lines) && !strongBody && !savedNameplateNeedsRead(lines) {
      return savedStrongCollectorObserved(lines) && savedCardLayout(lines) ? .supported : .footer
    }
    guard strongBody, savedUprightTextSupported(lines) else { return .unsupported }
    return savedNameplateNeedsRead(lines) ? .nameplate : .supported
  }

  func savedSceneHasTitleGlyph(_ lines: [[String: Any]]) -> Bool {
    lines.contains { line in
      guard let row: PartialText = partialText([line]).first,
            let height: Double = (line["glyphHeight"] as? Double) ?? (line["bounds"] as? [String: Double])?["height"] else { return false }
      return row.confidence >= 0.30 && row.box.minY >= 0 && row.box.minY < 0.10
        && row.box.minX < 0.60 && row.box.width >= 0.10 && row.box.height > 0 && row.box.height < 0.20
        && height > 0.008 && height < 0.07 && row.text.filter({ $0.isLetter }).count >= 3
        && isCardTitle(row.text) && !isCardType(row.text)
    }
  }

  func savedSceneFooterVerified(_ scene: [[String: Any]], by literalFooter: [[String: Any]]) -> Bool {
    !savedNameplateNeedsRead(scene) && savedBasicLandTypeSupported(scene)
      && savedStrongCollectorObserved(literalFooter) && savedCardLayout(scene + literalFooter)
  }

  func savedScenePoint(_ point: CGPoint, in region: CGRect) -> CGPoint? {
    guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1,
          region.minX.isFinite, region.minY.isFinite, region.width.isFinite, region.height.isFinite,
          region.width > 0, region.height > 0, region.minX >= 0, region.minY >= 0,
          region.maxX <= 1, region.maxY <= 1 else { return nil }
    return CGPoint(x: region.minX + point.x * region.width, y: region.minY + point.y * region.height)
  }

  func savedSceneRegions(_ geometry: [[CGPoint]], imageSize: CGSize) -> [CGRect] {
    guard imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0 else { return [] }
    let valid: [Int] = geometry.indices.filter { SavedCardProjection(corners: geometry[$0]) != nil }
    let areas: [CGFloat] = valid.map { polygonArea(geometry[$0]) }.sorted()
    guard !areas.isEmpty else { return [] }
    let typical: CGFloat = areas[areas.count / 2]
    func bounds(_ corners: [CGPoint]) -> CGRect {
      let x: CGFloat = corners.map({ $0.x }).min() ?? 0
      let y: CGFloat = corners.map({ $0.y }).min() ?? 0
      return CGRect(x: x, y: y, width: (corners.map({ $0.x }).max() ?? x) - x,
        height: (corners.map({ $0.y }).max() ?? y) - y)
    }
    let primary: [Int] = valid.filter { polygonArea(geometry[$0]) >= typical * 0.20 }.sorted {
      bounds(geometry[$0]).midX < bounds(geometry[$1]).midX
    }
    guard !primary.isEmpty else { return [] }
    let split: Int = (primary.count + 1) / 2
    let groups: [[Int]] = primary.count == 1 ? [primary] : [Array(primary.prefix(split)), Array(primary.dropFirst(split))]
    let unit: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    return groups.compactMap { indices in
      let expanded: [CGRect] = indices.map { index in
        let card: CGRect = bounds(geometry[index])
        return card.insetBy(dx: -card.width * 0.08, dy: -card.height * 0.15).intersection(unit)
      }
      guard let first: CGRect = expanded.first else { return nil }
      let region: CGRect = expanded.dropFirst().reduce(first) { $0.union($1) }.intersection(unit)
      let pixels: CGRect = CGRect(x: region.minX * imageSize.width, y: region.minY * imageSize.height,
        width: region.width * imageSize.width, height: region.height * imageSize.height).integral
        .intersection(CGRect(origin: .zero, size: imageSize))
      guard !pixels.isNull, !pixels.isEmpty else { return nil }
      return CGRect(x: pixels.minX / imageSize.width, y: pixels.minY / imageSize.height,
        width: pixels.width / imageSize.width, height: pixels.height / imageSize.height)
    }
  }

  private func savedSceneRows(_ image: CIImage, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> [SavedSceneRow] {
    guard savedScenePoint(CGPoint(x: 0, y: 0), in: region) != nil else { throw ScanError.unreadableImage }
    let pixels: CGRect = CGRect(x: region.minX * image.extent.width, y: region.minY * image.extent.height,
      width: region.width * image.extent.width, height: region.height * image.extent.height)
    let scene: CIImage = normalized(image.cropped(to: pixels))
    let request: VNRecognizeTextRequest = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0.003
    configureCardTextLanguages(request)
    try VNImageRequestHandler(ciImage: bounded(scene, edge: 6144), orientation: .up).perform([request])
    let observations: [VNRecognizedTextObservation] = request.results ?? []
    guard observations.count <= 512 else { return [] }
    return observations.compactMap { observation in
      let candidates: [VNRecognizedText] = observation.topCandidates(3)
      guard let first: VNRecognizedText = candidates.first, !first.string.isEmpty,
            first.confidence.isFinite,
            let glyph: VNRectangleObservation = try? first.boundingBox(for: first.string.startIndex..<first.string.endIndex),
            observation.boundingBox.width > 0, observation.boundingBox.height > 0,
            (rectangleCorners(observation) + rectangleCorners(glyph)).allSatisfy({
              $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1
            }) else { return nil }
      let globalQuad: [CGPoint] = rectangleCorners(observation).compactMap { savedScenePoint($0, in: region) }
      let globalGlyph: [CGPoint] = rectangleCorners(glyph).compactMap { savedScenePoint($0, in: region) }
      guard globalQuad.count == 4, globalGlyph.count == 4,
            let left: CGFloat = globalQuad.map({ $0.x }).min(), let right: CGFloat = globalQuad.map({ $0.x }).max(),
            let bottom: CGFloat = globalQuad.map({ $0.y }).min(), let top: CGFloat = globalQuad.map({ $0.y }).max() else { return nil }
      return SavedSceneRow(line: ["text": first.string, "confidence": Double(first.confidence),
        "alternatives": candidates.dropFirst().map { $0.string },
        "alternativeConfidences": candidates.dropFirst().map { Double($0.confidence) },
        "bounds": ["x": Double(left), "y": Double(1 - top), "width": Double(right - left), "height": Double(top - bottom)],
        "sceneRegion": ["x": Double(region.minX), "y": Double(1 - region.maxY),
          "width": Double(region.width), "height": Double(region.height)]],
        quad: globalQuad, glyph: globalGlyph)
    }
  }

  private func savedSceneCards(_ rows: [SavedSceneRow], image: CIImage,
      geometry: [[CGPoint]], diagnostics: (([String: Any]) -> Void)? = nil) -> [SavedSceneCard] {
    var cards: [SavedSceneCard] = geometry.map { _ in SavedSceneCard() }
    var decisions: [[String: Any]] = []
    let sizes: [CGSize?] = geometry.map { corners in
      guard let corrected: CIImage = image.applyingFilter("CIPerspectiveCorrection", parameters: [
        "inputTopLeft": vector(corners[0], in: image), "inputTopRight": vector(corners[1], in: image),
        "inputBottomRight": vector(corners[2], in: image), "inputBottomLeft": vector(corners[3], in: image)
      ]).finiteImage else { return nil }
      return corrected.extent.size
    }
    for row: SavedSceneRow in rows {
      let owner: Int? = savedSceneQuadOwner(row.quad, cards: geometry)
      let glyphOwner: Int? = savedSceneQuadOwner(row.glyph, cards: geometry)
      var decision: [String: Any] = row.line
      if diagnostics != nil {
        decision["owner"] = owner ?? -1
        decision["glyphOwner"] = glyphOwner ?? -1
        decision["lineQuad"] = row.quad.map(pointMap)
        decision["glyphQuad"] = row.glyph.map(pointMap)
      }
      if let owner, glyphOwner == owner, sizes[owner] != nil {
        let aspect: CGFloat = 63.0 / 88.0
        if let mapped: [String: Any] = mappedSavedSceneLine(row.line, quad: row.quad, glyph: row.glyph,
            corners: geometry[owner], imageAspect: aspect) {
          cards[owner].lines.append(mapped)
          decision["reason"] = "owned"
        } else {
          decision["reason"] = "mapped_orientation_or_geometry"
          if diagnostics != nil,
              let projection: SavedCardProjection = SavedCardProjection(corners: geometry[owner]),
              let mapped: [CGPoint] = projection.map(row.glyph) {
            decision["mappedGlyph"] = mapped.map { ["x": Double($0.x), "y": Double($0.y)] }
          }
        }
        if diagnostics != nil && decisions.count < 96 { decisions.append(decision) }
        continue
      }
      decision["reason"] = owner == nil ? "no_unique_line_owner" : "glyph_owner_mismatch"
      if diagnostics != nil && decisions.count < 96 { decisions.append(decision) }
      guard let value: String = row.line["text"] as? String,
            let confidence: Double = row.line["confidence"] as? Double, confidence >= 0.30 else { continue }
      var probes: [(index: Int, top: Bool, bottom: Bool)] = []
      for index: Int in geometry.indices {
        guard sizes[index] != nil,
              let projection: SavedCardProjection = SavedCardProjection(corners: geometry[index]),
              let mapped: [CGPoint] = projection.map(row.glyph),
              mapped.allSatisfy({ $0.x >= 0.02 && $0.x <= 0.98 && $0.y >= -0.08 && $0.y <= 1.12 }) else { continue }
        let low: CGFloat = mapped.map({ $0.y }).min() ?? 0
        let high: CGFloat = mapped.map({ $0.y }).max() ?? 0
        let top: Bool = low < 0 && high <= 0.10 && isCardTitle(value)
        let bottom: Bool = high > 1 && low >= 0.90 && (hasStructuredFooterCode(value)
          || value.range(of: #"^\s*(?:[CMRULST]\s+)?\d{2,5}[a-z★†]*(?:\s*/\s*\d{2,5})?\s*$"#,
            options: .regularExpression) != nil || isCardFooter(value))
        guard top || bottom, geometry.indices.allSatisfy({ $0 == index
          || polygonIntersection(row.quad, geometry[$0]) <= 0.000000000001 }) else { continue }
        probes.append((index, top, bottom))
      }
      if probes.count == 1, let probe = probes.first {
        cards[probe.index].probeTop = cards[probe.index].probeTop || probe.top
        cards[probe.index].probeBottom = cards[probe.index].probeBottom || probe.bottom
      } else {
        for index: Int in geometry.indices where polygonIntersection(row.quad, geometry[index]) > 0 {
          guard let projection: SavedCardProjection = SavedCardProjection(corners: geometry[index]),
                let mapped: [CGPoint] = projection.map(row.quad),
                mapped.contains(where: { $0.y >= 0.84 && $0.y <= 1.12 }) else { continue }
          cards[index].verifyFooter = true
        }
      }
    }
    diagnostics?(["phase": "saved-scene-observations", "rows": decisions, "rowCount": rows.count])
    return cards
  }

  private func prepareSavedCard(_ image: CIImage, corners: [CGPoint], index: Int,
      photoStarted: TimeInterval, diagnostics: Bool, skipBlankSmallRegion: Bool = false,
      scene: SavedSceneCard? = nil) throws -> SavedCardJob {
    var job: SavedCardJob = SavedCardJob(index: index, crop: nil, diagnostics: [], timings: [])
    let started: TimeInterval = ProcessInfo.processInfo.systemUptime
    guard let corrected = image.applyingFilter("CIPerspectiveCorrection", parameters: [
      "inputTopLeft": vector(corners[0], in: image), "inputTopRight": vector(corners[1], in: image),
      "inputBottomRight": vector(corners[2], in: image), "inputBottomLeft": vector(corners[3], in: image)
    ]).finiteImage else { return job }
    let upright: CIImage = canonicalCardAspect(normalized(corrected))
    if skipBlankSmallRegion {
      let evidence: [String: Any] = savedBlankRegionPixels(upright)
      if diagnostics {
        job.diagnostics.append(["phase": "saved-blank-before-ocr", "cardIndex": index,
          "sourceCorners": corners.map(pointMap), "pixels": evidence])
      }
      if evidence["background"] as? Bool == true {
        if diagnostics {
          job.timings.append(["phase": "card-blank-background", "cardIndex": index,
            "elapsedMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000,
            "finishedAtMilliseconds": (ProcessInfo.processInfo.systemUptime - photoStarted) * 1000])
        }
        return job
      }
    }
    let record: (([String: Any]) -> Void)? = diagnostics ? { entry in
      if job.diagnostics.count < 64 {
        var indexed: [String: Any] = entry
        indexed["cardIndex"] = index
        job.diagnostics.append(indexed)
      }
    } : nil
    let timing: ((String, Double) -> Void)? = diagnostics ? { phase, elapsed in
      if job.timings.count < 48 { job.timings.append(["phase": phase, "cardIndex": index,
        "elapsedMilliseconds": elapsed,
        "finishedAtMilliseconds": (ProcessInfo.processInfo.systemUptime - photoStarted) * 1000]) }
    } : nil
    var seed: SavedSceneSeed = scene.map { savedSceneSeed($0.lines) } ?? .unsupported
    let probeTop: Bool = scene?.probeTop == true && savedNameplateNeedsRead(scene?.lines ?? [])
    let probeBottom: Bool = scene?.probeBottom == true && !savedStrongCollectorObserved(scene?.lines ?? [])
    if (seed != .unsupported || savedHorizontalRulesSupported(scene?.lines ?? [])) && (probeTop || probeBottom) {
      seed = .borderProbe
    }
    record?(["phase": "saved-scene-route", "mode": seed.rawValue, "sourceCorners": corners.map(pointMap),
      "probeTop": probeTop, "probeBottom": probeBottom,
      "verifyFooter": scene?.verifyFooter ?? false, "lines": Array((scene?.lines ?? []).prefix(96))])
    var initialCrop: [String: Any] = try recognizeCrop(upright, sourceCorners: corners.map(pointMap), rectified: true,
      allowRotation: false, deferBorderRecovery: true, deferUnreadText: true,
      sceneLines: seed == .unsupported ? nil : scene?.lines, sceneGeometryOnly: seed == .borderProbe,
      sceneProbeTop: seed != .unsupported && probeTop,
      sceneProbeBottom: seed != .unsupported && probeBottom,
      sceneVerifyFooter: seed != .unsupported && scene?.verifyFooter == true,
      recordOrientation: record, recordTiming: timing)
    let measuredAspect: CGFloat = corrected.extent.width / corrected.extent.height
    if measuredAspect < 0.58 || measuredAspect > 0.84 {
      initialCrop["warnings"] = (initialCrop["warnings"] as? [String] ?? []) + ["geometry_adjusted"]
    }
    job.crop = initialCrop
    if diagnostics {
      let lines: [[String: Any]] = job.crop?["lines"] as? [[String: Any]] ?? []
      job.timings.append(["phase": "card-initial", "cardIndex": index,
        "elapsedMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000,
        "finishedAtMilliseconds": (ProcessInfo.processInfo.systemUptime - photoStarted) * 1000,
        "usableObservedText": savedUprightTextSupported(lines) || savedCardLayout(lines)])
    }
    return job
  }

  private func refineSavedCard(_ initial: SavedCardJob, in image: CIImage, corners sourceCorners: [CGPoint],
      neighboringCorners: [[CGPoint]], allowBorderRepair: Bool, photoStarted: TimeInterval,
      diagnostics: Bool) throws -> SavedCardJob {
    var job: SavedCardJob = initial
    var corners: [CGPoint] = sourceCorners
    guard var crop: [String: Any] = job.crop else { return job }
    var completed: Bool = false
    defer {
      if !completed, let path = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
    }
    let started: TimeInterval = ProcessInfo.processInfo.systemUptime
    let record: (([String: Any]) -> Void)? = diagnostics ? { entry in
      if job.diagnostics.count < 64 {
        var indexed: [String: Any] = entry
        indexed["cardIndex"] = initial.index
        job.diagnostics.append(indexed)
      }
    } : nil
    let timing: ((String, Double) -> Void)? = diagnostics ? { phase, elapsed in
      if job.timings.count < 48 { job.timings.append(["phase": phase, "cardIndex": initial.index,
        "elapsedMilliseconds": elapsed,
        "finishedAtMilliseconds": (ProcessInfo.processInfo.systemUptime - photoStarted) * 1000]) }
    } : nil
    let lines: [[String: Any]] = crop["lines"] as? [[String: Any]] ?? []
    record?(["phase": "saved-border-trigger", "sourceCorners": corners.map(pointMap),
      "needed": savedBorderRecoveryNeeded(lines) || crop["sceneProbeTop"] as? Bool == true
        || crop["sceneProbeBottom"] as? Bool == true, "repairAdmitted": allowBorderRepair,
      "nameplateScore": nameplateScore(lines), "footerSupported": savedFooterSupported(lines),
      "completeFooterObserved": completeSavedFooterObserved(lines), "lines": Array(lines.prefix(96))])
    if allowBorderRepair {
      if let rechecked = try? timedSavedPhase("card-outline-recheck", record: timing, operation: {
        try recheckSavedOutline(crop, in: image, corners: corners, neighboringCorners: neighboringCorners,
          recordOrientation: record, recordTiming: timing)
      }) {
        if let path: String = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
        crop = rechecked.crop
        corners = rechecked.corners
      }
      if let repaired = try? timedSavedPhase("card-border-recovery", record: timing, operation: {
        try recoverSavedBorder(crop, in: image, corners: corners, neighboringCorners: neighboringCorners,
          recordOrientation: record, recordTiming: timing)
      }) {
        if let path = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
        crop = repaired
      }
    }
    if crop["sceneGeometryOnly"] as? Bool == true {
      guard let corrected: CIImage = image.applyingFilter("CIPerspectiveCorrection", parameters: [
        "inputTopLeft": vector(corners[0], in: image), "inputTopRight": vector(corners[1], in: image),
        "inputBottomRight": vector(corners[2], in: image), "inputBottomLeft": vector(corners[3], in: image)
      ]).finiteImage else { throw ScanError.unreadableImage }
      let upright: CIImage = canonicalCardAspect(normalized(corrected))
      let independent: [String: Any] = try timedSavedPhase("scene-probe-full-fallback", record: timing) {
        try recognizeCrop(upright, sourceCorners: corners.map(pointMap), rectified: true,
          allowRotation: false, recordOrientation: record, recordTiming: timing)
      }
      if let path: String = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
      crop = independent
    }
    if crop["optionalRecoveryDeferred"] as? Bool == true,
        let actualCorners: [[String: Double]] = crop["sourceCorners"] as? [[String: Double]],
        let corrected: CIImage = image.applyingFilter("CIPerspectiveCorrection", parameters: [
          "inputTopLeft": vector(corners[0], in: image), "inputTopRight": vector(corners[1], in: image),
          "inputBottomRight": vector(corners[2], in: image), "inputBottomLeft": vector(corners[3], in: image)
        ]).finiteImage {
      let upright: CIImage = canonicalCardAspect(normalized(corrected))
      let recovered: [[String: Any]] = try recoverSavedText(upright,
        lines: crop["lines"] as? [[String: Any]] ?? [], sourceCorners: actualCorners,
        allowLightingRecovery: crop["rectified"] as? Bool == true,
        recordOrientation: record, recordTiming: timing)
      crop["lines"] = recovered
      crop["optionalRecoveryDeferred"] = false
      var warnings: [String] = crop["warnings"] as? [String] ?? []
      if hasLightingTitleConflict(recovered) && !warnings.contains("lighting_title_conflict") {
        warnings.append("lighting_title_conflict")
      }
      let aspect: Double = Double(crop["width"] as? Int ?? 0) / Double(max(1, crop["height"] as? Int ?? 1))
      if nameplateScore(recovered) > 0 && aspect >= 0.58 && aspect <= 0.84 {
        warnings.removeAll { $0 == "incomplete_card" }
      }
      if !recovered.isEmpty { warnings.removeAll { $0 == "no_text" } }
      if recovered.contains(where: { ($0["confidence"] as? Double ?? 0) >= 0.65 }) {
        warnings.removeAll { $0 == "low_text_confidence" }
      }
      crop["warnings"] = warnings
    }
    let recoveredLines: [[String: Any]] = crop["lines"] as? [[String: Any]] ?? []
    if !recoveredLines.isEmpty && !savedUprightTextSupported(recoveredLines)
        && (nameplateScore(recoveredLines) == 0 || !savedCardLayout(recoveredLines)),
        let priorPath = crop["imagePath"] as? String,
        let retryImage = CIImage(contentsOf: URL(fileURLWithPath: priorPath)),
        let retryCorners = crop["sourceCorners"] as? [[String: Double]] {
      var alternate: [String: Any] = try timedSavedPhase("card-orientation-retry", record: timing) {
        try recognizeCrop(normalized(retryImage), sourceCorners: retryCorners, rectified: true,
          recordOrientation: record, recordTiming: timing)
      }
      let alternateLines: [[String: Any]] = alternate["lines"] as? [[String: Any]] ?? []
      let originalAspect: Double = Double(crop["width"] as? Int ?? 0) / Double(max(1, crop["height"] as? Int ?? 1))
      let alternateAspect: Double = Double(alternate["width"] as? Int ?? 0)
        / Double(max(1, alternate["height"] as? Int ?? 1))
      let restoredAspect: Bool = (originalAspect < 0.58 || originalAspect > 0.84)
        && alternateAspect >= 0.58 && alternateAspect <= 0.84 && bodyOrientationScore(alternateLines) > 0
      if orientationScore(alternateLines) > orientationScore(recoveredLines)
          || (restoredAspect && orientationScore(alternateLines) >= orientationScore(recoveredLines)) {
        alternate["warnings"] = mergingSavedRecoveryWarnings(crop["warnings"] as? [String] ?? [],
          into: alternate["warnings"] as? [String] ?? [])
        try? FileManager.default.removeItem(atPath: priorPath)
        crop = alternate
      } else if let unused = alternate["imagePath"] as? String {
        try? FileManager.default.removeItem(atPath: unused)
      }
    }
    job.crop = crop
    if diagnostics {
      let finalLines: [[String: Any]] = crop["lines"] as? [[String: Any]] ?? []
      job.timings.append(["phase": "card-refined", "cardIndex": initial.index,
        "elapsedMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000,
        "finishedAtMilliseconds": (ProcessInfo.processInfo.systemUptime - photoStarted) * 1000,
        "usableObservedText": savedUprightTextSupported(finalLines) || savedCardLayout(finalLines)])
    }
    completed = true
    return job
  }

  func savedTargetRegions(_ raw: Any?) throws -> [[CGPoint]] {
    guard let raw else { return [] }
    guard let regions: [[[String: Any]]] = raw as? [[[String: Any]]], regions.count <= 8 else {
      throw ScanError.unreadableImage
    }
    var targets: [[CGPoint]] = []
    for region: [[String: Any]] in regions {
      guard region.count == 4 else { throw ScanError.unreadableImage }
      let corners: [CGPoint] = try region.map { point in
        guard let x: Double = point["x"] as? Double, let y: Double = point["y"] as? Double,
              x.isFinite, y.isFinite, x >= 0, x <= 1, y >= 0, y <= 1 else {
          throw ScanError.unreadableImage
        }
        return CGPoint(x: x, y: 1 - y)
      }
      let cross: CGFloat = (corners[1].x - corners[0].x) * (corners[2].y - corners[1].y)
        - (corners[1].y - corners[0].y) * (corners[2].x - corners[1].x)
      guard cross < 0, polygonArea(corners) >= 0.0004,
            SavedCardProjection(corners: corners) != nil else { throw ScanError.unreadableImage }
      if savedTargetNeedsProposal(corners, among: targets) { targets.append(corners) }
    }
    return targets
  }

  func savedTargetNeedsProposal(_ corners: [CGPoint], among geometry: [[CGPoint]]) -> Bool {
    let area: CGFloat = polygonArea(corners)
    guard area >= 0.0004, SavedCardProjection(corners: corners) != nil else { return false }
    return !geometry.contains { existing in
      let shared: CGFloat = polygonIntersection(corners, existing)
      let priorArea: CGFloat = polygonArea(existing)
      let smaller: CGFloat = min(area, priorArea)
      let ratio: CGFloat = area / max(priorArea, 0.000001)
      return smaller > 0 && ratio >= 0.55 && ratio <= 1.8 && shared / smaller >= 0.65
    }
  }

  func savedTargetTextSupported(_ lines: [[String: Any]]) -> Bool {
    liveNamedLayoutSupported(lines) || strongUprightBodyLayout(lines) || savedBasicLandIdentitySupported(lines)
  }

  func savedGuidedDuplicateIndices(_ crops: [[String: Any]]) -> [Int] {
    let guided: [Int] = crops.indices.filter {
      crops[$0]["geometrySource"] as? String == "live_outline"
        && savedTargetTextSupported(crops[$0]["lines"] as? [[String: Any]] ?? [])
    }
    func corners(_ crop: [String: Any]) -> [CGPoint]? {
      guard let raw: [[String: Double]] = crop["sourceCorners"] as? [[String: Double]] else { return nil }
      return try? savedTargetRegions([raw]).first
    }
    func evidence(_ crop: [String: Any], title: Bool) -> Set<String> {
      Set<String>((crop["lines"] as? [[String: Any]] ?? []).compactMap { line -> String? in
        guard let row: PartialText = partialText([line]).first, row.confidence >= 0.85,
              (title ? nameplateScore([line]) > 0 : isCardBody(row.text) && !isCardFooter(row.text)) else { return nil }
        return normalizedCardText(row.text)
      })
    }
    return crops.indices.filter { index in
      guard !guided.contains(index), let original: [CGPoint] = corners(crops[index]) else { return false }
      return guided.contains { guide in
        guard let proposed: [CGPoint] = corners(crops[guide]) else { return false }
        let smaller: CGFloat = min(polygonArea(original), polygonArea(proposed))
        guard smaller > 0, polygonIntersection(original, proposed) / smaller >= 0.95 else { return false }
        return !evidence(crops[index], title: true).intersection(evidence(crops[guide], title: true)).isEmpty
          || evidence(crops[index], title: false).intersection(evidence(crops[guide], title: false)).count >= 2
      }
    }.sorted(by: >)
  }

  private func recognizePresence(path: String, multiple: Bool, targetRegions: [[CGPoint]] = []) throws -> [String: Any] {
    let started: TimeInterval = ProcessInfo.processInfo.systemUptime
    guard let source: CIImage = CIImage(contentsOf: URL(fileURLWithPath: path),
      options: [.applyOrientationProperty: true]), !source.extent.isEmpty,
      !source.extent.isInfinite, source.extent.width.isFinite, source.extent.height.isFinite else {
      throw ScanError.unreadableImage
    }
    let image: CIImage = normalized(source)
    let detection: CIImage = bounded(image, edge: 2048)
    var timings: [String: Double] = [:]
    let rectangles: VNDetectRectanglesRequest = VNDetectRectanglesRequest()
    rectangles.minimumAspectRatio = 0.55
    rectangles.maximumAspectRatio = 1.0
    rectangles.minimumConfidence = 0.70
    rectangles.minimumSize = multiple ? 0.08 : 0.15
    rectangles.quadratureTolerance = 35
    rectangles.maximumObservations = 16
    try VNImageRequestHandler(ciImage: detection, orientation: .up).perform([rectangles])
    timings["rectangles"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
    var proposals: [VNRectangleObservation] = rectangles.results ?? []
    let documentStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
    if #available(iOS 15.0, *) {
      let document: VNDetectDocumentSegmentationRequest = VNDetectDocumentSegmentationRequest()
      if (try? VNImageRequestHandler(ciImage: detection, orientation: .up).perform([document])) != nil,
        let outline: VNRectangleObservation = document.results?.first,
        outline.boundingBox.width * outline.boundingBox.height >= 0.025,
        outline.boundingBox.width * outline.boundingBox.height <= 0.65 {
        proposals.append(outline)
      }
    }
    timings["document"] = (ProcessInfo.processInfo.systemUptime - documentStarted) * 1000
    let sorted: [VNRectangleObservation] = proposals.sorted {
      $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height
    }
    var geometry: [[CGPoint]] = []
    for rectangle: VNRectangleObservation in sorted {
      let corners: [CGPoint] = rectangleCorners(rectangle)
      let area: CGFloat = polygonArea(corners)
      guard area > 0.0001, !geometry.contains(where: {
        polygonIntersection(corners, $0) / area > 0.65
      }) else { continue }
      guard let corrected: CIImage = image.applyingFilter("CIPerspectiveCorrection", parameters: [
        "inputTopLeft": vector(corners[0], in: image), "inputTopRight": vector(corners[1], in: image),
        "inputBottomRight": vector(corners[2], in: image), "inputBottomLeft": vector(corners[3], in: image)
      ]).finiteImage else { continue }
      let shortEdge: CGFloat = min(corrected.extent.width, corrected.extent.height)
      let longEdge: CGFloat = max(corrected.extent.width, corrected.extent.height)
      let aspect: CGFloat = shortEdge / longEdge
      guard aspect.isFinite, aspect >= 0.50, aspect <= 1,
        shortEdge >= 400, longEdge >= 400 else { continue }
      geometry.append(corners)
      if geometry.count >= (multiple ? 8 : 1) { break }
    }
    var guidedIndices: Set<Int> = []
    for corners: [CGPoint] in targetRegions {
      guard geometry.count < (multiple ? 8 : 1), savedTargetNeedsProposal(corners, among: geometry) else { continue }
      guidedIndices.insert(geometry.count)
      geometry.append(corners)
    }
    var crops: [[String: Any]] = []
    var retained: Bool = false
    defer {
      if !retained {
        for crop: [String: Any] in crops {
          if let cropPath: String = crop["imagePath"] as? String {
            try? FileManager.default.removeItem(atPath: cropPath)
          }
        }
      }
    }
    var paddedGeometry: [[CGPoint]] = geometry
    for index: Int in paddedGeometry.indices {
      let neighbors: [[CGPoint]] = paddedGeometry.enumerated().filter { $0.offset != index }.map { $0.element }
      if let expanded: [CGPoint] = expandedSavedCardCorners(paddedGeometry[index],
          top: 0.04, bottom: 0.04, horizontal: 0.02, neighboringCorners: neighbors) {
        paddedGeometry[index] = expanded
      }
    }
    let targets: [[CGPoint]] = paddedGeometry
    let expandedTargets: [Bool] = targets.enumerated().map { $0.element != geometry[$0.offset] }
    let workers: [LocalCardScanner] = (0..<min(2, targets.count)).map { _ in LocalCardScanner() }
    let results: [Result<(crop: [String: Any]?, milliseconds: Double), Error>] = boundedSavedJobs(count: targets.count) { index, worker in
      let scanner: LocalCardScanner = workers[worker]
      let corners: [CGPoint] = targets[index]
      let cropStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
      return try autoreleasepool {
        guard let corrected: CIImage = image.applyingFilter("CIPerspectiveCorrection", parameters: [
          "inputTopLeft": scanner.vector(corners[0], in: image), "inputTopRight": scanner.vector(corners[1], in: image),
          "inputBottomRight": scanner.vector(corners[2], in: image), "inputBottomLeft": scanner.vector(corners[3], in: image)
        ]).finiteImage else { return (nil, (ProcessInfo.processInfo.systemUptime - cropStarted) * 1000) }
        let aspect: CGFloat = min(corrected.extent.width, corrected.extent.height)
          / max(corrected.extent.width, corrected.extent.height)
        guard aspect.isFinite, (guidedIndices.contains(index) || (aspect >= 0.50 && aspect <= 1)),
              min(corrected.extent.width, corrected.extent.height) >= 120 else {
          return (nil, (ProcessInfo.processInfo.systemUptime - cropStarted) * 1000)
        }
        let upright: CIImage = scanner.canonicalCardAspect(scanner.normalized(corrected))
        var crop: [String: Any] = try scanner.recognizeCrop(upright, sourceCorners: corners.map(scanner.pointMap),
          rectified: true, presenceOnly: true)
        if guidedIndices.contains(index) {
          guard scanner.savedTargetTextSupported(crop["lines"] as? [[String: Any]] ?? []) else {
            if let path: String = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
            return (nil, (ProcessInfo.processInfo.systemUptime - cropStarted) * 1000)
          }
          crop["geometrySource"] = "live_outline"
        }
        let measuredAspect: CGFloat = corrected.extent.width / corrected.extent.height
        if measuredAspect < 0.58 || measuredAspect > 0.84 {
          crop["warnings"] = (crop["warnings"] as? [String] ?? []) + ["geometry_adjusted"]
        }
        if expandedTargets[index] {
          crop["warnings"] = (crop["warnings"] as? [String] ?? []) + ["border_recovered"]
        }
        return (crop, (ProcessInfo.processInfo.systemUptime - cropStarted) * 1000)
      }
    }
    var firstError: Error?
    for (index, result) in results.enumerated() {
      switch result {
      case .success(let output):
        if let crop: [String: Any] = output.crop { crops.append(crop) }
        timings["crop\(index)"] = output.milliseconds
      case .failure(let error):
        if firstError == nil { firstError = error }
      }
    }
    if let error: Error = firstError { throw error }
    for index: Int in savedGuidedDuplicateIndices(crops) {
      if let path: String = crops[index]["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
      crops.remove(at: index)
    }
    func usablePresence(_ crop: [String: Any]) -> Bool {
      let lines: [[String: Any]] = crop["lines"] as? [[String: Any]] ?? []
      let warnings: [String] = crop["warnings"] as? [String] ?? []
      return crop["rectified"] as? Bool == true
        && !warnings.contains("incomplete_card") && !warnings.contains("no_text")
        && !warnings.contains("lighting_title_conflict")
        && (savedCardLayout(lines) || savedBasicLandIdentitySupported(lines))
    }
    if crops.isEmpty || crops.contains(where: { !usablePresence($0) }) {
      let recoveryStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
      let occupied: [CGRect] = crops.filter(usablePresence).compactMap { cropRegion($0) }
      let scene: [SavedSceneRow] = (try? savedSceneRows(image)) ?? []
      let recovered: [[String: Any]] = savedBasicLandCrops(image, observations: scene.map { $0.line },
        covered: occupied, limit: min(2, max(0, 8 - crops.filter(usablePresence).count)),
        presenceOnly: true, diagnostics: nil)
      crops.removeAll { crop in
        let warnings: [String] = crop["warnings"] as? [String] ?? []
        guard warnings.contains("incomplete_card") || warnings.contains("no_text"),
          let points: [[String: Double]] = crop["sourceCorners"] as? [[String: Double]],
          points.count == 4 else { return false }
        let corners: [CGPoint] = points.compactMap { point in
          guard let x: Double = point["x"], let y: Double = point["y"] else { return nil }
          return CGPoint(x: x, y: 1 - y)
        }
        let area: CGFloat = polygonArea(corners)
        guard corners.count == 4, area > 0.0001, recovered.contains(where: { full in
          guard let points: [[String: Double]] = full["sourceCorners"] as? [[String: Double]] else { return false }
          let outline: [CGPoint] = points.compactMap { point in
            guard let x: Double = point["x"], let y: Double = point["y"] else { return nil }
            return CGPoint(x: x, y: 1 - y)
          }
          return outline.count == 4 && polygonIntersection(corners, outline) / area >= 0.98
        }) else { return false }
        if let path: String = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
        return true
      }
      for index: Int in presenceCapacityDiscardIndices(crops, incomingCount: recovered.count) {
        if let path: String = crops[index]["imagePath"] as? String {
          try? FileManager.default.removeItem(atPath: path)
        }
        crops.remove(at: index)
      }
      let remaining: Int = max(0, 8 - crops.count)
      crops.append(contentsOf: recovered.prefix(remaining))
      for unused: [String: Any] in recovered.dropFirst(remaining) {
        if let path: String = unused["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
      }
      timings["basicLandRecovery"] = (ProcessInfo.processInfo.systemUptime - recoveryStarted) * 1000
    }
    let appearanceStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
    let targetAppearances: [[String: Any]] = savedTargetAppearances(image, regions: targetRegions)
    timings["targetAppearances"] = (ProcessInfo.processInfo.systemUptime - appearanceStarted) * 1000
    retained = true
    return ["imagePath": path, "width": Int(image.extent.width), "height": Int(image.extent.height),
      "crops": crops, "presenceOnly": true, "targetAppearances": targetAppearances,
      "timings": timings,
      "elapsedMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000]
  }

  func presenceCapacityDiscardIndices(_ crops: [[String: Any]], incomingCount: Int) -> [Int] {
    let needed: Int = max(0, crops.count + max(0, incomingCount) - 8)
    guard needed > 0 else { return [] }
    var noText: [Int] = []
    var incomplete: [Int] = []
    for (index, crop) in crops.enumerated() {
      let lines: [[String: Any]] = crop["lines"] as? [[String: Any]] ?? []
      let warnings: [String] = crop["warnings"] as? [String] ?? []
      guard !savedCardLayout(lines), !savedBasicLandIdentitySupported(lines) else { continue }
      if warnings.contains("no_text") { noText.append(index) }
      else if warnings.contains("incomplete_card") { incomplete.append(index) }
    }
    return Array((noText + incomplete).prefix(needed)).sorted(by: >)
  }

  private func recognize(path: String, multiple: Bool, includePartialDiagnostics: Bool = false,
      targetRegions: [[CGPoint]] = []) throws -> [String: Any] {
    let photoStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
    var partialDiagnostics: [String: Any]?
    var basicGeometryDiagnostics: [String: Any]?
    var basicSceneObservations: [[String: Any]] = []
    var orientationDiagnostics: [[String: Any]] = []
    var backgroundDiagnostics: [[String: Any]] = []
    var timingDiagnostics: [[String: Any]] = []
    func recordPhotoPhase(_ phase: String, since started: TimeInterval) {
      if includePartialDiagnostics {
        timingDiagnostics.append(["phase": phase,
          "elapsedMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000,
          "finishedAtMilliseconds": (ProcessInfo.processInfo.systemUptime - photoStarted) * 1000])
      }
    }
    let recordPartial: (([String: Any]) -> Void)? = includePartialDiagnostics ? { partialDiagnostics = $0 } : nil
    let recordOrientation: (([String: Any]) -> Void)? = includePartialDiagnostics ? {
      if orientationDiagnostics.count < 64 { orientationDiagnostics.append($0) }
    } : nil
    guard var image = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else {
      throw ScanError.unreadableImage
    }
    image = normalized(image)
    recordPhotoPhase("decode", since: photoStarted)
    // Detection uses a smaller image; normalized corners are applied to the full-resolution original.
    let detection = bounded(image, edge: 2048)
    let rectangles = VNDetectRectanglesRequest()
    rectangles.minimumAspectRatio = 0.55
    rectangles.maximumAspectRatio = 1.0
    rectangles.minimumConfidence = 0.70
    rectangles.minimumSize = multiple ? 0.08 : 0.15
    rectangles.quadratureTolerance = 35
    rectangles.maximumObservations = 16
    let rectangleStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
    try VNImageRequestHandler(ciImage: detection, orientation: .up).perform([rectangles])
    recordPhotoPhase("rectangles", since: rectangleStarted)
    var proposals: [VNRectangleObservation] = rectangles.results ?? []
    var fullSceneRows: [SavedSceneRow]?
    if #available(iOS 15.0, *) {
      let documentStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
      let document = VNDetectDocumentSegmentationRequest()
      let segmented: Bool
      do {
        try VNImageRequestHandler(ciImage: detection, orientation: .up).perform([document])
        segmented = true
      } catch {
        segmented = false
        recordOrientation?(["phase": "document-outline-unavailable", "error": error.localizedDescription])
      }
      recordOrientation?(["phase": "document-outline-proposals", "corners": (document.results ?? []).map { rectangleCorners($0).map(pointMap) }])
      if segmented,
          let outline = document.results?.first,
          outline.boundingBox.width * outline.boundingBox.height >= 0.025,
          outline.boundingBox.width * outline.boundingBox.height <= 0.65 {
        let corners: [CGPoint] = rectangleCorners(outline)
        let corrected = image.applyingFilter("CIPerspectiveCorrection", parameters: [
          "inputTopLeft": vector(corners[0], in: image), "inputTopRight": vector(corners[1], in: image),
          "inputBottomRight": vector(corners[2], in: image), "inputBottomLeft": vector(corners[3], in: image)
        ])
        let aspect: CGFloat = min(corrected.extent.width, corrected.extent.height) / max(corrected.extent.width, corrected.extent.height)
        recordOrientation?(["phase": "document-outline-aspect", "aspect": Double(aspect)])
        if aspect.isFinite && aspect >= 0.50 && aspect <= 1,
            let rows = try? savedSceneRows(image) {
          fullSceneRows = rows
          let observed = savedSceneCards(rows, image: image, geometry: [corners]).first?.lines ?? []
          // Segmentation proposes an outside edge; observed card layout must support it.
          if savedUprightTextSupported(observed) || savedCardLayout(observed) {
            proposals.append(outline)
            recordOrientation?(["phase": "document-outline", "sourceCorners": corners.map(pointMap), "lines": observed])
          }
        }
      }
      recordPhotoPhase("document-outline", since: documentStarted)
    }
    let sorted = proposals.sorted {
      $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height
    }
    var accepted: [[CGPoint]] = []
    for rectangle in sorted {
      let nested = accepted.contains { existing in
        let bounds: CGRect = existing.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let intersection = bounds.intersection(rectangle.boundingBox)
        let area = rectangle.boundingBox.width * rectangle.boundingBox.height
        return !intersection.isNull && intersection.width * intersection.height / area > 0.65
      }
      if !nested { accepted.append(rectangleCorners(rectangle)) }
      if accepted.count == (multiple ? 8 : 1) { break }
    }
    var guidedIndices: Set<Int> = []
    for corners: [CGPoint] in targetRegions {
      guard accepted.count < (multiple ? 8 : 1), savedTargetNeedsProposal(corners, among: accepted) else { continue }
      guidedIndices.insert(accepted.count)
      accepted.append(corners)
    }
    if !targetRegions.isEmpty {
      recordOrientation?(["phase": "saved-live-outline-proposals", "requested": targetRegions.count,
        "added": guidedIndices.count, "sourceCorners": guidedIndices.sorted().map { accepted[$0].map(pointMap) }])
    }
    var crops: [[String: Any]] = []
    var retained: Bool = false
    defer {
      if !retained {
        for crop: [String: Any] in crops {
          if let cropPath: String = crop["imagePath"] as? String {
            try? FileManager.default.removeItem(atPath: cropPath)
          }
        }
      }
    }
    if accepted.isEmpty {
      crops.append(try recognizeCrop(image, sourceCorners: fullImageCorners, rectified: false,
        recordOrientation: recordOrientation))
    } else {
      let geometry: [[CGPoint]] = accepted
      let workers: [LocalCardScanner] = (0..<min(2, accepted.count)).map { _ in LocalCardScanner() }
      let source: CIImage = image
      var sceneCards: [SavedSceneCard]?
      if let rows = fullSceneRows {
        basicSceneObservations = rows.map { $0.line }
        sceneCards = savedSceneCards(rows, image: source, geometry: geometry, diagnostics: recordOrientation)
      } else if multiple && accepted.count >= 2 {
        let sceneStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
        let regions: [CGRect] = savedSceneRegions(geometry, imageSize: source.extent.size)
        recordOrientation?(["phase": "saved-scene-regions", "regions": regions.map {
          ["x": Double($0.minX), "y": Double(1 - $0.maxY), "width": Double($0.width), "height": Double($0.height)]
        }])
        let tileResults: [Result<[SavedSceneRow], Error>] = boundedSavedJobs(count: regions.count) { index, worker in
          try workers[worker].savedSceneRows(source, region: regions[index])
        }
        do {
          let rows: [SavedSceneRow] = try tileResults.flatMap { try $0.get() }
          basicSceneObservations = rows.map { $0.line }
          if !rows.isEmpty {
            sceneCards = savedSceneCards(rows, image: source, geometry: geometry, diagnostics: recordOrientation)
          }
        } catch {
          recordOrientation?(["phase": "saved-scene-error", "message": error.localizedDescription])
        }
        recordPhotoPhase("scene-text", since: sceneStarted)
      }
      let sceneByIndex: [SavedSceneCard]? = sceneCards
      let initialStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
      let areas: [CGFloat] = geometry.map(polygonArea).sorted()
      let typicalGeometryArea: CGFloat = areas[areas.count / 2]
      let primaryIndices: [Int] = geometry.indices.filter {
        !multiple || polygonArea(geometry[$0]) >= typicalGeometryArea * 0.20
      }
      let smallIndices: [Int] = geometry.indices.filter { !primaryIndices.contains($0) }
      var initialResults: [Result<SavedCardJob, Error>] = boundedSavedJobs(count: primaryIndices.count) { slot, worker in
        let index: Int = primaryIndices[slot]
        return try workers[worker].prepareSavedCard(source, corners: geometry[index], index: index,
          photoStarted: photoStarted, diagnostics: includePartialDiagnostics, scene: sceneByIndex?[index])
      }
      let primary: [SavedCardJob]
      do { primary = try initialResults.map { try $0.get() } }
      catch {
        cleanupSavedJobs(initialResults)
        throw error
      }
      if !smallIndices.isEmpty {
        let readableAreas: [CGFloat] = primary.compactMap { job in
          guard let crop = job.crop, nameplateScore(crop["lines"] as? [[String: Any]] ?? []) > 0 else { return nil }
          return polygonArea(geometry[job.index])
        }.sorted()
        let typicalReadableArea: CGFloat? = readableAreas.count >= 2 ? readableAreas[readableAreas.count / 2] : nil
        let smaller: [Result<SavedCardJob, Error>] = boundedSavedJobs(count: smallIndices.count) { slot, worker in
          let index: Int = smallIndices[slot]
          let sampleBackground: Bool = typicalReadableArea.map { self.polygonArea(geometry[index]) < $0 * 0.20 } ?? false
          return try workers[worker].prepareSavedCard(source, corners: geometry[index], index: index,
            photoStarted: photoStarted, diagnostics: includePartialDiagnostics, skipBlankSmallRegion: sampleBackground,
            scene: sceneByIndex?[index])
        }
        initialResults.append(contentsOf: smaller)
      }
      let initial: [SavedCardJob]
      do { initial = try initialResults.map { try $0.get() }.sorted { $0.index < $1.index } }
      catch {
        cleanupSavedJobs(initialResults)
        throw error
      }
      recordPhotoPhase("initial-cards", since: initialStarted)
      let repairIndices: Set<Int> = Set(initial.filter { job in
        savedBorderRecoveryNeeded(job.crop?["lines"] as? [[String: Any]] ?? [])
          || job.crop?["sceneProbeTop"] as? Bool == true || job.crop?["sceneProbeBottom"] as? Bool == true
      }.prefix(4).map { $0.index })
      let refinementStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
      let refinedResults: [Result<SavedCardJob, Error>] = boundedSavedJobs(count: initial.count) { index, worker in
        try workers[worker].refineSavedCard(initial[index], in: source, corners: geometry[index],
          neighboringCorners: geometry.enumerated().filter { $0.offset != index }.map { $0.element },
          allowBorderRepair: repairIndices.contains(index), photoStarted: photoStarted,
          diagnostics: includePartialDiagnostics)
      }
      let refined: [SavedCardJob]
      do { refined = try refinedResults.map { try $0.get() } }
      catch {
        cleanupSavedJobs(refinedResults)
        cleanupSavedJobs(initialResults)
        throw error
      }
      recordPhotoPhase("refine-cards", since: refinementStarted)
      for job: SavedCardJob in refined {
        if var crop = job.crop {
          let guided: Bool = guidedIndices.contains(job.index)
          let supported: Bool = !guided || savedTargetTextSupported(crop["lines"] as? [[String: Any]] ?? [])
          if guided {
            recordOrientation?(["phase": "saved-live-outline-result", "cardIndex": job.index,
              "accepted": supported, "sourceCorners": crop["sourceCorners"] ?? [],
              "lines": crop["lines"] ?? []])
          }
          if supported {
            if guided { crop["geometrySource"] = "live_outline" }
            crops.append(crop)
          } else if let path: String = crop["imagePath"] as? String {
            try? FileManager.default.removeItem(atPath: path)
          }
        }
        for entry: [String: Any] in job.diagnostics { recordOrientation?(entry) }
        if includePartialDiagnostics { timingDiagnostics.append(contentsOf: job.timings) }
      }
      for index: Int in savedGuidedDuplicateIndices(crops) {
        if let path: String = crops[index]["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
        crops.remove(at: index)
      }
      if crops.isEmpty {
        crops.append(try recognizeCrop(image, sourceCorners: fullImageCorners, rectified: false,
          recordOrientation: recordOrientation))
      } else if !multiple && image.extent.width / image.extent.height >= 0.58
          && image.extent.width / image.extent.height <= 0.84
          && ((accepted.first.map { points in
              let bounds: CGRect = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
              return bounds.width * bounds.height
            } ?? 0) > 0.75
            || crops.allSatisfy({ ($0["warnings"] as? [String] ?? []).contains("incomplete_card") })) {
        // Edge-to-edge gallery cards may expose artwork rectangles instead of their outside border.
        let whole = try recognizeCrop(image, sourceCorners: fullImageCorners, rectified: false,
          recordOrientation: recordOrientation)
        let strongestCrop = crops.map { orientationScore($0["lines"] as? [[String: Any]] ?? []) }.max() ?? 0
        if !(whole["warnings"] as? [String] ?? []).contains("incomplete_card")
            && orientationScore(whole["lines"] as? [[String: Any]] ?? []) > strongestCrop {
          for crop in crops {
            if let path = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
          }
          crops = [whole]
        } else if let path = whole["imagePath"] as? String {
          try? FileManager.default.removeItem(atPath: path)
        }
      }
    }
    if multiple && crops.count < 8 {
      let occupied: [CGRect] = crops.compactMap { crop in
        let warnings: [String] = crop["warnings"] as? [String] ?? []
        guard crop["rectified"] as? Bool == true,
              !warnings.contains("incomplete_card"), !warnings.contains("no_text") else { return nil }
        return cropRegion(crop)
      }
      let started: TimeInterval = ProcessInfo.processInfo.systemUptime
      if savedBasicLandGuideRegions(basicSceneObservations, imageSize: image.extent.size, covered: occupied).isEmpty,
          crops.contains(where: { ($0["warnings"] as? [String] ?? []).contains("incomplete_card") }),
          let scene: [SavedSceneRow] = try? savedSceneRows(image) {
        basicSceneObservations = scene.map { $0.line }
        recordOrientation?(["phase": "full-scene-land-recovery", "rows": basicSceneObservations])
      }
      let recovered: [[String: Any]] = savedBasicLandCrops(image, observations: basicSceneObservations,
        covered: occupied, limit: 8 - crops.count, diagnostics: includePartialDiagnostics ? {
          basicGeometryDiagnostics = $0
        } : nil)
      let repairedRegions: [CGRect] = recovered.compactMap { cropRegion($0) }
      crops.removeAll { crop in
        let warnings: [String] = crop["warnings"] as? [String] ?? []
        guard warnings.contains("incomplete_card") || warnings.contains("no_text"),
              let region = cropRegion(crop),
              repairedRegions.contains(where: { overlapsPartial(region, $0) }) else { return false }
        if let path = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
        return true
      }
      crops.append(contentsOf: recovered)
      recordPhotoPhase("basic-land-geometry", since: started)
    }
    if multiple {
      let usable = crops.filter { crop in
        let warnings = crop["warnings"] as? [String] ?? []
        return !warnings.contains("incomplete_card") && !warnings.contains("no_text")
          && !warnings.contains("low_text_confidence")
      }
      let covered = accepted.isEmpty ? [] : usable.compactMap { cropRegion($0) }
      let partial: [[String: Any]]
      let partialStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
      do {
        let hasUnreadCard: Bool = crops.contains { crop in
          let warnings: [String] = crop["warnings"] as? [String] ?? []
          return warnings.contains("incomplete_card") || warnings.contains("no_text") || warnings.contains("low_text_confidence")
        }
        let probeStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
        let needsAccuratePartial: Bool
        if hasUnreadCard || accepted.isEmpty {
          needsAccuratePartial = true
        } else {
          needsAccuratePartial = try outsideSavedCardEvidence(image, covered: covered)
        }
        recordPhotoPhase("outside-partial-probe", since: probeStarted)
        if needsAccuratePartial {
          partial = try autoreleasepool(invoking: {
            try partialCardCrops(image, covered: covered, limit: 8 - usable.count, diagnostics: recordPartial)
          })
        } else {
          partial = []
          recordPartial?(["fullOutsideProbe": "no_card_anchor", "coveredCount": covered.count])
        }
      } catch {
        partial = []
        if includePartialDiagnostics {
          let cause: NSError = error as NSError
          partialDiagnostics = ["error": ["stage": "partial_card_crops", "domain": cause.domain,
            "code": cause.code, "message": cause.localizedDescription]]
        }
      }
      recordPhotoPhase("partial-recovery", since: partialStarted)
      if !partial.isEmpty {
        if accepted.isEmpty {
          let retained: [[String: Any]] = crops.filter { $0["rectified"] as? Bool == true }
          for crop in crops {
            if crop["rectified"] as? Bool == true { continue }
            if let path = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
          }
          crops = retained
          let remaining: Int = max(0, 8 - crops.count)
          crops.append(contentsOf: partial.prefix(remaining))
          for crop in partial.dropFirst(remaining) {
            if let path: String = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
          }
        } else {
          let replacementRegions = partial.compactMap { cropRegion($0) }
          crops.removeAll { crop in
            let warnings = crop["warnings"] as? [String] ?? []
            guard warnings.contains("incomplete_card") || warnings.contains("no_text")
                || warnings.contains("low_text_confidence"), let region = cropRegion(crop),
                replacementRegions.contains(where: { overlapsPartial(region, $0) }) else { return false }
            if let path = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
            return true
          }
          let remaining = max(0, 8 - crops.count)
          crops.append(contentsOf: partial.prefix(remaining))
          for crop in partial.dropFirst(remaining) {
            if let path = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
          }
        }
      }
    }
    if multiple {
      let readableAreas: [CGFloat] = crops.compactMap { crop in
        guard let lines = crop["lines"] as? [[String: Any]],
              nameplateScore(lines) > 0, let region = cropRegion(crop) else { return nil }
        return region.width * region.height
      }.sorted()
      if readableAreas.count >= 2 {
        let typicalArea: CGFloat = readableAreas[readableAreas.count / 2]
        crops.removeAll { crop in
          guard let lines = crop["lines"] as? [[String: Any]], lines.isEmpty,
                let region = cropRegion(crop),
                region.width * region.height < typicalArea * 0.20,
                let path = crop["imagePath"] as? String,
                let candidate = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return false }
          let evidence: [String: Any] = savedBlankRegionPixels(candidate)
          backgroundDiagnostics.append(["sourceCorners": crop["sourceCorners"] ?? [], "pixels": evidence])
          guard evidence["background"] as? Bool == true else { return false }
          if let path = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
          return true
        }
      }
    }
    let appearanceStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
    let targetAppearances: [[String: Any]] = savedTargetAppearances(image, regions: targetRegions)
    recordPhotoPhase("target-appearances", since: appearanceStarted)
    var result: [String: Any] = ["imagePath": path, "width": Int(image.extent.width), "height": Int(image.extent.height),
      "crops": crops, "targetAppearances": targetAppearances]
    if let basicGeometryDiagnostics {
      var details: [String: Any] = partialDiagnostics ?? [:]
      details["basicLandRecovery"] = basicGeometryDiagnostics
      partialDiagnostics = details
    }
    if let partialDiagnostics { result["partialDiagnostics"] = partialDiagnostics }
    if includePartialDiagnostics { result["orientationDiagnostics"] = orientationDiagnostics }
    if includePartialDiagnostics { result["timingDiagnostics"] = timingDiagnostics }
    if !backgroundDiagnostics.isEmpty { result["backgroundDiagnostics"] = backgroundDiagnostics }
    retained = true
    return result
  }

  private func cropRegion(_ crop: [String: Any], cornersKey: String = "sourceCorners") -> CGRect? {
    guard let corners = crop[cornersKey] as? [[String: Double]], corners.count == 4,
          let minX = corners.compactMap({ $0["x"] }).min(),
          let maxX = corners.compactMap({ $0["x"] }).max(),
          let minY = corners.compactMap({ $0["y"] }).min(),
          let maxY = corners.compactMap({ $0["y"] }).max() else { return nil }
    return CGRect(x: minX, y: 1 - maxY, width: maxX - minX, height: maxY - minY)
  }

  private struct PartialText {
    let text: String
    let confidence: Double
    let box: CGRect
  }

  private struct PartialAnchor {
    let title: PartialText
    let type: PartialText
    let region: CGRect
  }

  func expandedSavedCardCorners(_ corners: [CGPoint], top: CGFloat,
      bottom: CGFloat, horizontal: CGFloat, neighboringCorners: [[CGPoint]] = []) -> [CGPoint]? {
    guard corners.count == 4, top >= 0, top <= 0.10, bottom >= 0, bottom <= 0.14,
          horizontal >= 0, horizontal <= 0.06,
          corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), polygonArea(corners) > 0 else { return nil }
    func expanded(_ index: Int, side: Int, vertical: Int, height: CGFloat) -> CGPoint {
      let point: CGPoint = corners[index]
      return CGPoint(x: point.x + (point.x - corners[side].x) * horizontal
          + (point.x - corners[vertical].x) * height,
        y: point.y + (point.y - corners[side].y) * horizontal
          + (point.y - corners[vertical].y) * height)
    }
    let result: [CGPoint] = [expanded(0, side: 1, vertical: 3, height: top),
      expanded(1, side: 0, vertical: 2, height: top),
      expanded(2, side: 3, vertical: 1, height: bottom),
      expanded(3, side: 2, vertical: 0, height: bottom)]
    let unit: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard result.allSatisfy({ unit.contains($0) }), polygonArea(result) > polygonArea(corners) else { return nil }
    for neighbor: [CGPoint] in neighboringCorners {
      guard neighbor.count == 4, neighbor.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
            polygonArea(neighbor) > 0 else { return nil }
      let prior: CGFloat = polygonIntersection(corners, neighbor)
      let proposed: CGFloat = polygonIntersection(result, neighbor)
      if proposed > prior + 0.000001 { return nil }
    }
    return result
  }

  func mergingSavedRecoveryWarnings(_ original: [String], into alternate: [String]) -> [String] {
    let provenance: Set<String> = ["border_recovered", "geometry_adjusted", "partial_card", "orientation_ensemble"]
    return alternate + original.filter { provenance.contains($0) && !alternate.contains($0) }
  }

  func backgroundPixelEvidence(_ rgba: [UInt8]) -> [String: Any] {
    guard rgba.count == 8 * 12 * 4 else { return ["background": false, "valid": false] }
    var luminance: [Double] = []
    var minimumAlpha: UInt8 = 255
    for index: Int in 0..<(8 * 12) {
      let offset: Int = index * 4
      minimumAlpha = min(minimumAlpha, rgba[offset + 3])
      luminance.append((0.2126 * Double(rgba[offset]) + 0.7152 * Double(rgba[offset + 1])
        + 0.0722 * Double(rgba[offset + 2])) / 255)
    }
    let mean: Double = luminance.reduce(0, +) / Double(luminance.count)
    let variance: Double = luminance.reduce(0) { $0 + pow($1 - mean, 2) } / Double(luminance.count)
    guard let low: Double = luminance.min(), let high: Double = luminance.max() else {
      return ["background": false, "valid": false]
    }
    return ["background": minimumAlpha == 255 && low >= 0.64 && high - low <= 0.24 && variance <= 0.005,
      "valid": true, "minimumLuminance": low, "maximumLuminance": high,
      "variance": variance, "minimumAlpha": Int(minimumAlpha)]
  }

  func uniformBrightBackgroundPixels(_ rgba: [UInt8]) -> Bool {
    backgroundPixelEvidence(rgba)["background"] as? Bool == true
  }

  private func savedBlankRegionPixels(_ image: CIImage) -> [String: Any] {
    let scale: CGFloat = 12 / image.extent.height
    let scaled: CIImage = normalized(image).clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
      "inputScale": scale, "inputAspectRatio": (8 / image.extent.width) / scale
    ])
    var rgba: [UInt8] = [UInt8](repeating: 0, count: 8 * 12 * 4)
    rgba.withUnsafeMutableBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      context.render(scaled, toBitmap: base, rowBytes: 8 * 4,
        bounds: CGRect(x: 0, y: 0, width: 8, height: 12), format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB())
    }
    return backgroundPixelEvidence(rgba)
  }

  private func savedFooterSupported(_ lines: [[String: Any]]) -> Bool {
    partialText(lines).contains { row in
      row.confidence >= 0.50 && row.box.minY >= 0.88 && row.box.height < 0.07
        && (hasStructuredFooterCode(row.text)
          || row.text.range(of: #"^\s*(?:[CMRULST]\s+)?\d{2,5}[a-z★†]*(?:\s*/\s*\d{2,5})?\s*$"#,
            options: .regularExpression) != nil || isCardFooter(row.text))
    }
  }

  func completeSavedFooterObserved(_ lines: [[String: Any]]) -> Bool {
    let rows: [PartialText] = partialText(lines).filter { row in
      row.confidence >= 0.30 && row.box.minY >= 0.84 && row.box.maxY <= 0.99
        && row.box.minX < 0.65 && row.box.height > 0 && row.box.height < 0.05
    }
    return rows.contains { hasStructuredFooterCode($0.text) }
      && rows.contains { row in
        row.text.range(of: #"^\s*(?:[CMRULST]\s+)?\d{2,5}[a-z★†]*(?:\s*/\s*\d{2,5})?\s*$"#,
          options: .regularExpression) != nil
      }
  }

  func independentSavedFooterRowsObserved(_ lines: [[String: Any]]) -> Bool {
    let rows: [PartialText] = partialText(lines).filter { row in
      row.confidence >= 0.30 && row.box.minY >= 0.84 && row.box.maxY <= 0.99
        && row.box.height > 0 && row.box.height < 0.05
    }
    let number: PartialText? = rows.first { row in
      row.box.minX < 0.65 && row.text.range(of: #"^\s*(?:[CMRULST]\s+)?\d{2,5}[a-z★†]*(?:\s*/\s*\d{2,5})?\s*$"#,
        options: .regularExpression) != nil
    }
    guard let number else { return false }
    return rows.contains { row in
      normalizedCardText(row.text) != normalizedCardText(number.text)
        && abs(row.box.midY - number.box.midY) <= 0.08
        && (row.text.contains("©") || row.text.contains("™"))
    }
  }

  func savedFooterNeedsAlternateRead(_ lines: [[String: Any]]) -> Bool {
    let rows: [PartialText] = partialText(lines).filter { row in
      row.box.minX < 0.65 && row.box.minY >= 0.84 && row.box.height > 0 && row.box.height < 0.07
    }
    let numberPresent: Bool = rows.contains { row in
      row.confidence >= 0.30 && row.text.range(of: #"^\s*(?:[CMRULST]\s+)?\d{2,5}[a-z★†]*(?:\s*/\s*\d{2,5})?\s*$"#,
        options: .regularExpression) != nil
    }
    return numberPresent && !rows.contains { $0.confidence >= 0.85 && hasStructuredFooterCode($0.text) }
  }

  func savedNumericFooterRegion(_ lines: [[String: Any]]) -> CGRect? {
    guard completeSavedFooterObserved(lines) || independentSavedFooterRowsObserved(lines) else { return nil }
    let numbers: [PartialText] = partialText(lines).filter { row in
      row.confidence >= 0.30 && row.box.minX < 0.65 && row.box.minY >= 0.84
        && row.box.maxY <= 0.99 && row.box.height > 0 && row.box.height < 0.05
        && row.text.range(of: #"^\s*(?:[CMRULST]\s+)?\d{2,5}[a-z★†]*(?:\s*/\s*\d{2,5})?\s*$"#,
          options: .regularExpression) != nil
    }
    guard let first: PartialText = numbers.first else { return nil }
    var bounds: CGRect = first.box
    for row: PartialText in numbers.dropFirst() {
      guard overlapsPartial(first.box, row.box) else { return nil }
      bounds = bounds.union(row.box)
    }
    let padded: CGRect = bounds.insetBy(dx: -0.012, dy: -0.008)
    guard padded.minX >= 0, padded.maxX <= 0.65, padded.minY >= 0.82,
          padded.maxY <= 1, padded.width <= 0.35, padded.height <= 0.08 else { return nil }
    return CGRect(x: padded.minX, y: 1 - padded.maxY, width: padded.width, height: padded.height)
  }

  func savedAmbiguousFooterGeometryRegion(_ lines: [[String: Any]], originalCorners: [CGPoint],
      repairedCorners: [CGPoint]) -> CGRect? {
    guard savedCardLayout(lines), savedUprightTextSupported(lines),
          (originalCorners + repairedCorners).allSatisfy({ $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }),
          let original: SavedCardProjection = SavedCardProjection(corners: originalCorners),
          let repaired: SavedCardProjection = SavedCardProjection(corners: repairedCorners),
          let expression: NSRegularExpression = try? NSRegularExpression(
            pattern: #"^\s*[CMRULST]\s*([0-9][0-9A-Z]{2,4})\s*$"#, options: .caseInsensitive) else { return nil }
    var footprints: [CGRect] = []
    for line: [String: Any] in lines.prefix(96) {
      guard let row: PartialText = partialText([line]).first,
            row.confidence.isFinite, row.confidence >= 0.30, row.confidence <= 1,
            row.box.minX.isFinite, row.box.minY.isFinite, row.box.width.isFinite, row.box.height.isFinite,
            row.box.minX >= 0.01, row.box.maxX <= 0.65, row.box.minY >= 0.84, row.box.maxY <= 1.02,
            row.box.width > 0.025, row.box.width <= 0.30, row.box.height > 0, row.box.height < 0.05,
            let match: NSTextCheckingResult = expression.firstMatch(in: row.text,
              range: NSRange(row.text.startIndex..., in: row.text)),
            let range: Range<String.Index> = Range(match.range(at: 1), in: row.text) else { continue }
      let observed: Substring = row.text[range]
      guard observed.filter({ $0.isNumber }).count >= 2,
            observed.filter({ $0.isLetter }).count == 1 else { continue }
      func points(_ key: String) -> [CGPoint]? {
        guard let values: [[String: Double]] = line[key] as? [[String: Double]], values.count == 4 else { return nil }
        let result: [CGPoint] = values.compactMap { value in
          guard let x: Double = value["x"], let y: Double = value["y"], x.isFinite, y.isFinite else { return nil }
          return CGPoint(x: x, y: y)
        }
        return result.count == 4 ? result : nil
      }
      let box: [CGPoint] = [CGPoint(x: row.box.minX, y: row.box.minY),
        CGPoint(x: row.box.maxX, y: row.box.minY), CGPoint(x: row.box.maxX, y: row.box.maxY),
        CGPoint(x: row.box.minX, y: row.box.maxY)]
      if (line["sceneSourceGlyphCorners"] != nil && points("sceneSourceGlyphCorners") == nil)
          || (line["sceneGlyphCorners"] != nil && points("sceneGlyphCorners") == nil) { continue }
      guard let source: [CGPoint] = points("sceneSourceGlyphCorners")
              ?? original.unmap(points("sceneGlyphCorners") ?? box),
            source.allSatisfy({ $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }),
            let prior: [CGPoint] = original.map(source),
            prior.allSatisfy({ $0.x >= 0 && $0.x <= 1 && $0.y >= 0.84 && $0.y <= 1.02 }),
            let mapped: [CGPoint] = repaired.map(source),
            mapped.allSatisfy({ $0.x >= 0 && $0.x <= 0.65 && $0.y >= 0.84 && $0.y <= 0.99 }) else { continue }
      let horizontal: CGPoint = CGPoint(x: mapped[1].x - mapped[0].x, y: mapped[1].y - mapped[0].y)
      let vertical: CGPoint = CGPoint(x: mapped[3].x - mapped[0].x, y: mapped[3].y - mapped[0].y)
      guard horizontal.x > 0, abs(horizontal.y) <= horizontal.x * 0.30,
            vertical.y > 0, abs(vertical.x) <= vertical.y * 0.50,
            let left: CGFloat = mapped.map({ $0.x }).min(), let right: CGFloat = mapped.map({ $0.x }).max(),
            let top: CGFloat = mapped.map({ $0.y }).min(), let bottom: CGFloat = mapped.map({ $0.y }).max() else { continue }
      footprints.append(CGRect(x: left, y: top, width: right - left, height: bottom - top))
    }
    guard let first: CGRect = footprints.first else { return nil }
    var bounds: CGRect = first
    for footprint: CGRect in footprints.dropFirst() {
      guard overlapsPartial(first, footprint) else { return nil }
      bounds = bounds.union(footprint)
    }
    let padded: CGRect = bounds.insetBy(dx: -0.012, dy: -0.008)
    guard padded.minX >= 0, padded.maxX <= 0.65, padded.minY >= 0.82, padded.maxY <= 1,
          padded.width <= 0.35, padded.height <= 0.08 else { return nil }
    return CGRect(x: padded.minX, y: 1 - padded.maxY, width: padded.width, height: padded.height)
  }

  func savedGuidedFooterRetryRegion(_ lines: [[String: Any]], guide: CGRect?) -> CGRect? {
    guard !savedStrongCollectorObserved(lines), savedCardLayout(lines), savedUprightTextSupported(lines),
          let guide, guide.minX.isFinite, guide.minY.isFinite, guide.width.isFinite, guide.height.isFinite,
          guide.minX >= 0, guide.maxX <= 0.65, guide.minY >= 0, guide.maxY <= 0.18,
          guide.width > 0, guide.width <= 0.35, guide.height > 0, guide.height <= 0.08 else { return nil }
    let width: CGFloat = min(0.35, max(0.20, guide.width * 2.5))
    let height: CGFloat = min(0.08, max(0.06, guide.height * 2))
    let left: CGFloat = min(max(0, guide.minX - min(0.012, (width - guide.width) * 0.10)), 0.65 - width)
    let bottom: CGFloat = min(max(0, guide.minY - (height - guide.height) * 0.75), 0.18 - height)
    let context: CGRect = CGRect(x: left, y: bottom, width: width, height: height)
    return context.contains(guide) ? context : nil
  }

  func retainedSavedSceneFooterGuides(_ original: [[String: Any]], repairedLines: [[String: Any]],
      originalCorners: [CGPoint], repairedCorners: [CGPoint], neighboringCorners: [[CGPoint]] = [],
      imageAspect: CGFloat, acceptedRepair: Bool) -> [[String: Any]] {
    guard acceptedRepair, imageAspect.isFinite, imageAspect > 0,
          ([originalCorners, repairedCorners] + neighboringCorners).allSatisfy({ corners in
            corners.count == 4 && SavedCardProjection(corners: corners) != nil
              && corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite
                && $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 })
          }),
          !savedStrongCollectorObserved(original), !savedStrongCollectorObserved(repairedLines),
          savedCardLayout(original), savedUprightTextSupported(original),
          savedCardLayout(repairedLines), savedUprightTextSupported(repairedLines) else { return [] }
    func titles(_ lines: [[String: Any]]) -> Set<String> {
      Set(lines.filter { nameplateScore([$0]) > 0 && ($0["confidence"] as? Double ?? 0) >= 0.85 }
        .compactMap { ($0["text"] as? String).map { normalizedCardText($0) } })
    }
    func body(_ lines: [[String: Any]]) -> Set<String> {
      Set(partialText(lines).filter { $0.confidence >= 0.85 && isCardBody($0.text)
        && !isCardFooter($0.text) && $0.box.minY >= 0.35 && $0.box.maxY <= 0.93
        && $0.box.width >= 0.20 && $0.box.height > 0 && $0.box.height < 0.08 }
        .map { normalizedCardText($0.text) })
    }
    let oldTitles: Set<String> = titles(original)
    guard oldTitles.count == 1, oldTitles == titles(repairedLines),
          body(original).intersection(body(repairedLines)).count >= 2,
          let expression: NSRegularExpression = try? NSRegularExpression(
            pattern: #"^\s*[CMRULST]\s*([0-9]{1,3}[A-Z][0-9]{1,3})\s*$"#,
            options: .caseInsensitive) else { return [] }
    var result: [[String: Any]] = []
    for line: [String: Any] in original.prefix(96) {
      guard line["ocrSource"] as? String == "scene",
            let observed: PartialText = partialText([line]).first,
            observed.confidence.isFinite, observed.confidence >= 0.85, observed.confidence <= 1,
            observed.box.minX >= 0.01, observed.box.maxX <= 0.65, observed.box.minY >= 0.84,
            observed.box.maxY <= 1.02, observed.box.width > 0.025, observed.box.width <= 0.30,
            observed.box.height > 0, observed.box.height < 0.05,
            let match: NSTextCheckingResult = expression.firstMatch(in: observed.text,
              range: NSRange(observed.text.startIndex..., in: observed.text)),
            let field: Range<String.Index> = Range(match.range(at: 1), in: observed.text),
            observed.text[field].count >= 3, observed.text[field].count <= 5,
            let values: [[String: Double]] = line["sceneSourceGlyphCorners"] as? [[String: Double]],
            values.count == 4 else { continue }
      let source: [CGPoint] = values.compactMap { value in
        guard let x: Double = value["x"], let y: Double = value["y"],
              x.isFinite, y.isFinite, x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return CGPoint(x: x, y: y)
      }
      guard source.count == 4,
            savedSceneQuadOwner(source, cards: [originalCorners] + neighboringCorners) == 0,
            savedSceneQuadOwner(source, cards: [repairedCorners] + neighboringCorners) == 0,
            var mapped: [String: Any] = mappedSavedSceneLine(line, quad: source, glyph: source,
              corners: repairedCorners, imageAspect: imageAspect),
            let row: PartialText = partialText([mapped]).first,
            row.box.minX >= 0.01, row.box.maxX <= 0.65, row.box.minY >= 0.84, row.box.maxY <= 0.99,
            row.box.width > 0.025, row.box.width <= 0.30, row.box.height > 0, row.box.height < 0.05 else { continue }
      mapped["sceneFooterGuide"] = true
      result.append(mapped)
    }
    return result
  }

  func savedBorderRecoveryNeeded(_ lines: [[String: Any]]) -> Bool {
    let body: [PartialText] = partialText(lines).filter { row in
      row.confidence >= 0.65 && isCardBody(row.text) && !isCardFooter(row.text)
        && row.box.minY >= 0.35 && row.box.width >= 0.20
    }
    guard !body.isEmpty else { return false }
    let clippedFooter: Bool = partialText(lines).contains { row in
      row.confidence >= 0.30 && row.box.minX < 0.65 && row.box.minY >= 0.94
        && row.box.maxY >= 0.99 && row.box.height > 0 && row.box.height < 0.05
        && (hasStructuredFooterCode(row.text)
          || row.text.range(of: #"^\s*(?:[CMRULST]\s+)?\d{2,5}[a-z★†]*(?:\s*/\s*\d{2,5})?\s*$"#,
            options: .regularExpression) != nil)
    }
    let strongTitle: Bool = lines.contains { row in
      nameplateScore([row]) > 0 && (row["confidence"] as? Double ?? 0) >= 0.85
    }
    return nameplateScore(lines) == 0
      || (!savedFooterSupported(lines) && (body.contains { $0.box.maxY >= 0.92 }
        || (strongTitle && clippedFooter)))
  }

  private func recheckSavedOutline(_ crop: [String: Any], in image: CIImage,
      corners: [CGPoint], neighboringCorners: [[CGPoint]],
      recordOrientation: (([String: Any]) -> Void)?,
      recordTiming: ((String, Double) -> Void)?) throws -> (crop: [String: Any], corners: [CGPoint])? {
    let original: [[String: Any]] = crop["lines"] as? [[String: Any]] ?? []
    guard (crop["warnings"] as? [String] ?? []).contains("incomplete_card"),
          let left: CGFloat = corners.map({ $0.x }).min(), let right: CGFloat = corners.map({ $0.x }).max(),
          let bottom: CGFloat = corners.map({ $0.y }).min(), let top: CGFloat = corners.map({ $0.y }).max() else { return nil }
    let bounds: CGRect = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    let region: CGRect = bounds.insetBy(dx: -bounds.width * 0.12, dy: -bounds.height * 0.20)
      .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    let pixels: CGRect = CGRect(x: region.minX * image.extent.width, y: region.minY * image.extent.height,
      width: region.width * image.extent.width, height: region.height * image.extent.height)
    let request: VNDetectRectanglesRequest = VNDetectRectanglesRequest()
    request.minimumAspectRatio = 0.45
    request.maximumAspectRatio = 1
    request.minimumConfidence = 0.70
    request.minimumSize = 0.30
    request.quadratureTolerance = 35
    request.maximumObservations = 8
    try VNImageRequestHandler(ciImage: bounded(normalized(image.cropped(to: pixels)), edge: 2048),
      orientation: .up).perform([request])
    let originalArea: CGFloat = polygonArea(corners)
    recordOrientation?(["phase": "saved-outline-request", "observationCount": request.results?.count ?? 0,
      "region": ["x": Double(region.minX), "y": Double(1 - region.maxY),
        "width": Double(region.width), "height": Double(region.height)]])
    let candidates: [[CGPoint]] = (request.results ?? []).compactMap { observation in
      let local: [CGPoint] = rectangleCorners(observation)
      let proposed: [CGPoint] = local.map {
        CGPoint(x: region.minX + $0.x * region.width, y: region.minY + $0.y * region.height)
      }
      func record(_ reason: String) {
        recordOrientation?(["phase": "saved-outline-candidate", "reason": reason,
          "confidence": Double(observation.confidence), "localCorners": local.map(pointMap),
          "sourceCorners": proposed.map(pointMap)])
      }
      guard local.allSatisfy({ $0.x > 0.01 && $0.x < 0.99 && $0.y > 0.01 && $0.y < 0.99 }) else {
        record("roi_boundary"); return nil
      }
      let area: CGFloat = polygonArea(proposed)
      guard SavedCardProjection(corners: proposed) != nil else { record("invalid_quad"); return nil }
      guard area >= originalArea * 0.70, area <= originalArea * 1.60 else { record("area_change"); return nil }
      guard polygonIntersection(proposed, corners) / min(area, originalArea) >= 0.75 else {
        record("different_region"); return nil
      }
      guard neighboringCorners.allSatisfy({
        polygonIntersection(proposed, $0) <= polygonIntersection(corners, $0) + 0.000001
      }) else { record("neighbor_overlap"); return nil }
      guard (zip(proposed, corners).map({ pair in
        hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y)
      }).max() ?? 0) > 0.008 else { record("unchanged"); return nil }
      record("eligible")
      return proposed
    }.sorted { polygonArea($0) > polygonArea($1) }
    recordOrientation?(["phase": "saved-outline-proposals", "sourceCorners": corners.map(pointMap),
      "candidates": candidates.map { $0.map(pointMap) }])
    guard let proposed: [CGPoint] = candidates.first,
          let corrected: CIImage = image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": vector(proposed[0], in: image), "inputTopRight": vector(proposed[1], in: image),
            "inputBottomRight": vector(proposed[2], in: image), "inputBottomLeft": vector(proposed[3], in: image)
          ]).finiteImage else { return nil }
    var candidate: [String: Any] = try recognizeCrop(canonicalCardAspect(normalized(corrected)),
      sourceCorners: proposed.map(pointMap), rectified: true, allowRotation: false,
      recordOrientation: recordOrientation, recordTiming: recordTiming)
    let lines: [[String: Any]] = candidate["lines"] as? [[String: Any]] ?? []
    func body(_ rows: [[String: Any]]) -> Set<String> {
      Set(partialText(rows).filter { $0.confidence >= 0.65 && isCardBody($0.text) && !isCardFooter($0.text) }
        .map { normalizedCardText($0.text) })
    }
    let sameBody: Bool = body(original).intersection(body(lines)).count >= 2
    let improved: Bool = nameplateScore(lines) > nameplateScore(original)
      || (savedFooterSupported(lines) && !savedFooterSupported(original))
      || (completeSavedFooterObserved(lines) && !completeSavedFooterObserved(original))
    let accepted: Bool = sameBody && improved && savedCardLayout(lines)
    recordOrientation?(["phase": "saved-outline-result", "accepted": accepted, "sameBody": sameBody,
      "improved": improved, "sourceCorners": proposed.map(pointMap), "lines": Array(lines.prefix(96))])
    guard accepted else {
      if let path: String = candidate["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
      return nil
    }
    candidate["warnings"] = mergingSavedRecoveryWarnings(crop["warnings"] as? [String] ?? [],
      into: (candidate["warnings"] as? [String] ?? []) + ["border_recovered", "geometry_adjusted"])
    return (candidate, proposed)
  }

  private func recoverSavedBorder(_ crop: [String: Any], in image: CIImage,
      corners: [CGPoint], neighboringCorners: [[CGPoint]],
      recordOrientation: (([String: Any]) -> Void)?,
      recordTiming: ((String, Double) -> Void)? = nil) throws -> [String: Any]? {
    let original: [[String: Any]] = crop["lines"] as? [[String: Any]] ?? []
    let missingTitle: Bool = nameplateScore(original) == 0 || crop["sceneProbeTop"] as? Bool == true
    let missingFooter: Bool = !savedFooterSupported(original) || crop["sceneProbeBottom"] as? Bool == true
    guard let expanded = expandedSavedCardCorners(corners, top: missingTitle ? 0.08 : 0,
      bottom: missingFooter ? 0.12 : 0, horizontal: missingTitle ? 0.04 : 0.02,
      neighboringCorners: neighboringCorners) else {
      recordOrientation?(["phase": "saved-border-geometry", "accepted": false,
        "reason": "bounded_geometry_or_neighbor_overlap", "sourceCorners": corners.map(pointMap),
        "neighbors": neighboringCorners.map { $0.map(pointMap) }])
      return nil
    }
    guard let corrected = image.applyingFilter("CIPerspectiveCorrection", parameters: [
        "inputTopLeft": vector(expanded[0], in: image), "inputTopRight": vector(expanded[1], in: image),
        "inputBottomRight": vector(expanded[2], in: image), "inputBottomLeft": vector(expanded[3], in: image)
      ]).finiteImage else {
      recordOrientation?(["phase": "saved-border-geometry", "accepted": false,
        "reason": "rectification_failed", "sourceCorners": expanded.map(pointMap)])
      return nil
    }
    let oldBody: Set<String> = Set(partialText(original).filter {
      $0.confidence >= 0.65 && isCardBody($0.text) && !isCardFooter($0.text)
    }.map { normalizedCardText($0.text) })
    let footerGuide: CGRect? = savedAmbiguousFooterGeometryRegion(original,
      originalCorners: corners, repairedCorners: expanded)
    if let footerGuide {
      recordOrientation?(["phase": "saved-footer-geometry-guide", "sourceCorners": expanded.map(pointMap),
        "originalLines": Array(original.prefix(96)), "region": ["x": Double(footerGuide.minX),
          "y": Double(footerGuide.minY), "width": Double(footerGuide.width), "height": Double(footerGuide.height)]])
    }
    var recovered: [String: Any] = try recognizeCrop(canonicalCardAspect(normalized(corrected)),
      sourceCorners: expanded.map(pointMap), rectified: true, allowRotation: false,
      footerGeometryGuide: footerGuide,
      recordOrientation: recordOrientation, recordTiming: recordTiming)
    let lines: [[String: Any]] = recovered["lines"] as? [[String: Any]] ?? []
    let repeatsBody: Bool = partialText(lines).contains {
      $0.confidence >= 0.65 && oldBody.contains(normalizedCardText($0.text))
    }
    let improves: Bool = (nameplateScore(lines) > nameplateScore(original))
      || (savedFooterSupported(lines) && !savedFooterSupported(original))
      || (completeSavedFooterObserved(lines) && !completeSavedFooterObserved(original))
      || (independentSavedFooterRowsObserved(lines) && !independentSavedFooterRowsObserved(original))
    recordOrientation?(["phase": "saved-border-result", "sourceCorners": expanded.map(pointMap),
      "accepted": repeatsBody && improves, "repeatsBody": repeatsBody, "improves": improves,
      "nameplateScore": nameplateScore(lines), "originalNameplateScore": nameplateScore(original),
      "footerSupported": savedFooterSupported(lines), "originalFooterSupported": savedFooterSupported(original),
      "completeFooterObserved": completeSavedFooterObserved(lines),
      "originalCompleteFooterObserved": completeSavedFooterObserved(original),
      "independentFooterRows": independentSavedFooterRowsObserved(lines),
      "originalIndependentFooterRows": independentSavedFooterRowsObserved(original),
      "width": recovered["width"] ?? 0, "height": recovered["height"] ?? 0,
      "lines": Array(lines.prefix(96))])
    guard repeatsBody && improves else {
      if let path = recovered["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
      return nil
    }
    let aspect: CGFloat = CGFloat(recovered["width"] as? Int ?? 0) / CGFloat(max(1, recovered["height"] as? Int ?? 1))
    let guides: [[String: Any]] = retainedSavedSceneFooterGuides(original, repairedLines: lines,
      originalCorners: corners, repairedCorners: expanded, neighboringCorners: neighboringCorners,
      imageAspect: aspect, acceptedRepair: true)
    recovered["lines"] = lines + guides
    if !guides.isEmpty {
      recordOrientation?(["phase": "saved-footer-scene-retained", "sourceCorners": expanded.map(pointMap),
        "lines": Array(guides.prefix(16))])
    }
    var warnings: [String] = recovered["warnings"] as? [String] ?? []
    warnings.append("border_recovered")
    recovered["warnings"] = warnings
    return recovered
  }

  private func partialCardCrops(_ image: CIImage, covered: [CGRect], limit: Int,
      diagnostics: (([String: Any]) -> Void)? = nil) throws -> [[String: Any]] {
    guard limit > 0 else { return [] }
    var evidence: [String: Any] = [:]
    let recordAnchors: (([String: Any]) -> Void)? = diagnostics == nil ? nil : { evidence = $0 }
    let recordCrops: (([[String: Any]]) -> Void)? = diagnostics == nil ? nil : { evidence["verification"] = $0 }
    let anchors = try partialAnchors(image, covered: covered, diagnostics: recordAnchors)
    let crops: [[String: Any]] = partialCrops(image, anchors: anchors, covered: covered, limit: limit, diagnostics: recordCrops)
    diagnostics?(evidence)
    return crops
  }

  func savedBasicLandGuideRegions(_ observations: [[String: Any]], imageSize: CGSize,
      covered: [CGRect]) -> [CGRect] {
    guard imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0 else { return [] }
    let rows: [PartialText] = partialText(observations).filter { row in
      row.confidence.isFinite && row.box.minX.isFinite && row.box.minY.isFinite
        && row.box.width.isFinite && row.box.height.isFinite && row.box.width > 0 && row.box.height > 0
        && row.box.minX >= 0 && row.box.minY >= 0 && row.box.maxX <= 1 && row.box.maxY <= 1
    }
    let types: [PartialText] = rows.filter { row in
      row.confidence >= 0.85 && row.text.range(of: #"^Basic\s+(?:Snow\s+)?Land(?:\s*[—–-]\s*[A-Za-z ]+)?$"#,
        options: [.regularExpression, .caseInsensitive]) != nil
        && !covered.contains(where: { $0.contains(CGPoint(x: row.box.midX, y: 1 - row.box.midY)) })
    }
    var regions: [CGRect] = []
    for type: PartialText in types {
      let titles: [PartialText] = rows.filter { row in
        row.confidence >= 0.85 && isCardTitle(row.text) && row.box.maxY < type.box.minY
          && abs(row.box.minX - type.box.minX) <= max(0.025, type.box.width * 0.50)
          && row.box.height >= type.box.height * 0.50 && row.box.height <= type.box.height * 3
          && !covered.contains(where: { $0.contains(CGPoint(x: row.box.midX, y: 1 - row.box.midY)) })
      }.sorted { $0.box.minY > $1.box.minY }
      for title: PartialText in titles.prefix(2) {
        let footers: [PartialText] = rows.filter { row in
          row.confidence >= 0.30 && row.box.minY > type.box.maxY && row.box.height <= title.box.height * 1.50
            && (row.text.range(of: #"^\s*(?:[CMRULST]\s+)?\d{1,5}[a-z★†]*(?:\s*/+\s*\d{2,5})?(?:\s*[CMRULST])?\s*$"#,
              options: .regularExpression) != nil || row.text.contains("©") || row.text.contains("™"))
        }.sorted { $0.box.minY < $1.box.minY }
        for footer: PartialText in footers.prefix(4) {
          let height: CGFloat = (footer.box.midY - title.box.midY) / 0.90
          let width: CGFloat = height * imageSize.height / imageSize.width * 0.714
          let left: CGFloat = min(title.box.minX, type.box.minX)
          guard height >= 0.08, height <= 0.85, width >= 0.035, width <= 0.80,
                footer.box.midX >= left - width * 0.15 && footer.box.midX <= left + width * 1.10,
                !covered.contains(where: { $0.contains(CGPoint(x: footer.box.midX, y: 1 - footer.box.midY)) }) else { continue }
          let top: CGFloat = max(0, title.box.minY - height * 0.07)
          let bottom: CGFloat = min(1, footer.box.maxY + height * 0.08)
          let right: CGFloat = min(1, [title.box.maxX, type.box.maxX, footer.box.maxX, left + width * 1.08].max() ?? 0)
          let paddedLeft: CGFloat = max(0, left - width * 0.14)
          let proposed: CGRect = CGRect(x: paddedLeft, y: 1 - bottom,
            width: right - paddedLeft, height: bottom - top)
          guard !proposed.isEmpty, !regions.contains(where: { overlapsPartial($0, proposed) }) else { continue }
          regions.append(proposed)
          break
        }
        if regions.count == 2 { return regions }
      }
    }
    return regions
  }

  func savedRecoveredBasicLandSupported(_ lines: [[String: Any]]) -> Bool {
    let physicalFooter: Bool = partialText(lines).contains { row in
      row.confidence >= 0.85 && row.box.minY >= 0.88 && row.box.maxY <= 0.99
        && row.box.height > 0 && row.box.height < 0.07
        && (hasStructuredFooterCode(row.text) || isCardFooter(row.text))
    }
    return !savedNameplateNeedsRead(lines) && savedBasicLandTypeSupported(lines)
      && (savedStrongCollectorObserved(lines) || physicalFooter) && savedCardLayout(lines)
  }

  func savedBasicLandIdentitySupported(_ lines: [[String: Any]]) -> Bool {
    !savedNameplateNeedsRead(lines) && savedBasicLandTypeSupported(lines)
      && partialText(lines).contains { row in
        row.confidence >= 0.30 && row.box.minY >= 0.88 && row.box.maxY <= 1
          && row.box.height > 0 && row.box.height < 0.055 && row.box.minX < 0.65
          && (hasValidFooterCode(row.text) || row.text.range(of: #"\d{2,5}\s*/+\s*\d{2,5}"#,
            options: .regularExpression) != nil)
      }
  }

  func savedBasicLandGeometryRegions(imageSize: CGSize) -> [CGRect] {
    guard imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0 else { return [] }
    if imageSize.width >= imageSize.height {
      return [CGRect(x: 0, y: 0, width: 0.60, height: 1), CGRect(x: 0.40, y: 0, width: 0.60, height: 1)]
    }
    return [CGRect(x: 0, y: 0, width: 1, height: 0.60), CGRect(x: 0, y: 0.40, width: 1, height: 0.60)]
  }

  func savedBasicLandRetryCandidateAllowed(_ local: [CGPoint], region: CGRect, occupied: [CGRect]) -> Bool {
    guard local.count == 4, local.allSatisfy({ point in
      (region.minX == 0 || point.x > 0.002) && (region.maxX == 1 || point.x < 0.998)
        && (region.minY == 0 || point.y > 0.002) && (region.maxY == 1 || point.y < 0.998)
    }) else { return false }
    let corners: [CGPoint] = local.compactMap { savedScenePoint($0, in: region) }
    guard corners.count == 4, SavedCardProjection(corners: corners) != nil else { return false }
    return occupied.allSatisfy { known in
      polygonIntersection(corners, [CGPoint(x: known.minX, y: known.maxY), CGPoint(x: known.maxX, y: known.maxY),
        CGPoint(x: known.maxX, y: known.minY), CGPoint(x: known.minX, y: known.minY)]) <= 0.00000001
    }
  }

  func savedBasicLandFooterExpansion(_ lines: [[String: Any]], scene: [[String: Any]],
      corners: [CGPoint], occupied: [CGRect]) -> [CGPoint]? {
    guard !savedNameplateNeedsRead(lines),
          partialText(lines).contains(where: { row in
            row.confidence >= 0.85 && row.box.minY >= 0.87 && row.box.maxY <= 1
              && row.text.range(of: #"^Basic\s+(?:Snow\s+)?Land(?:\s*[—–-]\s*[A-Za-z ]+)?$"#,
                options: [.regularExpression, .caseInsensitive]) != nil
          }), let projection = SavedCardProjection(corners: corners) else { return nil }
    let footerBottoms: [CGFloat] = partialText(scene).compactMap { row in
      guard row.confidence >= 0.30, row.box.height > 0,
            row.text.range(of: #"^\s*(?:[CMRULST]\s+)?\d{1,5}[a-z★†]*(?:\s*/+\s*\d{2,5})?(?:\s*[CMRULST])?\s*$"#,
              options: .regularExpression) != nil || isCardFooter(row.text),
            let center = projection.map(CGPoint(x: row.box.midX, y: 1 - row.box.midY)),
            let bottom = projection.map(CGPoint(x: row.box.midX, y: 1 - row.box.maxY)),
            center.x >= 0.02, center.x <= 0.98, center.y > 1, center.y <= 1.12,
            bottom.y >= center.y, bottom.y <= 1.12 else { return nil }
      return bottom.y
    }
    guard let bottom = footerBottoms.max() else { return nil }
    let neighbors: [[CGPoint]] = occupied.map { region in
      [CGPoint(x: region.minX, y: region.maxY), CGPoint(x: region.maxX, y: region.maxY),
        CGPoint(x: region.maxX, y: region.minY), CGPoint(x: region.minX, y: region.minY)]
    }
    return expandedSavedCardCorners(corners, top: 0, bottom: min(0.14, bottom - 1 + 0.055),
      horizontal: 0, neighboringCorners: neighbors)
  }

  private func savedBasicLandSceneGuide(_ observations: [[String: Any]], corners: [CGPoint]) -> [[String: Any]] {
    guard let projection = SavedCardProjection(corners: corners) else { return [] }
    return observations.compactMap { line in
      guard let row = partialText([line]).first,
            let points = projection.map([
              CGPoint(x: row.box.minX, y: 1 - row.box.minY), CGPoint(x: row.box.maxX, y: 1 - row.box.minY),
              CGPoint(x: row.box.maxX, y: 1 - row.box.maxY), CGPoint(x: row.box.minX, y: 1 - row.box.maxY)
            ]), points.allSatisfy({ $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }),
            let left = points.map({ $0.x }).min(), let right = points.map({ $0.x }).max(),
            let top = points.map({ $0.y }).min(), let bottom = points.map({ $0.y }).max() else { return nil }
      var mapped = line
      mapped["bounds"] = ["x": Double(left), "y": Double(top), "width": Double(right - left), "height": Double(bottom - top)]
      return mapped
    }
  }

  func savedBasicLandCrops(_ image: CIImage, observations: [[String: Any]], covered: [CGRect],
      limit: Int, presenceOnly: Bool = false, diagnostics: (([String: Any]) -> Void)?) -> [[String: Any]] {
    let started: TimeInterval = ProcessInfo.processInfo.systemUptime
    let textGuides: [CGRect] = savedBasicLandGuideRegions(observations, imageSize: image.extent.size, covered: covered)
    let guides: [CGRect] = textGuides.isEmpty && !presenceOnly
      ? savedBasicLandGeometryRegions(imageSize: image.extent.size) : textGuides
    var crops: [[String: Any]] = []
    var occupied: [CGRect] = covered
    var attempts: [[String: Any]] = []
    var detections: [[String: Any]] = []
    var totalCandidateAttempts: Int = 0
    defer {
      diagnostics?(["mode": textGuides.isEmpty ? (presenceOnly ? "no_text_guide" : "geometry") : "text", "guides": guides.map { ["x": Double($0.minX), "y": Double(1 - $0.maxY),
        "width": Double($0.width), "height": Double($0.height)] }, "attempts": attempts, "detections": detections,
        "elapsedMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000])
    }
    for guide: CGRect in guides.prefix(2) {
      guard crops.count < limit, !presenceOnly || totalCandidateAttempts < 2 else { break }
      let pixels: CGRect = CGRect(x: guide.minX * image.extent.width, y: guide.minY * image.extent.height,
        width: guide.width * image.extent.width, height: guide.height * image.extent.height)
      let request: VNDetectRectanglesRequest = VNDetectRectanglesRequest()
      request.minimumAspectRatio = 0.55
      request.maximumAspectRatio = 0.85
      request.minimumConfidence = 0.50
      request.minimumSize = textGuides.isEmpty ? 0.08 : 0.25
      request.quadratureTolerance = 40
      request.maximumObservations = textGuides.isEmpty ? 8 : 4
      do {
        try VNImageRequestHandler(ciImage: bounded(normalized(image.cropped(to: pixels)), edge: 2048),
          orientation: .up).perform([request])
      } catch { continue }
      let detected: [VNRectangleObservation] = (request.results ?? []).sorted {
        $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height
      }
      var candidateAttempts: Int = 0
      for rectangle: VNRectangleObservation in detected {
        guard crops.count < limit, candidateAttempts < 2,
          !presenceOnly || totalCandidateAttempts < 2 else { break }
        let local: [CGPoint] = rectangleCorners(rectangle)
        var corners: [CGPoint] = local.compactMap { savedScenePoint($0, in: guide) }
        let allowed: Bool = savedBasicLandRetryCandidateAllowed(local, region: guide, occupied: occupied)
        if diagnostics != nil {
          detections.append(["eligible": allowed, "sourceCorners": corners.map(pointMap),
            "rectangleConfidence": Double(rectangle.confidence)])
        }
        guard allowed else { continue }
        candidateAttempts += 1
        totalCandidateAttempts += 1
        let observed = savedBasicLandSceneGuide(observations, corners: corners)
        let expandedBeforeRead = savedBasicLandFooterExpansion(observed, scene: observations,
          corners: corners, occupied: occupied)
        if let expandedBeforeRead { corners = expandedBeforeRead }
        guard let corrected: CIImage = image.applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": vector(corners[0], in: image), "inputTopRight": vector(corners[1], in: image),
                "inputBottomRight": vector(corners[2], in: image), "inputBottomLeft": vector(corners[3], in: image)
              ]).finiteImage else { continue }
        guard var crop: [String: Any] = try? autoreleasepool(invoking: {
          try recognizeCrop(normalized(corrected), sourceCorners: corners.map(pointMap), rectified: true,
            allowRotation: false, allowGeometryRepair: false, presenceOnly: presenceOnly)
        }) else { continue }
        if expandedBeforeRead != nil {
          crop["warnings"] = (crop["warnings"] as? [String] ?? []) + ["border_recovered"]
        }
        if !presenceOnly, let expanded = savedBasicLandFooterExpansion(crop["lines"] as? [[String: Any]] ?? [],
            scene: observations, corners: corners, occupied: occupied),
            let extended = image.applyingFilter("CIPerspectiveCorrection", parameters: [
              "inputTopLeft": vector(expanded[0], in: image), "inputTopRight": vector(expanded[1], in: image),
              "inputBottomRight": vector(expanded[2], in: image), "inputBottomLeft": vector(expanded[3], in: image)
            ]).finiteImage,
            var full: [String: Any] = try? recognizeCrop(normalized(extended), sourceCorners: expanded.map(pointMap),
              rectified: true, allowRotation: false, allowGeometryRepair: false) {
          if diagnostics != nil {
            attempts.append(["phase": "footer-extension", "sourceCorners": expanded.map(pointMap),
              "lines": full["lines"] ?? [], "warnings": full["warnings"] ?? [],
              "width": full["width"] ?? 0, "height": full["height"] ?? 0])
          }
          if savedRecoveredBasicLandSupported(full["lines"] as? [[String: Any]] ?? [])
              || savedBasicLandIdentitySupported(full["lines"] as? [[String: Any]] ?? []) {
            if let path = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
            full["warnings"] = (full["warnings"] as? [String] ?? []) + ["border_recovered"]
            crop = full
          } else if let path = full["imagePath"] as? String {
            try? FileManager.default.removeItem(atPath: path)
          }
        }
        let lines: [[String: Any]] = crop["lines"] as? [[String: Any]] ?? []
        let warnings: [String] = crop["warnings"] as? [String] ?? []
        let strongFooter: Bool = savedRecoveredBasicLandSupported(lines)
        let accepted: Bool = (strongFooter || savedBasicLandIdentitySupported(lines)) && !warnings.contains("incomplete_card")
          && !warnings.contains("no_card_rectangle") && crop["rectified"] as? Bool == true
        if diagnostics != nil {
          attempts.append(["accepted": accepted, "sourceCorners": corners.map(pointMap),
            "rectangleConfidence": Double(rectangle.confidence), "lines": Array(lines.prefix(64))])
        }
        guard accepted, let region: CGRect = cropRegion(crop) else {
          if let path: String = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
          continue
        }
        let addedWarnings: [String] = ["partial_card", "basic_land_outline"] + (strongFooter ? [] : ["unread_footer"])
        crop["warnings"] = warnings + addedWarnings.filter { !warnings.contains($0) }
        crops.append(crop)
        occupied.append(region)
        break
      }
    }
    return crops
  }

  func outsideSavedCardTextNeedsRecovery(_ observations: [[String: Any]], covered: [CGRect]) -> Bool {
    let rules: Set<String> = ["creature", "creatures", "artifact", "card", "cards", "damage", "source", "prevent",
      "draw", "discard", "mana", "counter", "graveyard", "battlefield", "opponent", "life", "target"]
    for row: PartialText in partialText(observations) where row.confidence >= 0.30 {
      let visionCenter: CGPoint = CGPoint(x: row.box.midX, y: 1 - row.box.midY)
      if covered.contains(where: { $0.contains(visionCenter) }) { continue }
      if isCardTypeProposal(row.text) { return true }
      guard row.box.width >= row.box.height * 2 && isCardBody(row.text) && !isCardFooter(row.text) else { continue }
      let words: Set<String> = Set(row.text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
      if words.intersection(rules).count >= 2 { return true }
    }
    return false
  }

  private func outsideSavedCardEvidence(_ image: CIImage, covered: [CGRect]) throws -> Bool {
    let rows: [SavedSceneRow] = try savedSceneRows(image)
    return outsideSavedCardTextNeedsRecovery(rows.map { $0.line }, covered: covered)
  }

  private func partialAnchors(_ image: CIImage, covered: [CGRect],
      diagnostics: (([String: Any]) -> Void)? = nil) throws -> [PartialAnchor] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.004
    configureCardTextLanguages(request)
    try VNImageRequestHandler(ciImage: bounded(image, edge: 4096), orientation: .up).perform([request])
    let lines: [PartialText] = (request.results ?? []).compactMap { observation in
      guard let text = observation.topCandidates(1).first else { return nil }
      return PartialText(text: text.string, confidence: Double(text.confidence), box: observation.boundingBox)
    }
    var anchors: [PartialAnchor] = []
    var probes = 0
    for observedType in lines where observedType.confidence >= 0.65 && isCardTypeProposal(observedType.text) {
      var type = observedType
      guard !covered.contains(where: { $0.contains(CGPoint(x: type.box.midX, y: type.box.midY)) }) else { continue }
      var available = lines
      if !isCardType(type.text) {
        guard probes < 3, type.confidence >= 0.85,
              let title = partialTitles(lines, type: type, image: image, covered: covered, footerLines: lines)
                .first(where: { $0.confidence >= 0.85 }) else { continue }
        let height = (title.box.midY - type.box.midY) / 0.43
        let width = height * image.extent.height / image.extent.width * 0.714
        guard height >= 0.08, height <= 0.85, width >= 0.06, width <= 1 else { continue }
        let region = CGRect(x: min(title.box.minX, type.box.minX) - width * 0.04,
          y: title.box.maxY + height * 0.035 - height, width: width, height: height)
          .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let body = lines.filter { line in
          line.confidence >= 0.80 && isCardBody(line.text)
            && line.box.maxY <= type.box.midY && line.box.midY >= region.minY + region.height * 0.10
            && abs(line.box.minX - type.box.minX) <= width * 0.18
            && line.box.width >= type.box.width * 0.60
            && line.box.midX >= region.minX && line.box.midX <= region.maxX
        }
        let words = Set(body.flatMap { $0.text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) })
        let rulesWords: Set<String> = ["opponent", "opponents", "token", "tokens", "sacrifice", "damage",
          "spell", "spells", "creature", "creatures", "life", "mana", "nonland", "battlefield", "graveyard"]
        guard !region.isEmpty, region.width >= width * 0.55, region.height >= height * 0.60,
              Set(body.map { normalizedCardText($0.text) }).count >= 2,
              words.intersection(rulesWords).count >= 2,
              !covered.contains(where: { overlapsPartial(region, $0) }) else { continue }
        probes += 1
        guard let local = try? partialRegionText(image, region: region),
              let verifiedType = local.first(where: { $0.confidence >= 0.85 && isCardType($0.text)
                && abs($0.box.midY - type.box.midY) < 0.04
                && abs($0.box.minX - type.box.minX) < width * 0.18 }) else { continue }
        available = local
        type = verifiedType
      }
      if !available.contains(where: { $0.box.midY > type.box.midY && isCardTitle($0.text)
        && abs($0.box.minX - type.box.minX) < 0.06 && $0.confidence >= 0.65 }), probes < 3 {
        let body = lines.filter { line in
          line.confidence >= 0.55 && isCardBody(line.text) && line.box.maxY <= type.box.midY
            && line.box.midY >= type.box.minY - 0.22
            && abs(line.box.minX - type.box.minX) <= max(0.015, type.box.width * 0.35)
            && line.box.width >= type.box.width * 0.60
        }
        if let width = body.map({ $0.box.width }).max() {
          let proposedWidth = width / 0.90
          let proposedHeight = proposedWidth * image.extent.width / image.extent.height / 0.714
          let proposed = CGRect(x: type.box.minX - proposedWidth * 0.04,
            y: type.box.midY - proposedHeight * 0.48, width: proposedWidth, height: proposedHeight)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
          if proposedHeight >= 0.08 && proposedHeight <= 0.85 && proposedWidth <= 1
              && !proposed.isEmpty && !covered.contains(where: { overlapsPartial(proposed, $0) }) {
            probes += 1
            if let local = try? partialRegionText(image, region: proposed),
               let repeatedType = local.first(where: { $0.confidence >= 0.65
                 && normalizedCardText($0.text) == normalizedCardText(type.text)
                 && abs($0.box.midY - type.box.midY) < 0.04 }) {
              available = local
              type = repeatedType
            }
          }
        }
      }
      let titles = partialTitles(available, type: type, image: image, covered: covered, footerLines: lines)
      guard let title = titles.first else { continue }
      let height = (title.box.midY - type.box.midY) / 0.43
      let width = height * image.extent.height / image.extent.width * 0.714
      guard height >= 0.08, height <= 0.85, width >= 0.06, width <= 1 else { continue }
      let left = min(title.box.minX, type.box.minX) - width * 0.04
      let top = title.box.maxY + height * 0.035
      let region = CGRect(x: left, y: top - height, width: width, height: height)
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
      guard !region.isEmpty, region.width >= width * 0.55, region.height >= height * 0.60,
            !covered.contains(where: { overlapsPartial(region, $0) }),
            available.contains(where: { body in
              body.confidence >= 0.55 && isCardBody(body.text)
                && body.box.maxY <= type.box.midY && body.box.midY >= region.minY + region.height * 0.10
                && abs(body.box.minX - type.box.minX) <= width * 0.18
                && body.box.width >= type.box.width * 0.60
                && body.box.midX >= region.minX && body.box.midX <= region.maxX
            }) else { continue }
      anchors.append(PartialAnchor(title: title, type: type, region: region))
    }
    anchors.sort { $0.title.confidence + $0.type.confidence > $1.title.confidence + $1.type.confidence }
    if let diagnostics {
      func box(_ region: CGRect) -> [String: Double] {
        ["x": Double(region.minX), "y": Double(region.minY), "width": Double(region.width), "height": Double(region.height)]
      }
      diagnostics(["lines": lines.map { ["text": $0.text, "confidence": $0.confidence, "bounds": box($0.box)] },
        "anchors": anchors.map { ["title": $0.title.text, "type": $0.type.text, "region": box($0.region)] },
        "covered": covered.map(box)])
    }
    return anchors
  }

  private func partialTitles(_ lines: [PartialText], type: PartialText, image: CIImage,
      covered: [CGRect], footerLines: [PartialText]) -> [PartialText] {
    lines.filter { title in
      let gap = title.box.midY - type.box.midY
      return title.confidence >= 0.65 && isCardTitle(title.text)
        && gap > max(0.035, type.box.height * 4) && gap < 0.35
        && title.box.height >= type.box.height * 0.5 && title.box.height <= type.box.height * 2.8
        && abs(title.box.minX - type.box.minX) < gap * image.extent.height / image.extent.width * 0.25
        && !covered.contains(where: { $0.contains(CGPoint(x: title.box.midX, y: title.box.midY)) })
        && !footerLines.contains(where: { footer in
          let width = gap / 0.43 * image.extent.height / image.extent.width * 0.714
          return footer.confidence >= 0.5 && isCardFooter(footer.text)
            && footer.box.midY < title.box.midY && footer.box.midY > type.box.midY
            && footer.box.midX >= min(title.box.minX, type.box.minX) - width * 0.04
            && footer.box.midX <= min(title.box.minX, type.box.minX) + width
        })
    }.sorted { $0.box.midY - type.box.midY < $1.box.midY - type.box.midY }
  }

  private func partialCrops(_ image: CIImage, anchors: [PartialAnchor], covered: [CGRect], limit: Int,
      diagnostics: (([[String: Any]]) -> Void)? = nil) -> [[String: Any]] {
    var regions = covered
    var crops: [[String: Any]] = []
    var attempts = 0
    var verification: [[String: Any]] = []
    defer { diagnostics?(verification) }
    for anchor in anchors {
      guard crops.count < min(3, limit), attempts < 3 else { break }
      guard !regions.contains(where: { overlapsPartial(anchor.region, $0) }) else { continue }
      attempts += 1
      let region = anchor.region
      let pixels = CGRect(x: region.minX * image.extent.width, y: region.minY * image.extent.height,
        width: region.width * image.extent.width, height: region.height * image.extent.height)
      let corners = [CGPoint(x: region.minX, y: region.maxY), CGPoint(x: region.maxX, y: region.maxY),
        CGPoint(x: region.maxX, y: region.minY), CGPoint(x: region.minX, y: region.minY)]
      guard var crop = try? autoreleasepool(invoking: {
        try recognizeCrop(normalized(image.cropped(to: pixels)), sourceCorners: corners.map(pointMap),
          rectified: false, allowRotation: false)
      }) else { continue }
      let verified = partialText(crop["lines"] as? [[String: Any]] ?? [])
      let type = verified.first { $0.confidence >= 0.65 && $0.box.minY >= 0.28 && $0.box.minY < 0.65
        && isCardType($0.text) && normalizedCardText($0.text) == normalizedCardText(anchor.type.text) }
      let body: [PartialText] = type.map { (type: PartialText) in
        verified.filter { (line: PartialText) in
          line.confidence >= 0.55 && isCardBody(line.text)
            && line.box.minY >= type.box.maxY && line.box.minY < 0.90
            && abs(line.box.minX - type.box.minX) < 0.18 && line.box.width >= type.box.width * 0.60
        }
      } ?? []
      let proposedTitle: String = normalizedCardText(anchor.title.text)
      let title: PartialText? = verified.first { (line: PartialText) in
        line.confidence >= 0.65 && line.box.minY < 0.13 && line.box.minX < 0.6
          && matchesPartialTitle(line, proposed: anchor.title.text, body: body)
      }
      if diagnostics != nil {
        verification.append(["anchorTitle": anchor.title.text, "anchorType": anchor.type.text,
          "titleMatched": title != nil, "typeMatched": type != nil,
          "titleRecoveredLeadingGlyph": title.map { normalizedCardText($0.text) != proposedTitle } ?? false,
          "lines": crop["lines"] as? [[String: Any]] ?? []])
      }
      guard let title, let type, !body.isEmpty, title.box.maxY < type.box.minY else {
        if let path = crop["imagePath"] as? String { try? FileManager.default.removeItem(atPath: path) }
        continue
      }
      var warnings = crop["warnings"] as? [String] ?? []
      for warning in ["partial_card", "incomplete_card", "no_card_rectangle"] where !warnings.contains(warning) {
        warnings.append(warning)
      }
      crop["warnings"] = warnings
      crops.append(crop)
      regions.append(region)
    }
    return crops
  }

  private func matchesPartialTitle(_ title: PartialText, proposed: String, body: [PartialText]) -> Bool {
    let expected: String = normalizedCardText(proposed)
    let observed: String = normalizedCardText(title.text)
    if observed == expected { return true }
    guard title.confidence >= 0.85, expected.count >= 8,
          observed.count == expected.count + 1, observed.first?.isLetter == true,
          String(observed.dropFirst()) == expected else { return false }
    let reliable: [PartialText] = body.filter { (line: PartialText) in line.confidence >= 0.85 }
    return reliable.contains { (first: PartialText) in
      reliable.contains { (second: PartialText) in
        normalizedCardText(first.text) != normalizedCardText(second.text)
          && abs(first.box.midY - second.box.midY) >= 0.01
      }
    }
  }

  private func partialRegionText(_ image: CIImage, region: CGRect) throws -> [PartialText] {
    let pixels = CGRect(x: region.minX * image.extent.width, y: region.minY * image.extent.height,
      width: region.width * image.extent.width, height: region.height * image.extent.height)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.007
    configureCardTextLanguages(request)
    try VNImageRequestHandler(ciImage: bounded(normalized(image.cropped(to: pixels)), edge: 4096),
      orientation: .up).perform([request])
    return (request.results ?? []).compactMap { observation in
      guard let text = observation.topCandidates(1).first else { return nil }
      let box = observation.boundingBox
      return PartialText(text: text.string, confidence: Double(text.confidence),
        box: CGRect(x: region.minX + box.minX * region.width, y: region.minY + box.minY * region.height,
          width: box.width * region.width, height: box.height * region.height))
    }
  }

  private func partialText(_ lines: [[String: Any]]) -> [PartialText] {
    lines.compactMap { line in
      guard let text = line["text"] as? String, let confidence = line["confidence"] as? Double,
            let bounds = line["bounds"] as? [String: Double], let x = bounds["x"], let y = bounds["y"],
            let width = bounds["width"], let height = bounds["height"] else { return nil }
      return PartialText(text: text, confidence: confidence, box: CGRect(x: x, y: y, width: width, height: height))
    }
  }

  private func isCardType(_ text: String) -> Bool {
    if text.range(of: #"^(?:(?:伝説の|基本|氷雪|ワールド)\s*)*(?:クリーチャー|インスタント|ソーサリー|エンチャント|アーティファクト|土地|プレインズウォーカー|バトル|同族|部族)(?:\s*[・･]\s*(?:クリーチャー|エンチャント|アーティファクト|土地))*(?:\s*(?:[—–－ー-]|・|･)\s*.+|\s+レジェンド)?$"#,
      options: .regularExpression) != nil { return true }
    return text.range(of: #"^(?:(?:legendary|basic|snow|world)\s+)*(?:creature|instant|sorcery|enchantment|artifact|land|planeswalker|battle|kindred|tribal)(?:\s+(?:creature|instant|sorcery|enchantment|artifact|land|planeswalker|battle|kindred|tribal))*(?:\s*[—–-]\s*.+)?$|^Enchant\s+(?:Creature|Artifact|Land|Enchantment|World|Player)$"#,
      options: [.regularExpression, .caseInsensitive]) != nil
  }

  private func isCardTypeProposal(_ text: String) -> Bool {
    if isCardType(text) { return true }
    let components = text.lowercased().components(separatedBy: CharacterSet(charactersIn: "—–-"))
    guard components.count == 2, components[1].filter({ $0.isLetter }).count >= 3 else { return false }
    let head = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
    guard head.count >= 6, head.allSatisfy({ $0.isLetter }) else { return false }
    let observed = Array(head)
    return ["creature", "instant", "sorcery", "enchantment", "artifact", "planeswalker", "battle", "kindred", "tribal"].contains { expected in
      let target = Array(expected)
      guard abs(observed.count - target.count) <= 2 else { return false }
      var previous = Array(0...target.count)
      for (index, character) in observed.enumerated() {
        var row = [index + 1]
        for (column, expectedCharacter) in target.enumerated() {
          row.append(min(previous[column + 1] + 1, row[column] + 1,
            previous[column] + (character == expectedCharacter ? 0 : 1)))
        }
        previous = row
      }
      return previous[target.count] <= 2
    }
  }

  private func isCardFooter(_ text: String) -> Bool {
    text.contains("©") || text.contains("™")
      || text.range(of: #"wizards\s+of\s+(?:the\s+)?coast"#, options: [.regularExpression, .caseInsensitive]) != nil
      || text.range(of: #"\b[A-Z0-9]{3,5}[ •·∙]+(?:EN|FR|DE|IT|ES|PT|JA|KO|RU)\b"#, options: .regularExpression) != nil
      || text.range(of: #"^\d+\s*/\s*\d+$"#, options: .regularExpression) != nil
  }

  private func isCardTitle(_ text: String) -> Bool {
    text.count >= 3 && text.count <= 70 && text.split(whereSeparator: { $0.isWhitespace }).count <= 10
      && text.filter({ $0.isLetter }).count >= 3 && !isCardType(text) && !isCardFooter(text)
      && !text.hasPrefix("-") && !text.hasPrefix("—") && !text.hasPrefix("–")
      && text.range(of: #"[.!?;\"“”©™]"#, options: .regularExpression) == nil
      && text.range(of: #"wizards\s+of\s+(?:the\s+)?coast"#, options: [.regularExpression, .caseInsensitive]) == nil
  }

  private func isCardBody(_ text: String) -> Bool {
    if isJapaneseRulesText(text) { return true }
    return text.filter({ $0.isLetter }).count >= 12 && text.split(whereSeparator: { $0.isWhitespace }).count >= 3
      && !text.hasPrefix("\"") && !text.hasPrefix("“") && !text.contains("©") && !text.contains("™")
      && !isCardType(text)
  }

  private func isJapaneseRulesText(_ text: String) -> Bool {
    let letters: Int = text.unicodeScalars.filter {
      (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
    }.count
    guard letters >= 8, !isCardType(text), !isCardFooter(text) else { return false }
    let rules: [String] = ["クリーチャー", "カード", "ダメージ", "呪文", "マナ", "ライフ",
      "コントロール", "戦場", "墓地", "対象", "修正", "生け贄", "トークン", "カウンター"]
    return rules.contains(where: text.contains)
  }

  func japaneseCardLayout(_ lines: [[String: Any]]) -> Bool {
    let text: [PartialText] = partialText(lines)
    return text.contains { type in
      type.confidence >= 0.85 && isCardType(type.text)
        && type.text.range(of: #"[ぁ-ゖァ-ヺ]"#, options: .regularExpression) != nil
        && type.box.minX < 0.65 && type.box.minY >= 0.35 && type.box.minY < 0.75
        && type.box.height > 0 && type.box.height < 0.11 && type.box.width >= type.box.height * 2
        && Set(text.filter { body in
          body.confidence >= 0.85 && isJapaneseRulesText(body.text)
            && body.box.minY >= type.box.maxY && body.box.maxY <= 0.93
            && body.box.height > 0 && body.box.height < 0.10 && body.box.width >= 0.20
            && body.box.width >= body.box.height * 4 && abs(body.box.minX - type.box.minX) < 0.18
        }.map { normalizedCardText($0.text) }).count >= 2
    }
  }

  private func normalizedCardText(_ text: String) -> String {
    text.lowercased().filter { $0.isLetter || $0.isNumber }
  }

  private func overlapsPartial(_ first: CGRect, _ second: CGRect) -> Bool {
    let intersection = first.intersection(second)
    guard !intersection.isNull else { return false }
    let area = min(first.width * first.height, second.width * second.height)
    return area > 0 && intersection.width * intersection.height / area > 0.45
  }

  private func hasStructuredFooterCode(_ text: String) -> Bool {
    text.range(of: #"\b(?=[A-Z0-9]{0,4}[A-Z])[A-Z0-9]{3,5}[\s•·∙]+(?:EN|ES|FR|DE|IT|PT|JA|KO|RU|ZHS|ZHT|HE|LA|GRC|AR|SA|PH|QYA)\b"#,
      options: .regularExpression) != nil
  }

  private func hasValidFooterCode(_ text: String) -> Bool {
    hasStructuredFooterCode(text) || isCardFooter(text)
      || text.range(of: #"^\s*(?:[CMRULST]\s+)?(?:[A-Za-z]{1,3}-?)?\d{1,5}[a-z★†]*(?:\s*/\s*\d{1,5})?(?:\s+[CMRULST])?\s*$"#,
        options: .regularExpression) != nil
  }

  private func footerCodeText(_ text: String) -> String {
    text.uppercased().filter { !$0.isWhitespace && !"•·∙".contains($0) }
  }

  private enum SavedFooterChannel { case luminance, green, blue }

  private func specializedFooterLines(_ image: CIImage, region: CGRect,
      channel: SavedFooterChannel = .luminance,
      recordRaw: (([String: Any]) -> Void)? = nil) throws -> [[String: Any]] {
    let pixels: CGRect = CGRect(x: image.extent.minX + region.minX * image.extent.width,
      y: image.extent.minY + region.minY * image.extent.height,
      width: region.width * image.extent.width, height: region.height * image.extent.height)
    var source: CIImage = normalized(image.cropped(to: pixels))
    if channel != .luminance {
      let selected: CIVector = channel == .green
        ? CIVector(x: 0, y: 1, z: 0, w: 0) : CIVector(x: 0, y: 0, z: 1, w: 0)
      source = source.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": selected, "inputGVector": selected, "inputBVector": selected,
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
      ])
    }
    let scale: CGFloat = channel == .blue ? 4 : 3
    let contrast: Double = channel == .blue ? 1.35 : 1.6
    let sharpness: Double = channel == .blue ? 0.35 : (channel == .green ? 0.6 : 0)
    let crop: CIImage = bounded(source
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0, "inputContrast": contrast])
      .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": sharpness]), edge: 4096)
    let request: VNRecognizeTextRequest = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    if #available(iOS 16.0, *) { request.automaticallyDetectsLanguage = false }
    request.minimumTextHeight = 0.008
    try VNImageRequestHandler(ciImage: crop, orientation: .up).perform([request])
    let observations: [VNRecognizedTextObservation] = request.results ?? []
    recordRaw?(["observationCount": observations.count, "width": Double(crop.extent.width),
      "height": Double(crop.extent.height), "minimumTextHeight": Double(request.minimumTextHeight),
      "recognitionLevel": "accurate",
      "pixelFormat": "CIImage",
      "rows": observations.prefix(16).map { observation in
        ["bounds": ["x": Double(observation.boundingBox.minX), "y": Double(observation.boundingBox.minY),
          "width": Double(observation.boundingBox.width), "height": Double(observation.boundingBox.height)],
          "candidates": observation.topCandidates(3).map {
            ["text": $0.string, "confidence": Double($0.confidence)] as [String: Any]
          }] as [String: Any]
      }])
    return recognizedLines(observations, region: region,
      imageAspect: image.extent.width / image.extent.height)
  }

  func mergingFooterLines(_ specialized: [[String: Any]], into original: [[String: Any]]) -> [[String: Any]] {
    var lines: [[String: Any]] = original
    for candidate: [String: Any] in specialized {
      guard let text: String = candidate["text"] as? String,
            let bounds: [String: Double] = candidate["bounds"] as? [String: Double],
            let x: Double = bounds["x"], let y: Double = bounds["y"],
            let width: Double = bounds["width"], let height: Double = bounds["height"] else { continue }
      let box: CGRect = CGRect(x: x, y: y, width: width, height: height)
      let confidence: Double = candidate["confidence"] as? Double ?? 0
      let overlapping: [Int] = lines.indices.filter { index in
        guard let prior: [String: Double] = lines[index]["bounds"] as? [String: Double],
              let priorX: Double = prior["x"], let priorY: Double = prior["y"],
              let priorWidth: Double = prior["width"], let priorHeight: Double = prior["height"] else { return false }
        let priorBox: CGRect = CGRect(x: priorX, y: priorY, width: priorWidth, height: priorHeight)
        return overlapsPartial(box, priorBox) && abs(box.midY - priorBox.midY) < 0.012
      }
      let protected: Bool = overlapping.contains { index in
        let priorText: String = lines[index]["text"] as? String ?? ""
        let priorConfidence: Double = lines[index]["confidence"] as? Double ?? 0
        if isJapaneseRulesText(priorText) && !savedLowerBodyLines([lines[index]]).isEmpty
            && !isJapaneseRulesText(text) { return true }
        return priorConfidence >= confidence
          && (footerCodeText(priorText) == footerCodeText(text)
            || (hasValidFooterCode(priorText) && !hasValidFooterCode(text)))
      }
      if protected { continue }
      let removable: Set<Int> = Set(overlapping.filter { index in
        let priorText: String = lines[index]["text"] as? String ?? ""
        let priorConfidence: Double = lines[index]["confidence"] as? Double ?? 0
        return priorConfidence <= confidence && (footerCodeText(priorText) == footerCodeText(text)
          || (!hasValidFooterCode(priorText) && hasValidFooterCode(text)))
      })
      // Conflicting valid codes remain separate evidence rather than silently replacing a printing.
      lines = lines.enumerated().compactMap { removable.contains($0.offset) ? nil : $0.element }
      lines.append(candidate)
    }
    return lines
  }

  func savedNameplateNeedsRead(_ lines: [[String: Any]]) -> Bool {
    !lines.contains { nameplateScore([$0]) > 0 && ($0["confidence"] as? Double ?? 0) >= 0.85 }
  }

  func mergingSavedNameplateLines(_ candidates: [[String: Any]],
      into original: [[String: Any]]) -> [[String: Any]] {
    var lines: [[String: Any]] = original
    for candidate: [String: Any] in candidates {
      guard let observed: PartialText = partialText([candidate]).first else { continue }
      let repeated: Bool = lines.contains { existing in
        guard let prior: PartialText = partialText([existing]).first else { return false }
        return prior.text == observed.text
          && prior.confidence == observed.confidence && overlapsPartial(prior.box, observed.box)
      }
      if repeated { continue }
      lines.append(candidate)
    }
    return lines
  }

  func savedStrongCollectorObserved(_ lines: [[String: Any]]) -> Bool {
    partialText(lines).contains { row in
      row.confidence >= 0.85 && row.box.minY >= 0.84 && row.box.maxY <= 0.99
        && row.box.minX < 0.65 && row.box.height > 0 && row.box.height < 0.05
        && row.text.range(of: #"^\s*(?:[CMRULST]\s+)?\d{2,5}[a-z★†]*(?:\s*/\s*\d{2,5})?\s*$"#,
          options: .regularExpression) != nil
    }
  }

  func savedIdentityTextSupported(_ lines: [[String: Any]]) -> Bool {
    savedStrongCollectorObserved(lines)
      || (!savedNameplateNeedsRead(lines) && savedCardLayout(lines) && savedUprightTextSupported(lines))
  }

  func savedFooterNeedsLiteralRetry(_ lines: [[String: Any]]) -> Bool {
    guard !savedStrongCollectorObserved(lines) else { return false }
    let rows: [PartialText] = partialText(lines)
    let strongComplete: Bool = completeSavedFooterObserved(lines)
      && rows.contains { $0.confidence >= 0.85 && hasStructuredFooterCode($0.text)
        && $0.box.minY >= 0.84 && $0.box.maxY <= 0.99 && $0.box.height < 0.05 }
    guard !strongComplete else { return false }
    let copyright: Bool = rows.contains { row in
      row.confidence >= 0.50 && row.box.minY >= 0.84 && row.box.maxY <= 0.99
        && row.box.height > 0 && row.box.height < 0.07
        && (row.text.contains("©") || row.text.contains("™"))
    }
    return !copyright || !savedUprightTextSupported(lines) || savedFooterNeedsAlternateRead(lines)
  }

  private func recoverSavedText(_ image: CIImage, lines original: [[String: Any]],
      sourceCorners: [[String: Double]], footerGeometryGuide: CGRect? = nil,
      allowLightingRecovery: Bool = false,
      recordOrientation: (([String: Any]) -> Void)?,
      recordTiming: ((String, Double) -> Void)?) throws -> [[String: Any]] {
    var lines: [[String: Any]] = original
    let rightFooterSupported: Bool = lines.contains { line in
      guard let value: String = line["text"] as? String,
            let bounds: [String: Double] = line["bounds"] as? [String: Double] else { return false }
      return (bounds["x"] ?? 0) >= 0.65 && (bounds["y"] ?? 0) >= 0.84
        && (bounds["height"] ?? 1) <= 0.06 && (line["confidence"] as? Double ?? 0) >= 0.75
        && hasStructuredFooterCode(value)
    }
    if savedFooterNeedsLiteralRetry(lines) {
      let literalFooter: [[String: Any]] = try timedSavedPhase("footer-latin", record: recordTiming) {
        try specializedFooterLines(image, region: CGRect(x: 0, y: 0, width: 0.65, height: 0.24))
      }
      lines = mergingFooterLines(literalFooter, into: lines)
    }
    let guidedRegion: CGRect? = savedGuidedFooterRetryRegion(lines, guide: footerGeometryGuide)
    if let guidedRegion {
      let numeric: [[String: Any]]? = try? timedSavedPhase("footer-guided-blue", record: recordTiming) {
        try specializedFooterLines(image, region: guidedRegion, channel: .blue,
          recordRaw: { raw in
          recordOrientation?(["phase": "saved-footer-guided-raw", "sourceCorners": sourceCorners,
            "vision": raw])
        })
      }
      recordOrientation?(["phase": "saved-footer-guided-blue", "sourceCorners": sourceCorners,
        "region": ["x": Double(guidedRegion.minX), "y": Double(guidedRegion.minY),
          "width": Double(guidedRegion.width), "height": Double(guidedRegion.height)],
        "completed": numeric != nil, "lines": Array((numeric ?? []).prefix(16))])
      if let numeric { lines = mergingFooterLines(numeric, into: lines) }
    }
    if guidedRegion == nil && savedFooterNeedsAlternateRead(lines) && !savedIdentityTextSupported(lines) {
      let alternate: [[String: Any]] = try timedSavedPhase("footer-green", record: recordTiming) {
        try specializedFooterLines(image, region: CGRect(x: 0, y: 0, width: 0.65, height: 0.20), channel: .green)
      }
      recordOrientation?(["phase": "saved-footer-alternate", "sourceCorners": sourceCorners,
        "lines": Array(alternate.prefix(48))])
      lines = mergingFooterLines(alternate, into: lines)
      if let numberRegion: CGRect = savedNumericFooterRegion(lines) {
        let numeric: [[String: Any]] = try timedSavedPhase("footer-numeric-blue", record: recordTiming) {
          try specializedFooterLines(image, region: numberRegion, channel: .blue)
        }
        recordOrientation?(["phase": "saved-footer-numeric-blue", "sourceCorners": sourceCorners,
          "region": ["x": Double(numberRegion.minX), "y": Double(numberRegion.minY),
            "width": Double(numberRegion.width), "height": Double(numberRegion.height)],
          "lines": Array(numeric.prefix(16))])
        lines = mergingFooterLines(numeric, into: lines)
      }
    }
    if rightFooterSupported {
      let right: [[String: Any]] = try timedSavedPhase("footer-right", record: recordTiming) {
        try specializedFooterLines(image, region: CGRect(x: 0.55, y: 0, width: 0.45, height: 0.16))
      }
      lines = mergingFooterLines(right, into: lines)
    }
    if savedNameplateNeedsRead(lines) {
      let names: [[String: Any]] = try timedSavedPhase("nameplate", record: recordTiming) {
        try nameplateTextLines(image)
      }
      lines = mergingSavedNameplateLines(names, into: lines)
    }
    var lightingTitleAttempted: Bool = false
    if allowLightingRecovery {
      if let recovered = try? recoverWashedOutText(image, lines: lines, recordTiming: recordTiming) {
        lines = recovered.lines
        lightingTitleAttempted = recovered.titleAttempted
      }
    }
    let nameConfidence: Double = lines.filter { nameplateScore([$0]) > 0 }
      .compactMap { $0["confidence"] as? Double }.max() ?? 0
    if !lightingTitleAttempted && nameConfidence < 0.85 && partialText(lines).contains(where: {
      $0.confidence >= 0.65 && isCardBody($0.text) && !isCardFooter($0.text)
    }) {
      let enhanced: [[String: Any]] = try timedSavedPhase("nameplate-enhanced", record: recordTiming) {
        try enhancedNameplateTextLines(image)
      }
      lines = mergingSavedNameplateLines(enhanced, into: lines)
    }
    if !savedCardLayout(lines) && !savedUprightTextSupported(lines) && !lines.isEmpty {
      let types: [[String: Any]] = try timedSavedPhase("type-band", record: recordTiming) {
        try savedTypeBandText(image, bodyLines: lines)
      }
      lines.append(contentsOf: types)
    }
    return lines
  }

  private func literalSavedFooterLines(_ image: CIImage,
      recordTiming: ((String, Double) -> Void)?) throws -> [[String: Any]] {
    let footer: VNRecognizeTextRequest = VNRecognizeTextRequest()
    footer.recognitionLevel = .accurate
    footer.usesLanguageCorrection = false
    footer.minimumTextHeight = 0.005
    let footerImage: CIImage = bounded(normalized(image.cropped(to: CGRect(x: 0, y: 0,
      width: image.extent.width, height: image.extent.height * 0.30))), edge: 4096)
    try timedSavedPhase("footer-base", record: recordTiming) {
      try VNImageRequestHandler(ciImage: footerImage, orientation: .up).perform([footer])
    }
    return recognizedLines(footer.results ?? [], region: CGRect(x: 0, y: 0, width: 1, height: 0.30),
      imageAspect: image.extent.width / image.extent.height)
  }

  func savedLowerBodyLines(_ lines: [[String: Any]]) -> [[String: Any]] {
    lines.filter { line in
      guard let row: PartialText = partialText([line]).first,
            row.confidence.isFinite && row.confidence >= 0.30 && row.confidence <= 1,
            row.box.midY >= 0.70 && row.box.midY < 0.86,
            row.box.height > 0 && row.box.height < 0.10 && row.box.width >= 0.20 else { return false }
      return isJapaneseRulesText(row.text) || (row.confidence >= 0.85 && isCardBody(row.text))
    }
  }

  private func baseSavedCardLines(_ image: CIImage, deferUnreadText: Bool = false,
      recordTiming: ((String, Double) -> Void)?) throws -> [[String: Any]] {
    let ocrImage: CIImage = bounded(image, edge: 4096)
    let text = VNRecognizeTextRequest()
    text.recognitionLevel = .accurate
    text.usesLanguageCorrection = true
    configureCardTextLanguages(text)
    text.minimumTextHeight = 0.007
    try timedSavedPhase("text-full-card", record: recordTiming) {
      try VNImageRequestHandler(ciImage: ocrImage, orientation: .up).perform([text])
    }
    // Footer codes bypass language correction; prefer that pass in overlaps.
    let observations: [VNRecognizedTextObservation] = text.results ?? []
    if deferUnreadText && observations.isEmpty { return [] }
    let general: [VNRecognizedTextObservation] = observations.filter { $0.boundingBox.midY > 0.30 }
    let retainedBody: [[String: Any]] = savedLowerBodyLines(recognizedLines(observations,
      region: CGRect(x: 0, y: 0, width: 1, height: 1), imageAspect: image.extent.width / image.extent.height))
    var footerLines: [[String: Any]] = try literalSavedFooterLines(image, recordTiming: recordTiming)
    for body: [String: Any] in retainedBody {
      footerLines.removeAll { footer in
        guard let value: String = footer["text"] as? String,
              !hasValidFooterCode(value), !hasStructuredFooterCode(value),
              (footer["confidence"] as? Double ?? 0) <= (body["confidence"] as? Double ?? 0),
              let a: PartialText = partialText([body]).first,
              let b: PartialText = partialText([footer]).first else { return false }
        let overlap: CGFloat = max(0, min(a.box.maxX, b.box.maxX) - max(a.box.minX, b.box.minX))
        return min(a.box.width, b.box.width) > 0 && overlap / min(a.box.width, b.box.width) >= 0.65
          && abs(a.box.midY - b.box.midY) < max(0.012, min(a.box.height, b.box.height) * 0.6)
      }
    }
    return recognizedLines(general, region: CGRect(x: 0, y: 0, width: 1, height: 1), imageAspect: image.extent.width / image.extent.height)
      + retainedBody + footerLines
  }

  private func recognizeCrop(_ image: CIImage, sourceCorners: [[String: Double]], rectified: Bool,
      allowRotation: Bool = true, allowGeometryRepair: Bool = true, deferBorderRecovery: Bool = false,
      deferUnreadText: Bool = false, presenceOnly: Bool = false,
      sceneLines: [[String: Any]]? = nil, sceneGeometryOnly: Bool = false,
      sceneProbeTop: Bool = false, sceneProbeBottom: Bool = false, sceneVerifyFooter: Bool = false,
      footerGeometryGuide: CGRect? = nil,
      recordOrientation: (([String: Any]) -> Void)? = nil,
      recordTiming: ((String, Double) -> Void)? = nil) throws -> [String: Any] {
    let encodingStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
    let ocrImage = bounded(image, edge: 4096)
    guard let bitmap = context.createCGImage(ocrImage, from: ocrImage.extent),
          let jpeg = UIImage(cgImage: bitmap).jpegData(compressionQuality: 0.94) else {
      throw ScanError.unreadableImage
    }
    let cropPath: URL = try Self.cropCache.nextCropURL()
    try jpeg.write(to: cropPath, options: .atomic)
    recordTiming?("crop-encode", (ProcessInfo.processInfo.systemUptime - encodingStarted) * 1000)
    var retained = false
    defer {
      if !retained { try? FileManager.default.removeItem(at: cropPath) }
    }

    var lines: [[String: Any]]
    if let scene: [[String: Any]] = sceneLines { lines = scene }
    else if presenceOnly {
      let request: VNRecognizeTextRequest = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = false
      request.minimumTextHeight = 0.006
      configureCardTextLanguages(request)
      try VNImageRequestHandler(ciImage: bounded(image, edge: 2048), orientation: .up).perform([request])
      lines = recognizedLines(request.results ?? [], region: CGRect(x: 0, y: 0, width: 1, height: 1),
        imageAspect: image.extent.width / image.extent.height)
      let hasObservedType: Bool = partialText(lines).contains { row in
        row.confidence >= 0.65 && isCardType(row.text) && row.box.minY >= 0.35
          && row.box.maxY <= 0.90 && row.box.height > 0 && row.box.height < 0.11
      }
      if !savedNameplateNeedsRead(lines) && hasObservedType {
        let footer: [[String: Any]] = try literalSavedFooterLines(image, recordTiming: recordTiming)
        lines = mergingFooterLines(footer, into: lines)
      }
    }
    else { lines = try baseSavedCardLines(image, deferUnreadText: deferUnreadText, recordTiming: recordTiming) }
    let requiresBasicFooter: Bool = sceneLines.map { savedSceneSeed($0) == .footer } ?? false
    if !presenceOnly && sceneLines != nil && (sceneVerifyFooter || requiresBasicFooter) && !sceneGeometryOnly {
      let literal: [[String: Any]] = try literalSavedFooterLines(image, recordTiming: recordTiming)
      if requiresBasicFooter, let scene: [[String: Any]] = sceneLines,
          !savedSceneFooterVerified(scene, by: literal) {
        recordOrientation?(["phase": "saved-scene-footer-fallback", "sourceCorners": sourceCorners])
        return try recognizeCrop(image, sourceCorners: sourceCorners, rectified: rectified,
          allowRotation: allowRotation, allowGeometryRepair: allowGeometryRepair,
          recordOrientation: recordOrientation, recordTiming: recordTiming)
      }
      lines = mergingFooterLines(literal, into: lines)
    }
    let deferred: Bool = deferBorderRecovery && (savedBorderRecoveryNeeded(lines)
      || sceneGeometryOnly || sceneProbeTop || sceneProbeBottom)
    if !presenceOnly && !deferred && (!deferUnreadText || !lines.isEmpty) {
      lines = try recoverSavedText(image, lines: lines, sourceCorners: sourceCorners,
        footerGeometryGuide: footerGeometryGuide,
        allowLightingRecovery: rectified,
        recordOrientation: recordOrientation, recordTiming: recordTiming)
    }
    if !presenceOnly, let initialScene: [[String: Any]] = sceneLines, !sceneGeometryOnly, !deferred,
        savedNameplateNeedsRead(initialScene), !lines.contains(where: {
          $0["ocrSource"] as? String != "scene" && nameplateScore([$0]) > 0
        }) {
      recordOrientation?(["phase": "saved-scene-name-fallback", "sourceCorners": sourceCorners])
      return try recognizeCrop(image, sourceCorners: sourceCorners, rectified: rectified,
        allowRotation: allowRotation, allowGeometryRepair: allowGeometryRepair,
        recordOrientation: recordOrientation, recordTiming: recordTiming)
    }
    if allowRotation && !lines.isEmpty && !savedUprightTextSupported(lines)
        && (nameplateScore(lines) == 0 || !savedCardLayout(lines)) {
      let orientationStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
      defer { recordTiming?("orientation-ensemble", (ProcessInfo.processInfo.systemUptime - orientationStarted) * 1000) }
      var candidates: [(image: CIImage, lines: [[String: Any]], geometryAdjusted: Bool)] = []
      let orientations: [CGImagePropertyOrientation] = [.up, .down, .left, .right]
      for orientation: CGImagePropertyOrientation in orientations {
        var candidate = normalized(image.oriented(orientation))
        let ratio = candidate.extent.width / candidate.extent.height
        let adjusted = rectified && (ratio < 0.58 || ratio > 0.84)
        if adjusted {
          candidate = canonicalCardAspect(candidate)
        }
        let candidateLines = orientation == .up && !adjusted ? lines : ((try? orientationTextLines(candidate)) ?? [])
        candidates.append((candidate, candidateLines, adjusted))
      }
      var best: (image: CIImage, typeLines: [[String: Any]], geometryAdjusted: Bool, bodySupported: Bool)?
      let initialScore: Int = orientationScore(lines)
      var bestScore: Int = initialScore
      for index in candidates.indices {
        let opposite = index % 2 == 0 ? index + 1 : index - 1
        let typeLines = oppositeTypeLines(candidates[opposite].lines)
          + rotatedObservedTypeLines(lines, orientation: orientations[index])
          + corroboratedActualTypeLines(candidates[index].lines)
        let candidateLines = candidates[index].lines + typeLines
        let named = nameplateScore(candidateLines) > 0 && savedCardLayout(candidateLines)
        let bodyScore = bodyOrientationScore(candidateLines)
        if let recordOrientation {
          recordOrientation(["phase": "candidate", "sourceCorners": sourceCorners, "index": index,
            "width": Int(candidates[index].image.extent.width), "height": Int(candidates[index].image.extent.height),
            "geometryAdjusted": candidates[index].geometryAdjusted, "initialScore": initialScore,
            "named": named, "orientationScore": orientationScore(candidateLines), "bodyScore": bodyScore,
            "typeEvidence": orientationBodyDiagnostics(candidateLines), "lines": Array(candidateLines.prefix(96))])
        }
        guard named || bodyScore > 0 else { continue }
        let score = named ? orientationScore(candidateLines) : bodyScore
        if score > bestScore {
          bestScore = score
          best = (candidates[index].image, typeLines, candidates[index].geometryAdjusted, !named)
        }
      }
      if let best {
        var alternate = try recognizeCrop(best.image, sourceCorners: sourceCorners,
          rectified: rectified, allowRotation: false, allowGeometryRepair: false,
          presenceOnly: presenceOnly,
          recordOrientation: recordOrientation, recordTiming: recordTiming)
        var retainedAlternate: Bool = false
        defer {
          if !retainedAlternate, let path: String = alternate["imagePath"] as? String {
            try? FileManager.default.removeItem(atPath: path)
          }
        }
        var alternateLines = alternate["lines"] as? [[String: Any]] ?? []
        let needsTypeEvidence = !savedCardLayout(alternateLines)
        if needsTypeEvidence { alternateLines.append(contentsOf: best.typeLines) }
        if !savedCardLayout(alternateLines) && bodyOrientationScore(alternateLines) > 0 {
          alternateLines.append(contentsOf: try enhancedBodyTypeTextLines(best.image, lines: alternateLines,
            recordOrientation: recordOrientation))
        }
        let bodyVerified = best.bodySupported && bodyOrientationScore(alternateLines) > 0
        if let recordOrientation {
          recordOrientation(["phase": "verification", "sourceCorners": sourceCorners,
            "bodySupported": best.bodySupported, "bodyVerified": bodyVerified,
            "namedVerified": nameplateScore(alternateLines) > 0 && savedCardLayout(alternateLines),
            "bodyScore": bodyOrientationScore(alternateLines),
            "typeEvidence": orientationBodyDiagnostics(alternateLines), "lines": Array(alternateLines.prefix(96))])
        }
        if (nameplateScore(alternateLines) > 0 && savedCardLayout(alternateLines)) || bodyVerified {
          if bodyVerified { alternateLines.append(contentsOf: observedOrientationTypeAlternatives(alternateLines)) }
          alternate["lines"] = alternateLines
          var alternateWarnings = alternate["warnings"] as? [String] ?? []
          if needsTypeEvidence || bodyVerified { alternateWarnings.append("orientation_ensemble") }
          if best.geometryAdjusted { alternateWarnings.append("geometry_adjusted") }
          alternate["warnings"] = alternateWarnings
          retainedAlternate = true
          return alternate
        }
      }
    }
    let aspect = CGFloat(bitmap.width) / CGFloat(bitmap.height)
    if allowGeometryRepair && !sceneGeometryOnly && rectified && (aspect < 0.58 || aspect > 0.84)
        && ((nameplateScore(lines) > 0 && savedCardLayout(lines)) || bodyOrientationScore(lines) > 0) {
      let canonical = canonicalCardAspect(image)
      var repaired = try recognizeCrop(canonical, sourceCorners: sourceCorners, rectified: true,
        allowRotation: false, allowGeometryRepair: false, presenceOnly: presenceOnly,
        recordOrientation: recordOrientation, recordTiming: recordTiming)
      let repairedLines = repaired["lines"] as? [[String: Any]] ?? []
      if (nameplateScore(repairedLines) > 0 && savedCardLayout(repairedLines)
          && !(repaired["warnings"] as? [String] ?? []).contains("incomplete_card"))
          || bodyOrientationScore(repairedLines) > 0 {
        var repairedWarnings = repaired["warnings"] as? [String] ?? []
        repairedWarnings.append("geometry_adjusted")
        repaired["warnings"] = repairedWarnings
        return repaired
      }
      if let unused = repaired["imagePath"] as? String {
        try? FileManager.default.removeItem(atPath: unused)
      }
    }
    var warnings: [String] = presenceOnly ? ["details_pending"] : []
    if presenceOnly && rectified && aspect >= 0.58 && aspect <= 0.84
        && savedBasicLandIdentitySupported(lines) {
      warnings.append(contentsOf: ["basic_land_outline", "unread_footer"])
    }
    if hasLightingTitleConflict(lines) { warnings.append("lighting_title_conflict") }
    if !rectified { warnings.append("no_card_rectangle") }
    if aspect < 0.58 || aspect > 0.84 || nameplateScore(lines) == 0 {
      warnings.append("incomplete_card")
    }
    if bitmap.height < 700 { warnings.append("small_image") }
    if lines.isEmpty { warnings.append("no_text") }
    if !lines.isEmpty && lines.allSatisfy({ ($0["confidence"] as? Double ?? 0) < 0.65 }) {
      warnings.append("low_text_confidence")
    }
    retained = true
    return [
      "imagePath": cropPath.path, "width": bitmap.width, "height": bitmap.height,
      "rectified": rectified, "sourceCorners": sourceCorners, "lines": lines, "warnings": warnings,
      "sharpness": imageSharpness(image), "optionalRecoveryDeferred": deferred,
      "sceneGeometryOnly": sceneGeometryOnly, "sceneProbeTop": sceneProbeTop, "sceneProbeBottom": sceneProbeBottom,
    ]
  }

  private func oppositeTypeLines(_ lines: [[String: Any]]) -> [[String: Any]] {
    lines.compactMap { line in
      guard let text = line["text"] as? String, isCardType(text),
            let confidence = line["confidence"] as? Double, confidence >= 0.65,
            let box = line["bounds"] as? [String: Double],
            let x = box["x"], let y = box["y"], let width = box["width"], let height = box["height"] else { return nil }
      let mappedX = 1 - x - width
      let mappedY = 1 - y - height
      guard mappedY >= 0.35, mappedY < 0.75, mappedX < 0.65, height < 0.11 else { return nil }
      var result = line
      result["bounds"] = ["x": mappedX, "y": mappedY, "width": width, "height": height]
      return result
    }
  }

  private func configureCardTextLanguages(_ request: VNRecognizeTextRequest) {
    if #available(iOS 16.0, *) {
      request.automaticallyDetectsLanguage = true
      if let supported: [String] = try? request.supportedRecognitionLanguages(), supported.contains("ja-JP") {
        request.recognitionLanguages = request.recognitionLanguages.filter { $0 != "ja-JP" } + ["ja-JP"]
      }
    }
  }

  private func orientationTextLines(_ image: CIImage) throws -> [[String: Any]] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.006
    configureCardTextLanguages(request)
    try VNImageRequestHandler(ciImage: bounded(image, edge: 2048), orientation: .up).perform([request])
    return recognizedLines(request.results ?? [], region: CGRect(x: 0, y: 0, width: 1, height: 1), imageAspect: image.extent.width / image.extent.height)
  }

  private func canonicalCardAspect(_ image: CIImage) -> CIImage {
    let targetWidth: CGFloat = image.extent.height * (63.0 / 88.0)
    // Restore the foreshortened axis without first discarding readable glyph pixels.
    let transform: CGAffineTransform = CGAffineTransform(
      scaleX: max(1, targetWidth / image.extent.width),
      y: max(1, image.extent.width / targetWidth))
    return bounded(normalized(image.transformed(by: transform)), edge: 4096)
  }

  private func recognizedLines(_ observations: [VNRecognizedTextObservation], region: CGRect, imageAspect: CGFloat) -> [[String: Any]] {
    let lines: [[String: Any]] = observations.compactMap { observation in
      let candidates = observation.topCandidates(3)
      guard let first = candidates.first else { return nil }
      let box = observation.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
      guard !box.isNull && !box.isEmpty else { return nil }
      let bounds: [String: Double] = ["x": Double(region.minX + box.minX * region.width),
        "y": Double(1 - (region.minY + box.maxY * region.height)),
        "width": Double(box.width * region.width), "height": Double(box.height * region.height)]
      var line: [String: Any] = ["text": first.string, "confidence": Double(first.confidence),
        "alternatives": candidates.dropFirst().map { $0.string },
        "alternativeConfidences": candidates.dropFirst().map { Double($0.confidence) }, "bounds": bounds]
      if let height = recognizedGlyphHeight(first, region: region, imageAspect: imageAspect) {
        line["glyphHeight"] = height
      }
      return line
    }
    return joiningObservedTypeFragments(lines)
  }

  func joiningObservedTypeFragments(_ lines: [[String: Any]]) -> [[String: Any]] {
    let fragments: [PartialText] = partialText(lines).filter {
      $0.confidence >= 0.30 && $0.box.minY >= 0.35 && $0.box.maxY < 0.80
        && $0.box.width > 0 && $0.box.height > 0 && $0.box.height < 0.10
        && !isCardFooter($0.text)
    }.sorted { $0.box.minX < $1.box.minX }
    var joined: [[String: Any]] = []
    for (index, first): (Int, PartialText) in fragments.enumerated() {
      for second: PartialText in fragments.dropFirst(index + 1) {
        let gap: CGFloat = second.box.minX - first.box.maxX
        guard gap >= -min(first.box.width, second.box.width) * 0.10,
              gap <= max(0.025, min(first.box.height, second.box.height)),
              abs(first.box.midY - second.box.midY) < min(first.box.height, second.box.height) * 0.40,
              max(first.box.height, second.box.height) <= min(first.box.height, second.box.height) * 1.6,
              let value: String = [first.text + second.text, first.text + " " + second.text]
                .first(where: { isCardType($0) }) else { continue }
        let box: CGRect = first.box.union(second.box)
        guard !lines.contains(where: { ($0["text"] as? String) == value }),
              !joined.contains(where: { ($0["text"] as? String) == value }) else { continue }
        joined.append(["text": value, "confidence": min(first.confidence, second.confidence),
          "bounds": ["x": Double(box.minX), "y": Double(box.minY),
            "width": Double(box.width), "height": Double(box.height)],
          "joinedFragments": [first.text, second.text]])
      }
    }
    return lines + joined
  }

  private func recognizedGlyphHeight(_ text: VNRecognizedText, region: CGRect,
      imageAspect: CGFloat) -> Double? {
    guard let quad = try? text.boundingBox(for: text.string.startIndex..<text.string.endIndex) else {
      return nil
    }
    func edge(_ top: CGPoint, _ bottom: CGPoint) -> Double {
      hypot(Double((top.x - bottom.x) * region.width * imageAspect),
        Double((top.y - bottom.y) * region.height))
    }
    let height = (edge(quad.topLeft, quad.bottomLeft) + edge(quad.topRight, quad.bottomRight)) / 2
    return height.isFinite && height > 0 && height <= 1 ? height : nil
  }

  private func nameplateScore(_ lines: [[String: Any]]) -> Int {
    var score = 0
    for line in lines {
      guard let text = line["text"] as? String,
            let bounds = line["bounds"] as? [String: Double],
            let y = bounds["y"], let x = bounds["x"],
            let width = bounds["width"], let axisHeight = bounds["height"],
            axisHeight > 0, axisHeight < 0.20,
            let height = (line["glyphHeight"] as? Double) ?? bounds["height"],
            let confidence = line["confidence"] as? Double,
            confidence >= 0.5, y < 0.10, x < 0.6, width >= 0.1,
            height > 0.008, height < 0.07, text.filter({ $0.isLetter }).count >= 3,
            !text.contains("©"), !text.contains("™"), !text.hasPrefix("\""), !text.hasPrefix("“"),
            text.range(of: #"wizards\s+of\s+(?:the\s+)?coast"#, options: [.regularExpression, .caseInsensitive]) == nil,
            text.range(of: #"^\d+\s*/"#, options: .regularExpression) == nil,
            text.range(of: #"\b[A-Z0-9]{3,5}[ •·∙]+(?:EN|FR|DE|IT|ES|PT|JA|KO|RU)\b"#,
              options: .regularExpression) == nil else { continue }
      score = max(score, 8 + Int(confidence * 4) + Int((0.10 - y) * 20))
    }
    return score
  }

  private func orientationScore(_ lines: [[String: Any]]) -> Int {
    nameplateScore(lines) + footerScore(lines) + (hasCardLayout(lines) ? 20 : 0)
  }

  private func bodyOrientationScore(_ lines: [[String: Any]]) -> Int {
    if japaneseCardLayout(lines) { return 29 }
    let text = partialText(lines)
    for raw: [String: Any] in lines {
      guard let minimumRows: Int = orientationTypeMinimumRows(raw),
            let type: PartialText = partialText([raw]).first,
            type.confidence >= 0.85 && type.box.minX < 0.65
              && type.box.minY >= 0.35 && type.box.minY < 0.75
              && type.box.height > 0 && type.box.height < 0.11 else { continue }
      let body: [PartialText] = orientationBodyLines(type, in: text)
      let distinct = Set(body.map { normalizedCardText($0.text) })
      guard distinct.count >= minimumRows else { continue }
      if minimumRows == 3 {
        var rows: [PartialText] = []
        for line: PartialText in body.sorted(by: { $0.box.midY < $1.box.midY }) {
          if !rows.contains(where: { prior in
            abs(prior.box.midY - line.box.midY) < max(0.012, min(prior.box.height, line.box.height) * 0.6)
          }) { rows.append(line) }
        }
        guard rows.count >= 3 else { continue }
      }
      let words = Set(body.flatMap { $0.text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) })
      let rulesWords: Set<String> = ["opponent", "opponents", "token", "tokens", "sacrifice", "sacrifices", "damage",
        "spell", "spells", "creature", "creatures", "life", "mana", "nonland", "battlefield", "graveyard",
        "prevent", "source", "draw", "discard", "counter", "artifact", "artifacts", "enchantment", "enchantments"]
      guard words.intersection(rulesWords).count >= 2 else { continue }
      return 20 + min(distinct.count, 3) * 3
    }
    return 0
  }

  private func orientationBodyLines(_ type: PartialText, in text: [PartialText]) -> [PartialText] {
    text.filter { line in
      line.confidence >= 0.85 && isCardBody(line.text)
        && line.box.minY >= type.box.maxY && line.box.minY < 0.86
        && line.box.height > 0 && line.box.height < 0.10 && line.box.width >= 0.20
        && abs(line.box.minX - type.box.minX) < 0.18
    }
  }

  private func orientationBodyDiagnostics(_ lines: [[String: Any]]) -> [[String: Any]] {
    let text: [PartialText] = partialText(lines)
    return lines.compactMap { raw -> [String: Any]? in
      guard let type: PartialText = partialText([raw]).first,
            let minimumRows: Int = orientationTypeMinimumRows(raw) else { return nil }
      let body: [PartialText] = orientationBodyLines(type, in: text)
      let minimumBoundsSupported: Bool = type.confidence >= 0.85 && type.box.minX < 0.65
        && type.box.minY >= 0.35 && type.box.minY < 0.75 && type.box.height > 0 && type.box.height < 0.11
      return ["type": type.text, "minimumRows": minimumRows, "typeBoundsSupported": minimumBoundsSupported,
        "bodyRows": body.count, "distinctBodyRows": Set(body.map { normalizedCardText($0.text) }).count,
        "bodyTexts": body.map { $0.text }]
    }
  }

  private func orientationTypeMinimumRows(_ line: [String: Any]) -> Int? {
    guard let observed: String = line["text"] as? String else { return nil }
    if isCardType(observed) { return line["orientationCorroboration"] as? Bool == true ? 3 : 2 }
    let alternatives: [String] = line["alternatives"] as? [String] ?? []
    let confidences: [Double] = line["alternativeConfidences"] as? [Double] ?? []
    if alternatives.enumerated().contains(where: { index, candidate in
      index < confidences.count && confidences[index] >= 0.85 && isCardType(candidate)
    }) { return 3 }
    let word: String = observed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let longTypes: [String] = ["enchantment", "planeswalker"]
    let matches: [String] = longTypes.filter { expected in
      let glyphs: [Character] = Array(expected)
      guard word.count == glyphs.count - 1 else { return false }
      return glyphs.indices.contains { missing in
        String(glyphs.enumerated().filter { $0.offset != missing }.map { $0.element }) == word
      }
    }
    // A single missing glyph supports rotation only; persisted text stays unmodified.
    return matches.count == 1 ? 3 : nil
  }

  private func observedOrientationTypeAlternatives(_ lines: [[String: Any]]) -> [[String: Any]] {
    guard bodyOrientationScore(lines) > 0 else { return [] }
    let supportingBody: [[String: Any]] = lines.filter { line in
      guard let value: String = line["text"] as? String else { return false }
      return isCardBody(value) && orientationTypeMinimumRows(line) == nil
    }
    var result: [[String: Any]] = []
    for raw: [String: Any] in lines {
      guard let primary: String = raw["text"] as? String, !isCardType(primary),
            orientationTypeMinimumRows(raw) == 3,
            bodyOrientationScore([raw] + supportingBody) > 0,
            let observed: PartialText = partialText([raw]).first,
            observed.confidence >= 0.85, observed.box.minX < 0.65,
            observed.box.minY >= 0.35, observed.box.minY < 0.75,
            observed.box.height > 0, observed.box.height < 0.11 else { continue }
      let alternatives: [String] = raw["alternatives"] as? [String] ?? []
      let confidences: [Double] = raw["alternativeConfidences"] as? [Double] ?? []
      for (index, alternative) in alternatives.enumerated() {
        guard isCardType(alternative), index < confidences.count, confidences[index] >= 0.85 else { continue }
        var observedType: [String: Any] = raw
        observedType["text"] = alternative
        observedType["confidence"] = confidences[index]
        observedType["alternatives"] = [primary]
        observedType["alternativeConfidences"] = [observed.confidence]
        result.append(observedType)
        break
      }
    }
    return result
  }

  private func hasCardLayout(_ lines: [[String: Any]]) -> Bool {
    let text = partialText(lines)
    return text.contains { type in
      type.confidence >= 0.65 && isCardType(type.text) && type.box.minX < 0.65
        && type.box.minY >= 0.35 && type.box.minY < 0.75
        && text.contains { body in
          body.confidence >= 0.65 && isCardBody(body.text) && body.box.minY >= type.box.maxY
            && body.box.minY < 0.86 && abs(body.box.minX - type.box.minX) < 0.18
        }
    }
  }

  private func footerScore(_ lines: [[String: Any]]) -> Int {
    var footer = false
    for line in lines {
      guard let text = line["text"] as? String,
            let bounds = line["bounds"] as? [String: Double],
            let y = bounds["y"], let confidence = line["confidence"] as? Double,
            confidence >= 0.5 else { continue }
      if y > 0.70 && (bounds["x"] ?? 1) < 0.65 && (bounds["height"] ?? 1) < 0.07
          && text.range(of: #"^(?:[CMRULST]\s+)?(?:[A-Za-z]{1,3}-?)?\d{1,5}[a-z★†]*(?:\s*/\s*\d{1,5})?(?:\s+[CMRULST])?$"#,
          options: .regularExpression) != nil { footer = true }
    }
    return footer ? 3 : 0
  }

  private func bounded(_ image: CIImage, edge: CGFloat) -> CIImage {
    let longest = max(image.extent.width, image.extent.height)
    guard longest > edge else { return image }
    let scale = edge / longest
    return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
  }

  private func normalized(_ image: CIImage) -> CIImage {
    image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
  }

  private func vector(_ point: CGPoint, in image: CIImage) -> CIVector {
    CIVector(x: point.x * image.extent.width, y: point.y * image.extent.height)
  }

  private func pointMap(_ point: CGPoint) -> [String: Double] {
    ["x": Double(min(1, max(0, point.x))), "y": Double(min(1, max(0, 1 - point.y)))]
  }

  private var fullImageCorners: [[String: Double]] {
    [["x": 0, "y": 0], ["x": 1, "y": 0], ["x": 1, "y": 1], ["x": 0, "y": 1]]
  }

  private enum ScanError: LocalizedError {
    case unreadableImage
    var errorDescription: String? { "This image could not be decoded. Choose another image or capture again." }
  }
}

private extension CIImage {
  var finiteImage: CIImage? {
    extent.isInfinite || extent.isEmpty || extent.width < 1 || extent.height < 1 ? nil : self
  }
}
