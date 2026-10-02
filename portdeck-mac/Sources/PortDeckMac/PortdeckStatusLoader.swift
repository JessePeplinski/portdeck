import Darwin
import Foundation
import PortDeckCore

struct LoadedPortdeckStatus: Sendable {
  let status: PortdeckStatus
  let rawJSON: String
}

protocol PortdeckStatusLoading: Sendable {
  func load() async throws -> LoadedPortdeckStatus
  func stopService(id serviceId: String) async throws -> PortdeckStopResult
}

struct LivePortdeckStatusLoader: PortdeckStatusLoading {
  func load() async throws -> LoadedPortdeckStatus {
    try await PortdeckStatusLoader.load()
  }

  func stopService(id serviceId: String) async throws -> PortdeckStopResult {
    try await PortdeckStatusLoader.stopService(id: serviceId)
  }
}

enum PortdeckStatusLoader {
  static func load(
    runtime: PortdeckRuntime? = nil,
    timeout: Duration = .seconds(30)
  ) async throws -> LoadedPortdeckStatus {
    let result = try await runPortdeckCommand(arguments: ["status", "--json"], runtime: runtime, timeout: timeout)
    return try decodeStatus(result)
  }

  static func stopService(id serviceId: String) async throws -> PortdeckStopResult {
    let result = try await runPortdeckCommand(arguments: ["stop", "--service-id", serviceId, "--json"])
    return try decodeStopResult(result)
  }

  private static func decodeStatus(_ result: PortdeckCommandResult) throws -> LoadedPortdeckStatus {
    let rawJSON = result.stdoutString

    guard result.terminationStatus == 0 else {
      throw PortdeckStatusLoaderError.commandFailed(result.errorMessage ?? "portdeck status --json failed")
    }

    do {
      let status = try JSONDecoder().decode(PortdeckStatus.self, from: result.stdout)
      return LoadedPortdeckStatus(status: status, rawJSON: rawJSON)
    } catch {
      throw PortdeckStatusLoaderError.invalidJSON(error.localizedDescription)
    }
  }

  private static func decodeStopResult(_ result: PortdeckCommandResult) throws -> PortdeckStopResult {
    do {
      return try JSONDecoder().decode(PortdeckStopResult.self, from: result.stdout)
    } catch {
      if result.terminationStatus != 0 {
        throw PortdeckStatusLoaderError.commandFailed(result.errorMessage ?? "portdeck stop failed")
      }
      throw PortdeckStatusLoaderError.invalidJSON(error.localizedDescription)
    }
  }

  private static func runPortdeckCommand(
    arguments: [String],
    runtime: PortdeckRuntime? = nil,
    timeout: Duration = .seconds(30)
  ) async throws -> PortdeckCommandResult {
    let coordinator = LocalHelperProcessCoordinator()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let result = try await Task.detached {
        try runCommandSync(arguments: arguments, runtime: runtime, timeout: timeout, coordinator: coordinator)
      }.value
      try Task.checkCancellation()
      return result
    } onCancel: {
      coordinator.cancel()
    }
  }

  private static func runCommandSync(
    arguments: [String],
    runtime: PortdeckRuntime?,
    timeout: Duration,
    coordinator: LocalHelperProcessCoordinator
  ) throws -> PortdeckCommandResult {
    let runtime = try runtime ?? PortdeckRuntimeResolver().resolveRuntime()
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent("portdeck-local-\(UUID().uuidString)")
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fileManager.removeItem(at: directory) }
    let stdoutURL = directory.appendingPathComponent("stdout")
    let stderrURL = directory.appendingPathComponent("stderr")
    for url in [stdoutURL, stderrURL] {
      guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw PortdeckStatusLoaderError.commandFailed("Could not create private helper output files.")
      }
    }
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    defer { try? stdout.close() }
    let stderr = try FileHandle(forWritingTo: stderrURL)
    defer { try? stderr.close() }
    let process = Process()
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    defer {
      process.terminationHandler = nil
      coordinator.clear()
    }
    process.executableURL = runtime.nodeURL
    process.arguments = [runtime.cliURL.path] + arguments
    process.standardOutput = stdout
    process.standardError = stderr

    // Files avoid the wait-before-drain pipe deadlock on large snapshots.
    try coordinator.start(process)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    let maximumOutputBytes = 8 * 1024 * 1024
    while exited.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
      let outputTooLarge = [stdoutURL, stderrURL].contains { url in
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return size > maximumOutputBytes
      }
      if coordinator.isCancelled || clock.now >= deadline || outputTooLarge {
        if process.isRunning { process.terminate() }
        // A helper that ignores SIGTERM must not retain a refresh forever.
        if exited.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
          if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
          process.waitUntilExit()
        }
        if coordinator.isCancelled { throw CancellationError() }
        if outputTooLarge { throw PortdeckStatusLoaderError.outputTooLarge }
        throw PortdeckStatusLoaderError.timedOut
      }
    }
    if coordinator.isCancelled { throw CancellationError() }
    let output = try readBoundedOutput(at: stdoutURL, limit: maximumOutputBytes)
    let errorOutput = try readBoundedOutput(at: stderrURL, limit: maximumOutputBytes)

    return PortdeckCommandResult(
      stdout: output,
      stderr: errorOutput,
      terminationStatus: process.terminationStatus
    )
  }

  private static func readBoundedOutput(at url: URL, limit: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw PortdeckStatusLoaderError.outputTooLarge }
    return data
  }
}

private final class LocalHelperProcessCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func start(_ process: Process) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { throw CancellationError() }
    try process.run()
    self.process = process
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    process = nil
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    cancelled = true
    if let process, process.isRunning { process.terminate() }
  }
}

private struct PortdeckCommandResult {
  let stdout: Data
  let stderr: Data
  let terminationStatus: Int32

  var stdoutString: String {
    String(data: stdout, encoding: .utf8) ?? ""
  }

  var errorMessage: String? {
    let message = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return message?.isEmpty == false ? message : nil
  }
}

enum PortdeckStatusLoaderError: LocalizedError, Equatable {
  case commandFailed(String)
  case invalidJSON(String)
  case timedOut
  case outputTooLarge

  var errorDescription: String? {
    switch self {
    case .commandFailed(let message):
      return message
    case .invalidJSON(let message):
      return "Could not parse portdeck status JSON: \(message)"
    case .timedOut:
      return "Local helper timed out. Try refreshing again."
    case .outputTooLarge:
      return "Local helper output exceeded the 8 MiB limit."
    }
  }
}
