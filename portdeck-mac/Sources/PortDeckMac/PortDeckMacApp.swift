import AppKit
import SwiftUI

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
  @StateObject private var providerConfiguration = ProviderConfigurationModel()

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
        providerConfiguration: providerConfiguration
      )
        .frame(width: 500, height: menuWindowHeight)
    } label: {
      Label("PortDeck", systemImage: model.menuIconName)
    }
    .menuBarExtraStyle(.window)
  }

  private var menuWindowHeight: CGFloat {
    NSScreen.main?.visibleFrame.height ?? 560
  }
}
