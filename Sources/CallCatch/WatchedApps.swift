enum WatchedApp: String, CaseIterable {
    case discord, signal, telegram, whatsapp

    var displayName: String {
        switch self {
        case .discord: "Discord"
        case .signal: "Signal"
        case .telegram: "Telegram"
        case .whatsapp: "WhatsApp"
        }
    }
}

enum WatchedApps {
    private static let prefixes: [(String, WatchedApp)] = [
        ("com.hnc.Discord", .discord),
        ("org.whispersystems.signal-desktop", .signal),
        ("ru.keepcoder.Telegram", .telegram),
        ("org.telegram.desktop", .telegram),
        ("net.whatsapp.WhatsApp", .whatsapp),
    ]

    /// Матчит точное совпадение или префикс на границе компонента ("<prefix>.something").
    static func match(bundleID: String) -> WatchedApp? {
        for (prefix, app) in prefixes {
            if bundleID == prefix || bundleID.hasPrefix(prefix + ".") { return app }
        }
        return nil
    }
}
