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
    // `FlutterBaseRegistrar` 以方法（而非属性）形式暴露 messenger
    registerMediaChannel(engineBridge.applicationRegistrar.messenger())
  }

  /// 注册图片保存通道：与 Android 侧 `com.appone.qnote_flutter/media` 保持同名同参，
  /// 供小Q 聊天图片的「下载」入口调用（Android 走 MediaStore，iOS 走 PHPhotoLibrary）。
  private func registerMediaChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.appone.qnote_flutter/media",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "saveToGallery",
            let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            !path.isEmpty
      else {
        result(FlutterError(code: "INVALID_PATH", message: "图片路径为空", details: nil))
        return
      }
      self.saveImageToGallery(path: path, result: result)
    }
  }

  /// 写入系统相册。`addOnly` 授权在首次调用时由系统弹窗征询，用户拒绝后回错误码，
  /// 由 Dart 侧降级为分享面板（用户仍可在面板里「存储图像」）。
  private func saveImageToGallery(path: String, result: @escaping FlutterResult) {
    guard let image = UIImage(contentsOfFile: path) else {
      result(FlutterError(code: "FILE_NOT_FOUND", message: "图片文件不存在", details: nil))
      return
    }
    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    if status == .denied || status == .restricted {
      result(FlutterError(code: "PERMISSION_DENIED", message: "相册写入权限被拒绝", details: nil))
      return
    }
    PHPhotoLibrary.shared().performChanges({
      PHAssetChangeRequest.creationRequestForAsset(from: image)
    }) { success, error in
      // 通道回调必须在平台线程返回，performChanges 的完成回调在后台队列
      DispatchQueue.main.async {
        if success {
          result(true)
        } else {
          result(
            FlutterError(
              code: "SAVE_FAILED",
              message: error?.localizedDescription ?? "相册写入失败",
              details: nil
            )
          )
        }
      }
    }
  }
}
