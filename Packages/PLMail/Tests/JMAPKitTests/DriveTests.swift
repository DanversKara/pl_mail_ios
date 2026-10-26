import Foundation
import Testing

@testable import JMAPKit

/// BearerMail Drive: the shapes the server and the Android app use.
@Suite("Drive")
struct DriveTests {
    @Test("an upload name survives the query string")
    func nameEncoding() {
        #expect(DriveClient.encode("a b&c=d+e.txt") == "a%20b%26c%3Dd%2Be.txt")
    }

    @Test("a listing decodes, with missing parts left empty")
    func listing() throws {
        let json = Data(
            #"{"folders":[{"id":2,"name":"Taxes","parentId":null}],"files":[{"id":9,"name":"cat.jpg","type":"image/jpeg","size":1200,"folderId":null}],"usedBytes":1200}"#
                .utf8)
        let listing = try JSONDecoder().decode(DriveListing.self, from: json)

        #expect(listing.folders.first?.name == "Taxes")
        #expect(listing.files.first?.isImage == true)
        #expect(listing.breadcrumbs.isEmpty)
        #expect(listing.quotaBytes == nil)
    }

    @Test("a share reads its protected flag")
    func share() throws {
        let json = Data(#"{"id":3,"url":"https://m.example/s/abc","protected":true}"#.utf8)
        let share = try JSONDecoder().decode(DriveShare.self, from: json)

        #expect(share.isProtected)
        #expect(share.downloadCount == 0)
    }
}
