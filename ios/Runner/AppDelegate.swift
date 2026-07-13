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
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FenghuoGallery") else {
      return
    }
    let channel = FlutterMethodChannel(name: "fenghuo/gallery", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      if call.method == "saveImage" {
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "invalid_args", message: "invalid_args", details: nil))
          return
        }
        guard let typed = args["bytes"] as? FlutterStandardTypedData else {
          result(FlutterError(code: "invalid_args", message: "bytes_empty", details: nil))
          return
        }
        let data = typed.data
        if data.isEmpty {
          result(FlutterError(code: "invalid_args", message: "bytes_empty", details: nil))
          return
        }

        func saveNow() {
          var placeholder: PHObjectPlaceholder?
          PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: data, options: nil)
            placeholder = req.placeholderForCreatedAsset
          }, completionHandler: { success, error in
            DispatchQueue.main.async {
              if success {
                result(placeholder?.localIdentifier)
              } else {
                result(FlutterError(code: "save_failed", message: error?.localizedDescription ?? "保存失败", details: nil))
              }
            }
          })
        }

        if #available(iOS 14, *) {
          PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            if status == .authorized {
              saveNow()
              return
            }
            DispatchQueue.main.async {
              result(FlutterError(code: "no_permission", message: "未获得相册权限", details: nil))
            }
          }
        } else {
          PHPhotoLibrary.requestAuthorization { status in
            if status == .authorized {
              saveNow()
              return
            }
            DispatchQueue.main.async {
              result(FlutterError(code: "no_permission", message: "未获得相册权限", details: nil))
            }
          }
        }
        return
      }
      result(FlutterMethodNotImplemented)
    }
  }
}
