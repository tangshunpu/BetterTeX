import Foundation

public enum AgentProvider: String, CaseIterable { case codex = "Codex", claude = "Claude" }

public struct AgentModel: Equatable {
    public let id: String
    public let name: String
    public let efforts: [String]
    public init(id: String, name: String, efforts: [String]) { self.id = id; self.name = name; self.efforts = efforts }
}

public struct AgentConfiguration: Equatable {
    public var model: String
    public var effort: String
    public init(model: String = "", effort: String = "") { self.model = model; self.effort = effort }
    public static let knownEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    public func arguments(for provider: AgentProvider) throws -> [String] {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.isEmpty || (model.count <= 150 && model.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/+\\-]*$", options: .regularExpression) != nil) else {
            throw BetterTeXError.message("模型名称包含无效字符，请使用 CLI 接受的模型 ID。")
        }
        guard effort.isEmpty || Self.knownEfforts.contains(effort) else { throw BetterTeXError.message("不支持的思考强度。") }
        var result: [String] = []
        if !model.isEmpty { result += ["--model", model] }
        if !effort.isEmpty {
            switch provider {
            case .codex: result += ["-c", "model_reasoning_effort=\"\(effort)\""]
            case .claude:
                guard ["low", "medium", "high", "xhigh", "max"].contains(effort) else { throw BetterTeXError.message("Claude CLI 不支持该思考强度。") }
                result += ["--effort", effort]
            }
        }
        return result
    }
    public static func codexModels(from data: Data) -> [AgentModel] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let models = root["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { entry in
            guard let id = entry["slug"] as? String else { return nil }
            if let visibility = entry["visibility"] as? String, visibility == "hide" { return nil }
            let efforts = (entry["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String } ?? ["low", "medium", "high", "xhigh"]
            return AgentModel(id: id, name: entry["display_name"] as? String ?? id, efforts: efforts)
        }
    }
}
