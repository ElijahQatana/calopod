import CalopodCommands

/// Entry point for the `calopod` command. The command tree lives in `CalopodRoot`.
@main
enum CalopodCLI {
    static func main() async {
        await CalopodRoot.main()
    }
}
