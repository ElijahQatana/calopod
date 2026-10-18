import CalopodStore

/// The shared local state database, for callers outside the command layer such as the Mac app.
public enum LocalState {
    public static func repository() throws -> LocalStateRepository { try CommandEnvironment.repository() }
}
