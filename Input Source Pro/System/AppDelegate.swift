import Cocoa
import Combine
import SwiftUI
import Alamofire
import LaunchAtLogin

class AppDelegate: NSObject, NSApplicationDelegate {
    var navigationVM: NavigationVM!
    var indicatorVM: IndicatorVM!
    var preferencesVM: PreferencesVM!
    var permissionsVM: PermissionsVM!
    var applicationVM: ApplicationVM!
    var inputSourceVM: InputSourceVM!
    var feedbackVM: FeedbackVM!
    var indicatorWindowController: IndicatorWindowController!
    var statusItemController: StatusItemController!

    func applicationDidFinishLaunching(_: Notification) {
        feedbackVM = FeedbackVM()
        navigationVM = NavigationVM()
        permissionsVM = PermissionsVM()
        preferencesVM = PreferencesVM(permissionsVM: permissionsVM)
        applicationVM = ApplicationVM(preferencesVM: preferencesVM)
        inputSourceVM = InputSourceVM(preferencesVM: preferencesVM)
        indicatorVM = IndicatorVM(permissionsVM: permissionsVM, preferencesVM: preferencesVM, applicationVM: applicationVM, inputSourceVM: inputSourceVM)

        indicatorWindowController = IndicatorWindowController(
            permissionsVM: permissionsVM,
            preferencesVM: preferencesVM,
            indicatorVM: indicatorVM,
            applicationVM: applicationVM,
            inputSourceVM: inputSourceVM
        )

        statusItemController = StatusItemController(
            navigationVM: navigationVM,
            permissionsVM: permissionsVM,
            preferencesVM: preferencesVM,
            applicationVM: applicationVM,
            indicatorVM: indicatorVM,
            feedbackVM: feedbackVM,
            inputSourceVM: inputSourceVM
        )
        
        LaunchAtLogin.migrateIfNeeded()
        openPreferencesAtFirstLaunch()
        sendLaunchPing()
        updateInstallVersionInfo()
    }

    func applicationDidBecomeActive(_: Notification) {
        statusItemController.openPreferences()
    }

    @MainActor
    func openPreferencesAtFirstLaunch() {
        if preferencesVM.preferences.prevInstalledBuildVersion != preferencesVM.preferences.buildVersion {
            statusItemController.openPreferences()
        }
    }

    @MainActor
    func updateInstallVersionInfo() {
        preferencesVM.preferences.prevInstalledBuildVersion = preferencesVM.preferences.buildVersion
    }
    
    @MainActor
    func sendLaunchPing() {
        let url = "https://inputsource.pro/api/launch"
        let launchData: [String: String] = [
            "prevInstalledBuildVersion": "\(preferencesVM.preferences.prevInstalledBuildVersion)",
            "shortVersion": Bundle.main.shortVersion,
            "buildVersion": "\(Bundle.main.buildVersion)",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        
        AF.request(
            url,
            method: .post,
            parameters: launchData,
            encoding: JSONEncoding.default
        )
        .response { response in
            switch response.result {
            case .success:
                print("Launch ping sent successfully.")
            case let .failure(error):
                print("Failed to send launch ping:", error)
            }
        }
    }
}
