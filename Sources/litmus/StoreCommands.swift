import AnalyzerCLI
import ArgumentParser
import Foundation
import LitmusCore

struct Store: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect, garbage-collect, pack or unpack a Litmus result store.",
        subcommands: [Status.self, GC.self, Pack.self, Unpack.self]
    )

    fileprivate static func execute(_ failureCode: ExitStatus = .badConfiguration, _ body: (String?) throws -> Void)
        throws
    {
        do {
            try body(ProcessInfo.processInfo.environment["LITMUS_STORE_KEY"])
        } catch { try fail(error, code: failureCode) }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show record counts, byte usage and age bounds.")
        @Argument(help: "Result store directory.") var directory: String
        @Flag(help: "Emit JSON instead of human-readable text.") var json = false

        mutating func run() throws {
            try Store.execute { secret in
                let status = try ResultStore.inspect(directory: directory, secret: secret)
                if json {
                    print(String(decoding: try ArtifactCodec.json(status), as: UTF8.self))
                    return
                }
                let mib = ((Double(status.allocatedBytes) / (1024 * 1024)) * 100).rounded() / 100
                print(
                    "store: \(status.directory)\n"
                        + "records: \(status.records) valid, \(status.corruptRecords) corrupt\n"
                        + "size: \(mib) MiB allocated (\(status.logicalBytes) B logical)\n"
                        + "oldest: \(status.oldestModified ?? "n/a")\n"
                        + "newest: \(status.newestModified ?? "n/a")"
                )
            }
        }
    }

    struct GC: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove corrupt records, expired records, and records exceeding a size cap."
        )
        @Argument(help: "Result store directory.") var directory: String
        @Option(help: "Remove records not touched within this many days.") var maxAgeDays: Int?
        @Option(help: "Evict oldest records until allocated bytes fit within this cap (MiB).") var maxSizeMiB: Int?

        mutating func run() throws {
            try Store.execute { secret in
                let out = try ResultStore.garbageCollect(
                    directory: directory,
                    maxAgeDays: maxAgeDays,
                    maxSizeMiB: maxSizeMiB,
                    secret: secret
                )
                stderr(
                    "litmus: store gc removed \(out.removedCorrupt) corrupt, \(out.removedExpired) expired, "
                        + "\(out.removedOverLimit) over-limit record(s); \(out.remaining) remaining"
                )
            }
        }
    }

    struct Pack: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Pack verified store records into a single integrity-checked archive for CI cache upload."
        )
        @Argument(help: "Result store directory.") var directory: String
        @Option(help: "Destination archive file path.") var output: String

        mutating func run() throws {
            try Store.execute(.outputFailure) { secret in
                let count = try ResultStore.pack(directory: directory, outputArchive: output, secret: secret)
                stderr("litmus: packed \(count) verified record(s) to \(output)")
            }
        }
    }

    struct Unpack: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Unpack and verify records from a packed archive into a result store."
        )
        @Argument(help: "Packed store archive file path.") var archive: String
        @Option(help: "Destination result store directory (created if missing).") var into: String
        @Option(help: "Maximum store size in MiB after import.") var maxSizeMiB: Int = 2048

        mutating func run() throws {
            try Store.execute { secret in
                let out = try ResultStore.unpack(
                    archivePath: archive,
                    into: into,
                    limitMiB: maxSizeMiB,
                    secret: secret
                )
                stderr(
                    "litmus: unpacked \(out.imported) record(s) into \(into) (\(out.skippedExisting) already present)"
                )
            }
        }
    }
}
