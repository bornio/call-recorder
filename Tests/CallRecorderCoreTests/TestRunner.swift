import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class TestCounter: @unchecked Sendable {
    var value = 0
}

private let completedTestCount = TestCounter()

func runTest(_ name: String, _ body: () throws -> Void) throws {
    do {
        try body()
        completedTestCount.value += 1
        print("PASS \(name)")
    } catch {
        throw TestFailure(description: "FAIL \(name): \(error)")
    }
}

func runAsyncTest(_ name: String, _ body: () async throws -> Void) async throws {
    do {
        try await body()
        completedTestCount.value += 1
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

func expectThrows(_ body: () throws -> Any) throws {
    do {
        _ = try body()
        throw TestFailure(description: "Expected an error")
    } catch is TestFailure {
        throw TestFailure(description: "Expected an error")
    } catch {
        return
    }
}

func require<T>(_ value: T?) throws -> T {
    guard let value else { throw TestFailure(description: "Required value was nil") }
    return value
}

@main
struct CallRecorderTestRunner {
    static func main() async {
        do {
            try runCaptureSessionStateMachineTests()
            try runAudioDeviceSelectionTests()
            try runRecordingStoreTests()
            try runDeepgramAndTranscriptTests()
            try runRecordingFinalizerTests()
            try runAudioExportServiceTests()
            try await runTranscriptionServiceTests()
            try await runRecordingJobQueueTests()
            print("\n\(completedTestCount.value) tests passed")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
