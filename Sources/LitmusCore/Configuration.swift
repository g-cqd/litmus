internal import AemiJSON
internal import AnalyzerConfiguration
internal import Foundation

/// Only syntax planning settings; execution inputs must remain explicit in argv/provenance.
public struct LitmusConfiguration: Decodable, Sendable {
    public var exclude: [String] = []
    /// Only files matching these substrings or globs are mutated (`.litmus.json` or the `litmus` section).
    public var include: [String] = []
    /// Calls to leave alone (`aridCalls` in `.litmus.json`, or `--arid-call` on the CLI): a matching call is neither
    /// removed by `remove-call` nor mutated inside its argument expressions (analytics, telemetry, logging).
    public var aridCalls: [String] = []
    /// Names or `*`-patterns of declarations whose bodies are not mutated (`excludeDeclarations` in `.litmus.json`,
    /// or `--exclude-declaration` on the CLI), such as `*ForTesting` or `*ForPreview`.
    public var excludeDeclarations: [String] = []
    /// The acceptance file of reviewed equivalent mutants (`acceptedFile`), relative to the root; default
    /// `.litmus-accepted.json`.
    public var acceptedFile: String?

    public init(
        exclude: [String] = [],
        include: [String] = [],
        aridCalls: [String] = [],
        excludeDeclarations: [String] = [],
        acceptedFile: String? = nil
    ) {
        self.exclude = exclude
        self.include = include
        self.aridCalls = aridCalls
        self.excludeDeclarations = excludeDeclarations
        self.acceptedFile = acceptedFile
    }

    /// Resolves the family's shared top-level exclusions plus `.litmus.json`; rejects duplicate/unknown keys.
    /// A `litmus` section of `.swift-analyzers.json` is read as well, with the shared keys only.
    public static func load(root: String, explicit: String?) throws -> Self {
        let resolved = try SharedConfiguration.resolve(
            for: SharedConfiguration.Tool(
                name: "litmus",
                fileName: ".litmus.json",
                keys: ["include", "aridCalls", "excludeDeclarations", "acceptedFile"]
            ),
            explicit: explicit,
            currentDirectory: root,
            analyzedPaths: [root]
        )
        // Known shared keys are validated by analyzerkit. This first execution policy does not interpret build defines.
        let value = try ArtifactCodec.decode(SharedValues.self, bytes: resolved.json)
        guard value.defines?.isEmpty ?? true, value.platforms?.isEmpty ?? true,
            value.includeRegions?.isEmpty ?? true, value.excludeRegions?.isEmpty ?? true
        else {
            throw LitmusFailure(
                "this version accepts exclude only; use the actual scheme/destination for build conditions and fixed production-region policy"
            )
        }
        return Self(
            exclude: value.exclude ?? [],
            include: value.include ?? [],
            aridCalls: value.aridCalls ?? [],
            excludeDeclarations: value.excludeDeclarations ?? [],
            acceptedFile: value.acceptedFile
        )
    }
    private struct SharedValues: Decodable {
        let exclude: [String]?
        let include: [String]?
        let aridCalls: [String]?
        let excludeDeclarations: [String]?
        let acceptedFile: String?
        let defines: [String]?
        let platforms: [String]?
        let includeRegions: [String]?
        let excludeRegions: [String]?
    }
}
