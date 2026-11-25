import AVFoundation
import Flutter
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "cut_video/splitter",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "splitAndSave",
            let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let parts = args["parts"] as? Int else {
        result(FlutterMethodNotImplemented)
        return
      }
      VideoSplitter.splitAndSave(path: path, parts: parts) { outcome in
        DispatchQueue.main.async {
          switch outcome {
          case .success(let count):
            result(count)
          case .failure(let error):
            result(FlutterError(code: "SPLIT_FAILED", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }
}

/// Cuts a video into `parts` equal-duration pieces (lossless, passthrough)
/// and saves each piece to the Photos library, one after another.
enum VideoSplitter {
  static func splitAndSave(
    path: String,
    parts: Int,
    completion: @escaping (Result<Int, Error>) -> Void
  ) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let total = CMTimeGetSeconds(asset.duration)

    guard parts >= 1, total.isFinite, total > 0 else {
      completion(.failure(SplitError("Could not read the video duration.")))
      return
    }

    requestAddAccess { granted in
      guard granted else {
        completion(.failure(SplitError("Photos access is needed to save the videos.")))
        return
      }
      export(asset: asset, total: total, index: 0, parts: parts, completion: completion)
    }
  }

  private static func export(
    asset: AVAsset,
    total: Double,
    index: Int,
    parts: Int,
    completion: @escaping (Result<Int, Error>) -> Void
  ) {
    if index == parts {
      completion(.success(parts))
      return
    }

    let segmentLength = total / Double(parts)
    let start = Double(index) * segmentLength
    let length = index == parts - 1 ? total - start : segmentLength

    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
      completion(.failure(SplitError("Could not create an exporter for this video.")))
      return
    }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("part_\(index + 1)_\(UUID().uuidString).mov")
    session.outputURL = outputURL
    session.outputFileType = session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
    session.timeRange = CMTimeRange(
      start: CMTime(seconds: start, preferredTimescale: 600),
      duration: CMTime(seconds: length, preferredTimescale: 600)
    )

    session.exportAsynchronously {
      guard session.status == .completed else {
        completion(.failure(session.error ?? SplitError("Export of part \(index + 1) failed.")))
        return
      }

      saveToPhotos(url: outputURL) { error in
        try? FileManager.default.removeItem(at: outputURL)
        if let error = error {
          completion(.failure(error))
          return
        }
        export(asset: asset, total: total, index: index + 1, parts: parts, completion: completion)
      }
    }
  }

  private static func saveToPhotos(url: URL, completion: @escaping (Error?) -> Void) {
    PHPhotoLibrary.shared().performChanges({
      PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
    }) { success, error in
      if success {
        completion(nil)
      } else {
        completion(error ?? SplitError("Could not save the video to Photos."))
      }
    }
  }

  private static func requestAddAccess(completion: @escaping (Bool) -> Void) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      completion(status == .authorized || status == .limited)
    }
  }

  struct SplitError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
