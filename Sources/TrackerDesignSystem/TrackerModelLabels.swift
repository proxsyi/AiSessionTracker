import Foundation

public enum TrackerModelLabels {
    public static func openAI(_ slug: String, title: String? = nil) -> String {
        if let title, !title.isEmpty, title != slug {
            return title.replacingOccurrences(of: "(?i)^GPT[- ]?", with: "", options: .regularExpression)
        }
        var value = slug.replacingOccurrences(of: "(?i)^gpt[- ]?", with: "", options: .regularExpression)
            .replacingOccurrences(of: "-wm$", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "^([0-9]+)-([0-9]+)(?=-|$)", with: "$1.$2", options: .regularExpression)
        return value.replacingOccurrences(of: "-", with: " ").capitalized
    }

    public static func claude(_ slug: String) -> String {
        var value = slug.replacingOccurrences(of: "^claude-", with: "", options: .regularExpression)
            .replacingOccurrences(of: "-(?:[0-9]{8}|latest)$", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "([0-9]+)-([0-9]+)", with: "$1.$2", options: .regularExpression)
        let parts = value.split(separator: "-").map(String.init)
        if let family = parts.first(where: { ["haiku", "sonnet", "opus"].contains($0) }) {
            return ([family.capitalized] + parts.filter { $0 != family }).joined(separator: " ")
        }
        return parts.map { $0.capitalized }.joined(separator: " ")
    }

    public static func effort(_ id: String, title: String? = nil) -> String {
        if let title, !title.isEmpty, title.lowercased() != id.lowercased() { return title }
        switch id {
        case "min": return "Light"
        case "xhigh": return "Extra high"
        case "default": return "Default"
        default: return id.capitalized
        }
    }
}
