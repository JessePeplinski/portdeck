import SwiftUI

struct SettingsView: View {
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject var launchAtLoginModel: LaunchAtLoginModel
  @ObservedObject var statusModel: StatusModel

  var body: some View {
    Form {
      Section("General") {
        if launchAtLoginModel.requiresDirectRegistration {
          HStack {
            Text("Launch PortDeck at login")

            Spacer()

            Button("Add to Startup") {
              launchAtLoginModel.setEnabled(true)
            }
          }
        } else {
          Toggle(
            "Launch PortDeck at login",
            isOn: Binding(
              get: { launchAtLoginModel.isEnabled },
              set: { enabled in
                launchAtLoginModel.setEnabled(enabled)
              }
            )
          )
        }

        Text(launchAtLoginDescription)
          .font(.callout)
          .foregroundStyle(.secondary)

        if launchAtLoginModel.requiresApproval {
          approvalRequiredMessage
        } else if launchAtLoginModel.shouldOfferSystemSettingsFallback {
          Label(
            "macOS could not add PortDeck automatically. You can still add it in Login Items.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.orange)

          Button("Open Login Items…") {
            launchAtLoginModel.openSystemSettings()
          }
        }

        if let errorMessage = launchAtLoginModel.errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          .textSelection(.enabled)
        }
      }

      Section("Diagnostics") {
        Toggle(
          "Show likely system listeners",
          isOn: $statusModel.showLikelySystemListeners
        )

        Text("Include macOS background listeners in the Local dashboard.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 440)
    .frame(minHeight: 320)
    .padding(.vertical, 12)
    .onAppear(perform: launchAtLoginModel.refresh)
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        launchAtLoginModel.refresh()
      }
    }
  }

  private var launchAtLoginDescription: String {
    launchAtLoginModel.requiresDirectRegistration
      ? "Add this PortDeck application directly to macOS Login Items."
      : "Open PortDeck automatically when you log in to this Mac."
  }

  private var approvalRequiredMessage: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        "Allow PortDeck in System Settings to finish enabling launch at login.",
        systemImage: "person.badge.key.fill"
      )
      .foregroundStyle(.orange)

      Button("Open Login Items Settings") {
        launchAtLoginModel.openSystemSettings()
      }
    }
  }
}
