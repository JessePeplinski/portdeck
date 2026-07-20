import Foundation

enum PackagedRuntimeBoundary {
  static let developmentFallbackMarker = ".portdeck-source-development"

  static func requiresBundledRuntime(
    bundleResourceURL: URL?,
    fileManager: FileManager
  ) -> Bool {
    guard let bundleResourceURL else { return false }

    let marker = bundleResourceURL.appendingPathComponent(developmentFallbackMarker)
    if fileManager.fileExists(atPath: marker.path) {
      return false
    }

    let contentsURL = bundleResourceURL.deletingLastPathComponent()
    let appURL = contentsURL.deletingLastPathComponent()
    return bundleResourceURL.lastPathComponent == "Resources"
      && contentsURL.lastPathComponent == "Contents"
      && appURL.pathExtension.lowercased() == "app"
  }
}
