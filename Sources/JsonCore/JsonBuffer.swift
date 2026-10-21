import Foundation

public enum LoadError: Error, LocalizedError {
    case cannotOpen(path: String, errno: Int32)
    case readFailed(errno: Int32)
    case unsupportedEncoding(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let path, let code):
            return "Cannot open file: \(path) (\(String(cString: strerror(code))))"
        case .readFailed(let code):
            return "Read error: \(String(cString: strerror(code)))"
        case .unsupportedEncoding(let name):
            return "Unsupported encoding: \(name). Please use UTF-8."
        }
    }
}

/// The whole document as one contiguous, immutable byte buffer.
///
/// Everything else (tree nodes, search hits) refers to offsets inside this buffer,
/// so no JSON text is ever copied until it is displayed. A NUL byte is kept after
/// the last byte as a sentinel.
public final class JsonBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<UInt8>
    public let bytes: UnsafePointer<UInt8>
    public let count: Int

    private init(storage: UnsafeMutablePointer<UInt8>, offset: Int, count: Int) {
        self.storage = storage
        self.bytes = UnsafePointer(storage + offset)
        self.count = count
    }

    deinit { storage.deallocate() }

    public static let readChunkSize = 10 << 20

    /// Reads the file in `readChunkSize` pieces into a single allocation.
    public static func load(
        path: String,
        cancel: CancelToken,
        progress: (_ done: Int, _ total: Int) -> Void
    ) throws -> JsonBuffer {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw LoadError.cannotOpen(path: path, errno: errno) }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw LoadError.readFailed(errno: errno) }
        let size = Int(info.st_size)
        _ = fcntl(fd, F_RDAHEAD, 1)

        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: size + 1)
        var done = 0
        do {
            while done < size {
                if cancel.isCancelled { throw CancelledError() }
                let n = read(fd, storage + done, min(readChunkSize, size - done))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw LoadError.readFailed(errno: errno)
                }
                if n == 0 { break }
                done += n
                progress(done, size)
            }
            return try make(storage: storage, count: done)
        } catch {
            storage.deallocate()
            throw error
        }
    }

    public static func from(data: Data) throws -> JsonBuffer {
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count + 1)
        data.copyBytes(to: storage, count: data.count)
        do {
            return try make(storage: storage, count: data.count)
        } catch {
            storage.deallocate()
            throw error
        }
    }

    public static func from(string: String) throws -> JsonBuffer {
        try from(data: Data(string.utf8))
    }

    private static func make(storage: UnsafeMutablePointer<UInt8>, count: Int) throws -> JsonBuffer {
        storage[count] = 0
        if count >= 2,
           (storage[0] == 0xFF && storage[1] == 0xFE) || (storage[0] == 0xFE && storage[1] == 0xFF) {
            throw LoadError.unsupportedEncoding("UTF-16")
        }
        let bom = count >= 3 && storage[0] == 0xEF && storage[1] == 0xBB && storage[2] == 0xBF ? 3 : 0
        return JsonBuffer(storage: storage, offset: bom, count: count - bom)
    }

    /// Decodes up to `limit` bytes as UTF-8 without splitting a multi-byte sequence.
    public func text(_ offset: Int, _ length: Int, limit: Int = .max) -> (text: String, truncated: Bool) {
        let offset = max(0, min(offset, count))
        let length = max(0, min(length, count - offset))
        var n = min(length, limit)
        if n < length {
            while n > 0 && bytes[offset + n] & 0xC0 == 0x80 { n -= 1 }
        }
        let s = String(decoding: UnsafeBufferPointer(start: bytes + offset, count: n), as: UTF8.self)
        return (s, n < length)
    }

    public func data(_ offset: Int, _ length: Int) -> Data {
        Data(bytes: bytes + offset, count: max(0, min(length, count - offset)))
    }
}
