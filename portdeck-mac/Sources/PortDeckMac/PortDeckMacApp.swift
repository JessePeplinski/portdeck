import AppKit
import SwiftUI

enum MenuWindowSizing {
  static let width: CGFloat = 500
  static let preferredHeight: CGFloat = 700
  static let fallbackHeight: CGFloat = 560
  static let displayMargin: CGFloat = 24

  static func height(for screen: NSScreen?) -> CGFloat {
    height(availableHeight: screen?.visibleFrame.height)
  }

  static func height(availableHeight: CGFloat?) -> CGFloat {
    guard let availableHeight else {
      return fallbackHeight
    }

    return min(preferredHeight, max(1, availableHeight - displayMargin))
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}

@main
struct PortDeckMacApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = StatusModel()
  @StateObject private var vercelModel = VercelStatusModel()
  @StateObject private var convexModel = ConvexStatusModel()
  @StateObject private var githubModel = GitHubStatusModel()
  @StateObject private var supabaseModel = SupabaseStatusModel()
  @StateObject private var cloudflareModel = CloudflareStatusModel()
  @StateObject private var railwayModel = RailwayStatusModel()
  @StateObject private var flyModel = FlyStatusModel()
  @StateObject private var netlifyModel = NetlifyStatusModel()
  @StateObject private var hostingerModel = HostingerStatusModel()
  @StateObject private var providerConfiguration = ProviderConfigurationModel()
  @StateObject private var launchAtLoginModel = LaunchAtLoginModel()
  @StateObject private var updateController = UpdateController()

  var body: some Scene {
    MenuBarExtra {
      StatusView(
        model: model,
        vercelModel: vercelModel,
        convexModel: convexModel,
        githubModel: githubModel,
        supabaseModel: supabaseModel,
        cloudflareModel: cloudflareModel,
        railwayModel: railwayModel,
        flyModel: flyModel,
        netlifyModel: netlifyModel,
        hostingerModel: hostingerModel,
        providerConfiguration: providerConfiguration,
        updateController: updateController
      )
        .frame(
          width: MenuWindowSizing.width,
          height: MenuWindowSizing.height(for: NSScreen.main)
        )
    } label: {
      Label {
        Text("PortDeck")
      } icon: {
        Image(nsImage: PortDeckMenuBarIcon.image)
      }
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(
        launchAtLoginModel: launchAtLoginModel,
        statusModel: model,
        updateController: updateController
      )
    }
  }
}
