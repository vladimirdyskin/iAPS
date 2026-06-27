import Foundation

// Приватный класс для локации бандла PickleLinkKit — используется Medtronic-копиями
// событий истории. Строки берутся из бандла MinimedKit (он всегда присутствует в хосте iAPS)
// чтобы пользователь видел уже переведённые тексты, а не ключи.
private class MedtronicLocalBundle {
    static var main: Bundle = {
        // Пробуем оригинальный бандл MinimedKit (он в том же App Bundle)
        if let mainResourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: mainResourceURL.appendingPathComponent("MinimedKit_MinimedKit.bundle"))
        {
            return bundle
        }
        // Fallback: бандл PickleLinkKit
        return Bundle(for: MedtronicLocalBundle.self)
    }()
}

// Функция намеренно называется LocalizedString (без префикса) — именно так
// её вызывают все скопированные PumpEvent-файлы. В модуле PickleLinkKit
// конфликта нет: PickleLinkClient и прочие используют эту же функцию.
func LocalizedString(_ key: String, tableName: String? = nil, value: String? = nil, comment: String) -> String {
    if let value = value {
        return NSLocalizedString(key, tableName: tableName, bundle: MedtronicLocalBundle.main, value: value, comment: comment)
    } else {
        return NSLocalizedString(key, tableName: tableName, bundle: MedtronicLocalBundle.main, comment: comment)
    }
}
