import ArgumentParser
import Foundation
import MuesliCore

struct ModelTermsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "model-terms",
        abstract: "Read model terms and optionally record acceptance on this Mac.")
    @Argument(help: "Model whose terms to display: medasr.") var model: String
    @Flag(name: .long, help: "Accept the displayed MedASR terms and use restrictions for this Mac user.")
    var accept = false

    mutating func validate() throws {
        guard model == "medasr" else { throw ValidationError("Terms are available for medasr.") }
    }

    func run() throws {
        try perform(license: .shared)
    }

    func perform(license: MedASRLicense, output: (String) -> Void = {
        FileHandle.standardOutput.write(Data($0.utf8))
    }) throws {
        let text = try MedASRLicense.agreementText()
        if accept { try license.accept() }
        output(text + (accept ? "\nMedASR terms accepted.\n" : "\nTo accept: muesli-cli model-terms medasr --accept\n"))
    }
}
