import Darwin
import Foundation

enum AtomicFilePublisher {
    static func publishNewFile(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).partial"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        try data.write(to: temporary, options: [.atomic])
        let descriptor = open(temporary.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError() }

        let result = temporary.path.withCString { source in
            destination.path.withCString { target in
                renameatx_np(AT_FDCWD, source, AT_FDCWD, target, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 {
            if errno == EEXIST {
                throw AtomicFilePublisherError.destinationExists
            }
            throw posixError()
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

enum AtomicFilePublisherError: Error {
    case destinationExists
}
