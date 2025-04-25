import Foundation

extension String {
    func string(at atIndex: Int) -> String {
        guard !isEmpty else { return self }

        let offset = max(min(count - 1, atIndex), 0)

        return String(self[index(startIndex, offsetBy: offset)])
    }
}
