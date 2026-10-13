import XCTest
@testable import MinutesCore

final class VocabularyTests: XCTestCase {

    func testBuiltInTermsFixCommonMishearings() {
        let v = Vocabulary()
        XCTAssertEqual(v.correct("at 400 in EVITA is 4.8"), "at 400 in EBITDA is 4.8")
        XCTAssertEqual(v.correct("finding a new PRP system"), "finding a new ERP system")
        XCTAssertEqual(v.correct("a Unitronch group"), "a unitranche group")
        XCTAssertEqual(v.correct("they submitted an loai"), "they submitted an LOI")
    }

    func testPersonalTermsMatchWholeWordsOnly() {
        let v = Vocabulary(terms: [
            VocabularyTerm(term: "Meridyan", heardAs: ["Meridian", "Meridien"]),
            VocabularyTerm(term: "Estée Lauder", heardAs: ["essay law", "estimate lauder", "S.A. Lauder"]),
        ])
        XCTAssertEqual(v.correct("Meridian is very pro cobot welders"), "Meridyan is very pro cobot welders")
        XCTAssertEqual(v.correct("from Meridian's end of things"), "from Meridyan's end of things")
        XCTAssertEqual(v.correct("does essay law say here are five"), "does Estée Lauder say here are five")
        XCTAssertEqual(v.correct("a vendor to estimate   lauder."), "a vendor to Estée Lauder.")
        XCTAssertEqual(v.correct("S.A. Lauder"), "Estée Lauder")
        // Not inside other words, and ordinary words are untouched.
        XCTAssertEqual(v.correct("Meridiann policy"), "Meridiann policy")
        XCTAssertEqual(v.correct("an essay lawyer"), "an essay lawyer")
        XCTAssertEqual(v.correct("similar sim cards"), "similar sim cards")
    }

    func testCorrectionIgnoresCaseAndKeepsTheRestOfTheLine() {
        let v = Vocabulary(terms: [VocabularyTerm(term: "Kestrel", heardAs: ["kestral", "castrol"])])
        XCTAssertEqual(v.correct("The CASTROL deal, kestral's LOI"), "The Kestrel deal, Kestrel's LOI")
        XCTAssertFalse(VocabularyCorrector(v).wouldChange("nothing to fix"))
        XCTAssertTrue(VocabularyCorrector(v).wouldChange("castrol"))
    }

    func testEmptyAndSelfReferentialVariantsAreIgnored() {
        let v = Vocabulary(terms: [
            VocabularyTerm(term: "Alder Paper", heardAs: ["", "  ", "alder paper"]),
            VocabularyTerm(term: "  ", heardAs: ["anything"]),
        ])
        XCTAssertEqual(v.correct("anything about alder paper"), "anything about alder paper")
        XCTAssertEqual(v.spellings, ["Alder Paper"])
    }

    func testSpellingsListPersonalTermsOnceWithoutBuiltIns() {
        let v = Vocabulary(terms: [
            VocabularyTerm(term: "Meridyan"), VocabularyTerm(term: "meridyan"), VocabularyTerm(term: "Mark Keller"),
        ])
        XCTAssertEqual(v.spellings, ["Meridyan", "Mark Keller"])
        XCTAssertEqual(NotesEngine.spellingNote(v.spellings), "Spell these exactly as written: Meridyan, Mark Keller.")
        XCTAssertEqual(NotesEngine.spellingNote([]), "")
    }

    func testVocabularyRoundTripsThroughJSON() throws {
        let v = Vocabulary(terms: [VocabularyTerm(term: "Meridyan", heardAs: ["Meridian"])])
        let data = try JSONEncoder().encode(v)
        XCTAssertEqual(try JSONDecoder().decode(Vocabulary.self, from: data), v)
    }
}
