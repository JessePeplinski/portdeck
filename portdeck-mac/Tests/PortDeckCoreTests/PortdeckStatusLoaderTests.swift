import Foundation
import PortDeckCore
import Testing
@testable import PortDeckMac

@Test func localHelperDrainsOutputLargerThanPipeCapacity() async throws {
  let fixture = try LocalHelperFixture(source: #"""
    use POSIX (); $SIG{ALRM} = sub { POSIX::_exit(9) }; alarm 2;
    print '{"schemaVersion":"0.2","generatedAt":"fixture","groups":[],"unknown":[],"warnings":["';
    print 'x' x (256 * 1024);
    print '"]}';
    """#)
  defer { fixture.remove() }
  let loaded = try await PortdeckStatusLoader.load(runtime: fixture.runtime)
  #expect(loaded.status.warnings.first?.count == 256 * 1024)
}

@Test func localHelperCancellationStopsInFlightWork() async throws {
  let fixture = try LocalHelperFixture(source: #"""
    open(my $ready, '>', $0 . '.ready') or die; close($ready);
    select(undef, undef, undef, 1);
    print '{"schemaVersion":"0.2","generatedAt":"fixture","groups":[],"unknown":[],"warnings":[]}';
    """#)
  defer { fixture.remove() }
  let task = Task { try await PortdeckStatusLoader.load(runtime: fixture.runtime) }
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(2))
  while !FileManager.default.fileExists(atPath: fixture.script.path + ".ready"), clock.now < deadline {
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(FileManager.default.fileExists(atPath: fixture.script.path + ".ready"))
  let start = clock.now
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(start.duration(to: clock.now) < .milliseconds(500))
}

@Test func localHelperTimeoutEscalatesWhenTerminationIsIgnored() async throws {
  let fixture = try LocalHelperFixture(source: #"""
    $SIG{TERM} = 'IGNORE'; select(undef, undef, undef, 10);
    """#)
  defer { fixture.remove() }
  let clock = ContinuousClock()
  let start = clock.now
  await #expect(throws: PortdeckStatusLoaderError.timedOut) {
    try await PortdeckStatusLoader.load(runtime: fixture.runtime, timeout: .milliseconds(100))
  }
  #expect(start.duration(to: clock.now) < .seconds(2))
}

@Test func localHelperRejectsOversizedOutput() async throws {
  let fixture = try LocalHelperFixture(source: "print 'x' x (9 * 1024 * 1024);")
  defer { fixture.remove() }
  await #expect(throws: PortdeckStatusLoaderError.outputTooLarge) {
    try await PortdeckStatusLoader.load(runtime: fixture.runtime)
  }
}

@Test func localHelperAlreadyCancelledDoesNotStart() async throws {
  let fixture = try LocalHelperFixture(source: #"""
    open(my $ready, '>', $0 . '.ready') or die; close($ready);
    """#)
  defer { fixture.remove() }
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try await PortdeckStatusLoader.load(runtime: fixture.runtime)
  }
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(!FileManager.default.fileExists(atPath: fixture.script.path + ".ready"))
}

private struct LocalHelperFixture {
  let directory: URL
  let script: URL
  var runtime: PortdeckRuntime {
    PortdeckRuntime(nodeURL: URL(fileURLWithPath: "/usr/bin/perl"), cliURL: script)
  }

  init(source: String) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("portdeck-local-helper-test-\(UUID().uuidString)")
    script = directory.appendingPathComponent("helper.pl")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try source.write(to: script, atomically: true, encoding: .utf8)
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}
