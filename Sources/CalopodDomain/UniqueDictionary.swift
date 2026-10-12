extension Dictionary {
    /// Builds a dictionary from pairs, or returns nil when two pairs share a
    /// key. Use it for stored data where a duplicate means ambiguity.
    public init?(uniquelyKeyed pairs: some Sequence<(Key, Value)>) {
        var result: [Key: Value] = [:]
        for (key, value) in pairs {
            guard result.updateValue(value, forKey: key) == nil else { return nil }
        }
        self = result
    }
}
