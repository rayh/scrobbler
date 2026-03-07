import Foundation

enum Config {
    #if DEBUG
    static let apiBaseUrl  = "https://api-rayhilton.slctr.io"
    static let siteBaseUrl = "https://rayhilton.slctr.io"
    static let stage       = "rayhilton"
    #else
    static let apiBaseUrl  = "https://api.slctr.io"
    static let siteBaseUrl = "https://slctr.io"
    static let stage       = "production"
    #endif

    // PostHog — one project, stage property separates environments in queries
    static let postHogApiKey = "phc_ShvPDG1ogxpNRXLrlZPc4qlH4HIpyRB4LayON3NheOs"
    static let postHogHost   = "https://eu.i.posthog.com" // "https://s.slctr.io"
}
