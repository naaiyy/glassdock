import Foundation
import NIOCore
import Vapor

protocol DockerControlPlaneRuntime: Sendable {
    func supportsLogOptions() async -> Bool
    func createContainer(_ request: DockerRuntimeContainerCreate) async throws -> DockerRuntimeContainer
    func startContainer(id: String) async throws
    func deleteContainer(id: String, force: Bool, removeVolumes: Bool) async throws
    func inspectContainer(id: String) async throws -> DockerRuntimeContainer
    func logs(id: String, stdout: Bool, stderr: Bool) async throws -> DockerRuntimeProcessOutput
    func logs(
        id: String,
        stdout: Bool,
        stderr: Bool,
        options: DockerRuntimeLogOptions
    ) async throws -> DockerRuntimeProcessOutput
    func streamLogs(
        id: String,
        stdout: Bool,
        stderr: Bool,
        options: DockerRuntimeLogOptions
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error>
}

extension GuestRuntime: DockerControlPlaneRuntime {}

extension DockerControlPlaneRuntime {
    func supportsLogOptions() async -> Bool { false }

    func logs(
        id: String,
        stdout: Bool,
        stderr: Bool,
        options: DockerRuntimeLogOptions
    ) async throws -> DockerRuntimeProcessOutput {
        try await logs(id: id, stdout: stdout, stderr: stderr)
    }

    func streamLogs(
        id: String,
        stdout: Bool,
        stderr: Bool,
        options: DockerRuntimeLogOptions
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        let output = try await logs(id: id, stdout: stdout, stderr: stderr, options: options)
        return AsyncThrowingStream { continuation in
            if stdout, !output.stdout.isEmpty {
                continuation.yield(.init(stream: .stdout, data: output.stdout, exitCode: nil))
            }
            if stderr, !output.stderr.isEmpty {
                continuation.yield(.init(stream: .stderr, data: output.stderr, exitCode: nil))
            }
            continuation.finish()
        }
    }
}

extension GuestRuntime {
    func supportsLogOptions() async -> Bool { true }

    func streamLogs(
        id: String,
        stdout: Bool,
        stderr: Bool,
        options: DockerRuntimeLogOptions
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        try await attachContainer(
            id: id, stdout: stdout, stderr: stderr, options: options
        )
    }
}
