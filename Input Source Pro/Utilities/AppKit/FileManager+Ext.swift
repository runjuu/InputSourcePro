import Foundation

extension FileManager {
    func isDirectory(atPath path: String) -> Bool {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false

        if fileManager.fileExists(atPath: path, isDirectory: &isDir) {
            return isDir.boolValue
        } else {
            return false
        }
    }
}
