import AppKit
import AXSwift

private let chromiumSearchBarDescMap = [
    "Aadressi- ja otsinguriba": true,
    "Address and search bar": true,
    "Address bar at bar sa paghahanap": true,
    "Adres ve arama çubuğu": true,
    "Adres- en soekbalk": true,
    "Adres- en zoekbalk": true,
    "Adreses un meklēšanas josla": true,
    "Adresna traka i traka za pretraživanje": true,
    "Adresní a vyhledávací řádek": true,
    "Adreso ir paieškos juosta": true,
    "Adress- och sökfält": true,
    "Adress- und Suchleiste": true,
    "Adresse og søgelinje": true,
    "Adresse- og søkefelt": true,
    "Bar alamat dan carian": true,
    "Bar cyfeiriad a chwilio": true,
    "Bara de adrese și de căutare": true,
    "Barra d'adreces i de cerca": true,
    "Barra de direcciones y de búsqueda": true,
    "Barra de direcciones y de búsqueda ": true,
    "Barra de enderezos e de busca": true,
    "Barra de endereço e de pesquisa": true,
    "Barra de pesquisa e endereço": true,
    "Barra degli indirizzi e di ricerca": true,
    "Barre d'adresse et de recherche": true,
    "Bilah penelusuran dan alamat": true,
    "Cím- és keresősáv": true,
    "Helbide- eta bilaketa-barra": true,
    "Ikheli nebha yosesho": true,
    "Manzil va qidiruv paneli": true,
    "Naslovna in iskalna vrstica": true,
    "Osoite- ja hakupalkki": true,
    "Panel s adresou a vyhľadávací panel": true,
    "Pasek adresu i wyszukiwania": true,
    "Shiriti i adresës dhe i kërkimit": true,
    "Thanh địa chỉ và tìm kiếm": true,
    "Traka za adresu i pretragu": true,
    "Traka za adresu i pretraživanje": true,
    "Upau wa anwani na utafutaji": true,
    "Veffanga- og leitarstika": true,
    "Ünvan və axtarış paneli": true,
    "Γραμμή διευθύνσεων και αναζήτησης": true,
    "Адрасны радок і панэль пошуку": true,
    "Адресная строка и строка поиска": true,
    "Адресний і пошуковий рядок": true,
    "Дарек жана издөө тилкеси": true,
    "Лента за адреса и за пребарување": true,
    "Лента за адреси и за търсене": true,
    "Мекенжайы және іздеу жолағы": true,
    "Трака за адресу и претрагу": true,
    "Хаяг ба хайлтын цонх": true,
    "Հասցեագոտի և որոնման գոտի": true,
    "שורת חיפוש וכתובות אתרים": true,
    "شريط العناوين والبحث": true,
    "نوار جستجو و آدرس": true,
    "پتہ اور تلاش بار": true,
    "ठेगाना र खोज पट्टी": true,
    "पता और सर्च बार": true,
    "पत्ता आणि शोध बार": true,
    "ঠিকনা আৰু সন্ধানৰ বাৰ": true,
    "ঠিকানা এবং সার্চ দণ্ড": true,
    "ਪਤਾ ਅਤੇ ਖੋਜ ਬਾਰ": true,
    "સરનામું અને શોધ બાર": true,
    "ଠିକଣା ଏବଂ ସନ୍ଧାନ ବାର୍": true,
    "முகவரி மற்றும் தேடல் பட்டி": true,
    "అడ్రస్‌ మరియు శోధన బార్": true,
    "ವಿಳಾಸ ಹಾಗೂ ಹುಡುಕಾಟ ಪಟ್ಟಿ": true,
    "വിലാസവും തിരയൽ ബാറും": true,
    "ලිපිනය සහ සෙවීම් බාර් එක": true,
    "ที่อยู่และแถบค้นหา": true,
    "ແຖບ​ທີ່​ຢູ່​ ແລະ​ຄົ້ນ​ຫາ": true,
    "လိပ်စာ နှင့် ရှာဖွေရေး ဘား": true,
    "მისამართი და ძიების ზოლი": true,
    "የአድራሻ እና ፍለጋ አሞሌ": true,
    "អាសយដ្ឋាន និងរបាស្វែងរក": true,
    "アドレス検索バー": true,
    "地址和搜索栏": true,
    "網址與搜尋列": true,
    "주소창 및 검색창": true,
]

enum BrowserThatCanWatchBrowserAddressFocus: CaseIterable {
    static var allBundleIdentifiers = allCases.map { $0.bundleIdentifier }

    static func createBy(bundleIdentifier: String?) -> BrowserThatCanWatchBrowserAddressFocus? {
        if let bundleIdentifier = bundleIdentifier {
            for item in allCases {
                if item.bundleIdentifier == bundleIdentifier {
                    return item
                }
            }
        }

        return nil
    }

    case Safari, SafariTechnologyPreview, Chrome, Chromium, Brave, BraveBeta, BraveNightly, Edge, Vivaldi, Arc, Opera, Firefox, FirefoxNightly, FirefoxDeveloperEdition, Zen, Dia, Atlas

    var bundleIdentifier: String {
        return browser.rawValue
    }

    var browser: Browser {
        switch self {
        case .Safari:
            return .Safari
        case .SafariTechnologyPreview:
            return .SafariTechnologyPreview
        case .Chrome:
            return .Chrome
        case .Chromium:
            return .Chromium
        case .Brave:
            return .Brave
        case .BraveBeta:
            return .BraveBeta
        case .BraveNightly:
            return .BraveNightly
        case .Edge:
            return .Edge
        case .Vivaldi:
            return .Vivaldi
        case .Arc:
            return .Arc
        case .Opera:
            return .Opera
        case .Firefox:
            return .Firefox
        case .FirefoxNightly:
            return .FirefoxNightly
        case .FirefoxDeveloperEdition:
            return .FirefoxDeveloperEdition
        case .Zen:
            return .Zen
        case .Dia:
            return .Dia
        case .Atlas:
            return .Atlas
        }
    }

    func isFocusOnBrowserAddress(focusedElement: UIElement?) -> Bool {
        guard let focusedElement = focusedElement
        else { return false }

        switch self {
        case .Safari, .SafariTechnologyPreview:
            return focusedElement.domIdentifier() == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"

        case .Arc:
            return focusedElement.domIdentifier() == "commandBarTextField"

        case .Vivaldi:
            let classList = focusedElement.domClassList()
            return classList.contains("UrlBar-UrlField") && classList.contains("vivaldi-addressfield")

        case .Opera:
            return focusedElement.domClassList().contains("AddressTextfieldView")

        case .Chromium, .Chrome, .Brave, .BraveBeta, .BraveNightly, .Edge, .Dia, .Atlas:
            if focusedElement.domClassList().contains("OmniboxViewViews") {
                if let description = focusedElement.safeString(attribute: .description),
                   chromiumSearchBarDescMap[description] == true
                {
                    return true
                }

                if let title = focusedElement.safeString(attribute: .title),
                   chromiumSearchBarDescMap[title] == true
                {
                    return true
                }

                return false
            } else {
                return false
            }

        case .Firefox, .FirefoxNightly, .FirefoxDeveloperEdition, .Zen:
            return focusedElement.firefoxDomIdentifier() == "urlbar-input"
        }
    }
}

extension PreferencesVM {
    func isFocusOnBrowserAddress(app: NSRunningApplication?, focusedElement: UIElement?) -> Bool {
        return BrowserThatCanWatchBrowserAddressFocus
            .createBy(bundleIdentifier: app?.bundleIdentifier)?
            .isFocusOnBrowserAddress(focusedElement: focusedElement) ?? false
    }
}
