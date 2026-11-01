import Testing
@testable import SlimeCore

@Test func groundedAnswersRejectInventedSourcesAndUnsupportedCertainty() throws {
    let note = KnowledgeNote(scope: "personal", title: "Preference", body: "Prefer Cantonese replies.")
    let valid = "{\"answer\":\"Cantonese\",\"citations\":[\"\(note.id)\"],\"uncertain\":false}"
    #expect(try KnowledgeAnswer.decode(valid, notes: [note]).citations == [note.id])
    #expect(throws: (any Error).self) { try KnowledgeAnswer.decode(valid, notes: []) }
    #expect(throws: (any Error).self) { try KnowledgeAnswer.decode("{\"answer\":\"English\",\"citations\":[],\"uncertain\":false}", notes: [note]) }
    #expect(try KnowledgeAnswer.decode("{\"answer\":\"No supporting evidence\",\"citations\":[],\"uncertain\":true}", notes: []).uncertain)
}
