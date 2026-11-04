import Foundation

/// Minimal gzip (RFC 1952) decoder on top of Foundation's raw-DEFLATE support.
/// Upstox publishes its instrument lists as `.json.gz` files.
nonisolated enum Gzip {
    nonisolated enum GzipError: Error, Equatable {
        case notGzip
        case truncated
        case unsupportedMethod
        case inflateFailed
    }

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18 else { throw GzipError.truncated }
        guard bytes[0] == 0x1F, bytes[1] == 0x8B else { throw GzipError.notGzip }
        guard bytes[2] == 8 else { throw GzipError.unsupportedMethod } // 8 = deflate
        let flags = bytes[3]
        var index = 10

        if flags & 0x04 != 0 { // FEXTRA
            guard index + 2 <= bytes.count else { throw GzipError.truncated }
            let length = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2 + length
        }
        if flags & 0x08 != 0 { // FNAME, zero-terminated
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT, zero-terminated
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 } // FHCRC

        let end = bytes.count - 8 // CRC32 + ISIZE trailer
        guard index < end else { throw GzipError.truncated }

        let deflated = Data(bytes[index..<end])
        do {
            // Foundation's `.zlib` algorithm is raw DEFLATE (RFC 1951), which is what gzip wraps.
            return try (deflated as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw GzipError.inflateFailed
        }
    }
}
