import XCTest
@testable import MinutesCore

final class RenderTests: XCTestCase {
    let tz = TimeZone(identifier: "America/New_York")!

    func sample() -> Meeting {
        var m = Meeting(title: "Harbor Tools <add-on> & \"diligence\"", titleIsAuto: false,
                        createdAt: Date(timeIntervalSince1970: 1_791_829_200))   // 2026-10-12 18:20 UTC
        m.duration = 2531
        m.utterances = [
            Utterance(id: 0, speaker: "S2", start: 1.2, end: 9, text: "Thanks everyone. <b>Bold</b> & \"quotes\" stay literal."),
            Utterance(id: 1, speaker: "S1", start: 9.4, end: 21, text: "The top ten are forty one percent.", overlapWith: ["S2"], overlapShare: 0.5),
            Utterance(id: 2, speaker: "S7", start: 3700, end: 3705, text: "Late remark."),
        ]
        m.speakerNames = ["S2": "Greg"]
        m.autoNamed = ["S2"]
        m.gaps = [RecordingGap(at: 30, duration: 125, reason: "a phone call took the microphone")]
        m.notes = MeetingNotes(
            title: "t", summary: "We reviewed diligence.", keyPoints: ["Concentration is 41%"], decisions: ["Hold at 6.5x"],
            actionItems: ["Dana: schedule calls (due Oct 20)"], openQuestions: [], figures: ["6.5x"],
            skippedSections: 1, totalSections: 4)
        return m
    }

    func testClockAndSpan() {
        XCTAssertEqual(Render.clock(0), "0:00")
        XCTAssertEqual(Render.clock(75.9), "1:15")
        XCTAssertEqual(Render.clock(3700), "1:01:40")
        XCTAssertEqual(Render.clock(-5), "0:00")
        XCTAssertEqual(Render.span(40), "40 sec")
        XCTAssertEqual(Render.span(2531), "42 min")
        XCTAssertEqual(Render.span(3600), "1 hr")
        XCTAssertEqual(Render.span(3900), "1 hr 5 min")
    }

    func testDatesUseTheGivenTimeZone() {
        let m = sample()
        XCTAssertEqual(Render.metaLine(m, timeZone: tz), "Oct 12, 2026 at 2:20 PM, 42 min")
        XCTAssertEqual(Render.defaultTitle(for: m.createdAt, timeZone: tz), "Meeting, Oct 12 at 2:20 PM")
    }

    func testSpeakerNumberingFollowsFirstAppearance() {
        let m = sample()
        XCTAssertEqual(m.speakerLabels, ["S2", "S1", "S7"])
        XCTAssertEqual(m.displayName(for: "S2"), "Greg")
        XCTAssertEqual(m.displayName(for: "S1"), "Speaker 2")
        XCTAssertEqual(m.displayName(for: "S7"), "Speaker 3")
        XCTAssertEqual(Render.speakersLine(m), "Greg, Speaker 2, Speaker 3")
    }

    func testTranscriptTextShowsCrosstalkAndGaps() {
        let text = Render.transcriptText(sample())
        XCTAssertTrue(text.hasPrefix("Greg [0:01]\nThanks everyone."))
        XCTAssertTrue(text.contains("Speaker 2 [0:09] (talking over Greg)\nThe top ten are forty one percent."))
        XCTAssertTrue(text.contains("[Recording paused for 2 min: a phone call took the microphone]\n\nSpeaker 3 [1:01:40]"))
    }

    func testNotesText() {
        let text = Render.notesText(sample())
        XCTAssertTrue(text.hasPrefix("SUMMARY\nWe reviewed diligence.\n\nKEY POINTS\n- Concentration is 41%\n\nDECISIONS\n- Hold at 6.5x\n\nACTION ITEMS\n- Dana: schedule calls (due Oct 20)\n\nFIGURES AND DATES\n- 6.5x"))
        XCTAssertFalse(text.contains("OPEN QUESTIONS"))
        XCTAssertTrue(text.hasSuffix("1 of 4 parts of the transcript could not be summarized and are missing from these notes."))
    }

