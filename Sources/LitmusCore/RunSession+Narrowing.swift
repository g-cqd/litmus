internal import Foundation
internal import ProjectModel
internal import SourceCorpus

extension RunSession {
    /// Under `xcodebuild`, narrows the scheme and test plan of the workspace copy to the test targets that can run the
    /// mutants, when the package and project graph names them for every mutant (or `--test-target` does): Xcode then
    /// builds those bundles and what they depend on, not the whole plan. A mutant in a file no test target is known to
    /// cover, an in-place workspace, or a scheme Litmus cannot edit safely keeps the whole build.
    func narrowXcodeBuild() {
        guard driver.usesXcode, prepared.restore == nil, !toRun.isEmpty, !driver.xcodebuildArgumentsSelectTests,
            let container = driver.container, let scheme = driver.scheme
        else { return }
        var targets: Set<String> = []
        if !options.testTargets.isEmpty {
            targets = Set(options.testTargets)
        } else {
            guard options.selectTestTargets, let layout = ProjectLayout.discover(paths: [snapshot.root]) else { return }
            let classification = ProjectClassification.load(layout)
            for path in Set(toRun.map(\.path)) {
                let covering = classification.testTargets(covering: SourcePath.canonical(snapshot.root + "/" + path))
                guard !covering.isEmpty else { return }
                targets.formUnion(covering.map(\.name))
            }
        }
        switch XcodeBuildNarrowing.narrow(
            workspace: snapshot.root,
            container: container,
            scheme: scheme,
            testPlan: driver.testPlan,
            keep: targets
        ) {
        case .success(let kept):
            artifact.notes.append(
                "the build is narrowed to the test targets that can run the mutants: " + kept.joined(separator: ", ")
            )
        case .failure(let reason):
            artifact.notes.append("the build is not narrowed: \(reason)")
        }
    }
}
