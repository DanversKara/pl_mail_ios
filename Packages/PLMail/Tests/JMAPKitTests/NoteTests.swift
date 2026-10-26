import Foundation
import Testing

@testable import JMAPKit

/// BearerMail notes: the bytes that go out and the notes that come back, in the
/// shapes the server and the Android app use.
@Suite("Notes")
struct NoteTests {
    @Test("neither method sends an accountId, and both declare the notes URN")
    func noAccountID() throws {
        var builder = RequestBuilder(maxCalls: 32)
        builder.add(NoteGet())
        builder.add(NoteSet(update: ["1": NotePatch(pinned: true)]))

        let body = try String(decoding: builder.encoded(), as: UTF8.self)

        #expect(body.contains("accountId") == false)
        #expect(body.contains("urn:plmail:params:jmap:notes"))
        #expect(body.contains(#"["Note/get",{"ids":null},"c0"]"#))
    }

    @Test("a patch sends only what it names, and clearing colour sends null")
    func patchEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let clear = try String(
            decoding: encoder.encode(NotePatch(color: .some(nil), trashed: true)), as: UTF8.self)
        #expect(clear == #"{"color":null,"trashed":true}"#)

        let title = try String(decoding: encoder.encode(NotePatch(title: "Shop")), as: UTF8.self)
        #expect(title == #"{"title":"Shop"}"#)
    }

    @Test("a draft leaves out labels when there are none")
    func draftEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let body = try String(
            decoding: encoder.encode(NoteDraft(title: "A", items: [NoteItem(text: "milk")])),
            as: UTF8.self)

        #expect(body.contains("labels") == false)
        #expect(body.contains(#""color":null"#))
        #expect(body.contains(#""items":[{"done":false,"text":"milk"}]"#))
    }

    @Test("a note missing newer properties still decodes")
    func lenientDecoding() throws {
        let json = Data(
            #"{"state":"abc","list":[{"id":"7","title":"Hi","pinned":true}],"notFound":[]}"#.utf8)
        let result = try JSONDecoder().decode(NoteGet.Result.self, from: json)

        #expect(result.list.count == 1)
        #expect(result.list[0].pinned)
        #expect(result.list[0].labels.isEmpty)
        #expect(result.list[0].media.isEmpty)
    }
}
