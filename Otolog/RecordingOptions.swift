import Foundation

enum RecordingMode: String, CaseIterable, Identifiable {
    case meeting, microphone
    var id: String { rawValue }
    var label: String { self == .meeting ? "再生音声＋マイク" : "マイクのみ" }
}
struct RecordingConfiguration {
    let mode: RecordingMode
    let bundle: String?
    let microphoneID: String
    let microphoneEnabled: Bool
    var title: String? = nil
    var capturesPlayback: Bool { mode == .meeting }
    var capturesMicrophone: Bool { mode == .microphone || microphoneEnabled }
    var gains: [Float] { mode == .microphone ? [0, 1] : [0.5, 0.5] }
}
struct RecordingManifest: Codable { let startedAt: Date; var title: String? = nil }
enum RecordingNames {
    static func baseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss'_JST'"
        return formatter.string(from: date)
    }
    static func baseName(for date: Date, title: String?) -> String {
        guard let title else { return baseName(for: date) }
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
        let clean = title.components(separatedBy: forbidden).joined(separator: "-")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        var result = ""
        for character in clean.prefix(120) {
            guard result.utf8.count + String(character).utf8.count <= 200 else { break }
            result.append(character)
        }
        return result.isEmpty ? baseName(for: date) : result
    }
    static func uniqueURL(in directory: URL, baseName: String) throws -> URL {
        for index in 1...10000 {
            let name = index == 1 ? baseName : "\(baseName) (\(index))"
            let url = directory.appendingPathComponent(name).appendingPathExtension("m4a")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw RecorderError("同名の録音が多すぎます．別の保存先を選択してください．")
    }
}