    func testHTMLIsEscapedEverywhere() {
        let html = Render.emailHTML(sample(), timeZone: tz)
        XCTAssertTrue(html.contains("<h1 style=\"font-size:22px;line-height:1.25;margin:0 0 4px\">Harbor Tools &lt;add-on&gt; &amp; &quot;diligence&quot;</h1>"))
        XCTAssertTrue(html.contains("&lt;b&gt;Bold&lt;/b&gt; &amp; &quot;quotes&quot; stay literal."))
        XCTAssertFalse(html.contains("<b>Bold</b>"))
        XCTAssertTrue(html.contains("names recognized by voice"))
        XCTAssertTrue(html.contains("talking over Greg"))
        XCTAssertTrue(html.contains("Recording paused for 2 min"))
        XCTAssertLessThan(html.range(of: "Key points")!.lowerBound, html.range(of: ">Transcript<")!.lowerBound)
    }

    func testEmailAssembly() {
        let m = sample()
        let e = Render.email(for: m, from: "me@gmail.com", to: ["me@gmail.com"], timeZone: tz, now: Date(timeIntervalSince1970: 1_791_830_000))
        XCTAssertEqual(e.subject, "Meeting notes: Harbor Tools <add-on> & \"diligence\" (Oct 12, 2026)")
        XCTAssertEqual(e.attachments.map { $0.filename }, [
            "Harbor Tools add-on & diligence 2026-10-12 - Notes.txt",
            "Harbor Tools add-on & diligence 2026-10-12 - Transcript.txt",
        ])
        let transcript = String(decoding: e.attachments[1].data, as: UTF8.self)
        XCTAssertTrue(transcript.contains("Speakers: Greg, Speaker 2, Speaker 3 (names recognized by voice; check them)"))
        XCTAssertTrue(transcript.contains("Late remark."))
        XCTAssertTrue(e.text.contains("TRANSCRIPT"))
        XCTAssertEqual(e.messageID, "\(m.id).1.1791830000")
        XCTAssertEqual(e.fromName, "Minutes")
    }

    func testFileSafe() {
        XCTAssertEqual(Render.fileSafe("a/b\\c:d*e?f\"g<h>i|j\nk"), "a b c d e f g h i j k")
        XCTAssertEqual(Render.fileSafe("   "), "Meeting")
        XCTAssertEqual(Render.fileSafe(String(repeating: "x", count: 200)).count, 80)
    }

    func testModelLinesHaveNoTimestamps() {
        XCTAssertEqual(Render.modelLines(sample())[1], "Speaker 2: The top ten are forty one percent.")
    }

    func testInvitedLineComesFromTheCalendarMeeting() {
        var m = sample()
        XCTAssertNil(Render.invitedLine(m))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        m.calendarEvent = CalendarEvent(
            id: "e1", title: "Florac intro", start: start, end: start + 1800,
            people: [Person(name: "Dov Herzberg", email: "dov@florac.com"), Person(name: "Lee Park"), Person(name: "x@y.com", email: "x@y.com")])
        XCTAssertEqual(Render.invitedLine(m), "Invited: Dov Herzberg <dov@florac.com>, Lee Park, x@y.com")
        XCTAssertTrue(Render.headerText(m).contains("\nInvited: Dov Herzberg <dov@florac.com>, Lee Park, x@y.com\n"))
        XCTAssertTrue(Render.emailHTML(m).contains("Invited: Dov Herzberg &lt;dov@florac.com&gt;"))
        let data = try! JSONEncoder().encode(m)
        XCTAssertEqual(try! JSONDecoder().decode(Meeting.self, from: data).calendarEvent, m.calendarEvent)
    }

    func testCurrentCalendarMeetingsAreTheOnesOnNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func event(_ id: String, _ startMinutes: Double, _ lengthMinutes: Double) -> CalendarEvent {
            CalendarEvent(id: id, title: id, start: now + startMinutes * 60, end: now + (startMinutes + lengthMinutes) * 60, people: [])
        }
        let events = [
            event("yesterday", -24 * 60, 60),
            event("ended 30 min ago", -90, 60),
            event("ran long", -70, 60),      // ended 10 min ago: still the one being recorded
            event("on now", -20, 60),
            event("in 10 min", 10, 30),
            event("in an hour", 60, 30),
        ]
        XCTAssertEqual(CalendarEvent.current(events, at: now).map(\.id), ["in 10 min", "on now", "ran long"])
        XCTAssertEqual(CalendarEvent.current([], at: now), [])
    }
}
