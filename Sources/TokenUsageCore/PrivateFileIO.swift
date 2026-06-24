import Foundation

public enum PrivateFileIO {
    public static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func writePrivateData(_ data: Data, to url: URL) throws {
        try createPrivateDirectory(url.deletingLastPathComponent())
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            try data.write(to: url, options: [.atomic])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func writePrivateString(_ string: String, to url: URL) throws {
        try writePrivateData(Data(string.utf8), to: url)
    }
}
