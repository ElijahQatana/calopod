import CalopodCommands
import CalopodStore
import Foundation
import Observation

@MainActor
@Observable
final class SettingsFileModel {
    private(set) var plan: SettingsImportPlan?
    private(set) var message: String?
    private(set) var failed = false
    /// Called after an import, so the open screens show what changed.
    @ObservationIgnored var onImported: (@MainActor () -> Void)?
    @ObservationIgnored private let state: LocalStateRepository?

    init(state: LocalStateRepository?) {
        self.state = state
    }

    func export(to url: URL) {
        report {
            guard let state else { throw SettingsFileError.unreadable }
            try SettingsFile(repository: state).encoded().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return "Saved \(url.lastPathComponent)."
        }
    }

    func chooseImport(_ url: URL) {
        plan = nil
        report {
            guard let state else { throw SettingsFileError.unreadable }
            let file = try SettingsFile.decode(Data(contentsOf: url))
            plan = try SettingsImporter(repository: state).plan(file)
            return nil
        }
    }

    func applyImport() {
        guard let state, let plan else { return }
        let result = SettingsImporter(repository: state).apply(plan)
        self.plan = nil
        message = result.failed.isEmpty
            ? "Changes made: \(result.applied)."
            : "Changes made: \(result.applied) of \(plan.lines.count). Not made: \(result.failed.joined(separator: "; "))"
        failed = !result.failed.isEmpty
        onImported?()
    }

    func cancelImport() {
        plan = nil
        message = nil
    }

    private func report(_ work: () throws -> String?) {
        do {
            message = try work()
            failed = false
        } catch let error as SettingsFileError {
            message = error.description
            failed = true
        } catch {
            message = "Calopod couldn't read or write that file."
            failed = true
        }
    }
}
