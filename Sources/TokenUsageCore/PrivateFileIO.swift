import Foundation
import Darwin

public enum PrivateFileIO {
    public static func createPrivateDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw privateFileError("\(url.path) exists but is not a directory.")
            }
            try validateNoSymlink(url, expectedDirectory: true)
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try validateOwnerAndMode(url, maxPermissions: 0o700)
    }

    public static func writePrivateData(_ data: Data, to url: URL) throws {
        try createPrivateDirectory(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) {
            try validateNoSymlink(url, expectedDirectory: false)
            try validateOwnerAndMode(url, maxPermissions: 0o600)
        }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            try data.write(to: url, options: [.atomic])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try validateNoSymlink(url, expectedDirectory: false)
        try validateOwnerAndMode(url, maxPermissions: 0o600)
    }

    public static func writePrivateString(_ string: String, to url: URL) throws {
        try writePrivateData(Data(string.utf8), to: url)
    }

    private static func validateNoSymlink(_ url: URL, expectedDirectory: Bool) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw privateFileError("\(url.path) must not be a symlink.")
        }
        if expectedDirectory {
            guard values.isDirectory == true else {
                throw privateFileError("\(url.path) is not a directory.")
            }
        } else {
            guard values.isRegularFile == true else {
                throw privateFileError("\(url.path) is not a regular file.")
            }
        }
    }

    private static func validateOwnerAndMode(_ url: URL, maxPermissions: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let owner = attributes[.ownerAccountID] as? NSNumber
        guard owner?.uint32Value == getuid() else {
            throw privateFileError("\(url.path) is not owned by the current user.")
        }
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
            throw privateFileError("\(url.path) permissions could not be verified.")
        }
        guard permissions & ~maxPermissions == 0 else {
            throw privateFileError("\(url.path) has overly broad permissions.")
        }
    }

    private static func privateFileError(_ message: String) -> NSError {
        NSError(
            domain: "PrivateFileIO",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
