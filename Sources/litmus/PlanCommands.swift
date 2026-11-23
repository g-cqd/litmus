import AnalyzerCLI
import ArgumentParser
import Foundation
import LitmusCore
import ReportSupport

struct Plan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Discover syntax mutation candidates without building or executing project code."
    )
    @OptionGroup var subject: SubjectOptions
    @OptionGroup var change: ChangeOptions
    @Option(help: "Package directory relative to root; limit mutation discovery to this package.") var packagePath:
        String?
    @Option(help: "Output plan (.json or .pb); stdout JSON when omitted.") var output: String?
    @Option(help: "Bounded source-discovery parallelism, 1...16.") var jobs: Int = 4
    mutating func run() async throws {
        guard (1...16).contains(jobs) else { throw ValidationError("jobs must be 1...16") }
        let excludes = try subject.excludes()
        let plan: MutationPlan
        do {
            let driver = try BuildDriver(
                root: subject.absoluteRoot,
                packagePath: packagePath,
                scheme: nil,
                destination: nil
            )
            try driver.validatePackage(workspace: subject.absoluteRoot)
            plan = try await MutationPlanner.plan(
                root: subject.absoluteRoot,
                exclude: excludes,
                include: try subject.includes(),
                packagePath: packagePath,
                jobs: jobs,
                scope: try await change.scope(root: subject.absoluteRoot)
            )
        } catch let error as ValidationError {
            throw error
        } catch {
            try fail(error, code: .usage)
        }
        do {
            if let output {
                try ArtifactCodec.write(plan, path: output)
            } else {
                print(String(decoding: try ArtifactCodec.json(plan), as: UTF8.self))
            }
        } catch { try fail(error, code: .outputFailure) }
        stderr(
            "litmus: \(plan.mutations.count) candidates, \(plan.suppressed.count) suppressed in \(plan.analyzedFiles) files; plan is not test evidence"
        )
        if plan.notes.contains(where: \.isDegraded) { throw ExitCode(ExitStatus.internalFailure.rawValue) }
    }
}

struct Census: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Count where candidate operators would apply (syntax only; sizes operators before they exist)."
    )
    @OptionGroup var subject: SubjectOptions
    @Option(help: "json or text.") var format: String = "text"
    mutating func run() async throws {
        guard ["json", "text"].contains(format) else { throw ValidationError("format must be json or text") }
        let report: CensusReport
        do { report = try await MutationCensus.run(root: subject.absoluteRoot, exclude: try subject.excludes()) } catch
        {
            try fail(error, code: .usage)
        }
        if format == "json" {
            print(String(decoding: try ArtifactCodec.json(report), as: UTF8.self))
            return
        }
        print(
            "production files \(report.files), excluded \(report.excludedFiles), degraded \(report.degradedFiles.count)"
        )
        for entry in report.entries {
            print(
                "\(entry.operatorID)\t\(entry.shape.rawValue)\tsites \(entry.sites)\tmutants \(entry.mutants)\tblocked \(entry.blocked)"
            )
        }
    }
}
