import Foundation
import Testing

@testable import JMAPKit

/// BearerMail contacts: the shapes the server and the Android app use.
@Suite("Contacts")
struct ContactTests {
    @Test("query and get go out under the mail URN, get by back-reference")
    func encoding() throws {
        var builder = RequestBuilder(maxCalls: 32)
        let query = builder.add(ContactQuery(accountID: AccountID("1")))
        builder.add(
            ContactGet(accountID: AccountID("1"), ids: .reference(query.reference(path: "/ids"))))

        let body = try String(decoding: builder.encoded(), as: UTF8.self)

        #expect(body.contains("urn:plmail:params:jmap:contacts") == false)
        #expect(body.contains(#""sort":"name""#))
        #expect(body.contains(#""limit":500"#))
        #expect(body.contains(#""#ids":{"#))
    }

    @Test("a new contact leaves blank fields out; an update clears them")
    func draftEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let create = try String(
            decoding: encoder.encode(
                ContactDraft(displayName: "Ada", emails: [ContactEmail(email: "a@x.org")])),
            as: UTF8.self)
        #expect(create.contains("company") == false)
        #expect(create.contains("phones") == false)
        #expect(create.contains(#""email":"a@x.org""#))

        var update = ContactDraft(displayName: "Ada")
        update.isUpdate = true
        let patch = try String(decoding: encoder.encode(update), as: UTF8.self)
        #expect(patch.contains(#""company":null"#))
        #expect(patch.contains(#""phones":[]"#))
    }

    @Test("a contact decodes with missing lists, and initials come from the name")
    func decoding() throws {
        let json = Data(#"{"id":"4","displayName":"Grace Brewster Hopper","photoUrl":null}"#.utf8)
        let contact = try JSONDecoder().decode(Contact.self, from: json)

        #expect(contact.emails.isEmpty)
        #expect(contact.initials == "GH")
        #expect(contact.matches("grace hop"))
    }
}
