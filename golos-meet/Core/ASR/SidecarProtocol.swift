import Foundation

/// Сегмент с таймкодами (секунды от начала файла) от sidecar.
struct TimedSegment: Decodable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// Управляющие сообщения Swift → sidecar (stdin, JSON-lines).
enum SidecarRequest: Encodable, Equatable {
    case load(id: UInt64, modelPath: String)
    case transcribeFile(id: UInt64, path: String)
    case shutdown(id: UInt64)

    var id: UInt64 {
        switch self {
        case .load(let i, _): return i
        case .transcribeFile(let i, _): return i
        case .shutdown(let i): return i
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, path
        case modelPath = "model_path"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        switch self {
        case .load(_, let p):
            try c.encode("load", forKey: .type)
            try c.encode(p, forKey: .modelPath)
        case .transcribeFile(_, let p):
            try c.encode("transcribe_file", forKey: .type)
            try c.encode(p, forKey: .path)
        case .shutdown:
            try c.encode("shutdown", forKey: .type)
        }
    }
}

/// Ответы sidecar → Swift (stdout, JSON-lines).
enum SidecarResponse: Decodable, Equatable {
    case hello(version: String)
    case ready(id: UInt64)
    case segments(id: UInt64, segments: [TimedSegment], durationMs: UInt64)
    case error(id: UInt64?, kind: String, message: String)

    var id: UInt64? {
        switch self {
        case .hello: return nil
        case .ready(let i): return i
        case .segments(let i, _, _): return i
        case .error(let i, _, _): return i
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, version, segments, kind, message
        case durationMs = "duration_ms"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let id = try c.decodeIfPresent(UInt64.self, forKey: .id)
        switch type {
        case "hello":
            self = .hello(version: try c.decode(String.self, forKey: .version))
        case "ready":
            self = .ready(id: id ?? 0)
        case "segments":
            self = .segments(
                id: id ?? 0,
                segments: try c.decode([TimedSegment].self, forKey: .segments),
                durationMs: try c.decode(UInt64.self, forKey: .durationMs))
        case "error":
            self = .error(id: id,
                          kind: try c.decode(String.self, forKey: .kind),
                          message: try c.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown response type: \(type)")
        }
    }
}

enum ASRError: Error, Equatable {
    case sidecarNotRunning
    case modelLoadFailed(String)
    case transcribeFailed(String)
    case timeout
    case protocolError(String)
}
