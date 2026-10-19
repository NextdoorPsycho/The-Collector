import FirebaseCore
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    #if DEBUG || PROFILE
    configureEmulatorFirebaseIfRequested()
    #endif
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  #if DEBUG || PROFILE
  private func configureEmulatorFirebaseIfRequested() {
    guard FirebaseApp.app() == nil,
          let encoded = Bundle.main.object(forInfoDictionaryKey: "CollectorDartDefines") as? String else { return }
    let emulatorRequested = encoded.split(separator: ",").contains { value in
      guard let data = Data(base64Encoded: String(value)),
            let define = String(data: data, encoding: .utf8) else { return false }
      return define == "USE_FIREBASE_EMULATORS=true"
    }
    guard emulatorRequested,
          let configURL = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
          let config = NSDictionary(contentsOf: configURL),
          let appID = config["GOOGLE_APP_ID"] as? String,
          let bundleID = Bundle.main.bundleIdentifier else { return }
    // Configure before firebase_core's eager default initialization from the production plist.
    let options = FirebaseOptions(googleAppID: appID, gcmSenderID: "123456789")
    options.apiKey = "A00000000000000000000000000000000000000"
    options.projectID = "demo-the-collector"
    options.bundleID = bundleID
    FirebaseApp.configure(options: options)
    FirebaseApp.app()?.isDataCollectionDefaultEnabled = false
  }
  #endif

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    #if DEBUG || PROFILE
    configureEmulatorFirebaseIfRequested()
    #endif
    LocalCardScanner.prepareTemporaryCrops()
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LocalCardScanner") {
      LocalCardScanner.register(with: registrar)
    }
  }
}
