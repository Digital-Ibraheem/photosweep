import CryptoKit
import Foundation

/// Computes SHA-256 of a file in fixed-size chunks so memory use does not depend on file size.
public enum ContentHasher {
    public static let chunkSize = 1 << 20

    /// Hashes the file and verifies its metadata did not change during the read.
    /// - Parameter expected: metadata recorded at discovery. If the file no longer matches it
    ///   before or after reading, the result is discarded and `changedDuringRead` is thrown.
    public static func sha256(path: String, expected: FileMetadata) throws -> String {
        let before = try readMetadata(path: path)
        guard before.sameContentSignature(as: expected) else { throw PhotoSweepError.changedDuringRead(path) }
        let digest = try sha256(path: path)
        let after = try readMetadata(path: path)
        guard after.sameContentSignature(as: before) else { throw PhotoSweepError.changedDuringRead(path) }
        return digest
    }

    /// Hashes the file without any metadata checks.
    public static func sha256(path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw PhotoSweepError.readFailed(path: path, message: "cannot open")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            } catch {
                throw PhotoSweepError.readFailed(path: path, message: error.localizedDescription)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
