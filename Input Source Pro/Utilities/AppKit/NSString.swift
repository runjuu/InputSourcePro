import Foundation

extension String {
    func string(at atIndex: Int) -> String {
        guard !isEmpty else { return self }

        let offset = max(min(count - 1, atIndex), 0)

        return String(self[index(startIndex, offsetBy: offset)])
    }
}

extension String {
    func runCommand(
        requireSudo: Bool,
        completion: @escaping (_ output: String, _ errorOutput: String, _ exitCode: Int32) -> Void
    ) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        if requireSudo {
            let appleScript = """
            do shell script "\(self.replacingOccurrences(of: "\"", with: "\\\""))" with administrator privileges
            """
            process.launchPath = "/usr/bin/osascript"
            process.arguments = ["-e", appleScript]
        } else {
            process.launchPath = "/bin/bash"
            process.arguments = ["-c", self]
        }

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { proc in
            let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            let exitCode = proc.terminationStatus

            DispatchQueue.main.async {
                completion(output, errorOutput, exitCode)
            }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                completion("", "Process failed to start: \(error)", -1)
            }
        }
    }
}
