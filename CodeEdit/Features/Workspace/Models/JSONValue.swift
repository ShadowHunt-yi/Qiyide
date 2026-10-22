//
//  JSONValue.swift
//  CodeEdit
//
//  配置分层合并所需的通用 JSON 值类型。
//

import Foundation

/// 一个与具体模型解耦的 JSON 值。
///
/// 配置分层（用户全局 → 工作区 → 文件夹 → 文档）需要在**不丢失未知字段**的前提下逐层合并。
/// 若直接用 `SettingsData` 合并，任何一层出现新字段都会因类型不匹配而丢失。
/// 因此在合并阶段使用本类型，只在最外层做一次解码。
enum JSONValue: Codable, Hashable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// 以字符串为键读取对象成员；非对象或键不存在时返回 `nil`。
    subscript(key: String) -> JSONValue? {
        guard case .object(let dictionary) = self else { return nil }
        return dictionary[key]
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let dictionary) = self else { return nil }
        return dictionary
    }

    // MARK: - Merge

    /// 深合并两个 JSON 值。
    ///
    /// 规则与 VS Code 的设置合并保持一致：
    /// - 两侧都是对象：按键递归合并，`override` 优先。
    /// - 其余情况（含数组）：整体替换。数组不做逐项合并，避免产生无意义的混合结果。
    /// - `override` 为 `.null` 表示显式清除该键。
    /// - 未在 `override` 中出现的键保留 `base` 的值（因此新版本新增的设置项不会丢失）。
    static func merge(base: JSONValue, override: JSONValue) -> JSONValue {
        guard case .object(var baseObject) = base,
              case .object(let overrideObject) = override else {
            return override
        }

        for (key, value) in overrideObject {
            if case .null = value {
                baseObject.removeValue(forKey: key)
            } else if let baseValue = baseObject[key] {
                baseObject[key] = merge(base: baseValue, override: value)
            } else {
                baseObject[key] = value
            }
        }

        return .object(baseObject)
    }

    /// 依次合并多层覆盖，后者优先。
    static func merge(_ layers: [JSONValue]) -> JSONValue {
        layers.reduce(JSONValue.object([:])) { partial, next in
            merge(base: partial, override: next)
        }
    }

    // MARK: - Serialization

    static func decode(from data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func encoded(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(self)
    }
}
