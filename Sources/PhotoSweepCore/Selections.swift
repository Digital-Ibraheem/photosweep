import Foundation

/// The file exported by the HTML report: which files the user chose to quarantine.
public struct SelectionFile: Codable, Sendable {
    public static let formatName = "photosweep-selections"

    public struct Selection: Codable, Hashable, Sendable {
        public var path: String
        public var groupId: String

        public init(path: String, groupId: String) {
            self.path = path
            self.groupId = groupId
        }
    }

    public var format: String
    public var version: Int
    public var scanId: String
    public var root: String
    /// Absolute path of the scan manifest the report was generated from.
    public var manifest: String
    public var selections: [Selection]

    public init(scanId: String, root: String, manifest: String, selections: [Selection]) {
        format = Self.formatName
        version = 1
        self.scanId = scanId
        self.root = root
        self.manifest = manifest
        self.selections = selections
    }

    public static func load(from url: URL) throws -> SelectionFile {
        let file: SelectionFile
        do {
            file = try JSONCoding.decoder.decode(SelectionFile.self, from: Data(contentsOf: url))
        } catch {
            throw PhotoSweepError.invalidInput("\(url.path) is not a PhotoSweep selections file: \(error.localizedDescription)")
        }
        guard file.format == formatName, file.version == 1 else {
            throw PhotoSweepError.invalidInput("Unsupported selections format \(file.format) v\(file.version)")
        }
        return file
    }
}
