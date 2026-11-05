import Testing
@testable import MochletCore

@Suite struct DiffEngineTests {
    @Test func identicalIsEmpty() {
        let d = DiffEngine.diff(path: "a.swift", old: "a\nb\n", new: "a\nb\n")
        #expect(d.hunks.isEmpty && d.added == 0 && d.removed == 0)
    }

    @Test func singleLineChangeWithContext() {
        let old = (1...10).map(String.init).joined(separator: "\n")
        let new = (1...10).map { $0 == 5 ? "five" : String($0) }.joined(separator: "\n")
        let d = DiffEngine.diff(path: "n.txt", old: old, new: new)
        #expect(d.added == 1 && d.removed == 1)
        #expect(d.hunks.count == 1)
        let h = d.hunks[0]
        #expect(h.oldStart == 2 && h.newStart == 2)
        #expect(h.lines.map(\.kind) == [.context, .context, .context, .removed, .added, .context, .context, .context])
        #expect(h.header == "@@ -2,7 +2,7 @@")
    }

    @Test func twoDistantChangesMakeTwoHunks() {
        let old = (1...40).map(String.init).joined(separator: "\n")
        var ls = (1...40).map(String.init)
        ls[2] = "x"; ls[30] = "y"
        let d = DiffEngine.diff(path: "n.txt", old: old, new: ls.joined(separator: "\n"))
        #expect(d.hunks.count == 2)
        #expect(d.added == 2 && d.removed == 2)
    }

    @Test func insertionsAndDeletions() {
        let d = DiffEngine.diff(path: "n.txt", old: "a\nb\nc\n", new: "a\nb\nb2\nc\nd\n")
        #expect(d.added == 2 && d.removed == 0)
        let d2 = DiffEngine.diff(path: "n.txt", old: "a\nb\nc\nd\n", new: "a\nd\n")
        #expect(d2.added == 0 && d2.removed == 2)
    }

    @Test func myersMatchesCountsOnRandomInputs() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<30 {
            let a = (0..<Int.random(in: 0...25, using: &rng)).map { _ in String(Int.random(in: 0...4, using: &rng)) }
            let b = (0..<Int.random(in: 0...25, using: &rng)).map { _ in String(Int.random(in: 0...4, using: &rng)) }
            let ops = DiffEngine.myers(a, b)
            // Replaying the ops must reproduce both sides exactly.
            let oldSide = ops.filter { $0.kind != .added }.map(\.text)
            let newSide = ops.filter { $0.kind != .removed }.map(\.text)
            #expect(oldSide == a)
            #expect(newSide == b)
        }
    }

    @Test func hugeInputsFallBackToCounts() {
        let old = (1...3000).map(String.init).joined(separator: "\n")
        let new = (1...3000).map { $0 % 2 == 0 ? "e\($0)" : String($0) }.joined(separator: "\n")
        let d = DiffEngine.diff(path: "big.txt", old: old, new: new)
        #expect(d.countsOnly)
        #expect(d.added == 1500 && d.removed == 1500)
        #expect(d.hunks.isEmpty)
    }

    @Test func newFileIsAllAdded() {
        let d = DiffEngine.fromNew(path: "x.md", content: "one\ntwo\n")
        #expect(d.isNewFile && d.added == 2 && d.removed == 0 && d.hunks.count == 1)
    }

    @Test func applyPatchParsesFiles() {
        let patch = """
        *** Begin Patch
        *** Update File: src/a.py
        @@ def f():
        -    return 1
        +    return 2
        *** Add File: src/b.py
        +print("hi")
        *** Delete File: src/c.py
        *** End Patch
        """
        let ds = DiffEngine.fromApplyPatch(patch)
        #expect(ds.map(\.path) == ["src/a.py", "src/b.py", "src/c.py"])
        #expect(ds[0].added == 1 && ds[0].removed == 1)
        #expect(ds[1].isNewFile && ds[1].added == 1)
    }
}
