import CryptoKit
import Foundation

extension Data {
    func md5() -> String {
        Insecure.MD5
            .hash(data: self)
            .map { String(format: "%02hhx", $0) }
            .joined()
    }
}
