import ProteinDomain
import Testing

struct SnapshotRestorationTests {
    @Test func canonicalMotifsRoundTripAfterExpansionAndEnzymes() throws {
        let special = ",GGT(A/T)ACC"
        let custom = String(repeating: "A", count: AvoidMotifs.maximumCustomLength - special.utf16.count) + special
        let motifs = try AvoidMotifs(custom, enzymes: RestrictionEnzyme.allCases)
        #expect(custom.utf16.count == AvoidMotifs.maximumCustomLength)
        #expect(motifs.wireValue.utf16.count > AvoidMotifs.maximumCustomLength)
        #expect(try AvoidMotifs(canonicalWireValue: motifs.wireValue) == motifs)
        #expect(throws: AvoidMotifsError.inputTooLong(limit: 2_000)) { try AvoidMotifs(motifs.wireValue) }
        #expect(try AvoidMotifs(canonicalWireValue: "") == .empty)
    }

    @Test(arguments: [",AC", "AC,", "AC,,TG", "AC,AC", "Ac", " AC", "GGT(A/T)ACC", "AC;TG", "AN"])
    func canonicalMotifsRejectNoncanonicalText(_ wireValue: String) {
        #expect(throws: AvoidMotifsError.self) { try AvoidMotifs(canonicalWireValue: wireValue) }
    }
}
