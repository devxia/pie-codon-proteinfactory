import ProteinDomain
import Testing

struct DNAValidationTests {
    @Test func speciesWireValuesAndEnzymeMotifsMatchTheReference() {
        #expect(Species.allCases.map(\.wireValue) == [
            "D2P(default)", "Escherichia_coli", "Chinsese_hamster_ovary(CHO)_cells", "Pichia_pastoris",
            "Saccharomyces_cerevisiae", "Bacillus_subtilis", "Clostridium_acetobutylicum", "Kluyveromyces_lactis", "Pseudomonas_fluorescens",
        ])
        #expect(Species.chineseHamsterOvary.displayName == "Chinese hamster ovary (CHO) cells")
        #expect(Species(rawValue: Species.chineseHamsterOvary.displayName) == nil)
        #expect(StopPolicy.allCases.map(\.rawValue) == ["preserve", "add"])
        let defaults = OptimizationParameters()
        #expect(defaults.species == .defaultD2P)
        #expect(defaults.startPolicy == .none)
        #expect(defaults.stopPolicy == .preserve)
        #expect(defaults.avoid.wireValue.isEmpty)
        #expect(RestrictionEnzyme.allCases.map { [$0.rawValue, $0.motif] } == [
            ["EcoRI", "GAATTC"], ["BamHI", "GGATCC"], ["HindIII", "AAGCTT"], ["BsaI", "GGTCTC"],
            ["BsmBI", "CGTCTC"], ["NotI", "GCGGCCGC"], ["NdeI", "CATATG"], ["XhoI", "CTCGAG"],
        ])
    }

    @Test func motifsAreCanonicalizedWithStableDeduplicationAndExpansion() throws {
        let motifs = try AvoidMotifs("  gg ttacc；GGT(a / t)ACC，GGATCC ; g g a t c c, A A G C T T;;", enzymes: [.bamHI, .ecoRI, .hindIII, .ecoRI])
        #expect(motifs.motifs == ["GGTTACC", "GGTAACC", "GGATCC", "AAGCTT", "GAATTC"])
        #expect(motifs.wireValue == "GGTTACC,GGTAACC,GGATCC,AAGCTT,GAATTC")
        #expect(try AvoidMotifs("GGT(A/T)ACC").motifs == ["GGTAACC", "GGTTACC"])
        #expect(try AvoidMotifs(" ;，\n") == .empty)
        #expect(throws: AvoidMotifsError.invalidMotif(position: 2)) { try AvoidMotifs("AGT;CNN") }
        #expect(throws: AvoidMotifsError.invalidMotif(position: 1)) { try AvoidMotifs("AGGT(A/T)ACC") }
        #expect(throws: AvoidMotifsError.invalidMotif(position: 1)) { try AvoidMotifs("AſT") }
        #expect(throws: AvoidMotifsError.inputTooLong(limit: 2_000)) { try AvoidMotifs(String(repeating: "A", count: 2_001)) }
    }

    @Test func standardGeneticCodeValidatesAllSixtyFourCodons() throws {
        let codonsByResidue = [
            "A": "GCT GCC GCA GCG", "C": "TGT TGC", "D": "GAT GAC", "E": "GAA GAG", "F": "TTT TTC",
            "G": "GGT GGC GGA GGG", "H": "CAT CAC", "I": "ATT ATC ATA", "K": "AAA AAG", "L": "TTA TTG CTT CTC CTA CTG",
            "M": "ATG", "N": "AAT AAC", "P": "CCT CCC CCA CCG", "Q": "CAA CAG", "R": "CGT CGC CGA CGG AGA AGG",
            "S": "TCT TCC TCA TCG AGT AGC", "T": "ACT ACC ACA ACG", "V": "GTT GTC GTA GTG", "W": "TGG", "Y": "TAT TAC",
        ]
        var tested: Set<String> = []
        for (residue, codons) in codonsByResidue {
            let sequence = try ProteinSequence(residue)
            for codon in codons.split(separator: " ").map(String.init) {
                let result = try DNAValidation.verify(codon, against: sequence)
                #expect(result.checks.aminoAcidCount == 1)
                #expect(!result.checks.hasTerminalStop)
                #expect(tested.insert(codon).inserted)
            }
        }
        let sequenceWithStop = try ProteinSequence("A*")
        for stop in ["TAA", "TAG", "TGA"] {
            let result = try DNAValidation.verify("GCT" + stop, against: sequenceWithStop)
            #expect(result.checks.hasTerminalStop)
            #expect(tested.insert(stop).inserted)
        }
        #expect(tested.count == 64)
    }

    @Test func validDNAIsUppercasedWithGCAndAHash() throws {
        let protein = try ProteinSequence("MA*")
        let result = try DNAValidation.verify("atgGcttaa", against: protein, avoiding: try AvoidMotifs("AAAA, CCCC"))
        #expect(result.dna == "ATGGCTTAA")
        #expect(result.sha256 == .hash("ATGGCTTAA"))
        #expect(result.checks.basePairCount == 9)
        #expect(result.checks.aminoAcidCount == 2)
        #expect(result.checks.hasTerminalStop)
        #expect(result.checks.checkedMotifCount == 2)
        #expect(abs(result.checks.gcPercent - 100.0 / 3) < 1e-12)
    }

    @Test func DNARejectsIncorrectLengthTranslationStopsAndAlphabet() throws {
        let protein = try ProteinSequence("MA*")
        #expect(throws: DNAValidationError.emptyDNA) { try DNAValidation.verify("", against: protein) }
        #expect(throws: DNAValidationError.incorrectLength(expected: 9, actual: 3)) { try DNAValidation.verify("ATG", against: protein) }
        #expect(throws: DNAValidationError.invalidBase(position: 4)) { try DNAValidation.verify("ATGNCTTAA", against: protein) }
        #expect(throws: DNAValidationError.invalidBase(position: 4)) { try DNAValidation.verify("ATG U", against: protein) }
        #expect(throws: DNAValidationError.invalidBase(position: 10)) { try DNAValidation.verify("ATGGCTTAA\n", against: protein) }
        #expect(throws: DNAValidationError.translationMismatch(position: 2, expected: "A", actual: "K")) {
            try DNAValidation.verify("ATGAAATAA", against: protein)
        }
        #expect(throws: DNAValidationError.unexpectedStop(position: 2)) { try DNAValidation.verify("ATGTAATAA", against: protein) }
        #expect(throws: DNAValidationError.missingTerminalStop(position: 3)) { try DNAValidation.verify("ATGGCTGCT", against: protein) }
        #expect(throws: DNAValidationError.unexpectedStop(position: 1)) { try DNAValidation.verify("TAA", against: try ProteinSequence("A")) }
    }

    @Test func startCodonPoliciesValidateExistingDNAPrefixes() throws {
        let alanine = try ProteinSequence("A*")
        let methionine = try ProteinSequence("M*")
        #expect(StartCodonPolicy.allCases.map(\.rawValue) == ["none", "always", "ifNotMethionine"])
        #expect(!StartCodonPolicy.none.prependsATG(to: alanine))
        #expect(StartCodonPolicy.always.prependsATG(to: methionine))
        #expect(!StartCodonPolicy.ifNotMethionine.prependsATG(to: methionine))
        #expect(StartCodonPolicy.ifNotMethionine.prependsATG(to: alanine))

        for policy in [StartCodonPolicy.always, .ifNotMethionine] {
            let verified = try DNAValidation.verify("atgGCTTAA", against: alanine, startPolicy: policy)
            #expect(verified.dna == "ATGGCTTAA")
            #expect(verified.checks.basePairCount == 9)
            #expect(verified.checks.aminoAcidCount == 1)
            #expect(alanine.value == "A*")
        }
        #expect(try DNAValidation.verify("ATGTAA", against: methionine, startPolicy: .ifNotMethionine).dna == "ATGTAA")
        #expect(try DNAValidation.verify("ATGATGTAA", against: methionine, startPolicy: .always).checks.basePairCount == 9)
        #expect(throws: DNAValidationError.incorrectLength(expected: 9, actual: 6)) {
            try DNAValidation.verify("ATGTAA", against: alanine, startPolicy: .always)
        }
        #expect(throws: DNAValidationError.translationMismatch(position: 0, expected: "M", actual: "A")) {
            try DNAValidation.verify("GCTGCTTAA", against: alanine, startPolicy: .always)
        }

        let rows = try DNAValidation.compareCodons("atgGCTTAA", with: alanine, startPolicy: .always)
        #expect(rows.map(\.position) == [0, 1, 2])
        #expect(rows.map(\.isPrependedStart) == [true, false, false])
        #expect(rows[0].codon == "atg")
        #expect(rows[0].expected == "M")
        #expect(rows[0].translated == "M")
    }

    @Test func readOnlyCodonComparisonShowsMatchesMismatchesAndInvalidCodons() throws {
        let protein = try ProteinSequence("MAW*")
        let rows = try DNAValidation.compareCodons("atgAAANGGTAA", with: protein)
        #expect(rows.map(\.position) == [1, 2, 3, 4])
        #expect(rows.map(\.expected) == ["M", "A", "W", "*"])
        #expect(rows.map(\.codon) == ["atg", "AAA", "NGG", "TAA"])
        #expect(rows.map(\.translated) == ["M", "K", nil, "*"])
        #expect(throws: DNAValidationError.incorrectLength(expected: 12, actual: 3)) {
            try DNAValidation.compareCodons("ATG", with: protein)
        }
    }

    @Test func motifDetectionChecksBothStrandsAndAcrossCodons() throws {
        let protein = try ProteinSequence("MA*")
        #expect(throws: DNAValidationError.forbiddenMotif("TGGC", orientation: .forward)) {
            try DNAValidation.verify("ATGGCTTAA", against: protein, avoiding: try AvoidMotifs("TGGC"))
        }
        #expect(throws: DNAValidationError.forbiddenMotif("GCCA", orientation: .reverseComplement)) {
            try DNAValidation.verify("ATGGCTTAA", against: protein, avoiding: try AvoidMotifs("GCCA"))
        }
        #expect(throws: DNAValidationError.forbiddenMotif("AATT", orientation: .forward)) {
            try DNAValidation.verify("CAATTG", against: try ProteinSequence("QL"), avoiding: try AvoidMotifs("AATT"))
        }
    }
}
