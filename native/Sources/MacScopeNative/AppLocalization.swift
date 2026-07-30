import Foundation

enum AppLocalization {
  static func string(
    _ key: String,
    language: AppLanguage,
    arguments: [CVarArg] = []
  ) -> String {
    let bundle: Bundle
    if let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
      let localizedBundle = Bundle(path: path)
    {
      bundle = localizedBundle
    } else {
      bundle = .main
    }
    let format = bundle.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: language.locale, arguments: arguments)
  }
}

