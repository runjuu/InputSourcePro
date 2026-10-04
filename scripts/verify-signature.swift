import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
guard let publicKeyData = Data(base64Encoded: arguments[2]),
      let signature = Data(base64Encoded: arguments[3]) else {
    fail("Invalid Sparkle signature encoding")
}
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
guard publicKey.isValidSignature(signature, for: archive) else {
    fail("Sparkle signature does not match the app's existing public key")
}
