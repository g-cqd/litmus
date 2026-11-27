import Foundation
import Testing

@testable import LitmusCore

#if os(macOS)
    /// The schema runtime against a real control page: a schematised file compiled with `swiftc` into a driver that
    /// stays alive and answers one line per request, while the test switches mutants on the page between requests.
    @Suite(.serialized) struct SharedControlPageTests {
        static let source = """
            func classify(_ x: Int) -> String {
                if x > 0 { return "positive" }
                return x == 0 ? "zero" : "negative"
            }
            enum Cached { static let value = classify(1) }

            """
        static let driver = """
            while readLine() != nil {
                print(classify(5), classify(0), classify(-5), Cached.value)
                unsafe fflush(stdout)
            }

            """

        /// A running driver: `ask()` sends one request and returns its answer.
        final class Driver {
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            var buffer: [UInt8] = []

            init(binary: String, environment: [String: String]) throws {
                process.executableURL = URL(fileURLWithPath: binary)
                process.environment = environment
                process.standardInput = input
                process.standardOutput = output
                try process.run()
            }

            func ask() throws -> String {
                try input.fileHandleForWriting.write(contentsOf: Data("go\n".utf8))
                while !buffer.contains(UInt8(ascii: "\n")) {
                    let chunk = output.fileHandleForReading.availableData
                    guard !chunk.isEmpty else { throw LitmusFailure("driver ended") }
                    buffer += chunk
                }
                let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) ?? buffer.endIndex
                defer { buffer.removeSubrange(...newline) }
                return String(decoding: buffer[..<newline], as: UTF8.self)
            }

            deinit {
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
            }
        }

        private func build(strict: Bool) async throws -> (directory: String, binary: String, sites: [Mutation]) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("litmus-page-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let sites = try MutationPlanner.mutations(
                in: Self.source,
                path: "Classify.swift",
                operators: Set(MutationOperator.allCases)
            )
            let schema = try SchemaWriter.schema(Self.source, mutations: sites, token: "feedf00d")
            try Data(schema.text.utf8).write(to: URL(fileURLWithPath: directory + "/Classify.swift"))
            let driver = strict ? Self.driver : Self.driver.replacingOccurrences(of: "unsafe fflush", with: "fflush")
            try Data(("import Foundation\n" + driver).utf8).write(
                to: URL(fileURLWithPath: directory + "/main.swift")
            )
            let compiler = try await runTool(
                "/usr/bin/xcrun",
                ["swiftc", "-swift-version", "6", "-module-name", "Subject"]
                    + (strict ? ["-strict-memory-safety", "-warnings-as-errors"] : [])
                    + ["Classify.swift", "main.swift", "-o", "driver"],
                directory: directory
            )
            guard compiler.status == 0 else { throw LitmusFailure("swiftc failed:\n\(compiler.output)") }
            return (directory, directory + "/driver", sites)
        }

        @Test(.timeLimit(.minutes(10)), arguments: [false, true])
        func `one process runs mutant after mutant from the page, and counts evaluations`(strict: Bool) async throws {
            let (directory, binary, sites) = try await build(strict: strict)
            defer { try? FileManager.default.removeItem(atPath: directory) }
            #expect(sites.count >= 2)
            let page = try SharedControlPage(
                path: directory + "/page",
                slots: SharedControlLayout.slots(for: sites).sorted { $0.value < $1.value }.map(\.key)
            )
            let driver = try sharedDriver(binary, page: page.path)
            let baseline = try driver.ask()
            #expect(baseline == "positive zero negative positive")
            for site in sites {
                try page.activate(site.id)
                let mutated = try driver.ask()
                #expect(mutated != baseline, "mutant \(site.id) (\(site.operatorID.rawValue)) changed nothing")
                #expect(page.activeHits > 0)
                // Off again: the same process answers as the unmutated subject (Cached.value was fixed at first use).
                try page.activate(nil)
                #expect(try driver.ask() == baseline)
                #expect(page.activeHits == 0)
            }
            // Counting: every switch on the request's path counts its evaluations, the same number on each request.
            page.countsEvaluations = true
            _ = try driver.ask()
            let first = page.evaluations()
            _ = try driver.ask()
            let second = page.evaluations()
            page.countsEvaluations = false
            #expect(first.values.contains { $0 > 0 })
            for (id, count) in first { #expect(second[id] == count * 2, "\(id)") }
            _ = try driver.ask()
            #expect(page.evaluations() == second)
        }

        @Test(.timeLimit(.minutes(10))) func `without a valid page the process keeps LITMUS_ACTIVE_ID`() async throws {
            let (directory, binary, sites) = try await build(strict: false)
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let site = try #require(sites.first)
            let isolated = try Driver(binary: binary, environment: ["LITMUS_ACTIVE_ID_feedf00d": site.id])
            let mutated = try isolated.ask()
            #expect(mutated != "positive zero negative positive")
            // A page without the magic word (a stale or foreign file) is ignored.
            let zeros = directory + "/zeros"
            try Data(count: SharedControlLayout.byteCount).write(to: URL(fileURLWithPath: zeros))
            let foreign = try Driver(
                binary: binary,
                environment: ["LITMUS_ACTIVE_ID_feedf00d": site.id, "LITMUS_SHARED_MAP_feedf00d": zeros]
            )
            #expect(try foreign.ask() == mutated)
        }

        private func sharedDriver(_ binary: String, page: String) throws -> Driver {
            try Driver(binary: binary, environment: ["LITMUS_SHARED_MAP_feedf00d": page])
        }
    }
#endif
