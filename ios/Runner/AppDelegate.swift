import AVFoundation
import Flutter
import Photos
import PhotosUI
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var progressSink: FlutterEventSink?
  private var pickerDelegate: VideoPickerDelegate?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()

    let channel = FlutterMethodChannel(name: "cut_video/splitter", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "pickVideo":
        self?.presentPicker(result: result)

      case "splitAndSave":
        guard let args = call.arguments as? [String: Any],
              let assetId = args["assetId"] as? String,
              let parts = args["parts"] as? Int else {
          result(FlutterMethodNotImplemented)
          return
        }
        let deleteOriginal = args["delete"] as? Bool ?? false

        VideoSplitter.splitAndSave(
          assetId: assetId,
          parts: parts,
          deleteOriginal: deleteOriginal,
          progress: { fraction in
            DispatchQueue.main.async { self?.progressSink?(fraction) }
          },
          completion: { outcome in
            DispatchQueue.main.async {
              switch outcome {
              case .success(let deleted):
                result(["saved": parts, "deleted": deleted])
              case .failure(let error):
                result(FlutterError(code: "SPLIT_FAILED", message: error.localizedDescription, details: nil))
              }
            }
          }
        )

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let progressChannel = FlutterEventChannel(name: "cut_video/progress", binaryMessenger: messenger)
    progressChannel.setStreamHandler(ProgressStreamHandler { [weak self] sink in
      self?.progressSink = sink
    })
  }

  // MARK: - Picking

  /// Shows the system photo picker (videos only) and returns the chosen
  /// video's file path, size and Photos asset id, so it can be deleted later.
  private func presentPicker(result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async {
          result(FlutterError(code: "NO_ACCESS", message: "Photos access is needed to choose a video.", details: nil))
        }
        return
      }

      DispatchQueue.main.async {
        var config = PHPickerConfiguration(photoLibrary: PHPhotoLibrary.shared())
        config.filter = .videos
        config.selectionLimit = 1

        let delegate = VideoPickerDelegate { asset in
          self.pickerDelegate = nil
          guard let asset = asset else {
            result(nil) // cancelled
            return
          }
          self.loadVideo(asset: asset, result: result)
        }
        self.pickerDelegate = delegate

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = delegate
        self.topViewController()?.present(picker, animated: true)
      }
    }
  }

  /// Returns only the Photos asset id and its size. The file itself is read
  /// by the splitter through Photos, not by path (the sandbox blocks direct
  /// access to files in the Photos library).
  private func loadVideo(asset: PHAsset, result: @escaping FlutterResult) {
    let resource = PHAssetResource.assetResources(for: asset).first
    let size = (resource?.value(forKey: "fileSize") as? NSNumber)?.intValue ?? 0
    result([
      "size": size,
      "assetId": asset.localIdentifier,
    ])
  }

  private func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }
}

/// Hands the picked asset (or nil on cancel) back to the caller.
final class VideoPickerDelegate: NSObject, PHPickerViewControllerDelegate {
  private let onPick: (PHAsset?) -> Void

  init(onPick: @escaping (PHAsset?) -> Void) {
    self.onPick = onPick
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let identifier = results.first?.assetIdentifier else {
      onPick(nil)
      return
    }
    let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    onPick(asset)
  }
}

/// Forwards progress events (0.0 ... 1.0) from the native side to Dart.
final class ProgressStreamHandler: NSObject, FlutterStreamHandler {
  private let onSink: (FlutterEventSink?) -> Void

  init(onSink: @escaping (FlutterEventSink?) -> Void) {
    self.onSink = onSink
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    onSink(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onSink(nil)
    return nil
  }
}

/// Cuts a video into `parts` equal-duration pieces (lossless, passthrough)
/// and saves each piece to the Photos library, one after another.
/// If `assetId` is given, the original is deleted once every part is saved.
/// `progress` receives the overall fraction done (0.0 ... 1.0).
enum VideoSplitter {
  static func splitAndSave(
    assetId: String,
    parts: Int,
    deleteOriginal: Bool,
    progress: @escaping (Double) -> Void,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    guard let photoAsset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
      completion(.failure(SplitError("Could not find this video in Photos.")))
      return
    }

    loadAVAsset(photoAsset) { avAsset in
      guard let asset = avAsset else {
        completion(.failure(SplitError("Could not open this video.")))
        return
      }
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
        export(asset: asset, total: total, index: 0, parts: parts, progress: progress) { outcome in
          switch outcome {
          case .failure(let error):
            completion(.failure(error))
          case .success:
            guard deleteOriginal else {
              completion(.success(false))
              return
            }
            VideoSplitter.deleteOriginal(assetId: assetId) { deleted in
              completion(.success(deleted))
            }
          }
        }
      }
    }
  }

  /// Gets the playable AVAsset for a Photos video, as provided by Photos.
  private static func loadAVAsset(_ asset: PHAsset, completion: @escaping (AVAsset?) -> Void) {
    let options = PHVideoRequestOptions()
    options.version = .original
    options.isNetworkAccessAllowed = true
    PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
      completion(avAsset)
    }
  }

  private static func export(
    asset: AVAsset,
    total: Double,
    index: Int,
    parts: Int,
    progress: @escaping (Double) -> Void,
    completion: @escaping (Result<Int, Error>) -> Void
  ) {
    if index == parts {
      progress(1.0)
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

    // Poll the exporter so the bar moves smoothly within each part.
    // The timer lives on the main run loop, so it is created and stopped there.
    var timer: Timer?
    DispatchQueue.main.async {
      timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        let partFraction = Double(session.progress)
        progress((Double(index) + partFraction) / Double(parts))
      }
    }

    session.exportAsynchronously {
      DispatchQueue.main.async { timer?.invalidate() }

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
        progress(Double(index + 1) / Double(parts))
        export(asset: asset, total: total, index: index + 1, parts: parts, progress: progress, completion: completion)
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

  /// Deletes the original. iOS shows its own confirmation alert; returns
  /// false if the asset is missing or the user declined that alert.
  private static func deleteOriginal(assetId: String, completion: @escaping (Bool) -> Void) {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
      completion(false)
      return
    }
    PHPhotoLibrary.shared().performChanges({
      PHAssetChangeRequest.deleteAssets([asset] as NSArray)
    }) { success, _ in
      completion(success)
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
