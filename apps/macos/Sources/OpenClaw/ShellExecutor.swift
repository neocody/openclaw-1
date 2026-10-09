import Foundation
import OpenClawIPC

enum ShellExecutor {
    struct ShellResult: Sendable {
        var stdout: String
        var stderr: String
        var exitCode: Int?
        var timedOut: Bool
        var success: Bool
        var errorMessage: String?
    }

    private final class DeadlineState: @unchecked Sendable {
        private let lock = NSLock()
        private var expired = false

        func expire() {
            self.lock.lock()
            self.expired = true
            self.lock.unlock()
        }

        var timedOut: Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.expired
        }
    }

    private static func readPipe(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            // Blocking pipe reads must not occupy Swift's cooperative executor.
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: pipe.fileHandleForReading.readToEndSafely())
            }
        }
    }

    private static func waitForExit(_ process: Process) async -> Int {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume(returning: Int(process.terminationStatus))
            }
        }
    }

    static func runDetailed(
        command: [String],
        cwd: String?,
        env: [String: String]?,
        timeout: Double?) async -> ShellResult
    {
        guard !command.isEmpty else {
            return ShellResult(
                stdout: "",
                stderr: "",
                exitCode: nil,
                timedOut: false,
                success: false,
                errorMessage: "empty command")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        if let env {
            process.environment = env
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ShellResult(
                stdout: "",
                stderr: "",
                exitCode: nil,
                timedOut: false,
                success: false,
                errorMessage: "failed to start: \(error.localizedDescription)")
        }

        let deadline = DeadlineState()
        let outTask = Task { await self.readPipe(stdoutPipe) }
        let errTask = Task { await self.readPipe(stderrPipe) }

        let waitTask = Task { () -> ShellResult in
            let status = await self.waitForExit(process)
            let out = await outTask.value
            let err = await errTask.value
            let timedOut = deadline.timedOut
            return ShellResult(
                stdout: String(bytes: out, encoding: .utf8) ?? "",
                stderr: String(bytes: err, encoding: .utf8) ?? "",
                exitCode: status,
                timedOut: timedOut,
                success: !timedOut && status == 0,
                errorMessage: timedOut ? "timeout" : (status == 0 ? nil : "exit \(status)"))
        }

        if let timeout, timeout > 0 {
            let nanos = UInt64(timeout * 1_000_000_000)
            return await withTaskGroup(of: ShellResult.self) { group in
                group.addTask { await waitTask.value }
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: nanos)
                    } catch {
                        return await waitTask.value
                    }
                    if process.isRunning {
                        // Mark the deadline before termination can win the completion race.
                        deadline.expire()
                        process.terminate()
                    }
                    return await waitTask.value // drain pipes after termination
                }
                let first = await group.next()!
                group.cancelAll()
                return first
            }
        }

        return await waitTask.value
    }

    static func run(command: [String], cwd: String?, env: [String: String]?, timeout: Double?) async -> Response {
        let result = await self.runDetailed(command: command, cwd: cwd, env: env, timeout: timeout)
        let combined = result.stdout.isEmpty ? result.stderr : result.stdout
        let payload = combined.isEmpty ? nil : Data(combined.utf8)
        return Response(ok: result.success, message: result.errorMessage, payload: payload)
    }
}
