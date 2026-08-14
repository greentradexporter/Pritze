import Contacts
import ContactsUI
import Flutter
import UIKit
import flutter_local_notifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate,
  CNContactPickerDelegate
{
  private var phoneHintResult: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let launched = super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
    application.registerForRemoteNotifications()
    return launched
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let phoneHintChannel = FlutterMethodChannel(
      name: "com.trimtime.app/phone_hint",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    phoneHintChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "requestPhoneNumber" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.presentPhoneNumberPicker(result: result)
    }
  }

  private func presentPhoneNumberPicker(result: @escaping FlutterResult) {
    guard phoneHintResult == nil else {
      result(
        FlutterError(
          code: "in_progress",
          message: "A phone-number picker is already open.",
          details: nil
        )
      )
      return
    }
    guard let presenter = topViewController() else {
      result(
        FlutterError(
          code: "unavailable",
          message: "The phone-number picker is unavailable.",
          details: nil
        )
      )
      return
    }

    let picker = CNContactPickerViewController()
    picker.delegate = self
    picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
    picker.predicateForEnablingContact = NSPredicate(
      format: "phoneNumbers.@count > 0"
    )
    picker.predicateForSelectionOfContact = NSPredicate(
      format: "phoneNumbers.@count == 1"
    )
    picker.predicateForSelectionOfProperty = NSPredicate(
      format: "key == 'phoneNumbers'"
    )
    phoneHintResult = result
    presenter.present(picker, animated: true)
  }

  func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
    finishPhoneNumberPicker(value: nil)
  }

  func contactPicker(
    _ picker: CNContactPickerViewController,
    didSelect contact: CNContact
  ) {
    finishPhoneNumberPicker(value: contact.phoneNumbers.first?.value.stringValue)
  }

  func contactPicker(
    _ picker: CNContactPickerViewController,
    didSelect contactProperty: CNContactProperty
  ) {
    let phoneNumber = contactProperty.value as? CNPhoneNumber
    finishPhoneNumberPicker(value: phoneNumber?.stringValue)
  }

  private func finishPhoneNumberPicker(value: String?) {
    let result = phoneHintResult
    phoneHintResult = nil
    result?(value)
  }

  private func topViewController() -> UIViewController? {
    let sceneRoot = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?
      .rootViewController
    var controller = window?.rootViewController ?? sceneRoot
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    if let navigationController = controller as? UINavigationController {
      return navigationController.visibleViewController ?? navigationController
    }
    if let tabBarController = controller as? UITabBarController {
      return tabBarController.selectedViewController ?? tabBarController
    }
    return controller
  }
}
