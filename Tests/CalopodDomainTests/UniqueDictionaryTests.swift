import Testing

@testable import CalopodDomain

@Suite("Unique dictionary")
struct UniqueDictionaryTests {
    @Test("Distinct keys build a dictionary")
    func distinctKeys() {
        let result = Dictionary(uniquelyKeyed: [("a", 1), ("b", 2)])
        #expect(result == ["a": 1, "b": 2])
    }

    @Test("A repeated key is reported instead of trapping", arguments: [
        [("a", 1), ("a", 1)],
        [("a", 1), ("b", 2), ("a", 3)],
    ])
    func repeatedKey(pairs: [(String, Int)]) {
        #expect(Dictionary(uniquelyKeyed: pairs) == nil)
    }

    @Test("No pairs build an empty dictionary")
    func empty() {
        #expect(Dictionary<String, Int>(uniquelyKeyed: []) == [:])
    }
}
