import Foundation

enum ApplicationFilterMode: String, CaseIterable {
    case exclude
    case include

    var title: String {
        switch self {
        case .exclude: "All Apps Except Excluded"
        case .include: "Only Included Apps"
        }
    }
}

@MainActor
final class ApplicationFilter {
    private let defaults: UserDefaults
    private(set) var mode: ApplicationFilterMode
    private var includedApplications: Set<String>
    private var excludedApplications: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = ApplicationFilterMode(
            rawValue: defaults.string(forKey: "applicationFilterMode") ?? ""
        ) ?? .exclude
        includedApplications = Set(
            (defaults.stringArray(forKey: "includedApplications") ?? []).map { $0.lowercased() }
        )
        excludedApplications = Set(
            (defaults.stringArray(forKey: "excludedApplications") ?? []).map { $0.lowercased() }
        )
    }

    func applications(in list: ApplicationFilterMode) -> Set<String> {
        list == .include ? includedApplications : excludedApplications
    }

    func allows(_ bundleIdentifier: String?) -> Bool {
        guard let identifier = bundleIdentifier?.lowercased() else { return mode == .exclude }
        return !excludedApplications.contains(identifier)
            && (mode == .exclude || includedApplications.contains(identifier))
    }

    func setMode(_ mode: ApplicationFilterMode) {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: "applicationFilterMode")
    }

    func setApplication(_ identifier: String, selected: Bool, in list: ApplicationFilterMode) {
        var applications = applications(in: list)
        if selected {
            applications.insert(identifier.lowercased())
        } else {
            applications.remove(identifier.lowercased())
        }
        switch list {
        case .include: includedApplications = applications
        case .exclude: excludedApplications = applications
        }
        defaults.set(
            applications.sorted(),
            forKey: list == .include ? "includedApplications" : "excludedApplications"
        )
    }
}
