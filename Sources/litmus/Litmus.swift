import ArgumentParser

@main struct Litmus: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Mutation testing for Swift packages and Xcode projects.", version: "0.1.0-dev")
}
