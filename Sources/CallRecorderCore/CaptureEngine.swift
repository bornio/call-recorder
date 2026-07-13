import AudioCaptureBridge
import Foundation

public struct CaptureConfiguration: Sendable {
    public var systemDirectory: URL
    public var microphoneDirectory: URL
    public var microphoneUID: String
    public var chunkDurationSeconds: UInt32
    public var ringCapacityBlocks: UInt32

    public init(
        systemDirectory: URL,
        microphoneDirectory: URL,
        microphoneUID: String,
        chunkDurationSeconds: UInt32 = 15,
        ringCapacityBlocks: UInt32 = 256
    ) {
        self.systemDirectory = systemDirectory
        self.microphoneDirectory = microphoneDirectory
        self.microphoneUID = microphoneUID
        self.chunkDurationSeconds = chunkDurationSeconds
        self.ringCapacityBlocks = ringCapacityBlocks
    }
}

public struct CaptureLiveStatistics: Equatable, Sendable {
    public var isRunning: Bool
    public var systemLevel: Float
    public var microphoneLevel: Float
    public var summary: CaptureSummary
    public var fatalErrorCode: Int32
    public var fatalErrorName: String?

    public static let empty = CaptureLiveStatistics(
        isRunning: false,
        systemLevel: 0,
        microphoneLevel: 0,
        summary: CaptureSummary(),
        fatalErrorCode: 0,
        fatalErrorName: nil
    )
}

public struct CaptureEngineError: LocalizedError, Sendable {
    public let code: Int32
    public let message: String

    public var errorDescription: String? { message }
}

public final class CaptureEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: CRCaptureHandle?
    private var lastStatistics: CaptureLiveStatistics = .empty

    public init() {}

    deinit {
        lock.lock()
        if let handle {
            _ = cr_capture_stop(handle, nil, 0)
            cr_capture_destroy(handle)
        }
        handle = nil
        lock.unlock()
    }

    public func start(configuration: CaptureConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }
        guard handle == nil else {
            throw CaptureEngineError(code: -1, message: "A recording is already active.")
        }
        lastStatistics = .empty

        var errorBuffer = [CChar](repeating: 0, count: 768)
        var newHandle: CRCaptureHandle?
        let result = configuration.systemDirectory.path.withCString { systemPath in
            configuration.microphoneDirectory.path.withCString { microphonePath in
                configuration.microphoneUID.withCString { microphoneUID in
                    var bridgeConfiguration = CRCaptureConfiguration(
                        system_directory: systemPath,
                        microphone_directory: microphonePath,
                        microphone_uid: microphoneUID,
                        chunk_duration_seconds: configuration.chunkDurationSeconds,
                        ring_capacity_blocks: configuration.ringCapacityBlocks
                    )
                    return cr_capture_start(
                        &bridgeConfiguration,
                        &newHandle,
                        &errorBuffer,
                        errorBuffer.count
                    )
                }
            }
        }
        guard result == CR_CAPTURE_OK, let newHandle else {
            let message = errorBuffer.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            }
            throw CaptureEngineError(
                code: result,
                message: message.isEmpty ? Self.errorName(result) : message
            )
        }
        handle = newHandle
    }

    public func statistics() -> CaptureLiveStatistics {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return lastStatistics }
        var bridgeStatistics = CRCaptureStatistics()
        guard cr_capture_copy_statistics(handle, &bridgeStatistics) == CR_CAPTURE_OK else {
            return .empty
        }
        let fatalCode = bridgeStatistics.fatal_error_code
        let statistics = CaptureLiveStatistics(
            isRunning: bridgeStatistics.running,
            systemLevel: bridgeStatistics.system_level,
            microphoneLevel: bridgeStatistics.microphone_level,
            summary: CaptureSummary(
                systemFrames: bridgeStatistics.system_frames,
                microphoneFrames: bridgeStatistics.microphone_frames,
                systemDroppedFrames: bridgeStatistics.system_dropped_frames,
                microphoneDroppedFrames: bridgeStatistics.microphone_dropped_frames,
                systemSampleRate: bridgeStatistics.system_sample_rate,
                microphoneSampleRate: bridgeStatistics.microphone_sample_rate
            ),
            fatalErrorCode: fatalCode,
            fatalErrorName: fatalCode == CR_CAPTURE_OK ? nil : Self.errorName(fatalCode)
        )
        lastStatistics = statistics
        return statistics
    }

    public func setPaused(_ paused: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else {
            throw CaptureEngineError(code: -1, message: "No recording is active.")
        }
        let result = cr_capture_set_paused(handle, paused)
        guard result == CR_CAPTURE_OK else {
            throw CaptureEngineError(code: result, message: Self.errorName(result))
        }
    }

    @discardableResult
    public func stop() throws -> CaptureLiveStatistics {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return lastStatistics }
        var errorBuffer = [CChar](repeating: 0, count: 768)
        let result = cr_capture_stop(handle, &errorBuffer, errorBuffer.count)
        var bridgeStatistics = CRCaptureStatistics()
        _ = cr_capture_copy_statistics(handle, &bridgeStatistics)
        cr_capture_destroy(handle)
        self.handle = nil

        let statistics = CaptureLiveStatistics(
            isRunning: false,
            systemLevel: bridgeStatistics.system_level,
            microphoneLevel: bridgeStatistics.microphone_level,
            summary: CaptureSummary(
                systemFrames: bridgeStatistics.system_frames,
                microphoneFrames: bridgeStatistics.microphone_frames,
                systemDroppedFrames: bridgeStatistics.system_dropped_frames,
                microphoneDroppedFrames: bridgeStatistics.microphone_dropped_frames,
                systemSampleRate: bridgeStatistics.system_sample_rate,
                microphoneSampleRate: bridgeStatistics.microphone_sample_rate
            ),
            fatalErrorCode: bridgeStatistics.fatal_error_code,
            fatalErrorName: bridgeStatistics.fatal_error_code == CR_CAPTURE_OK
                ? nil
                : Self.errorName(bridgeStatistics.fatal_error_code)
        )
        lastStatistics = statistics
        if result != CR_CAPTURE_OK {
            let message = errorBuffer.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            }
            throw CaptureEngineError(
                code: result,
                message: message.isEmpty ? Self.errorName(result) : message
            )
        }
        return statistics
    }

    public static func defaultAudioRoutes() throws -> AudioRouteSnapshot {
        var routes = CRDefaultAudioDevices()
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let result = cr_copy_default_audio_devices(&routes, &errorBuffer, errorBuffer.count)
        guard result == CR_CAPTURE_OK else {
            let message = errorBuffer.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            }
            throw CaptureEngineError(
                code: result,
                message: message.isEmpty ? Self.errorName(result) : message
            )
        }
        return AudioRouteSnapshot(
            defaultInputDevice: routes.default_input_device,
            defaultOutputDevice: routes.default_output_device
        )
    }

    private static func errorName(_ code: Int32) -> String {
        guard let name = cr_capture_error_name(code) else { return "Unknown capture error" }
        return String(cString: name)
    }
}
