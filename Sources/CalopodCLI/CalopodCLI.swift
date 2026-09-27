import CalopodCommands

/// Executable entry point for the `calopod` command. Kept to a single
/// delegating line so the actual command tree (`CalopodRoot` and its
/// subcommands) stays testable independent of process entry.
@main
enum CalopodCLI {
    static func main() async {
        await CalopodRoot.main()
    }
}
