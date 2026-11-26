import AnalyzerCLI
import ArgumentParser
import Foundation
import LitmusCore
import ReportSupport

@main struct Litmus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Evidence-led mutation testing for Swift packages and Xcode projects.",
        version: LitmusVersion.current,
        subcommands: [
            Plan.self, Run.self, Analyze.self, Census.self, Restore.self, Merge.self, Check.self, Accept.self,
            Unaccept.self,
        ]
    )
}
