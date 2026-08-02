import Foundation

struct ChatGPTAssistantTurn: Equatable {
    let nodeID: String
    let text: String
    let isComplete: Bool
}

/// Reads the active branch of ChatGPT's conversation tree. Mapping order is
/// not chronological, so completion must start at `current_node` and follow
/// parent links instead of choosing the last dictionary entry.
enum ChatGPTConversationParser {
    static func newestAssistantTurn(
        in object: [String: Any],
        stoppingAt previousNodeID: String?
    ) -> ChatGPTAssistantTurn? {
        guard let mapping = object["mapping"] as? [String: Any],
              var nodeID = object["current_node"] as? String else { return nil }
        var visited = Set<String>()

        while !nodeID.isEmpty, !visited.contains(nodeID), nodeID != previousNodeID {
            visited.insert(nodeID)
            guard let node = mapping[nodeID] as? [String: Any] else { return nil }
            if let message = node["message"] as? [String: Any],
               let author = message["author"] as? [String: Any],
               author["role"] as? String == "assistant",
               let content = message["content"] as? [String: Any] {
                let text = visibleText(in: content)
                if !text.isEmpty {
                    return ChatGPTAssistantTurn(
                        nodeID: nodeID,
                        text: text,
                        isComplete: isComplete(message)
                    )
                }
            }
            nodeID = node["parent"] as? String ?? ""
        }
        return nil
    }

    private static func isComplete(_ message: [String: Any]) -> Bool {
        if message["end_turn"] as? Bool == true { return true }
        guard let status = (message["status"] as? String)?.lowercased() else { return false }
        return ["finished_successfully", "finished", "complete", "completed"].contains(status)
    }

    private static func visibleText(in content: [String: Any]) -> String {
        var pieces: [String] = []
        if let text = content["text"] as? String { pieces.append(text) }
        if let result = content["result"] as? String { pieces.append(result) }
        if let parts = content["parts"] as? [Any] {
            pieces.append(contentsOf: parts.compactMap(text(from:)))
        }
        return pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func text(from value: Any) -> String? {
        if let text = value as? String { return text }
        guard let dictionary = value as? [String: Any] else { return nil }
        if let text = dictionary["text"] as? String { return text }
        if let content = dictionary["content"] as? String { return content }
        if let nested = dictionary["parts"] as? [Any] {
            return nested.compactMap(text(from:)).joined(separator: "\n")
        }
        return nil
    }
}
