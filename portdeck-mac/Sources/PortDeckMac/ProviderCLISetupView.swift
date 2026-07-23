import AppKit
import SwiftUI

struct ProviderCLISetupView: View {
  let systemImage: String
  let title: String
  let detail: String
  let installCommand: String
  let documentationURL: String
  let onRefresh: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(.secondary)
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 10) {
        Text(installCommand)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .lineLimit(1)
        Spacer(minLength: 8)
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(installCommand, forType: .string)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy install command")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
      .frame(maxWidth: 420)

      HStack(spacing: 8) {
        Button {
          guard let url = URL(string: documentationURL) else { return }
          NSWorkspace.shared.open(url)
        } label: {
          Label("Open install guide", systemImage: "arrow.up.forward.square")
        }
        .buttonStyle(.borderedProminent)

        Button(action: onRefresh) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(24)
    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
  }
}
