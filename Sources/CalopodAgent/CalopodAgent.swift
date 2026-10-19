import CalopodRuntime
import Darwin
import Dispatch
import Foundation

@main
struct CalopodAgent {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.isEmpty || arguments == ["--once"] else {
            writeError("Usage: calopod-agent [--once]\n")
            exit(64)
        }
        do {
            let environment = try CalopodRuntimeEnvironment()
            if ProcessInfo.processInfo.environment[AgentLogFiles.switchName] == "1" {
                try? AgentLogFiles.redirectOutput(for: environment.stateLocation)
            }
            let runner = CalopodAgentRunner(
                environment: environment,
                schedule: try AgentSchedule(
                    environment: ProcessInfo.processInfo.environment,
                    fillingDefaults: true
                )
            )
            if arguments == ["--once"] {
                let report = await runner.runOnce()
                write(report)
                switch report.status {
                case "ok": exit(0)
                case "busy": exit(75)
                default: exit(1)
                }
            }

            let signals = TerminationSignals()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await runner.runUntilCancelled(report: write)
                }
                group.addTask {
                    await signals.wait()
                }
                await group.next()
                group.cancelAll()
            }
        } catch {
            write(
                AgentRunReport(
                    status: "failed",
                    failureCategory: syncFailureCategory(error)
                )
            )
            // Startup errors here are configuration problems that a restart
            // cannot fix. Stay idle so launchd does not loop on them; a
            // schedule or install change restarts the service.
            if arguments.isEmpty {
                await TerminationSignals().wait()
                exit(0)
            }
            exit(1)
        }
    }

    private static func write(_ report: AgentRunReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private final class TerminationSignals: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private var sources: [DispatchSourceSignal] = []

    init() {
        var continuation: AsyncStream<Void>.Continuation?
        stream = AsyncStream { continuation = $0 }
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global(qos: .utility)
            )
            source.setEventHandler {
                continuation?.yield(())
                continuation?.finish()
            }
            source.resume()
            sources.append(source)
        }
    }

    func wait() async {
        for await _ in stream { return }
    }

    deinit {
        sources.forEach { $0.cancel() }
    }
}
