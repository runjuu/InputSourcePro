import Foundation

extension String {
    func i18n(
        comment: String = "",
        tableName: String = "Localizable"
    ) -> String {
        #if DEBUG
            let fallback = "**\(self)**"
        #else
            let fallback = self
        #endif

        return NSLocalizedString(
            self,
            tableName: tableName,
            value: fallback,
            comment: comment
        )
    }
}
