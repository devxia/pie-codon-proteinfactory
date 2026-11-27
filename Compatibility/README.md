# Cross-platform compatibility fixtures

These fixtures describe behavior shared by the macOS and Windows implementations. The original Swift fixtures remain in the macOS test tree. Fixture changes must be checked against the corresponding Swift source and tests.

- `dna/codon-table.json` lists the standard genetic code in T, C, A, G order at each position. The Windows Domain tests exercise each codon, including the three terminal stops.
- `service/request-ascii.json` is the compact UTF-8 request expected from the input in `request-ascii-input.json`. The input mirrors `ProteinServiceClientTests.requestUsesFixedEndpointSubmittedSequenceAndFinalWireValues`.

Windows intentionally prefixes CSV fields beginning with `=`, `+`, `-`, or `@` after leading whitespace with an apostrophe. The export leaves the stored record name intact. See the standalone Windows CSV fixture under `export/`.

The JSON fixture files end in a repository newline. Comparison with the HTTP request omits that final file newline.
