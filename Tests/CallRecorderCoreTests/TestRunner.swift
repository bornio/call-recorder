import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor private var completedTestCount = 0
private let expectedTestCount = 77

@MainActor
func runTest(_ name: String, _ body: () throws -> Void) throws {
    do {
        try body()
        completedTestCount += 1
        print("PASS \(name)")
    } catch {
        throw TestFailure(description: "FAIL \(name): \(error)")
    }
}

@MainActor
func runAsyncTest(_ name: String, _ body: () async throws -> Void) async throws {
    do {
        try await body()
        completedTestCount += 1
        print("PASS \(name)")
    } catch {
        throw TestFailure(description: "FAIL \(name): \(error)")
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String = "Expectation failed") throws {
    guard condition() else { throw TestFailure(description: message) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T) throws {
    guard actual == expected else {
        throw TestFailure(description: "Expected \(expected), got \(actual)")
    }
}

@MainActor
func expectThrows<T, ExpectedError: Error>(
    _ expectedType: ExpectedError.Type,
    matching matches: (ExpectedError) -> Bool = { _ in true },
    _ body: () throws -> T
) throws {
    do {
        _ = try body()
    } catch let error as ExpectedError {
        guard matches(error) else {
            throw TestFailure(description: "Unexpected \(expectedType): \(error)")
        }
        return
    } catch {
        throw TestFailure(
            description: "Expected \(expectedType), got \(type(of: error)): \(error)"
        )
    }
    throw TestFailure(description: "Expected \(expectedType), but no error was thrown")
}

@MainActor
func expectThrows<T, ExpectedError: Error>(
    _ expectedType: ExpectedError.Type,
    matching matches: (ExpectedError) -> Bool = { _ in true },
    _ body: () async throws -> T
) async throws {
    do {
        _ = try await body()
    } catch let error as ExpectedError {
        guard matches(error) else {
            throw TestFailure(description: "Unexpected \(expectedType): \(error)")
        }
        return
    } catch {
        throw TestFailure(
            description: "Expected \(expectedType), got \(type(of: error)): \(error)"
        )
    }
    throw TestFailure(description: "Expected \(expectedType), but no error was thrown")
}

func withTemporaryDirectory(
    prefix: String = "CallRecorderTests",
    _ body: (URL) throws -> Void
) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    do {
        try body(url)
    } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
    }
    try FileManager.default.removeItem(at: url)
}

@MainActor
func withTemporaryDirectory(
    prefix: String,
    _ body: (URL) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    do {
        try await body(url)
    } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
    }
    try FileManager.default.removeItem(at: url)
}

func require<T>(_ value: T?) throws -> T {
    guard let value else { throw TestFailure(description: "Required value was nil") }
    return value
}

@main
struct CallRecorderTestRunner {
    @MainActor
    static func main() async {
        do {
            try runCaptureSessionStateMachineTests()
            try runAudioDeviceSelectionTests()
            try runCalendarMatchingTests()
            try runTranscriptSearchTests()
            try runRecordingPresentationTests()
            try runRecordingStoreTests()
            try runDeepgramAndTranscriptTests()
            try runRecordingFinalizerTests()
            try runAudioExportServiceTests()
            try await runTranscriptionServiceTests()
            try await runRecordingJobQueueTests()
            guard completedTestCount == expectedTestCount else {
                throw TestFailure(
                    description: "Expected \(expectedTestCount) registered tests, " +
                        "but ran \(completedTestCount)"
                )
            }
            print("\n\(completedTestCount) tests passed")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
