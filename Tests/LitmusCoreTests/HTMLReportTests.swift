import Foundation
import Testing

@testable import LitmusCore

@Suite struct HTMLReportTests {
    @Test func `the page is self-contained and run data cannot break out of its script element`() async throws {
        var (_, artifact, root) = try await CIScaleTests.run { _ in .survived }
        defer { try? FileManager.default.removeItem(atPath: root) }
        let first = try #require(artifact.results.first)
        let hostile = "</script><script>alert(1)</script> & <b>"
        artifact.results[0] = MutationResult(
            mutation: first.mutation,
            verdict: .survived,
            reason: hostile,
            nanoseconds: 2
        )
        let page = try HTMLReport.render(artifact, root: root, run: "/runs/<1>")
        #expect(page.contains("default-src 'none'"))
        #expect(!page.contains("http://") && !page.contains("https://"))
        #expect(page.components(separatedBy: "</script>").count == 3)
        #expect(!page.contains("<b>"))
        let start = try #require(page.range(of: #"<script type="application/json" id="litmus-data">"#))
        let end = try #require(page.range(of: "</script>", range: start.upperBound..<page.endIndex))
        let data = try JSONSerialization.jsonObject(with: Data(page[start.upperBound..<end.lowerBound].utf8))
        let files = try #require((data as? [String: Any])?["files"] as? [[String: Any]])
        let reasons = files.flatMap { ($0["mutants"] as? [[String: Any]]) ?? [] }.compactMap { $0["reason"] as? String }
        #expect(reasons.contains(hostile))
        #expect(files.allSatisfy { $0["source"] is String })
    }
}
