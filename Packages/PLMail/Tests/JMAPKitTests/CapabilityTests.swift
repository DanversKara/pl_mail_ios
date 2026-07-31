import Testing

@testable import JMAPKit

@Suite("Capability")
struct CapabilityTests {
    @Test("URNs match the wire form exactly")
    func urns() {
        #expect(Capability.core.rawValue == "urn:ietf:params:jmap:core")
        #expect(Capability.mail.rawValue == "urn:ietf:params:jmap:mail")
        #expect(Capability.submission.rawValue == "urn:ietf:params:jmap:submission")
        #expect(Capability.push.rawValue == "urn:plmail:params:jmap:push")
    }

    /// The server advertises `push` in its Session but rejects it in `using`
    /// with a 400. Nothing about the URN itself says so, so it is pinned here.
    @Test("the push extension is advertised but never declarable in `using`")
    func pushIsNotDeclarable() {
        #expect(Capability.push.isSupportedInUsing == false)
        #expect(Capability.core.isSupportedInUsing)
        #expect(Capability.mail.isSupportedInUsing)
        #expect(Capability.submission.isSupportedInUsing)
    }
}
