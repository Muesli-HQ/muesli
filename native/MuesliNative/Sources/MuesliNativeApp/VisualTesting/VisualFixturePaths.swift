import Foundation

/// The runner owns every mutable visual-test path. Keeping this contract in the
/// app module means a future UI-test host and the SwiftPM snapshot suite reject
/// the same unsafe launch before constructing app services.
struct VisualFixturePaths: Equatable {
    static let fixtureDirectoryKey = "MUESLI_VISUAL_FIXTURE_DIR"
    static let dataDirectoryKey = "MUESLI_VISUAL_DATA_DIR"
    static let artifactDirectoryKey = "MUESLI_VISUAL_ARTIFACT_DIR"

    let fixtureDirectory: URL
    let dataDirectory: URL
    let artifactDirectory: URL

    init(environment: [String: String]) throws {
        fixtureDirectory = try Self.directory(
            named: Self.fixtureDirectoryKey,
            environment: environment,
            mustExist: true
        )
        dataDirectory = try Self.directory(
            named: Self.dataDirectoryKey,
            environment: environment,
            mustExist: true
        )
        artifactDirectory = try Self.directory(
            named: Self.artifactDirectoryKey,
            environment: environment,
            mustExist: true
        )

        let paths = [fixtureDirectory.path, dataDirectory.path, artifactDirectory.path]
        guard Set(paths).count == paths.count else {
            throw VisualFixturePathError.directoriesMustBeDistinct
        }
        try Self.rejectProductSupportDirectory(dataDirectory, named: Self.dataDirectoryKey)
        try Self.rejectProductSupportDirectory(artifactDirectory, named: Self.artifactDirectoryKey)
    }

    var manifestURL: URL {
        fixtureDirectory.appendingPathComponent("visual-scenarios.v1.json")
    }

    var seedURL: URL {
        fixtureDirectory.appendingPathComponent("seed.v1.json")
    }

    var databaseURL: URL {
        dataDirectory.appendingPathComponent("muesli.sqlite")
    }

    private static func directory(
        named key: String,
        environment: [String: String],
        mustExist: Bool
    ) throws -> URL {
        guard let value = environment[key], !value.isEmpty else {
            throw VisualFixturePathError.missingDirectory(key)
        }
        guard value.hasPrefix("/") else {
            throw VisualFixturePathError.notAbsolute(key, value)
        }

        let url = URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard !mustExist || (exists && isDirectory.boolValue) else {
            throw VisualFixturePathError.notExistingDirectory(key, url.path)
        }
        return url
    }

    /// Local result directories can live in a checkout below the user's home,
    /// but fixture mode must never target any real Muesli support directory.
    private static func rejectProductSupportDirectory(_ url: URL, named key: String) throws {
        let applicationSupport = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.path
        guard candidate != applicationSupport, !candidate.hasPrefix(applicationSupport + "/Muesli") else {
            throw VisualFixturePathError.productSupportDirectory(key, candidate)
        }
    }
}

enum VisualFixturePathError: LocalizedError, Equatable {
    case missingDirectory(String)
    case notAbsolute(String, String)
    case notExistingDirectory(String, String)
    case directoriesMustBeDistinct
    case productSupportDirectory(String, String)

    var errorDescription: String? {
        switch self {
        case .missingDirectory(let key):
            "Visual-test launch is missing \(key)."
        case .notAbsolute(let key, let path):
            "Visual-test \(key) must be an absolute path, got \(path)."
        case .notExistingDirectory(let key, let path):
            "Visual-test \(key) must name a runner-created directory, got \(path)."
        case .directoriesMustBeDistinct:
            "Visual-test fixture, data, and artifact directories must be distinct."
        case .productSupportDirectory(let key, let path):
            "Visual-test \(key) must not target a Muesli application-support directory, got \(path)."
        }
    }
}
