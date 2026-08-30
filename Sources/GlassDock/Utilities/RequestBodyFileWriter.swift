import Foundation
import Vapor

enum RequestBodyFileWriter {
    static func createSecureTemporaryDirectory(
        in parent: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let directory = parent.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    /// Copies a request body to a file with bounded memory. Regex-routed Docker
    /// endpoints receive the body as an async stream, so collecting it first can
    /// otherwise retain an entire multi-gigabyte image archive in the daemon.
    @discardableResult
    static func write<Chunks: AsyncSequence>(
        _ chunks: Chunks,
        to destination: URL,
        maxBytes: Int,
        kind: String
    ) async throws -> Int where Chunks.Element == ByteBuffer {
        guard
            FileManager.default.createFile(
                atPath: destination.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw Abort(.internalServerError, reason: "failed to create temporary file for \(kind)")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        var completed = false
        defer {
            try? handle.close()
            if !completed {
                try? FileManager.default.removeItem(at: destination)
            }
        }

        var totalBytes = 0
        func writeChunk(_ buffer: ByteBuffer) throws {
            guard buffer.readableBytes <= maxBytes - totalBytes else {
                throw Abort(.payloadTooLarge, reason: "\(kind) exceeds the \(maxBytes)-byte limit")
            }
            try handle.write(contentsOf: Data(buffer: buffer))
            totalBytes += buffer.readableBytes
        }

        for try await chunk in chunks {
            try Task.checkCancellation()
            try writeChunk(chunk)
        }
        try Task.checkCancellation()
        completed = true
        return totalBytes
    }

    /// Copies an asynchronous Data stream to a private file without retaining
    /// the complete stream in memory. Runtime archive responses use Data rather
    /// than ByteBuffer, so keep this sibling to `write` instead of adapting the
    /// stream through an unstructured task.
    @discardableResult
    static func writeData<Chunks: AsyncSequence>(
        _ chunks: Chunks,
        to destination: URL,
        maxBytes: Int,
        kind: String
    ) async throws -> Int where Chunks.Element == Data {
        guard
            FileManager.default.createFile(
                atPath: destination.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw Abort(.internalServerError, reason: "failed to create temporary file for \(kind)")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        var completed = false
        defer {
            try? handle.close()
            if !completed {
                try? FileManager.default.removeItem(at: destination)
            }
        }

        var totalBytes = 0
        for try await data in chunks {
            try Task.checkCancellation()
            guard data.count <= maxBytes - totalBytes else {
                throw Abort(.payloadTooLarge, reason: "\(kind) exceeds the \(maxBytes)-byte limit")
            }
            try handle.write(contentsOf: data)
            totalBytes += data.count
        }
        try Task.checkCancellation()
        completed = true
        return totalBytes
    }
}
