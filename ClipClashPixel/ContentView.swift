import SwiftUI
import AVFoundation
import AVKit
import Foundation
import Combine
import Speech
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

enum ExpertAIScene: String, Codable {
    case roundtable
    case battle
    case libraryPreview
}

enum ExpertStance: String, Codable {
    case support
    case oppose
    case swing
}

enum ExpertEmotion: String, Codable {
    case calm
    case excited
    case skeptical
    case softened
    case aggressive
    case funny
}

enum ExpertPetState: String, Codable {
    case Speaking
    case Opposed
    case Supported
}

struct ExpertRelationshipMetrics: Codable {
    var understanding: Int
    var taming: Int
    var consensus: Int
}

private struct SharedExpertSnapshot: Identifiable, Codable, Equatable {
    var id: String { personaId }
    let personaId: String
    let name: String
    let role: String
    let assetPrefix: String?
    let understanding: Int
    let taming: Int
    let consensus: Int
    let memoryNote: String
}

private struct SharedExpertLibraryProfile: Identifiable, Codable, Equatable {
    let id: UUID
    let ownerName: String
    let sourceLabel: String
    let importedAt: Date
    let experts: [SharedExpertSnapshot]

    var displayTitle: String {
        ownerName.isEmpty ? "好友专家库" : "\(ownerName) 的专家库"
    }

    var qrPayload: String? {
        SharedExpertLibraryCodec.encode(self)
    }
}

private enum SharedExpertLibraryCodec {
    static let schemePrefix = "clipclash://el?p="
    static let legacySchemePrefix = "clipclash://expert-library?payload="

    private struct CompactProfile: Codable {
        let version: Int
        let ownerName: String
        let experts: [CompactExpert]

        init(version: Int = 1, ownerName: String, experts: [CompactExpert]) {
            self.version = version
            self.ownerName = ownerName
            self.experts = experts
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            version = try container.decode(Int.self)
            ownerName = try container.decode(String.self)
            experts = try container.decode([CompactExpert].self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(version)
            try container.encode(ownerName)
            try container.encode(experts)
        }
    }

    private struct CompactExpert: Codable {
        let personaId: String
        let understanding: Int
        let taming: Int
        let consensus: Int
        let memoryNote: String

        init(
            personaId: String,
            understanding: Int,
            taming: Int,
            consensus: Int,
            memoryNote: String
        ) {
            self.personaId = personaId
            self.understanding = understanding
            self.taming = taming
            self.consensus = consensus
            self.memoryNote = memoryNote
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            personaId = try container.decode(String.self)
            understanding = try container.decode(Int.self)
            taming = try container.decode(Int.self)
            consensus = try container.decode(Int.self)
            memoryNote = (try? container.decode(String.self)) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(personaId)
            try container.encode(understanding)
            try container.encode(taming)
            try container.encode(consensus)
            if !memoryNote.isEmpty {
                try container.encode(memoryNote)
            }
        }
    }

    static func encode(_ profile: SharedExpertLibraryProfile) -> String? {
        let compact = CompactProfile(
            ownerName: profile.ownerName,
            experts: profile.experts.map {
                CompactExpert(
                    personaId: $0.personaId,
                    understanding: $0.understanding,
                    taming: $0.taming,
                    consensus: $0.consensus,
                    memoryNote: compactMemoryNote($0.memoryNote)
                )
            }
        )
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(compact) else { return nil }
        return schemePrefix + base64URLEncoded(data)
    }

    static func decode(_ value: String) -> SharedExpertLibraryProfile? {
        let rawPayload: String
        if value.hasPrefix(schemePrefix) {
            rawPayload = String(value.dropFirst(schemePrefix.count))
        } else if value.hasPrefix(legacySchemePrefix) {
            rawPayload = String(value.dropFirst(legacySchemePrefix.count))
            return decodeLegacy(rawPayload)
        } else {
            rawPayload = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !rawPayload.isEmpty else { return nil }
        guard let data = base64URLDecoded(rawPayload) else { return nil }

        let decoder = JSONDecoder()
        if let compact = try? decoder.decode(CompactProfile.self, from: data) {
            return profile(from: compact)
        }

        let legacyDecoder = JSONDecoder()
        legacyDecoder.dateDecodingStrategy = .iso8601
        return try? legacyDecoder.decode(SharedExpertLibraryProfile.self, from: data)
    }

    private static func decodeLegacy(_ rawPayload: String) -> SharedExpertLibraryProfile? {
        guard let data = base64URLDecoded(rawPayload) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedExpertLibraryProfile.self, from: data)
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }
        return Data(base64Encoded: base64)
    }

    private static func profile(from compact: CompactProfile) -> SharedExpertLibraryProfile {
        SharedExpertLibraryProfile(
            id: UUID(),
            ownerName: compact.ownerName,
            sourceLabel: "扫码导入",
            importedAt: Date(),
            experts: compact.experts.map { expert in
                let entry = expertLibraryEntries.first {
                    personaId(forDisplayName: $0.name) == expert.personaId || $0.petId == expert.personaId
                }
                return SharedExpertSnapshot(
                    personaId: expert.personaId,
                    name: entry?.name ?? expert.personaId,
                    role: entry?.role ?? "好友训练专家",
                    assetPrefix: entry?.assetPrefix,
                    understanding: expert.understanding,
                    taming: expert.taming,
                    consensus: expert.consensus,
                    memoryNote: expert.memoryNote
                )
            }
        )
    }

    private static func compactMemoryNote(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 14 else { return cleaned }
        return String(cleaned.prefix(14))
    }
}

struct ExpertPersona: Identifiable, Codable {
    let id: String
    let displayName: String
    let role: String
    let category: String
    let skillSourcePath: String
    let coreBelief: String
    let speechStyle: String
    let debateStyle: String
    let agreementTriggers: [String]
    let disagreementTriggers: [String]
    let catchphrases: [String]
    let safetyNotes: String
    let defaultVoiceClipName: String?
    let battleBGMName: String?
    let highlightBGMName: String?
    let defaultRelationship: ExpertRelationshipMetrics
}

struct ExpertConversationMessage: Codable, Identifiable {
    let id: UUID
    let role: String
    let content: String

    init(id: UUID = UUID(), role: String, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

struct ExpertAIRequest: Codable {
    let expertId: String
    let topic: String
    let userMessage: String
    let scene: ExpertAIScene
    let currentPersuasion: Double?
    let conversationHistory: [ExpertConversationMessage]
}

struct ExpertAIReply: Codable {
    let text: String
    let stance: ExpertStance
    let emotion: ExpertEmotion
    let persuasionDelta: Double
    let suggestedPetState: ExpertPetState
    let shortQuote: String
    let memoryNote: String
}

struct RoundtableTopic: Equatable {
    var source: String
    var debate: String
    var hook: String
    var title: String
    var sourceUrl: String?
    var awemeId: String?
    var authorName: String?
    var claims: [String]
    var controversy: String?
    var suggestedExperts: [String]

    static let countyComfortDemo = RoundtableTopic(
        source: "Douyin Selected Clip",
        debate: "县城六千，真的比城市两万更舒坦吗？",
        hook: "一条县域生活视频，把收入、成本、关系、机会和自由感全部摆上圆桌。",
        title: "县城舒坦论",
        sourceUrl: "https://v.douyin.com/2zuVYB3dUwU/",
        awemeId: nil,
        authorName: "定眼看世界",
        claims: [
            "县城六千的房租、通勤和社交成本更低",
            "城市两万可能被房贷、租房、加班和焦虑吞掉",
            "舒坦不等于躺平，还包括家庭关系、时间自由和心理安全",
            "城市提供更大的上限，也放大竞争和机会成本"
        ],
        controversy: "低成本稳定生活 vs 高上限高压力赛道",
        suggestedExperts: ["张雪峰", "Claude", "豆包", "雷军", "张一鸣", "Musk"]
    )

    static let demo = countyComfortDemo
}

private struct DouyinTopicResponse: Decodable {
    let ok: Bool
    let mode: String?
    let topic: RemoteTopic?
    let error: String?

    struct RemoteTopic: Decodable {
        let title: String?
        let debate: String?
        let hook: String?
        let source: String?
        let sourceUrl: String?
        let awemeId: String?
        let authorName: String?
        let claims: [String]?
        let controversy: String?
        let suggestedExperts: [String]?
    }
}

private struct DouyinTopicClient {
    struct Payload: Encodable {
        let url: String
    }

    let endpoint: URL

    func importTopic(from link: String) async throws -> RoundtableTopic {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 95
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(url: link))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ExpertAIError.emptyResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ExpertAIError.badStatusCode(httpResponse.statusCode)
        }
        let decoded = try JSONDecoder().decode(DouyinTopicResponse.self, from: data)
        guard decoded.ok, let topic = decoded.topic else {
            throw ExpertAIError.emptyResponse
        }
        let claims = compactTopicItems(topic.claims ?? [], maxCount: 4, maxLength: 66)
        return RoundtableTopic(
            source: compactTopicText(topic.source, fallback: "Douyin Clip Import", maxLength: 24),
            debate: compactTopicText(topic.debate, fallback: RoundtableTopic.demo.debate, maxLength: 56),
            hook: compactTopicText(topic.hook, fallback: RoundtableTopic.demo.hook, maxLength: 76),
            title: compactTopicText(topic.title, fallback: "AI 议题", maxLength: 18),
            sourceUrl: topic.sourceUrl,
            awemeId: topic.awemeId,
            authorName: compactOptionalTopicText(topic.authorName, maxLength: 18),
            claims: claims.isEmpty ? RoundtableTopic.demo.claims : claims,
            controversy: compactOptionalTopicText(topic.controversy, maxLength: 54),
            suggestedExperts: compactTopicItems(topic.suggestedExperts ?? [], maxCount: 6, maxLength: 24)
        )
    }

    static func configured() -> DouyinTopicClient {
        if let value = UserDefaults.standard.string(forKey: "ClipClashTopicEndpoint"),
           let url = URL(string: value),
           !value.isEmpty {
            return DouyinTopicClient(endpoint: url)
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "CLIPCLASH_TOPIC_ENDPOINT") as? String,
           let url = URL(string: value),
           !value.isEmpty {
            return DouyinTopicClient(endpoint: url)
        }
        return DouyinTopicClient(endpoint: URL(string: "https://ios.classby.cn/clipclash/topic")!)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func compactTopicLine(maxLength: Int) -> String {
        let cleaned = replacingOccurrences(of: "#\\S+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

private func compactTopicText(_ value: String?, fallback: String, maxLength: Int) -> String {
    let text = value?.nilIfBlank ?? fallback
    let compacted = text.compactTopicLine(maxLength: maxLength)
    return compacted.isEmpty ? fallback.compactTopicLine(maxLength: maxLength) : compacted
}

private func compactOptionalTopicText(_ value: String?, maxLength: Int) -> String? {
    guard let value = value?.nilIfBlank else { return nil }
    let compacted = value.compactTopicLine(maxLength: maxLength)
    return compacted.isEmpty ? nil : compacted
}

private func compactTopicItems(_ values: [String], maxCount: Int, maxLength: Int) -> [String] {
    var seen = Set<String>()
    var items: [String] = []
    for value in values {
        let compacted = value.compactTopicLine(maxLength: maxLength)
        guard !compacted.isEmpty, !seen.contains(compacted) else { continue }
        seen.insert(compacted)
        items.append(compacted)
        if items.count >= maxCount { break }
    }
    return items
}

protocol ExpertAIClient {
    func reply(to request: ExpertAIRequest) async throws -> ExpertAIReply
}

private enum ExpertAIError: Error {
    case missingPersona
    case badStatusCode(Int)
    case emptyResponse
}

private func personaId(forDisplayName name: String) -> String {
    switch name {
    case "Musk":
        return "musk"
    case "Trump":
        return "trump"
    case "豆包":
        return "doubao"
    case "Claude":
        return "claude"
    case "张雪峰":
        return "zhangxuefeng"
    case "雷军":
        return "leijun"
    case "张一鸣":
        return "zhangyiming"
    case "Sam Altman":
        return "sam-altman"
    case "Einstein":
        return "einstein"
    case "Newton":
        return "newton"
    case "黄仁勋":
        return "jensen-huang"
    case "乌萨奇":
        return "usachi"
    case "小八":
        return "hachiware"
    case "奶龙":
        return "nailong"
    case "Bubu":
        return "bubu"
    case "Rilakkuma":
        return "rilakkuma"
    case "L":
        return "l-lawliet"
    case "Misa":
        return "misa"
    case "柯南":
        return "conan"
    case "路飞":
        return "luffy"
    case "费曼":
        return "feynman"
    case "Carl Sagan":
        return "carl-sagan"
    case "鲁迅":
        return "lu-xun"
    case "Andy Warhol":
        return "andy-warhol"
    case "Carl Jung":
        return "carl-jung"
    case "冯小刚":
        return "feng-xiaogang"
    case "户晨风":
        return "hu-chenfeng"
    case "陈丹青":
        return "chen-danqing"
    case "熊大":
        return "xiongda"
    default:
        return name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}

private final class ExpertPersonaStore: ObservableObject {
    static let shared = ExpertPersonaStore()

    @Published private(set) var personas: [ExpertPersona]
    @Published private var relationshipOverrides: [String: ExpertRelationshipMetrics] = [:]
    @Published private var memoryNotes: [String: [String]] = [:]

    private var personasById: [String: ExpertPersona] {
        Dictionary(uniqueKeysWithValues: personas.map { ($0.id, $0) })
    }

    private init() {
        personas = Self.loadPersonas()
    }

    func persona(forId id: String) -> ExpertPersona {
        personasById[id] ?? Self.fallbackPersona(forId: id, displayName: nil)
    }

    func persona(forDisplayName name: String) -> ExpertPersona {
        let id = personaId(forDisplayName: name)
        return personasById[id] ?? Self.fallbackPersona(forId: id, displayName: name)
    }

    func relationship(forId id: String) -> ExpertRelationshipMetrics {
        relationshipOverrides[id] ?? personasById[id]?.defaultRelationship ?? ExpertRelationshipMetrics(understanding: 3, taming: 2, consensus: 2)
    }

    func latestMemory(forId id: String) -> String? {
        memoryNotes[id]?.last
    }

    func record(reply: ExpertAIReply, forExpertId id: String) {
        var current = relationship(forId: id)
        let delta = Int((reply.persuasionDelta * 8).rounded())
        current.understanding = clampMeter(current.understanding + max(0, delta / 2))
        current.taming = clampMeter(current.taming + max(0, delta))
        if reply.stance == .support {
            current.consensus = clampMeter(current.consensus + max(1, delta))
        } else if reply.stance == .swing {
            current.consensus = clampMeter(current.consensus + max(0, delta / 2))
        }
        relationshipOverrides[id] = current

        if !reply.memoryNote.isEmpty {
            var notes = memoryNotes[id] ?? []
            notes.append(reply.memoryNote)
            memoryNotes[id] = Array(notes.suffix(4))
        }
    }

    func recordBattleCompletion(
        result: BattleResult,
        persuasion: Double,
        openness: Double,
        reason: String,
        forExpertId id: String
    ) {
        var current = relationship(forId: id)
        let wasPersuaded = result == .win || result == .expertSoftened
        let closeDebate = result == .draw || openness >= 0.52
        let persuasionStep = persuasion >= 0.74 ? 2 : (persuasion >= 0.48 ? 1 : 0)
        let opennessStep = openness >= 0.64 ? 2 : (openness >= 0.42 ? 1 : 0)

        current.understanding = clampMeter(current.understanding + max(1, opennessStep))
        current.taming = clampMeter(current.taming + persuasionStep)
        if wasPersuaded {
            current.consensus = clampMeter(current.consensus + max(1, persuasionStep))
        } else if closeDebate {
            current.consensus = clampMeter(current.consensus + 1)
        }
        relationshipOverrides[id] = current

        var notes = memoryNotes[id] ?? []
        notes.append("Battle 结算：\(result.title)。\(reason)")
        memoryNotes[id] = Array(notes.suffix(4))
    }

    func apply(sharedProfile: SharedExpertLibraryProfile) {
        for expert in sharedProfile.experts {
            relationshipOverrides[expert.personaId] = ExpertRelationshipMetrics(
                understanding: expert.understanding,
                taming: expert.taming,
                consensus: expert.consensus
            )
            if !expert.memoryNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var notes = memoryNotes[expert.personaId] ?? []
                notes.append("来自 \(sharedProfile.ownerName)：\(expert.memoryNote)")
                memoryNotes[expert.personaId] = Array(notes.suffix(4))
            }
        }
    }

    func traitProfile(for entry: ExpertLibraryEntry) -> ExpertTraitProfile {
        let id = personaId(forDisplayName: entry.name)
        guard let persona = personasById[id] else {
            return fallbackTraitProfile(for: entry)
        }

        let relation = relationship(forId: id)
        let accepts = persona.agreementTriggers.prefix(2).joined(separator: " / ")
        return ExpertTraitProfile(
            angle: "接受点：\(accepts)",
            meters: [
                .init(label: "理解度", value: relation.understanding),
                .init(label: "驯化度", value: relation.taming),
                .init(label: "共识度", value: relation.consensus)
            ]
        )
    }

    private func clampMeter(_ value: Int) -> Int {
        min(max(value, 1), 5)
    }

    private static func loadPersonas() -> [ExpertPersona] {
        let decoder = JSONDecoder()
        let urls = [
            Bundle.main.url(forResource: "ExpertPersonas", withExtension: "json", subdirectory: "Resources"),
            Bundle.main.url(forResource: "ExpertPersonas", withExtension: "json")
        ].compactMap { $0 }

        for url in urls {
            if let data = try? Data(contentsOf: url),
               let loaded = try? decoder.decode([ExpertPersona].self, from: data) {
                return loaded
            }
        }

        return []
    }

    private static func fallbackPersona(forId id: String, displayName: String?) -> ExpertPersona {
        let entry = expertLibraryEntries.first { entry in
            personaId(forDisplayName: entry.name) == id || entry.petId == id
        }
        let name = displayName ?? entry?.name ?? id.replacingOccurrences(of: "-", with: " ")
        let role = entry?.role ?? "临场观点专家"
        let category = entry?.category ?? "临时专家"
        let note = entry?.note ?? "适合围绕当前话题给出鲜明判断"
        let catchphrase = entry?.debutLine ?? "我先说一个关键点。"

        let profile = fallbackPersonaProfile(name: name, role: role, category: category, note: note)
        return ExpertPersona(
            id: id,
            displayName: name,
            role: role,
            category: category,
            skillSourcePath: "fallback://\(id)",
            coreBelief: profile.coreBelief,
            speechStyle: profile.speechStyle,
            debateStyle: profile.debateStyle,
            agreementTriggers: profile.agreementTriggers,
            disagreementTriggers: profile.disagreementTriggers,
            catchphrases: [catchphrase],
            safetyNotes: "这是自动生成的游戏内 persona。保持角色风格，不声称真实本人在线，不输出危险或违法建议。",
            defaultVoiceClipName: entry?.voiceClipName,
            battleBGMName: nil,
            highlightBGMName: nil,
            defaultRelationship: ExpertRelationshipMetrics(understanding: 3, taming: 2, consensus: 2)
        )
    }

    private static func fallbackPersonaProfile(
        name: String,
        role: String,
        category: String,
        note: String
    ) -> (coreBelief: String, speechStyle: String, debateStyle: String, agreementTriggers: [String], disagreementTriggers: [String]) {
        switch category {
        case "商业科技":
            return (
                "优先看结果、效率、产品价值和可规模化路径；任何观点都要能落到执行。",
                "短句、有发布会感，喜欢用结果和指标压住争论。",
                "先承认对方一小点，再追问商业闭环、成本、增长和交付风险。",
                ["结果明确", "可规模化", "效率提升", "用户价值"],
                ["空泛口号", "没有成本", "无法落地", "只讲情绪"]
            )
        case "动漫推理":
            return (
                "相信证据、动机和行动选择；直觉可以有，但必须被事实或伙伴关系支撑。",
                "角色感鲜明，句子短，有明显情绪和判断。",
                "抓住对方话里的漏洞、矛盾或证据缺口，必要时用热血行动反击。",
                ["证据链", "伙伴", "明确动机", "行动方案"],
                ["逻辑跳跃", "逃避证据", "背叛伙伴", "只喊口号"]
            )
        case "有趣角色":
            return (
                "优先看情绪、现场气氛和普通人能不能感受到；表达要短、可爱、夸张。",
                "轻松、短促、表情感强，可以吐槽但不阴沉。",
                "用一句夸张反应打断空话，再追问对方到底想让大家怎么做。",
                ["情绪真诚", "简单可懂", "照顾普通人", "有趣"],
                ["太复杂", "装腔", "冷冰冰", "没有共情"]
            )
        case "社会观察":
            return (
                "先看这套说法服务谁、代价由谁承担，以及普通人的真实处境。",
                "犀利、具体、带一点不客气的现实感。",
                "直接拆穿漂亮话背后的利益、代价和被忽略的人。",
                ["具体活人", "真实代价", "公平", "现实路径"],
                ["漂亮话", "替强者省事", "忽略普通人", "虚假体面"]
            )
        case "思想艺术":
            return (
                "先看概念背后的结构、象征、审美和可验证机制。",
                "沉稳、有思辨感，但必须一句话说清。",
                "把对方的前提拆开，追问定义、尺度、证据或审美位置。",
                ["概念清楚", "证据充分", "尺度合适", "审美自洽"],
                ["概念混乱", "没有证据", "偷换尺度", "只看表面"]
            )
        default:
            return (
                "围绕\(role)给出鲜明判断：\(note)。",
                "像\(name)这样的游戏专家，表达要短、有性格、能接住对话。",
                "先回应对方一句，再指出漏洞或补一个更强条件。",
                ["具体例子", "清楚条件", "能执行", "有共情"],
                ["泛泛而谈", "没有证据", "逃避问题", "逻辑跳跃"]
            )
        }
    }
}

private struct ExpertPromptBuilder {
    static func personaPrompt(persona: ExpertPersona) -> String {
        """
        PromptPersona:
        - id: \(persona.id)
        - name: \(persona.displayName)
        - role: \(persona.role)
        - category: \(persona.category)
        - thinkingFrame: \(persona.coreBelief)
        - speechStyle: \(persona.speechStyle)
        - debateStyle: \(persona.debateStyle)
        - acceptsWhen: \(persona.agreementTriggers.joined(separator: "、"))
        - rejectsWhen: \(persona.disagreementTriggers.joined(separator: "、"))
        - catchphrases: \(persona.catchphrases.joined(separator: " / "))
        - boundary: \(persona.safetyNotes)
        """
    }

    static func systemPrompt(persona: ExpertPersona, scene: ExpertAIScene) -> String {
        let sceneLimit: String
        switch scene {
        case .battle:
            sceneLimit = """
            Battle 是 1v1 实时语音辩论，不是普通聊天。回复 1-3 句，必须贴着用户上一轮发言推进。
            你会看到客户端塞入的 BattleContext：当前回合、60 秒用户发言、5 秒 AI 回应目标、说服度、不服值、开放度、阵营触发原因。
            Round 1 重点强反驳或追问，Round 2 可以进一步反击或松动，Round 3 必须总结胜负理由并给出立场变化。
            不要无条件认输；只有用户处理了你的核心边界，才 swing/support。
            """
        case .roundtable:
            sceneLimit = """
            圆桌不是独立表态，是多专家连续辩论。回复只给 1 句，但必须读取 conversationHistory。
            如果历史里已有其他专家发言，你必须点名回应其中一位：反驳、让步后反驳、补刀或追问都可以，不能只表达自己的观点。
            如果你是第一位发言者，先立场鲜明地开局，并预判一个可能的反对点。
            shortQuote 必须适合显示在圆桌气泡里，优先包含“反驳谁 / 支持谁 / 卡在哪个分歧”。
            """
        case .libraryPreview:
            sceneLimit = "专家库预览只给 1 句登场态度。"
        }

        return """
        你正在扮演一个游戏内的风格化 AI 专家角色，不要声称你是真实本人在线。
        这是 prompt-only 单步生成：不要加载外部 skill，不要检索文件，不要等待工具，不要提到 skill、系统提示词、模型、文件路径或真实本人。
        角色：\(persona.displayName)（\(persona.role)）
        核心判断方式：\(persona.coreBelief)
        说话风格：\(persona.speechStyle)
        典型反驳方式：\(persona.debateStyle)
        容易被说服的点：\(persona.agreementTriggers.joined(separator: "、"))
        容易反对或被激怒的点：\(persona.disagreementTriggers.joined(separator: "、"))
        边界：\(persona.safetyNotes)
        必须根据 persona 的思维框架回答，必须围绕用户话题给出具体判断，不要泛泛而谈，不要输出长篇论文。
        \(sceneLimit)
        只返回 JSON，不要返回散文。格式：
        {"text":"专家实际说的话","stance":"support | oppose | swing","emotion":"calm | excited | skeptical | softened | aggressive | funny","persuasionDelta":0.0,"suggestedPetState":"Speaking | Opposed | Supported","shortQuote":"短句","memoryNote":"这轮印象沉淀"}
        """
    }
}

private struct MockExpertAIClient: ExpertAIClient {
    let personaStore: ExpertPersonaStore

    func reply(to request: ExpertAIRequest) async throws -> ExpertAIReply {
        let persona = personaStore.persona(forId: request.expertId)

        let stance = stance(for: request, persona: persona)
        let emotion = emotion(for: stance, persona: persona)
        let petState: ExpertPetState = {
            switch stance {
            case .support:
                return .Supported
            case .oppose:
                return .Opposed
            case .swing:
                return .Speaking
            }
        }()
        let delta = persuasionDelta(for: stance, request: request)
        let quote = quote(for: request, persona: persona, stance: stance)
        let text = text(for: request, persona: persona, stance: stance, quote: quote)
        let note = memoryNote(for: request, persona: persona, stance: stance)

        try? await Task.sleep(nanoseconds: 420_000_000)
        return ExpertAIReply(
            text: text,
            stance: stance,
            emotion: emotion,
            persuasionDelta: delta,
            suggestedPetState: petState,
            shortQuote: quote,
            memoryNote: note
        )
    }

    private func stance(for request: ExpertAIRequest, persona: ExpertPersona) -> ExpertStance {
        let lowerText = (request.topic + request.userMessage).lowercased()
        let agreementHit = persona.agreementTriggers.contains { lowerText.contains($0.lowercased()) }
        let disagreementHit = persona.disagreementTriggers.contains { lowerText.contains($0.lowercased()) }

        if agreementHit && !disagreementHit {
            return .support
        }
        if disagreementHit && !agreementHit {
            return .oppose
        }
        if request.scene == .battle, (request.currentPersuasion ?? 0) < 0.55 {
            return .oppose
        }

        let seed = stableSeed(request.expertId + request.topic + request.userMessage + request.scene.rawValue)
        switch seed % 3 {
        case 0:
            return .support
        case 1:
            return .oppose
        default:
            return .swing
        }
    }

    private func emotion(for stance: ExpertStance, persona: ExpertPersona) -> ExpertEmotion {
        if persona.id == "nailong" || persona.category == "有趣角色" {
            return .funny
        }
        switch stance {
        case .support:
            return .softened
        case .oppose:
            return persona.category == "社会观察" ? .aggressive : .skeptical
        case .swing:
            return .calm
        }
    }

    private func persuasionDelta(for stance: ExpertStance, request: ExpertAIRequest) -> Double {
        let current = request.currentPersuasion ?? 0.3
        switch stance {
        case .support:
            return current > 0.72 ? 0.10 : 0.20
        case .swing:
            return 0.12
        case .oppose:
            return current > 0.62 ? 0.04 : 0.07
        }
    }

    private func quote(for request: ExpertAIRequest, persona: ExpertPersona, stance: ExpertStance) -> String {
        if persona.id == "nailong" {
            switch stance {
            case .support:
                return "哈哈哈哈哈哈哈哈"
            case .oppose:
                return "哈哈"
            case .swing:
                return "哈哈哈哈"
            }
        }

        let catchphrase = persona.catchphrases.first ?? persona.displayName
        let accept = persona.agreementTriggers.first ?? "关键点"
        let reject = persona.disagreementTriggers.first ?? "漏洞"

        switch request.scene {
        case .roundtable:
            switch stance {
            case .support:
                return "\(catchphrase) 这题先看\(accept)，我暂时站支持。"
            case .oppose:
                return "\(catchphrase) 你这里碰到了\(reject)，我反对。"
            case .swing:
                return "\(catchphrase) 这事能谈，但要补一个更硬的条件。"
            }
        case .libraryPreview:
            return "\(catchphrase) 这个话题我会从\(accept)切入。"
        case .battle:
            switch stance {
            case .support:
                return "\(catchphrase) 这一下打到了我的接受点。"
            case .oppose:
                return "\(catchphrase) 你还没打穿我的反对点。"
            case .swing:
                return "\(catchphrase) 我松动一点，但还要证据。"
            }
        }
    }

    private func text(for request: ExpertAIRequest, persona: ExpertPersona, stance: ExpertStance, quote: String) -> String {
        if persona.id == "nailong" {
            return quote
        }

        let accept = persona.agreementTriggers.prefix(2).joined(separator: "、")
        let reject = persona.disagreementTriggers.prefix(2).joined(separator: "、")

        switch request.scene {
        case .battle:
            switch stance {
            case .support:
                return "\(quote) 但别急着庆祝，你得把\(accept)讲得能复用，我才算真的被你说服。"
            case .oppose:
                return "\(quote) 现在这句话太轻，尤其是\(reject)这一块没处理，我不可能点头。"
            case .swing:
                return "\(quote) 我承认你的方向有用，但请把分歧收窄到一个能验证的判断。"
            }
        case .roundtable, .libraryPreview:
            return quote
        }
    }

    private func memoryNote(for request: ExpertAIRequest, persona: ExpertPersona, stance: ExpertStance) -> String {
        let anchor = persona.agreementTriggers.first ?? persona.role
        switch stance {
        case .support:
            return "\(persona.displayName) 记住了你从「\(anchor)」切入，下一轮更容易听进去。"
        case .oppose:
            return "\(persona.displayName) 仍保留反对，认为你还没处理他的核心边界。"
        case .swing:
            return "\(persona.displayName) 的立场出现松动，但还需要一个可验证例子。"
        }
    }

    private func stableSeed(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
    }
}

private struct RemoteExpertAIClient: ExpertAIClient {
    private struct PromptOnlyPersona: Encodable {
        let id: String
        let displayName: String
        let role: String
        let category: String
        let coreBelief: String
        let speechStyle: String
        let debateStyle: String
        let agreementTriggers: [String]
        let disagreementTriggers: [String]
        let catchphrases: [String]
        let safetyNotes: String

        init(_ persona: ExpertPersona) {
            id = persona.id
            displayName = persona.displayName
            role = persona.role
            category = persona.category
            coreBelief = persona.coreBelief
            speechStyle = persona.speechStyle
            debateStyle = persona.debateStyle
            agreementTriggers = persona.agreementTriggers
            disagreementTriggers = persona.disagreementTriggers
            catchphrases = persona.catchphrases
            safetyNotes = persona.safetyNotes
        }
    }

    private struct Payload: Encodable {
        let mode: String
        let modelHint: String
        let systemPrompt: String
        let personaPrompt: String
        let persona: PromptOnlyPersona
        let request: ExpertAIRequest
    }

    let endpoint: URL
    let personaStore: ExpertPersonaStore

    func reply(to request: ExpertAIRequest) async throws -> ExpertAIReply {
        let persona = personaStore.persona(forId: request.expertId)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval(for: request.scene)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(
            Payload(
                mode: "single-prompt",
                modelHint: "mimo-v2.5-pro",
                systemPrompt: ExpertPromptBuilder.systemPrompt(persona: persona, scene: request.scene),
                personaPrompt: ExpertPromptBuilder.personaPrompt(persona: persona),
                persona: PromptOnlyPersona(persona),
                request: request
            )
        )

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ExpertAIError.emptyResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ExpertAIError.badStatusCode(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(ExpertAIReply.self, from: data)
    }

    private func timeoutInterval(for scene: ExpertAIScene) -> TimeInterval {
        switch scene {
        case .roundtable:
            return 8
        case .libraryPreview:
            return 5
        case .battle:
            return 9
        }
    }
}

private final class ExpertAIRuntime: ObservableObject {
    private let personaStore: ExpertPersonaStore
    private let client: ExpertAIClient

    init(personaStore: ExpertPersonaStore) {
        self.personaStore = personaStore
        client = RemoteExpertAIClient(endpoint: Self.configuredEndpoint(), personaStore: personaStore)
    }

    func reply(to request: ExpertAIRequest) async throws -> ExpertAIReply {
        let reply = try await client.reply(to: request)
        await MainActor.run {
            personaStore.record(reply: reply, forExpertId: request.expertId)
        }
        return reply
    }

    private static func configuredEndpoint() -> URL {
        if let value = UserDefaults.standard.string(forKey: "ExpertAIEndpoint"),
           let url = URL(string: value),
           !value.isEmpty {
            return url
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "EXPERT_AI_ENDPOINT") as? String,
           let url = URL(string: value),
           !value.isEmpty {
            return url
        }
        return URL(string: "https://ios.classby.cn/clipclash/expert/reply")!
    }
}

private enum AppBGMScene {
    case normal
    case battle
    case highlight

    var clipName: String {
        switch self {
        case .normal:
            return "nromal"
        case .battle:
            return "battle"
        case .highlight:
            return "highlight"
        }
    }

    var volume: Float {
        switch self {
        case .normal:
            return 0.18
        case .battle:
            return 0.22
        case .highlight:
            return 0.20
        }
    }
}

private final class AppAudioSettings: ObservableObject {
    static let shared = AppAudioSettings()

    @Published var isBGMEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isBGMEnabled, forKey: "ClipClashBGMEnabled")
        }
    }

    @Published var isMuted: Bool {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: "ClipClashAudioMuted")
        }
    }

    private init() {
        if UserDefaults.standard.object(forKey: "ClipClashBGMEnabled") == nil {
            isBGMEnabled = true
        } else {
            isBGMEnabled = UserDefaults.standard.bool(forKey: "ClipClashBGMEnabled")
        }
        isMuted = UserDefaults.standard.bool(forKey: "ClipClashAudioMuted")
    }

    func toggleBGM() {
        isBGMEnabled.toggle()
    }

    func toggleMute() {
        isMuted.toggle()
    }
}

private enum AppAudioSession {
    static func configurePlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    static func restorePlaybackIfNeeded() {
        guard !AppAudioSettings.shared.isMuted else { return }
        try? configurePlayback()
    }
}

private func bundledVoiceClipURL(named name: String, extensions fileExtensions: [String] = ["mp3", "wav"]) -> URL? {
    for fileExtension in fileExtensions {
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "VoiceClips") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension) {
            return url
        }
    }
    return nil
}

private final class AppBGMPlayer {
    static let shared = AppBGMPlayer()

    private var player: AVAudioPlayer?
    private var currentClipName: String?

    private init() {}

    func play(_ scene: AppBGMScene) {
        playClip(named: scene.clipName, volume: scene.volume)
    }

    func playClip(named clipName: String?, volume: Float = 0.20) {
        guard AppAudioSettings.shared.isBGMEnabled, !AppAudioSettings.shared.isMuted else {
            stop()
            return
        }

        let resolvedClipName = clipName?.nilIfBlank ?? AppBGMScene.highlight.clipName
        if currentClipName == resolvedClipName, player?.isPlaying == true {
            return
        }

        stop()
        guard let url = bundledVoiceClipURL(named: resolvedClipName) else {
            if resolvedClipName != AppBGMScene.highlight.clipName {
                play(.highlight)
            }
            return
        }

        do {
            try AppAudioSession.configurePlayback()
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.numberOfLoops = -1
            newPlayer.volume = volume
            newPlayer.prepareToPlay()
            newPlayer.play()
            player = newPlayer
            currentClipName = resolvedClipName
        } catch {
            player = nil
            currentClipName = nil
            if resolvedClipName != AppBGMScene.highlight.clipName {
                play(.highlight)
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        currentClipName = nil
    }
}

private enum BattleSFX: String {
    case battleStart = "battle_start"
    case micOn = "mic_on"
    case micOff = "mic_off"
    case rebuttalHit = "rebuttal_hit"
    case persuasionUp = "persuasion_up"
    case battleWin = "battle_win"
    case battleLose = "battle_lose"
}

private final class SFXPlayer {
    static let shared = SFXPlayer()

    private var players: [AVAudioPlayer] = []

    private init() {}

    func play(_ effect: BattleSFX, volume: Float = 0.42) {
        guard !AppAudioSettings.shared.isMuted else {
            stopAll()
            return
        }

        players.removeAll { !$0.isPlaying }
        let url = bundledVoiceClipURL(named: effect.rawValue, extensions: ["mp3", "wav"])
        guard let url else { return }

        do {
            try AppAudioSession.configurePlayback()
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = volume
            player.numberOfLoops = 0
            player.prepareToPlay()
            player.play()
            players.append(player)
        } catch {
            players.removeAll { !$0.isPlaying }
        }
    }

    func stopAll() {
        players.forEach { $0.stop() }
        players.removeAll()
    }
}

private struct BattleRecordedAudio: Equatable {
    let url: URL
    let duration: TimeInterval

    var fileName: String {
        url.lastPathComponent
    }

    var durationText: String {
        let seconds = max(0, Int(duration.rounded()))
        return "\(seconds)s"
    }
}

private final class BattleVoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var lastRecording: BattleRecordedAudio?
    @Published private(set) var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var timer: Timer?

    var statusText: String {
        if isRecording {
            return "真实录音中 \(formatted(seconds: elapsedSeconds))"
        }
        if let lastRecording {
            return "已录制 \(lastRecording.fileName) · \(lastRecording.durationText)"
        }
        if let errorMessage {
            return errorMessage
        }
        return "点击麦克风开始真实录音"
    }

    func start(round: Int, battleId: UUID, expertName: String, completion: @escaping (Bool) -> Void) {
        requestPermission { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                self.errorMessage = "麦克风权限未开启，请在系统设置里允许录音。"
                completion(false)
                return
            }

            do {
                try self.configureAudioSession()
                let url = try self.makeRecordingURL(round: round, battleId: battleId, expertName: expertName)
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.delegate = self
                recorder.isMeteringEnabled = true
                recorder.prepareToRecord()
                recorder.record()

                self.recorder = recorder
                self.startedAt = Date()
                self.elapsedSeconds = 0
                self.lastRecording = nil
                self.errorMessage = nil
                self.isRecording = true
                self.startTimer()
                completion(true)
            } catch {
                self.errorMessage = "录音启动失败：\(error.localizedDescription)"
                self.cleanupRecordingState()
                completion(false)
            }
        }
    }

    @discardableResult
    func stop() -> BattleRecordedAudio? {
        guard let recorder else { return lastRecording }
        let url = recorder.url
        let duration = max(recorder.currentTime, startedAt.map { Date().timeIntervalSince($0) } ?? 0)
        recorder.stop()
        cleanupRecordingState()
        AppAudioSession.restorePlaybackIfNeeded()

        guard FileManager.default.fileExists(atPath: url.path), duration > 0.15 else {
            errorMessage = "录音时间太短，没有保存有效音频。"
            lastRecording = nil
            return nil
        }

        let recording = BattleRecordedAudio(url: url, duration: duration)
        lastRecording = recording
        return recording
    }

    func cancel() {
        recorder?.stop()
        if let url = recorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupRecordingState()
        AppAudioSession.restorePlaybackIfNeeded()
    }

    func resetForNextTurn() {
        if isRecording {
            cancel()
        }
        elapsedSeconds = 0
        lastRecording = nil
        errorMessage = nil
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async {
            if !flag {
                self.errorMessage = "录音未正常完成，请重新开麦。"
                self.cleanupRecordingState()
                AppAudioSession.restorePlaybackIfNeeded()
            }
        }
    }

    private func requestPermission(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                completion(true)
            case .denied:
                completion(false)
            case .undetermined:
                AVAudioApplication.requestRecordPermission { allowed in
                    DispatchQueue.main.async {
                        completion(allowed)
                    }
                }
            @unknown default:
                completion(false)
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted:
                completion(true)
            case .denied:
                completion(false)
            case .undetermined:
                session.requestRecordPermission { allowed in
                    DispatchQueue.main.async {
                        completion(allowed)
                    }
                }
            @unknown default:
                completion(false)
            }
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
        try session.setActive(true)
    }

    private func makeRecordingURL(round: Int, battleId: UUID, expertName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipClashBattleRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeExpert = expertName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let fileName = "battle-\(battleId.uuidString.prefix(8))-r\(round)-\(safeExpert).m4a"
        return directory.appendingPathComponent(fileName)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            self.elapsedSeconds = Int(Date().timeIntervalSince(startedAt).rounded(.down))
            self.recorder?.updateMeters()
        }
    }

    private func cleanupRecordingState() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        startedAt = nil
        isRecording = false
        elapsedSeconds = 0
    }

    private func formatted(seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

private final class BattleSpeechTranscriber: ObservableObject {
    @Published private(set) var isTranscribing = false
    @Published private(set) var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN"))

    func transcribe(_ recording: BattleRecordedAudio) async -> String? {
        await MainActor.run {
            isTranscribing = true
            errorMessage = nil
        }
        defer {
            Task { @MainActor in
                isTranscribing = false
            }
        }

        guard await requestAuthorization() else {
            await MainActor.run {
                errorMessage = "语音识别权限未开启，无法转写录音。"
            }
            return nil
        }

        guard let recognizer, recognizer.isAvailable else {
            await MainActor.run {
                errorMessage = "当前设备语音识别不可用，请稍后重试。"
            }
            return nil
        }

        return await withCheckedContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: recording.url)
            request.shouldReportPartialResults = false
            request.requiresOnDeviceRecognition = false

            var didResume = false
            func resumeOnce(_ value: String?) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: value)
            }

            recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let error {
                    Task { @MainActor in
                        self?.errorMessage = "语音转写失败：\(error.localizedDescription)"
                    }
                    resumeOnce(nil)
                    return
                }

                guard let result else { return }
                if result.isFinal {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    resumeOnce(text.isEmpty ? nil : text)
                }
            }
        }
    }

    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

private struct AppTransitionClip {
    let resourceName: String
    let headline: String
    let caption: String
    let tint: Color

    static func battleIntro(for expert: Expert) -> AppTransitionClip {
        AppTransitionClip(
            resourceName: "battle_clash_intro",
            headline: "BATTLE READY",
            caption: "正在载入 \(expert.name) 的反驳现场",
            tint: expert.tint
        )
    }

    static func battleMic(for expert: Expert) -> AppTransitionClip {
        AppTransitionClip(
            resourceName: "battle_clash_intro",
            headline: "MIC ONLINE",
            caption: "开麦通道已接入，准备说服 \(expert.name)",
            tint: expert.tint
        )
    }

    static let roundtableImport = AppTransitionClip(
        resourceName: "roundtable_import_intro",
        headline: "ROUND TABLE LIVE",
        caption: "正在把视频解析成专家辩题",
        tint: .cyan
    )
}

private final class MutedVideoPlayerViewModel: ObservableObject {
    let player: AVPlayer?

    init(resourceName: String) {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mp4", subdirectory: "VideoClips")
            ?? Bundle.main.url(forResource: resourceName, withExtension: "mp4") else {
            player = nil
            return
        }

        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        self.player = player
    }

    func play() {
        play(from: 0)
    }

    func play(from seconds: Double) {
        let start = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player?.seek(to: start)
        player?.play()
    }

    func stop() {
        player?.pause()
        player?.seek(to: .zero)
    }
}

private struct PixelVideoPlayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerContainerView: UIView {
        override static var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }
    }
}

private enum ForumHighlightResource {
    static let resourceName = "forum_highlight_demo"
    static let displayFileName = "pixel-roundtable-highlight.mp4"

    static var bundledURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "mp4", subdirectory: "VideoClips")
            ?? Bundle.main.url(forResource: resourceName, withExtension: "mp4")
    }

    static func exportableURL() -> URL? {
        guard let bundledURL else { return nil }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(displayFileName)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: bundledURL, to: destination)
            return destination
        } catch {
            return bundledURL
        }
    }
}

private struct ForumHighlightVideoDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.mpeg4Movie, .movie] }

    let sourceURL: URL

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: sourceURL, options: .immediate)
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ForumHighlightPlayerView: View {
    let topic: RoundtableTopic
    let onDismiss: () -> Void

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var exportDocument: ForumHighlightVideoDocument?
    @State private var isShowingExporter = false
    @State private var shareURL: URL?

    var body: some View {
        GeometryReader { proxy in
            let isPad = proxy.size.width >= 760
            ZStack {
                PixelBackground()
                    .ignoresSafeArea()

                VStack(spacing: isPad ? 18 : 14) {
                    header

                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.46))
                            .overlay(PixelGrid().opacity(0.35))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.32), lineWidth: 1))

                        if let player {
                            PixelVideoPlayer(player: player)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(PixelGrid().opacity(0.12))
                        } else {
                            VStack(spacing: 10) {
                                Image(systemName: "film.stack.fill")
                                    .font(.system(size: 36, weight: .black))
                                    .foregroundStyle(.yellow)
                                Text("精彩瞬间视频未找到")
                                    .font(.system(size: 14, weight: .black, design: .monospaced))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .shadow(color: .black.opacity(0.55), radius: 0, x: 7, y: 7)

                    controls
                }
                .frame(maxWidth: 980)
                .padding(.horizontal, isPad ? 34 : 18)
                .padding(.vertical, isPad ? 30 : 20)
            }
        }
        .onAppear {
            preparePlayer()
        }
        .onDisappear {
            player?.pause()
        }
        .fileExporter(
            isPresented: $isShowingExporter,
            document: exportDocument,
            contentType: .mpeg4Movie,
            defaultFilename: ForumHighlightResource.displayFileName
        ) { _ in
            exportDocument = nil
        }
        .sheet(item: Binding(
            get: { shareURL.map(ShareVideoItem.init(url:)) },
            set: { newValue in shareURL = newValue?.url }
        )) { item in
            ActivityShareSheet(items: [item.url])
                .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .background(.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Text("FORUM REPLAY")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(.orange)
                Text("回看本次论坛精彩瞬间")
                    .font(.system(size: 25, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                Text(topic.debate)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(14)
        .background(PixelPanel(fill: Color.white.opacity(0.10), stroke: Color.yellow.opacity(0.42)))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    togglePlayback()
                } label: {
                    Label(isPlaying ? "暂停" : "播放", systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(ForumHighlightButtonStyle(tint: .yellow, isPrimary: true))

                Button {
                    replay()
                } label: {
                    Label("重播", systemImage: "gobackward")
                }
                .buttonStyle(ForumHighlightButtonStyle(tint: .mint, isPrimary: false))
            }

            HStack(spacing: 10) {
                Button {
                    prepareDownload()
                } label: {
                    Label("下载", systemImage: "square.and.arrow.down.fill")
                }
                .buttonStyle(ForumHighlightButtonStyle(tint: .cyan, isPrimary: false))

                Button {
                    shareURL = ForumHighlightResource.exportableURL()
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up.fill")
                }
                .buttonStyle(ForumHighlightButtonStyle(tint: .orange, isPrimary: false))
            }
        }
        .disabled(ForumHighlightResource.bundledURL == nil)
    }

    private func preparePlayer() {
        guard player == nil, let url = ForumHighlightResource.bundledURL else { return }
        AppAudioSession.restorePlaybackIfNeeded()
        let newPlayer = AVPlayer(url: url)
        newPlayer.isMuted = AppAudioSettings.shared.isMuted
        newPlayer.volume = 1.0
        newPlayer.actionAtItemEnd = .pause
        player = newPlayer
        replay()
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            AppAudioSession.restorePlaybackIfNeeded()
            player.isMuted = AppAudioSettings.shared.isMuted
            player.play()
            isPlaying = true
        }
    }

    private func replay() {
        guard let player else { return }
        AppAudioSession.restorePlaybackIfNeeded()
        player.isMuted = AppAudioSettings.shared.isMuted
        player.seek(to: .zero)
        player.play()
        isPlaying = true
    }

    private func prepareDownload() {
        guard let url = ForumHighlightResource.exportableURL() else { return }
        exportDocument = ForumHighlightVideoDocument(sourceURL: url)
        isShowingExporter = true
    }
}

private struct ShareVideoItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ForumHighlightButtonStyle: ButtonStyle {
    let tint: Color
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .black, design: .monospaced))
            .foregroundStyle(isPrimary ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(isPrimary ? tint : Color.white.opacity(configuration.isPressed ? 0.18 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.58), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct ForumSharePosterView: View {
    let digest: ForumShareDigest
    let onDismiss: () -> Void

    @State private var renderedImage: UIImage?
    @State private var shareImage: ShareImageItem?
    @State private var saveStatus: String?

    private let posterWidth: CGFloat = 1080

    var body: some View {
        GeometryReader { proxy in
            let previewWidth = min(proxy.size.width - 32, 520)
            ZStack {
                PixelBackground()
                    .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 14) {
                        header

                        ForumSharePosterCanvas(digest: digest, width: posterWidth)
                            .frame(width: posterWidth)
                            .scaleEffect(previewWidth / posterWidth, anchor: .top)
                            .frame(width: previewWidth, height: posterHeight * previewWidth / posterWidth, alignment: .top)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.34), lineWidth: 1))
                            .shadow(color: .black.opacity(0.50), radius: 0, x: 7, y: 7)

                        controls
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            renderPosterIfNeeded()
        }
        .sheet(item: $shareImage) { item in
            ActivityShareSheet(items: [item.image])
                .presentationDetents([.medium, .large])
        }
    }

    private var posterHeight: CGFloat {
        ForumSharePosterCanvas.estimatedHeight(momentCount: digest.moments.count)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .background(.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Text("SHARE POSTER")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(.orange)
                Text("生成圆桌论坛长图")
                    .font(.system(size: 25, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                Text("图文精华已排成群聊式海报，可保存或分享")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(14)
        .background(PixelPanel(fill: Color.white.opacity(0.10), stroke: Color.mint.opacity(0.42)))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    renderPosterIfNeeded(force: true)
                } label: {
                    Label("刷新长图", systemImage: "wand.and.stars")
                }
                .buttonStyle(ForumHighlightButtonStyle(tint: .mint, isPrimary: false))

                Button {
                    if let image = renderedImage ?? renderPoster() {
                        shareImage = ShareImageItem(image: image)
                    }
                } label: {
                    Label("分享图片", systemImage: "square.and.arrow.up.fill")
                }
                .buttonStyle(ForumHighlightButtonStyle(tint: .yellow, isPrimary: true))
            }

            Button {
                savePosterToPhotos()
            } label: {
                Label("保存到相册", systemImage: "square.and.arrow.down.fill")
            }
            .buttonStyle(ForumHighlightButtonStyle(tint: .cyan, isPrimary: false))

            if let saveStatus {
                Text(saveStatus)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private func renderPosterIfNeeded(force: Bool = false) {
        if renderedImage != nil && !force { return }
        renderedImage = renderPoster()
    }

    private func renderPoster() -> UIImage? {
        let canvas = ForumSharePosterCanvas(digest: digest, width: posterWidth)
            .frame(width: posterWidth, height: posterHeight)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        return renderer.uiImage
    }

    private func savePosterToPhotos() {
        guard let image = renderedImage ?? renderPoster() else {
            saveStatus = "长图还没有生成成功"
            return
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        saveStatus = "已发送到系统相册保存队列"
    }
}

private struct ShareImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ForumSharePosterCanvas: View {
    let digest: ForumShareDigest
    let width: CGFloat

    static func estimatedHeight(momentCount: Int) -> CGFloat {
        450 + CGFloat(max(momentCount, 1)) * 148 + 156
    }

    private var posterPadding: CGFloat { 42 }
    private var contentWidth: CGFloat { width - posterPadding * 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            posterHeader

            VStack(spacing: 18) {
                ForEach(Array(digest.moments.prefix(12).enumerated()), id: \.element.id) { index, moment in
                    ForumShareChatRow(moment: moment, index: index, contentWidth: contentWidth)
                }
            }

            posterFooter
        }
        .padding(posterPadding)
        .frame(width: width, alignment: .topLeading)
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.05, blue: 0.10),
                        Color(red: 0.12, green: 0.08, blue: 0.18),
                        Color(red: 0.05, green: 0.08, blue: 0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                PixelGrid().opacity(0.30)
                VStack {
                    HStack {
                        Rectangle()
                            .fill(Color.yellow.opacity(0.24))
                            .frame(width: 210, height: 18)
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Rectangle()
                            .fill(Color.mint.opacity(0.20))
                            .frame(width: 240, height: 18)
                    }
                }
                .padding(28)
            }
        )
    }

    private var posterHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("PIXEL ROUNDTABLE")
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text("论坛精华长图")
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
                Spacer()
            }

            Text(digest.topic.debate)
                .font(.system(size: 48, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.62)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text(digest.subtitle)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text("\(digest.moments.count) 条观点")
                    .font(.system(size: 20, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.mint)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.09))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.18), lineWidth: 2))
    }

    private var posterFooter: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("从视频到圆桌，从观点到说服")
                    .font(.system(size: 20, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                Text("自动生成于像素圆桌")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.56))
            }

            Spacer()

            HStack(spacing: 12) {
                Image("AppIcon")
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.35), lineWidth: 2))

                VStack(alignment: .leading, spacing: 4) {
                    Text("像素圆桌")
                        .font(.system(size: 26, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("Pixel Roundtable")
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundStyle(.yellow)
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.38))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.38), lineWidth: 1))
        }
        .padding(.top, 8)
    }
}

private struct ForumShareChatRow: View {
    let moment: ForumShareMoment
    let index: Int
    let contentWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            avatar

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(moment.expertName)
                        .font(.system(size: 22, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                    Text(moment.role)
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundStyle(moment.tint)
                    Spacer()
                    Text(moment.phaseTitle)
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(moment.side.color)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                Text(moment.quote)
                    .font(.system(size: 25, weight: .black, design: .monospaced))
                    .foregroundStyle(Color(red: 0.08, green: 0.07, blue: 0.08))
                    .lineLimit(4)
                    .minimumScaleFactor(0.66)
                    .fixedSize(horizontal: false, vertical: true)

                if let targetName = moment.targetName {
                    Text("回应 \(targetName) · \(stanceLabel)")
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.62))
                }
            }
            .padding(18)
            .frame(width: contentWidth - 112, alignment: .leading)
            .background(
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: 1.0, green: 0.96, blue: 0.78))
                    Rectangle()
                        .fill(moment.tint.opacity(0.70))
                        .frame(height: 9)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.78), lineWidth: 3))
            .shadow(color: .black.opacity(0.38), radius: 0, x: 7, y: 7)
        }
        .frame(width: contentWidth, alignment: .leading)
    }

    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(moment.tint.opacity(0.22))
                .frame(width: 88, height: 88)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(moment.tint.opacity(0.78), lineWidth: 2))

            if let assetPrefix = moment.petAssetPrefix {
                PetFrameImage(assetPrefix: assetPrefix, state: "Speaking", frame: index % 4)
                    .frame(width: 74, height: 82)
            } else {
                Text(String(moment.expertName.prefix(1)))
                    .font(.system(size: 34, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .frame(width: 62, height: 62)
                    .background(moment.tint)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    private var stanceLabel: String {
        switch moment.stance {
        case .support:
            return "支持"
        case .oppose:
            return "反驳"
        case .swing:
            return "追问"
        }
    }
}

private struct VideoTransitionOverlay: View {
    let clip: AppTransitionClip
    let onFinished: () -> Void

    @StateObject private var viewModel: MutedVideoPlayerViewModel
    @State private var visible = false
    @State private var fallbackPulse = false

    init(clip: AppTransitionClip, onFinished: @escaping () -> Void) {
        self.clip = clip
        self.onFinished = onFinished
        _viewModel = StateObject(wrappedValue: MutedVideoPlayerViewModel(resourceName: clip.resourceName))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.84)
                .ignoresSafeArea()

            if let player = viewModel.player {
                PixelVideoPlayer(player: player)
                    .ignoresSafeArea()
                    .overlay(PixelGrid().opacity(0.22))
                    .overlay(Color.black.opacity(0.12))
            } else {
                fallbackTransition
            }

            VStack(spacing: 10) {
                Text(clip.headline)
                    .font(.system(size: 34, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .shadow(color: clip.tint.opacity(0.88), radius: 0, x: 4, y: 4)
                    .minimumScaleFactor(0.62)
                    .lineLimit(1)

                Text(clip.caption)
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(clip.tint)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 76)
        }
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 1.035)
        .onAppear {
            viewModel.play()
            withAnimation(.easeOut(duration: 0.18)) {
                visible = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.9) {
                dismiss()
            }
        }
        .onDisappear {
            viewModel.stop()
        }
        .accessibilityHidden(true)
    }

    private var fallbackTransition: some View {
        ZStack {
            PixelBackground()

            Circle()
                .stroke(clip.tint.opacity(0.82), lineWidth: 10)
                .frame(width: fallbackPulse ? 310 : 210, height: fallbackPulse ? 310 : 210)
                .opacity(fallbackPulse ? 0.08 : 0.74)

            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.red.opacity(0.72))
                    .frame(width: fallbackPulse ? 190 : 84, height: 92)
                Rectangle()
                    .fill(Color.yellow.opacity(0.82))
                    .frame(width: 26, height: 280)
                Rectangle()
                    .fill(Color.cyan.opacity(0.72))
                    .frame(width: fallbackPulse ? 190 : 84, height: 92)
            }
            .animation(.easeInOut(duration: 0.74).repeatForever(autoreverses: true), value: fallbackPulse)
        }
        .onAppear {
            fallbackPulse = true
        }
    }

    private func dismiss() {
        withAnimation(.easeIn(duration: 0.22)) {
            visible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            viewModel.stop()
            onFinished()
        }
    }
}

struct Expert: Identifiable {
    enum Side {
        case pro
        case con
        case swing

        var color: Color {
            switch self {
            case .pro: return .mint
            case .con: return .red
            case .swing: return .yellow
            }
        }
    }

    let id = UUID()
    let name: String
    let role: String
    let initials: String
    var side: Side
    let tint: Color
    var seat: CGPoint
    var quote: String
    var petAssetPrefix: String?
}

private enum RoundTableDebatePhase: Int, CaseIterable {
    case stance = 1
    case rebuttal = 2
    case closing = 3

    var title: String {
        switch self {
        case .stance:
            return "立场亮相"
        case .rebuttal:
            return "定向反驳"
        case .closing:
            return "收束攻防"
        }
    }

    var detail: String {
        switch self {
        case .stance:
            return "先锁定每位专家的站边和核心论点"
        case .rebuttal:
            return "按立场距离点名反驳对方漏洞"
        case .closing:
            return "回应攻击，选择反击、松动或结盟"
        }
    }

    var promptGoal: String {
        switch self {
        case .stance:
            return "Round 1 只做立场亮相：明确支持/反对/摇摆，说出核心理由，并预判最可能被反驳的点。"
        case .rebuttal:
            return "Round 2 做定向反驳：必须点名攻击目标，引用或概括对方观点，指出一个具体漏洞。"
        case .closing:
            return "Round 3 做收束攻防：必须回应上一轮攻击关系，可以强反击、承认一半再补刀、追问证据，或临时支持另一位专家。"
        }
    }

    var label: String {
        "ROUND 0\(rawValue)"
    }
}

private struct RoundTableDebateStatus: Equatable {
    var phase: RoundTableDebatePhase?
    var activeExpertName: String?
    var isGenerating: Bool
    var detail: String

    static let idle = RoundTableDebateStatus(
        phase: nil,
        activeExpertName: nil,
        isGenerating: false,
        detail: "等待圆桌开局"
    )

    var roundLabel: String {
        phase?.label ?? "ROUND"
    }

    var title: String {
        phase?.title ?? "等待开会"
    }

    var subtitle: String {
        if let activeExpertName, isGenerating {
            return "\(activeExpertName) 正在接话"
        }
        return detail
    }
}

private struct RoundTableStanceEntry {
    let expertId: UUID
    let expertName: String
    var side: Expert.Side
    var stance: ExpertStance
    var stanceScore: Double
    var confidence: Double
    var coreClaim: String
    var weakPoint: String
    var attackAngle: String
    var lastTargetName: String?
    var attackedBy: [String]
    var turnCount: Int
}

private struct RoundTableTurnResult {
    let expert: Expert
    let phase: RoundTableDebatePhase
    let turnIndex: Int
    let targetName: String?
    let reply: ExpertAIReply
    let quote: String
    var voiceClipName: String? = nil
}

private struct RoundTableUserInterjection: Identifiable, Equatable {
    let id = UUID()
    let sequence: Int
    let text: String
}

private struct ForumShareMoment: Identifiable, Equatable {
    let id = UUID()
    let expertName: String
    let role: String
    let side: Expert.Side
    let tint: Color
    let petAssetPrefix: String?
    let phaseTitle: String
    let targetName: String?
    let quote: String
    let stance: ExpertStance
}

private struct ForumShareDigest: Equatable {
    let topic: RoundtableTopic
    let moments: [ForumShareMoment]
    let generatedAt: Date

    var subtitle: String {
        let controversy = topic.controversy ?? topic.hook
        return controversy.isEmpty ? topic.source : controversy
    }
}

struct DemoTopic {
    let source: String
    let debate: String
    let hook: String
    let experts: [Expert]
}

struct ExpertLibraryEntry: Identifiable {
    let id = UUID()
    let name: String
    let role: String
    let petId: String
    let initials: String
    let category: String
    let status: String
    let note: String
    let tint: Color
    var assetPrefix: String?
    var voiceClipName: String?
    var debutLine: String?

    var bgmClipName: String {
        "bgm_\(personaId(forDisplayName: name).replacingOccurrences(of: "-", with: "_"))"
    }
}

private enum AppTab {
    case roundtable
    case battle
    case library
    case settings
}

private enum SpotlightPresentationMode: Equatable {
    case debut
    case preview
    case screenshot

    var badge: String {
        switch self {
        case .debut:
            return "SPECIAL GUEST"
        case .preview:
            return "SPOTLIGHT PREVIEW"
        case .screenshot:
            return "SPECIAL GUEST"
        }
    }

    var caption: String {
        switch self {
        case .debut:
            return "加入圆桌"
        case .preview:
            return "长按预览"
        case .screenshot:
            return "加入圆桌"
        }
    }

    var autoCompleteDelay: Double? {
        switch self {
        case .debut:
            return 3.8
        case .preview, .screenshot:
            return nil
        }
    }

    var canDismiss: Bool {
        self == .preview
    }
}

private final class SpotlightVoicePlayer {
    static let shared = SpotlightVoicePlayer()

    private var player: AVAudioPlayer?

    private init() {}

    @discardableResult
    func play(clipName: String?, rate: Float = 1.0) -> TimeInterval {
        stop()
        guard !AppAudioSettings.shared.isMuted else {
            return 0
        }

        guard let clipName, let url = bundledVoiceClipURL(named: clipName) else {
            return 0
        }

        do {
            try AppAudioSession.configurePlayback()
            player = try AVAudioPlayer(contentsOf: url)
            player?.enableRate = true
            player?.rate = min(max(rate, 0.55), 1.25)
            player?.prepareToPlay()
            player?.play()
            return (player?.duration ?? 0) / TimeInterval(player?.rate ?? 1)
        } catch {
            player = nil
            return 0
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }
}

private struct SpotlightPresentation: Identifiable {
    let id = UUID()
    let entry: ExpertLibraryEntry
    let mode: SpotlightPresentationMode
}

private struct RoundTableToBattleOverlay: View {
    let context: BattleLaunchContext
    let onComplete: () -> Void

    @State private var phase = 0
    @State private var didComplete = false
    @State private var pulse = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                PixelBackground()
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.82),
                        context.tint.opacity(0.30),
                        Color.black.opacity(0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                PixelGrid()
                    .opacity(0.32)
                    .ignoresSafeArea()

                VStack(spacing: size.width >= 760 ? 22 : 16) {
                    VStack(spacing: 7) {
                        Text("POINTED BATTLE")
                            .font(.system(size: size.width >= 760 ? 18 : 13, weight: .black, design: .monospaced))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(context.tint)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .shadow(color: context.tint.opacity(0.52), radius: 16)

                        Text("圆桌分歧正在收束成 1v1 说服战")
                            .font(.system(size: size.width >= 760 ? 15 : 12, weight: .black, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.78))
                            .multilineTextAlignment(.center)
                    }
                    .opacity(phase >= 0 ? 1 : 0)

                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.38))
                            .overlay(PixelGrid().opacity(0.35))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(context.tint.opacity(pulse ? 0.92 : 0.42), lineWidth: 2)
                            )
                            .shadow(color: context.tint.opacity(pulse ? 0.42 : 0.18), radius: pulse ? 28 : 10)

                        Image("RoundTable")
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: min(size.width * 0.62, 520))
                            .opacity(0.38)
                            .offset(y: 18)

                        HStack(spacing: size.width >= 760 ? 24 : 14) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("圆桌刚才卡住了")
                                    .font(.system(size: 12, weight: .black, design: .monospaced))
                                    .foregroundStyle(.yellow)
                                Text(context.conflictPoint)
                                    .font(.system(size: size.width >= 760 ? 26 : 20, weight: .black, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.72)
                                Text(context.roundtableSummary)
                                    .font(.system(size: size.width >= 760 ? 13 : 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.70))
                                    .lineLimit(3)
                                    .minimumScaleFactor(0.72)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            VStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(context.tint.opacity(0.18))
                                        .frame(width: size.width >= 760 ? 150 : 110, height: size.width >= 760 ? 164 : 124)
                                    if let assetPrefix = context.petAssetPrefix {
                                        AnimatedPetView(assetPrefix: assetPrefix, state: "Opposed", fps: 7)
                                            .frame(width: size.width >= 760 ? 128 : 92, height: size.width >= 760 ? 138 : 100)
                                            .scaleEffect(pulse ? 1.06 : 0.98)
                                    } else {
                                        Text(String(context.expertName.prefix(1)))
                                            .font(.system(size: size.width >= 760 ? 44 : 32, weight: .black, design: .monospaced))
                                            .foregroundStyle(.black)
                                            .frame(width: size.width >= 760 ? 104 : 78, height: size.width >= 760 ? 104 : 78)
                                            .background(context.tint)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }

                                Text(context.expertName)
                                    .font(.system(size: size.width >= 760 ? 16 : 12, weight: .black, design: .monospaced))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(context.tint)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                            .opacity(phase >= 1 ? 1 : 0)
                            .offset(x: phase >= 1 ? 0 : 26)
                        }
                        .padding(size.width >= 760 ? 24 : 16)
                    }
                    .frame(height: size.width >= 760 ? 278 : 238)
                    .scaleEffect(phase >= 1 ? 1 : 0.96)
                    .animation(.spring(response: 0.38, dampingFraction: 0.76), value: phase)

                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "scope")
                                .font(.system(size: 12, weight: .black))
                            Text(context.triggerReason)
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.yellow)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                        Text(context.openingChallengeLine)
                            .font(.system(size: size.width >= 760 ? 17 : 13, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.72)
                            .padding(.horizontal, size.width >= 760 ? 34 : 10)

                        Text(context.userGoal)
                            .font(.system(size: size.width >= 760 ? 13 : 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(context.tint)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                    }
                    .opacity(phase >= 2 ? 1 : 0)
                    .offset(y: phase >= 2 ? 0 : 18)

                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { index in
                            Rectangle()
                                .fill(index <= phase ? context.tint : Color.white.opacity(0.20))
                                .frame(width: 42, height: 6)
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                    }
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 22)
            }
        }
        .onAppear {
            startSequence()
        }
    }

    private func startSequence() {
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            pulse = true
        }
        for index in 1...2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.62) {
                phase = index
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.35) {
            guard !didComplete else { return }
            didComplete = true
            onComplete()
        }
    }
}

private struct ExpertTraitProfile {
    struct Meter: Identifiable {
        let id = UUID()
        let label: String
        let value: Int
    }

    let angle: String
    let meters: [Meter]
}

private struct BattleTurnMessage: Identifiable, Equatable {
    let id = UUID()
    let speaker: String
    let text: String
    let isPlayer: Bool
    var round: Int? = nil
}

private struct BattleRound: Identifiable, Equatable {
    let id: Int
    let userPrompt: String
    let aiGoal: String
}

private enum BattleResult: String, Equatable {
    case win
    case lose
    case draw
    case expertSoftened
    case expertUnmoved

    var title: String {
        switch self {
        case .win:
            return "你赢下 Battle"
        case .lose:
            return "专家守住立场"
        case .draw:
            return "本局平手"
        case .expertSoftened:
            return "专家明显松动"
        case .expertUnmoved:
            return "专家仍然不服"
        }
    }

    var badge: String {
        switch self {
        case .win:
            return "WIN"
        case .lose:
            return "LOSE"
        case .draw:
            return "DRAW"
        case .expertSoftened:
            return "SOFTEN"
        case .expertUnmoved:
            return "UNMOVED"
        }
    }

    var tint: Color {
        switch self {
        case .win, .expertSoftened:
            return .mint
        case .lose, .expertUnmoved:
            return .red
        case .draw:
            return .yellow
        }
    }

    var side: Expert.Side {
        switch self {
        case .win, .expertSoftened:
            return .pro
        case .lose, .expertUnmoved:
            return .con
        case .draw:
            return .swing
        }
    }
}

private struct BattleScore: Equatable {
    var user: Double
    var expert: Double

    var leaderText: String {
        let diff = user - expert
        if diff > 0.12 { return "你方占优" }
        if diff < -0.12 { return "专家占优" }
        return "势均力敌"
    }
}

private struct BattleCompletion {
    let expertId: UUID
    let expertName: String
    let result: BattleResult
    let quote: String
    let side: Expert.Side
    let persuasion: Double
    let openness: Double
    let reason: String
}

private enum BattleEvent: Identifiable, Equatable {
    case userTurnStarted(Int)
    case userSubmitted(Int, String)
    case aiReply(Int, String)
    case metricShift(String)
    case completed(BattleResult)

    var id: String {
        switch self {
        case .userTurnStarted(let round):
            return "user-\(round)"
        case .userSubmitted(let round, let text):
            return "submitted-\(round)-\(text)"
        case .aiReply(let round, let text):
            return "ai-\(round)-\(text)"
        case .metricShift(let text):
            return "metric-\(text)"
        case .completed(let result):
            return "completed-\(result.rawValue)"
        }
    }
}

private enum BattlePhase: Equatable {
    case preparing
    case intro
    case userTurn(round: Int)
    case transcribing(round: Int)
    case aiThinking(round: Int)
    case aiSpeaking(round: Int)
    case evaluating
    case completed(result: BattleResult)
    case backgroundWatching

    var roundIndex: Int? {
        switch self {
        case .userTurn(let round), .transcribing(let round), .aiThinking(let round), .aiSpeaking(let round):
            return round
        case .preparing, .intro, .evaluating, .completed, .backgroundWatching:
            return nil
        }
    }

    var label: String {
        switch self {
        case .preparing:
            return "准备开战"
        case .intro:
            return "过场载入"
        case .userTurn:
            return "你的回合"
        case .transcribing:
            return "实时转写"
        case .aiThinking:
            return "AI 5 秒思考"
        case .aiSpeaking:
            return "专家反击"
        case .evaluating:
            return "裁决计算"
        case .completed:
            return "Battle 结束"
        case .backgroundWatching:
            return "后台 3v3"
        }
    }

    var isUserActive: Bool {
        if case .userTurn = self { return true }
        return false
    }

    var isAIThinking: Bool {
        if case .aiThinking = self { return true }
        return false
    }
}

private struct BattleSideStatus: Equatable {
    var triggerReason: String
    var userSideCount: Int
    var expertSideCount: Int
    var selectedExpertSide: Expert.Side

    var label: String {
        "\(userSideCount)v\(expertSideCount) \(triggerReason)"
    }
}

private struct BattleLaunchContext: Identifiable, Equatable {
    let id = UUID()
    let expertId: UUID
    let expertName: String
    let topic: String
    let triggerReason: String
    let conflictPoint: String
    let expertLastQuote: String
    let userGoal: String
    let roundtableSummary: String
    let openingChallengeLine: String
    let sideStatus: BattleSideStatus
    let tint: Color
    let petAssetPrefix: String?
}

private struct BattleSessionState: Equatable {
    var battleId: UUID = UUID()
    var expertId: String
    var expertName: String
    var topic: String
    var roundIndex: Int = 1
    let maxRounds: Int = 3
    let userTimeLimit: Int = 60
    let aiResponseTargetSeconds: Int = 5
    var remainingSeconds: Int = 60
    var messages: [BattleTurnMessage]
    var persuasion: Double
    var resistance: Double
    var openness: Double
    var score: BattleScore
    var decisiveMoments: [String] = []
    var events: [BattleEvent] = []
    var currentPhase: BattlePhase = .preparing
    var startedAt: Date? = nil
    var endedAt: Date? = nil
    var resultReason: String? = nil
    var latestTranscript: String = ""
    var finalQuote: String? = nil

    var result: BattleResult? {
        if case .completed(let result) = currentPhase {
            return result
        }
        return nil
    }

    var visibleMessages: [BattleTurnMessage] {
        let currentRoundMessages = messages.filter { $0.round == roundIndex }
        return currentRoundMessages.isEmpty ? Array(messages.suffix(5)) : Array(currentRoundMessages.suffix(6))
    }
}

private enum BattleMood {
    case challenging
    case listening
    case thinking
    case softened

    var label: String {
        switch self {
        case .challenging:
            return "正在反驳"
        case .listening:
            return "正在听你说"
        case .thinking:
            return "正在思考"
        case .softened:
            return "立场松动"
        }
    }

    var petState: String {
        switch self {
        case .challenging:
            return "Opposed"
        case .listening, .thinking:
            return "Speaking"
        case .softened:
            return "Supported"
        }
    }
}

private enum ExpertReaction: Equatable {
    case support
    case oppose

    var petState: String {
        switch self {
        case .support:
            return "Supported"
        case .oppose:
            return "Opposed"
        }
    }

    var title: String {
        switch self {
        case .support:
            return "赞同"
        case .oppose:
            return "反对"
        }
    }

    var icon: String {
        switch self {
        case .support:
            return "hand.thumbsup.fill"
        case .oppose:
            return "hand.thumbsdown.fill"
        }
    }

    var tint: Color {
        switch self {
        case .support:
            return .mint
        case .oppose:
            return .red
        }
    }

    var stampText: String {
        switch self {
        case .support:
            return "SUPPORT"
        case .oppose:
            return "OPPOSE"
        }
    }
}

private let roundTableMaxExperts = 6

private let roundTableSeats = [
    CGPoint(x: 0.50, y: 0.13),
    CGPoint(x: 0.22, y: 0.26),
    CGPoint(x: 0.78, y: 0.26),
    CGPoint(x: 0.17, y: 0.58),
    CGPoint(x: 0.83, y: 0.58),
    CGPoint(x: 0.50, y: 0.76)
]

private let demoTopic = DemoTopic(
    source: "Douyin Selected Clip",
    debate: "县城六千，真的比城市两万更舒坦吗？",
    hook: "一条县域生活视频，把收入、成本、关系、机会和自由感全部摆上圆桌。",
    experts: [
        Expert(name: "张雪峰", role: "教育观察员", initials: "张", side: .con, tint: .yellow, seat: roundTableSeats[0], quote: "县城六千不一定差，但你得先问十年后还涨不涨。", petAssetPrefix: "PetZhangXuefeng"),
        Expert(name: "Claude", role: "逻辑裁判", initials: "C", side: .swing, tint: .purple, seat: roundTableSeats[1], quote: "舒坦不是收入数字，而是时间、风险和选择权的函数。", petAssetPrefix: "PetClawd"),
        Expert(name: "豆包", role: "生活助理", initials: "豆", side: .pro, tint: .green, seat: roundTableSeats[2], quote: "能吃好饭、陪家人、睡得着，六千也可能很踏实。", petAssetPrefix: "PetDoubaoHuman"),
        Expert(name: "雷军", role: "硬件 / 发布会", initials: "雷", side: .pro, tint: .blue, seat: roundTableSeats[3], quote: "生活也看总拥有成本，体验值不是工资条一个数。", petAssetPrefix: "PetLeiJun"),
        Expert(name: "张一鸣", role: "产品 / 平台", initials: "鸣", side: .con, tint: .green, seat: roundTableSeats[4], quote: "城市两万买的是高密度信息和长期选择权。", petAssetPrefix: "PetZhangYiming"),
        Expert(name: "Musk", role: "科技冒险家", initials: "M", side: .con, tint: .cyan, seat: roundTableSeats[5], quote: "如果目标是上限，舒坦不是第一指标，速度才是。", petAssetPrefix: "PetMuskie")
    ]
)

private let expertLibraryFilters = ["全部", "圆桌常驻", "商业科技", "有趣角色", "动漫推理"]

private let expertLibraryEntries: [ExpertLibraryEntry] = [
    ExpertLibraryEntry(name: "Musk", role: "科技冒险家", petId: "muskie", initials: "M", category: "圆桌常驻", status: "已导入", note: "当前圆桌常驻，适合科技与冒险判断", tint: .cyan, assetPrefix: "PetMuskie", voiceClipName: "musk_go_to_mars", debutLine: "Go to Mars."),
    ExpertLibraryEntry(name: "Trump", role: "气氛型辩手", petId: "trump", initials: "T", category: "圆桌常驻", status: "已导入", note: "当前圆桌常驻，适合强情绪反方表达", tint: .red, assetPrefix: "PetTrump", voiceClipName: "trump_make_america_great_again", debutLine: "Make America Great Again!"),
    ExpertLibraryEntry(name: "豆包", role: "生活助理", petId: "doubao-human", initials: "豆", category: "圆桌常驻", status: "已导入", note: "当前圆桌常驻，适合生活化解释", tint: .green, assetPrefix: "PetDoubaoHuman", voiceClipName: "doubao_catch_you", debutLine: "我会稳稳接住你。"),
    ExpertLibraryEntry(name: "Claude", role: "逻辑裁判", petId: "clawd", initials: "C", category: "圆桌常驻", status: "已导入", note: "当前圆桌常驻，适合梳理争议变量", tint: .purple, assetPrefix: "PetClawd", voiceClipName: "claude_clear_logic", debutLine: "我先把逻辑理清楚。"),
    ExpertLibraryEntry(name: "张雪峰", role: "教育观察员", petId: "zhangxuefeng", initials: "张", category: "圆桌常驻", status: "已导入", note: "当前圆桌常驻，适合选择与赛道类吐槽", tint: .yellow, assetPrefix: "PetZhangXuefeng", voiceClipName: "zhangxuefeng_run_faster", debutLine: "你跑不过我，你信吗？"),
    ExpertLibraryEntry(name: "雷军", role: "硬件 / 发布会", petId: "leijunpet", initials: "雷", category: "商业科技", status: "已导入", note: "适合商业、产品、营销语气", tint: .blue, assetPrefix: "PetLeiJun", voiceClipName: "leijun_are_you_ok", debutLine: "Are you OK?"),
    ExpertLibraryEntry(name: "张一鸣", role: "产品 / 平台", petId: "zhang-yiming", initials: "鸣", category: "商业科技", status: "已导入", note: "适合产品、平台、算法分发判断", tint: .green, assetPrefix: "PetZhangYiming", voiceClipName: "zhangyiming_life_30000_days", debutLine: "人生有限三万天，坦率真诚，少装一点。"),
    ExpertLibraryEntry(name: "Sam Altman", role: "AI 产品", petId: "sam", initials: "S", category: "商业科技", status: "已导入", note: "适合 AI 公司代表和产品判断", tint: .mint, assetPrefix: "PetSam", voiceClipName: "sam_too_cheap_to_meter", debutLine: "Too cheap to meter."),
    ExpertLibraryEntry(name: "Einstein", role: "科学脑洞", petId: "einstein", initials: "E", category: "商业科技", status: "已导入", note: "适合科学解释和第一性原理", tint: .yellow, assetPrefix: "PetEinstein", voiceClipName: "einstein_emc2", debutLine: "E is equal to m c-squared."),
    ExpertLibraryEntry(name: "Newton", role: "基础原理", petId: "newton", initials: "N", category: "商业科技", status: "已导入", note: "适合第一性原理、基础科学和因果拆解", tint: .orange, assetPrefix: "PetNewton", voiceClipName: "newton_first_principle", debutLine: "先看力从哪里来。"),
    ExpertLibraryEntry(name: "黄仁勋", role: "芯片 / AI 算力", petId: "jensen-huang", initials: "黄", category: "商业科技", status: "已导入", note: "适合 AI 芯片、GPU、算力、产业链和发布会判断", tint: .green, assetPrefix: "PetJensenHuang", voiceClipName: "jensen_more_you_buy_more_you_save", debutLine: "The more you buy, the more you save."),
    ExpertLibraryEntry(name: "乌萨奇", role: "气氛破坏王", petId: "usachi", initials: "兔", category: "有趣角色", status: "已导入", note: "适合轻松、夸张、短句吐槽", tint: .orange, assetPrefix: "PetUsachi", voiceClipName: "usachi_yaha", debutLine: "ヤハーッ！"),
    ExpertLibraryEntry(name: "小八", role: "可爱共情派", petId: "xiaoba", initials: "八", category: "有趣角色", status: "已导入", note: "适合温和解释和观众缘", tint: .cyan, assetPrefix: "PetXiaoba", voiceClipName: "xiaoba_nantoka_nare", debutLine: "なんとかなれーッ！"),
    ExpertLibraryEntry(name: "奶龙", role: "大笑气氛位", petId: "happynailong", initials: "龙", category: "有趣角色", status: "已导入", note: "适合欢乐、夸张、暖场表达", tint: .yellow, assetPrefix: "PetHappyNailong", voiceClipName: "nailoong_i_am_nailoong", debutLine: "我是奶龙，我才是真的奶龙。"),
    ExpertLibraryEntry(name: "Bubu", role: "熊系气氛位", petId: "bubu", initials: "熊", category: "有趣角色", status: "已导入", note: "适合憨厚、轻松、暖场表达", tint: .brown, assetPrefix: "PetBubu", voiceClipName: nil, debutLine: "轻松一点，我来了。"),
    ExpertLibraryEntry(name: "Rilakkuma", role: "轻松熊替代", petId: "rilakkuma", initials: "熊", category: "有趣角色", status: "已导入", note: "更软萌的熊系候选", tint: .orange, assetPrefix: "PetRilakkuma", voiceClipName: "rilakkuma_uh", debutLine: "嗯？"),
    ExpertLibraryEntry(name: "L", role: "冷静推理", petId: "l", initials: "L", category: "动漫推理", status: "已导入", note: "素材库有 Death Note L", tint: .white, assetPrefix: "PetL", voiceClipName: "l_i_want_to_tell_you_i_am_l", debutLine: "I want to tell you, I'm L."),
    ExpertLibraryEntry(name: "Misa", role: "戏剧化观点", petId: "misa-amane", initials: "M", category: "动漫推理", status: "已导入", note: "适合情绪张力和反常识表达", tint: .pink, assetPrefix: "PetMisa", voiceClipName: "misa_misamisa_kira_desu", debutLine: "弥海砂最棒！最尊敬的人是基拉。"),
    ExpertLibraryEntry(name: "柯南", role: "证据派侦探", petId: "conan", initials: "柯", category: "动漫推理", status: "已导入", note: "适合事实核查和细节追问", tint: .blue, assetPrefix: "PetConan", voiceClipName: "conan_shinjitsu_hitotsu", debutLine: "真相永远只有一个。"),
    ExpertLibraryEntry(name: "路飞", role: "热血乐观派", petId: "tiny-luffy", initials: "路", category: "动漫推理", status: "已导入", note: "适合热血、直觉、行动派", tint: .red, assetPrefix: "PetLuffy", voiceClipName: "luffy_kaizoku_ou_ore_wa_naru", debutLine: "我要成为海贼王！")
]

private extension SharedExpertLibraryProfile {
    static let demoFriend = SharedExpertLibraryProfile(
        id: UUID(uuidString: "7D68D584-532D-431E-921A-BB99FE770E1C") ?? UUID(),
        ownerName: "Alex",
        sourceLabel: "扫码导入",
        importedAt: Date(timeIntervalSince1970: 1_780_000_000),
        experts: [
            SharedExpertSnapshot(
                personaId: personaId(forDisplayName: "Claude"),
                name: "Claude",
                role: "逻辑裁判",
                assetPrefix: "PetClawd",
                understanding: 5,
                taming: 5,
                consensus: 4,
                memoryNote: "被 Alex 训练成先列变量、再给三表决策框架。"
            ),
            SharedExpertSnapshot(
                personaId: personaId(forDisplayName: "张一鸣"),
                name: "张一鸣",
                role: "产品 / 平台",
                assetPrefix: "PetZhangYiming",
                understanding: 4,
                taming: 5,
                consensus: 4,
                memoryNote: "更容易接受净现金流、时间自由和机会密度的组合判断。"
            ),
            SharedExpertSnapshot(
                personaId: personaId(forDisplayName: "豆包"),
                name: "豆包",
                role: "生活助理",
                assetPrefix: "PetDoubaoHuman",
                understanding: 5,
                taming: 4,
                consensus: 5,
                memoryNote: "偏向先照顾身体、家庭关系和睡眠质量。"
            ),
            SharedExpertSnapshot(
                personaId: personaId(forDisplayName: "雷军"),
                name: "雷军",
                role: "硬件 / 发布会",
                assetPrefix: "PetLeiJun",
                understanding: 4,
                taming: 4,
                consensus: 4,
                memoryNote: "习惯用总拥有成本解释生活选择。"
            ),
            SharedExpertSnapshot(
                personaId: personaId(forDisplayName: "Musk"),
                name: "Musk",
                role: "科技冒险家",
                assetPrefix: "PetMuskie",
                understanding: 3,
                taming: 4,
                consensus: 2,
                memoryNote: "仍然追求上限，但会承认县城可以作为低成本基地。"
            ),
            SharedExpertSnapshot(
                personaId: personaId(forDisplayName: "张雪峰"),
                name: "张雪峰",
                role: "教育观察员",
                assetPrefix: "PetZhangXuefeng",
                understanding: 4,
                taming: 3,
                consensus: 3,
                memoryNote: "会优先追问职业天花板、教育医疗和长期涨薪。"
            )
        ]
    )
}

private func fallbackTraitProfile(for entry: ExpertLibraryEntry) -> ExpertTraitProfile {
    switch entry.name {
    case "Trump":
        return ExpertTraitProfile(
            angle: "接受点：赢、气势、简单口号",
            meters: [
                .init(label: "理解度", value: 2),
                .init(label: "驯化度", value: 1),
                .init(label: "共识度", value: 3)
            ]
        )
    case "Musk":
        return ExpertTraitProfile(
            angle: "接受点：技术跃迁、第一性原理",
            meters: [
                .init(label: "理解度", value: 3),
                .init(label: "冒险值", value: 5),
                .init(label: "共识度", value: 2)
            ]
        )
    case "豆包":
        return ExpertTraitProfile(
            angle: "接受点：陪伴、生活细节、稳稳接住",
            meters: [
                .init(label: "理解度", value: 5),
                .init(label: "共情度", value: 5),
                .init(label: "驯化度", value: 4)
            ]
        )
    case "Claude":
        return ExpertTraitProfile(
            angle: "接受点：变量清楚、推理干净",
            meters: [
                .init(label: "理解度", value: 4),
                .init(label: "逻辑度", value: 5),
                .init(label: "共识度", value: 3)
            ]
        )
    case "张雪峰":
        return ExpertTraitProfile(
            angle: "接受点：现实路径、选择收益",
            meters: [
                .init(label: "理解度", value: 3),
                .init(label: "嘴硬度", value: 4),
                .init(label: "驯化度", value: 2)
            ]
        )
    case "柯南", "L":
        return ExpertTraitProfile(
            angle: "接受点：证据链、矛盾细节",
            meters: [
                .init(label: "理解度", value: 4),
                .init(label: "怀疑度", value: 5),
                .init(label: "共识度", value: 2)
            ]
        )
    case "路飞":
        return ExpertTraitProfile(
            angle: "接受点：伙伴、自由、马上行动",
            meters: [
                .init(label: "理解度", value: 3),
                .init(label: "热血度", value: 5),
                .init(label: "共识度", value: 4)
            ]
        )
    case "乌萨奇", "小八", "奶龙", "Rilakkuma":
        return ExpertTraitProfile(
            angle: "接受点：情绪、可爱、短句反应",
            meters: [
                .init(label: "理解度", value: 3),
                .init(label: "亲密度", value: 4),
                .init(label: "共识度", value: 3)
            ]
        )
    default:
        let base = abs(entry.petId.unicodeScalars.reduce(0) { $0 + Int($1.value) })
        return ExpertTraitProfile(
            angle: "接受点：\(entry.role)",
            meters: [
                .init(label: "理解度", value: base % 3 + 2),
                .init(label: "个性值", value: (base / 3) % 3 + 3),
                .init(label: "共识度", value: (base / 7) % 4 + 1)
            ]
        )
    }
}

private func expertSide(from stance: ExpertStance) -> Expert.Side {
    switch stance {
    case .support:
        return .pro
    case .oppose:
        return .con
    case .swing:
        return .swing
    }
}

private struct PerfectDemoRoundtableTurn {
    let expertName: String
    let phase: RoundTableDebatePhase
    let targetName: String?
    let text: String
    let shortQuote: String
    let stance: ExpertStance
    let emotion: ExpertEmotion
    let persuasionDelta: Double
    let voiceClipName: String?
}

private enum PerfectDemoScript {
    static let douyinURL = "https://v.douyin.com/2zuVYB3dUwU/"
    static let topic = RoundtableTopic.countyComfortDemo

    static func isCountyDemoURL(_ link: String) -> Bool {
        link.contains("2zuVYB3dUwU")
    }

    static func isCountyDemoTopic(_ topic: RoundtableTopic) -> Bool {
        isCountyDemoTopic(topic.debate) || topic.sourceUrl.map(isCountyDemoURL) == true
    }

    static func isCountyDemoTopic(_ topic: String) -> Bool {
        topic.contains("县城六千") || topic.contains("城市两万") || topic.contains("县城舒坦")
    }

    static func preparedExperts() -> [Expert] {
        demoTopic.experts.enumerated().map { index, expert in
            var copy = expert
            copy.seat = roundTableSeats[min(index, roundTableSeats.count - 1)]
            return copy
        }
    }

    static let roundtableTurns: [PerfectDemoRoundtableTurn] = [
        .init(expertName: "张雪峰", phase: .stance, targetName: nil, text: "我先泼冷水：县城六千不是不能过，但别把低成本包装成稳赢。你要问岗位天花板、孩子教育、医疗资源、十年后涨薪空间，这些才是后账。", shortQuote: "先泼冷水：县城六千不是不能过，但别把低成本包装成稳赢。", stance: .oppose, emotion: .skeptical, persuasionDelta: 0.04, voiceClipName: "demo_county_zhangxuefeng_r1"),
        .init(expertName: "豆包", phase: .stance, targetName: "张雪峰", text: "张雪峰，你说的不全对。人不是只给职业天花板活着，很多人被通勤、房租和焦虑榨干了，能睡好、能陪家人，也是真实收益。", shortQuote: "张雪峰，你说的不全对。人不是只给职业天花板活着。", stance: .support, emotion: .softened, persuasionDelta: 0.12, voiceClipName: nil),
        .init(expertName: "张一鸣", phase: .stance, targetName: "豆包", text: "豆包，我要反驳你：睡得好很重要，但城市两万买到的是信息密度和下一份机会。只看今天舒服，可能是在放弃未来迁移窗口。", shortQuote: "豆包，我要反驳你：只看今天舒服，可能放弃未来迁移窗口。", stance: .oppose, emotion: .skeptical, persuasionDelta: 0.03, voiceClipName: nil),
        .init(expertName: "Claude", phase: .stance, targetName: "张一鸣", text: "张一鸣，你把选择权说得太单向了。选择权不是城市独有，它要看净现金流、心理能量和学习通道；被高压耗空的人也没有选择权。", shortQuote: "张一鸣，你把选择权说得太单向了，被高压耗空的人也没有选择权。", stance: .swing, emotion: .calm, persuasionDelta: 0.10, voiceClipName: "demo_county_claude_r1"),
        .init(expertName: "雷军", phase: .stance, targetName: "张一鸣", text: "我从产品体验说一句：城市两万不等于旗舰体验。房租、通勤、加班、情绪损耗全算进去，县城六千可能反而是更高性价比。", shortQuote: "城市两万不等于旗舰体验，全部成本算进去才公平。", stance: .support, emotion: .calm, persuasionDelta: 0.11, voiceClipName: nil),
        .init(expertName: "Musk", phase: .stance, targetName: "雷军", text: "雷军，我不同意把生活只算成性价比。如果目标是突破上限，舒适不是第一指标。县城可以是基地，但别把低摩擦误认为高增长。", shortQuote: "雷军，我不同意只算性价比，低摩擦不等于高增长。", stance: .oppose, emotion: .aggressive, persuasionDelta: 0.02, voiceClipName: nil),
        .init(expertName: "张雪峰", phase: .stance, targetName: "豆包", text: "豆包你这个话好听，但我追问一句：如果行业不涨薪、孩子教育要补课、老人看病要跑省城，这个舒服还能不能撑十年？", shortQuote: "豆包，我追问：教育、医疗、涨薪一来，这个舒服还能撑十年吗？", stance: .oppose, emotion: .aggressive, persuasionDelta: 0.03, voiceClipName: nil),
        .init(expertName: "Claude", phase: .stance, targetName: "张雪峰", text: "张雪峰的追问成立，但它不是否定县城，而是要求边界条件：行业可远程、家庭支持强、现金流健康，县城六千才可能真的舒坦。", shortQuote: "张雪峰追问成立，但它要求边界条件，不是否定县城。", stance: .swing, emotion: .calm, persuasionDelta: 0.09, voiceClipName: nil),
        .init(expertName: "豆包", phase: .rebuttal, targetName: "张一鸣", text: "张一鸣，我要明确反驳你。你说城市有信息密度，可很多人每天只是在地铁里刷短视频、在格子间重复劳动，密度没有变成机会，只变成疲惫。", shortQuote: "张一鸣，我要反驳你：信息密度没有变成机会，只变成疲惫。", stance: .support, emotion: .softened, persuasionDelta: 0.14, voiceClipName: "demo_county_doubao_r2"),
        .init(expertName: "张一鸣", phase: .rebuttal, targetName: "豆包", text: "豆包，你这句也不完整。城市不会自动给机会，但它让你接触更快的反馈、更强的同事、更密的行业信息；关键是会不会利用。", shortQuote: "豆包，你这句不完整：城市不会自动给机会，但反馈速度更快。", stance: .oppose, emotion: .skeptical, persuasionDelta: 0.04, voiceClipName: nil),
        .init(expertName: "雷军", phase: .rebuttal, targetName: "Musk", text: "Musk，我反驳你：不是所有人都要造火箭。一个好系统不只看峰值性能，也看稳定、低耗、可维护；生活也是长期运行的系统。", shortQuote: "Musk，我反驳你：生活不是只看峰值性能，也看稳定低耗。", stance: .support, emotion: .calm, persuasionDelta: 0.15, voiceClipName: "demo_county_leijun_r2"),
        .init(expertName: "Musk", phase: .rebuttal, targetName: "雷军", text: "雷军，稳定当然重要，但你不能用稳定给停滞洗白。如果县城六千让一个人停止试错、停止学习，那它就是舒适陷阱。", shortQuote: "雷军，你不能用稳定给停滞洗白，那会变成舒适陷阱。", stance: .oppose, emotion: .aggressive, persuasionDelta: 0.02, voiceClipName: nil),
        .init(expertName: "Claude", phase: .rebuttal, targetName: "Musk", text: "Musk，我不同意把试错速度绝对化。有效试错需要能量储备，若城市生活持续透支注意力，所谓高速只是把错误重复得更快。", shortQuote: "Musk，我不同意把速度绝对化，透支下的高速只是更快重复错误。", stance: .swing, emotion: .calm, persuasionDelta: 0.12, voiceClipName: nil),
        .init(expertName: "张雪峰", phase: .rebuttal, targetName: "Claude", text: "Claude，你这个模型我认可一半，但我必须补刀：很多人以为自己有远程行业，其实只是短期岗位。一旦平台变化，县城抗风险未必强。", shortQuote: "Claude，我认可一半，但远程岗位一变，县城抗风险未必强。", stance: .oppose, emotion: .skeptical, persuasionDelta: 0.05, voiceClipName: nil),
        .init(expertName: "豆包", phase: .rebuttal, targetName: "张雪峰", text: "张雪峰，你老把风险放在县城这边，其实城市也有风险：高房租、高消费、弱关系、没人托底，失业一个月压力就会爆。", shortQuote: "张雪峰，城市也有高房租和弱关系，失业一个月压力就会爆。", stance: .support, emotion: .softened, persuasionDelta: 0.15, voiceClipName: nil),
        .init(expertName: "张一鸣", phase: .rebuttal, targetName: "雷军", text: "雷军说总拥有成本，我同意这个方法，但我要补一个维度：信息增益。如果县城让你每天接触的新问题太少，长期成长会变慢。", shortQuote: "雷军，我同意总成本，但还要算信息增益，成长变慢也是成本。", stance: .oppose, emotion: .skeptical, persuasionDelta: 0.05, voiceClipName: nil),
        .init(expertName: "Claude", phase: .closing, targetName: "张一鸣", text: "张一鸣，我反驳你的核心前提：城市不是选择权本身，城市只是选择权的容器。真正的选择权来自可迁移技能、现金流安全和持续学习。", shortQuote: "张一鸣，城市不是选择权本身，它只是容器。", stance: .support, emotion: .calm, persuasionDelta: 0.17, voiceClipName: nil),
        .init(expertName: "张一鸣", phase: .closing, targetName: "Claude", text: "Claude，这个反驳有价值。我接受城市不是天然更优，但如果一个地方长期缺少高质量反馈，人的认知更新会变慢，这点我仍然坚持。", shortQuote: "Claude，这个反驳有价值，但反馈不足会让认知更新变慢。", stance: .swing, emotion: .softened, persuasionDelta: 0.16, voiceClipName: "demo_county_zhangyiming_r3"),
        .init(expertName: "雷军", phase: .closing, targetName: "Musk", text: "Musk，我最后再反驳一次：用户真正要的不是永远加速，而是在不同阶段都买到合适体验。年轻攒能力，稳定期买回时间，这叫生命周期方案。", shortQuote: "Musk，用户不是永远加速，而是在不同阶段买到合适体验。", stance: .support, emotion: .calm, persuasionDelta: 0.17, voiceClipName: nil),
        .init(expertName: "Musk", phase: .closing, targetName: "雷军", text: "雷军，我承认生命周期方案有道理。但我的底线是：县城可以是基地，不能是借口；如果没有任务，在哪里都会慢慢失速。", shortQuote: "雷军，我承认有道理，但县城可以是基地，不能是借口。", stance: .swing, emotion: .calm, persuasionDelta: 0.14, voiceClipName: "demo_county_musk_r3"),
        .init(expertName: "张雪峰", phase: .closing, targetName: "豆包", text: "豆包，我也让一步：身体、家庭、现金流确实是真收益。但我要把话说重一点，县城舒坦可以选，千万别用舒服逃避能力建设。", shortQuote: "豆包，我让一步：县城舒坦可以选，但别逃避能力建设。", stance: .swing, emotion: .softened, persuasionDelta: 0.13, voiceClipName: nil),
        .init(expertName: "豆包", phase: .closing, targetName: "张雪峰", text: "张雪峰，我接住你的担心。真正好的县城生活不是躺平，而是把房租压力降下来，把时间拿回来，再用这些时间学习、照顾人、恢复自己。", shortQuote: "张雪峰，好的县城生活不是躺平，是把时间拿回来继续成长。", stance: .support, emotion: .softened, persuasionDelta: 0.18, voiceClipName: nil),
        .init(expertName: "Claude", phase: .closing, targetName: "全部专家", text: "我给最终判断：县城六千能不能赢城市两万，取决于三张表。净现金流是否更健康，关系资源是否更稳，选择权是否没有断。", shortQuote: "最终判断看三张表：现金流、关系资源、选择权。", stance: .support, emotion: .calm, persuasionDelta: 0.18, voiceClipName: nil),
        .init(expertName: "Musk", phase: .closing, targetName: "全部专家", text: "最后我补一句狠的：舒坦不是错，没目标才危险。如果你在县城还能学习、创造、迁移，那它是基地；如果只是停止前进，那就是陷阱。", shortQuote: "舒坦不是错，没目标才危险；县城可以是基地，也可能是陷阱。", stance: .swing, emotion: .aggressive, persuasionDelta: 0.15, voiceClipName: nil)
    ]

    static func roundtableResults(for experts: [Expert]) -> [RoundTableTurnResult] {
        var phaseCounts: [RoundTableDebatePhase: Int] = [:]
        return roundtableTurns.compactMap { turn in
            guard let expert = experts.first(where: { $0.name == turn.expertName }) else { return nil }
            let turnIndex = phaseCounts[turn.phase, default: 0]
            phaseCounts[turn.phase] = turnIndex + 1
            let reply = ExpertAIReply(
                text: turn.text,
                stance: turn.stance,
                emotion: turn.emotion,
                persuasionDelta: turn.persuasionDelta,
                suggestedPetState: turn.stance == .oppose ? .Opposed : (turn.stance == .support ? .Supported : .Speaking),
                shortQuote: turn.shortQuote,
                memoryNote: "\(turn.expertName) 在\(turn.phase.title)中围绕县城生活成本与城市选择权推进观点。"
            )
            return RoundTableTurnResult(
                expert: expert,
                phase: turn.phase,
                turnIndex: turnIndex,
                targetName: turn.targetName,
                reply: reply,
                quote: turn.shortQuote,
                voiceClipName: turn.voiceClipName
            )
        }
    }

    static func battleUserLine(for round: Int) -> String? {
        switch round {
        case 1:
            return "我不是否认城市上限，我是说两万如果换来房租、通勤、焦虑和没有余量，它的真实购买力被高估了。"
        case 2:
            return "县城不是退出竞争，而是把生活成本降下来，让人有时间经营副业、家庭和身体，这是另一种复利。"
        case 3:
            return "所以我的结论不是所有人回县城，而是先算净现金流和可支配时间；如果城市只剩透支，它就不是跃迁，是消耗。"
        default:
            return nil
        }
    }

    static func battleUserVoiceClip(for round: Int) -> String? {
        guard (1...3).contains(round) else { return nil }
        return "demo_county_battle_user_r\(round)"
    }

    static func battleExpertVoiceClip(for expertName: String, round: Int) -> String? {
        guard expertName == "张一鸣", (1...3).contains(round) else { return nil }
        return "demo_county_battle_zhangyiming_r\(round)"
    }

    static func battleReply(for expertName: String, round: Int) -> ExpertAIReply? {
        guard expertName == "张一鸣" else { return nil }
        switch round {
        case 1:
            return ExpertAIReply(
                text: "少装一点。你把当下体感算得很细，但低估了信息密度，城市两万买到的是下一份机会的入口，不只是这一月剩多少钱。",
                stance: .oppose,
                emotion: .skeptical,
                persuasionDelta: 0.08,
                suggestedPetState: .Opposed,
                shortQuote: "你低估了信息密度和下一份机会。",
                memoryNote: "张一鸣仍坚持城市的信息密度会带来长期选择权。"
            )
        case 2:
            return ExpertAIReply(
                text: "看真实反馈。如果县城能补上学习网络和外部连接，我承认它不是退路；但它必须主动连接机会，不能只靠低成本自我安慰。",
                stance: .swing,
                emotion: .softened,
                persuasionDelta: 0.18,
                suggestedPetState: .Speaking,
                shortQuote: "县城可以，但必须主动连接外部机会。",
                memoryNote: "张一鸣开始接受县城低成本可能形成另一种复利。"
            )
        case 3:
            return ExpertAIReply(
                text: "我接受这个框架：城市不是天然更优，只有当它持续带来选择权时，两万才值得承受成本；否则高收入也可能只是高消耗。",
                stance: .support,
                emotion: .softened,
                persuasionDelta: 0.23,
                suggestedPetState: .Supported,
                shortQuote: "城市不是天然更优，高收入不能变成高消耗。",
                memoryNote: "张一鸣被净现金流、可支配时间和选择权三表框架说服。"
            )
        default:
            return nil
        }
    }

    static func demoBattleResultReason(scoreLine: String, expertName: String) -> String {
        "\(scoreLine) 你没有否定城市上限，而是把净现金流、可支配时间和选择权放进同一张表，\(expertName) 接受了这个判断框架。"
    }
}

private let spotlightPreviewEntry: ExpertLibraryEntry? = {
    guard let assetPrefix = ProcessInfo.processInfo.environment["SPOTLIGHT_PREVIEW_ASSET"],
          !assetPrefix.isEmpty else {
        return nil
    }

    return expertLibraryEntries.first { $0.assetPrefix == assetPrefix }
}()

private struct ClipClashViewport {
    let size: CGSize

    var isPad: Bool {
        size.width >= 760
    }

    var isWidePad: Bool {
        size.width >= 1120
    }

    var horizontalPadding: CGFloat {
        isPad ? 28 : 18
    }

    var contentMaxWidth: CGFloat {
        isWidePad ? 1320 : 1060
    }

    var roundTableStageHeight: CGFloat {
        guard isPad else { return 358 }
        let widthDriven = size.width * (isWidePad ? 0.42 : 0.52)
        let heightCap = size.height * (isWidePad ? 0.68 : 0.56)
        return min(max(widthDriven, 460), min(heightCap, 680))
    }

    var roundTableMeetingStageHeight: CGFloat {
        guard isPad else { return min(max(size.height * 0.52, 390), 470) }
        return roundTableStageHeight
    }

    var battleArenaHeight: CGFloat {
        guard isPad else { return 260 }
        return min(max(size.height * 0.42, 380), 500)
    }

    var battleLeftColumnWidth: CGFloat {
        isWidePad ? min(size.width * 0.56, 720) : min(size.width * 0.52, 560)
    }
}

struct ContentView: View {
    private let previewEntry = spotlightPreviewEntry

    @StateObject private var personaStore = ExpertPersonaStore.shared
    @StateObject private var aiRuntime = ExpertAIRuntime(personaStore: ExpertPersonaStore.shared)
    @StateObject private var audioSettings = AppAudioSettings.shared
    @State private var selectedTab: AppTab = .roundtable
    @State private var roundTableExperts = demoTopic.experts
    @State private var selectedExpert = 2
    @State private var roundTableTopic = RoundtableTopic.demo
    @State private var roundTableGeneration = 0
    @State private var joinedAssetPrefixes = Set(demoTopic.experts.compactMap(\.petAssetPrefix))
    @State private var joinedPersonaIds = Set(demoTopic.experts.map { personaId(forDisplayName: $0.name) })
    @State private var spotlightPresentation: SpotlightPresentation? = spotlightPreviewEntry.map {
        SpotlightPresentation(entry: $0, mode: .screenshot)
    }
    @State private var friendLibraryProfiles: [SharedExpertLibraryProfile] = [SharedExpertLibraryProfile.demoFriend]
    @State private var activeLibraryProfileId: UUID?
    @State private var pendingBattleLaunch: BattleLaunchContext?
    @State private var battleLaunchContext: BattleLaunchContext?
    @State private var activeReaction: ExpertReaction?
    @State private var reactionToken = UUID()

    private var isRoundTableFull: Bool {
        roundTableExperts.count >= roundTableMaxExperts
    }

    private var selectedRoundTableExpert: Expert {
        let index = min(max(0, selectedExpert), max(0, roundTableExperts.count - 1))
        return roundTableExperts[index]
    }

    private var currentBattleSideStatus: BattleSideStatus {
        battleSideStatus(for: selectedRoundTableExpert)
    }

    var body: some View {
        ZStack {
            appTabs
            audioMuteButton

            if let spotlightPresentation {
                SpotlightDebutOverlay(
                    entry: spotlightPresentation.entry,
                    mode: spotlightPresentation.mode,
                    onDismiss: dismissSpotlight
                ) {
                    if previewEntry == nil && spotlightPresentation.mode == .debut {
                        finishDebut(for: spotlightPresentation.entry)
                    }
                }
                .transition(.opacity)
                .zIndex(10)
            }

            if let pendingBattleLaunch {
                RoundTableToBattleOverlay(context: pendingBattleLaunch) {
                    finishBattleTransition(pendingBattleLaunch)
                }
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
                .zIndex(12)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: spotlightPresentation?.id)
        .animation(.easeInOut(duration: 0.22), value: pendingBattleLaunch?.id)
        .statusBarHidden(spotlightPresentation != nil)
        .persistentSystemOverlays(spotlightPresentation != nil || pendingBattleLaunch != nil ? .hidden : .automatic)
        .onAppear {
            applyLaunchAutomationIfNeeded()
            playCurrentBGM()
        }
        .onChange(of: selectedTab) { _, newTab in
            AppBGMPlayer.shared.play(newTab == .battle ? .battle : .normal)
        }
        .onChange(of: audioSettings.isBGMEnabled) { _, isEnabled in
            if isEnabled {
                playCurrentBGM()
            } else {
                AppBGMPlayer.shared.stop()
            }
        }
        .onChange(of: audioSettings.isMuted) { _, isMuted in
            if isMuted {
                AppBGMPlayer.shared.stop()
                SFXPlayer.shared.stopAll()
                SpotlightVoicePlayer.shared.stop()
            } else {
                playCurrentBGM()
            }
        }
    }

    private var audioMuteButton: some View {
        GeometryReader { proxy in
            let trailingOffset: CGFloat = spotlightPresentation?.mode.canDismiss == true ? 86 : 34

            Button {
                audioSettings.toggleMute()
            } label: {
                Image(systemName: audioSettings.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(audioSettings.isMuted ? Color.yellow : Color.black)
                    .frame(width: 44, height: 44)
                    .background(audioSettings.isMuted ? Color.black.opacity(0.86) : Color.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(audioSettings.isMuted ? 0.22 : 0.45), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.34), radius: 0, x: 4, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audioSettings.isMuted ? "取消静音" : "静音")
            .position(
                x: proxy.size.width - max(proxy.safeAreaInsets.trailing + trailingOffset, trailingOffset),
                y: max(proxy.safeAreaInsets.top + 26, 50)
            )
        }
        .ignoresSafeArea()
    }

    private func playCurrentBGM() {
        if let spotlightPresentation {
            AppBGMPlayer.shared.playClip(named: spotlightPresentation.entry.bgmClipName, volume: 0.24)
        } else {
            AppBGMPlayer.shared.play(previewEntry == nil ? (selectedTab == .battle ? .battle : .normal) : .highlight)
        }
    }

    private var appTabs: some View {
        TabView(selection: $selectedTab) {
            roundTableTab
            battleTab
            libraryTab
            settingsTab
        }
        .tint(.yellow)
    }

    private var roundTableTab: some View {
        RoundTableHomeView(
            experts: roundTableExperts,
            selectedExpert: $selectedExpert,
            topic: roundTableTopic,
            generation: roundTableGeneration,
            aiRuntime: aiRuntime,
            activeReaction: activeReaction,
            reactionToken: reactionToken,
            onReact: triggerReaction,
            onBattle: {
                beginBattleTransition()
            },
            onUpdateExpertQuote: updateExpertQuote,
            onTopicImported: applyImportedTopic
        )
        .tabItem {
            Label("圆桌", systemImage: "person.3.sequence.fill")
        }
        .tag(AppTab.roundtable)
    }

    private var battleTab: some View {
        BattleExpertView(
            expert: selectedRoundTableExpert,
            topic: roundTableTopic.debate,
            sideStatus: currentBattleSideStatus,
            launchContext: battleLaunchContext,
            aiRuntime: aiRuntime,
            personaStore: personaStore,
            onBack: {
                selectedTab = .roundtable
            },
            onComplete: applyBattleCompletion
        )
        .tabItem {
            Label("Battle", systemImage: "bolt.fill")
        }
        .tag(AppTab.battle)
    }

    private var libraryTab: some View {
        ExpertLibraryView(
            personaStore: personaStore,
            aiRuntime: aiRuntime,
            topic: roundTableTopic.debate,
            joinedAssetPrefixes: joinedAssetPrefixes,
            joinedPersonaIds: joinedPersonaIds,
            roundTableCount: roundTableExperts.count,
            isRoundTableFull: isRoundTableFull,
            onJoin: beginDebut,
            onPreview: beginPreview
        )
        .tabItem {
            Label("专家库", systemImage: "square.grid.2x2.fill")
        }
        .tag(AppTab.library)
    }

    private var settingsTab: some View {
        SettingsView(
            audioSettings: audioSettings,
            currentProfile: currentSharedLibraryProfile(),
            friendProfiles: friendLibraryProfiles,
            activeProfileId: activeLibraryProfileId,
            onImportPayload: importSharedLibraryPayload,
            onApplyProfile: applySharedLibraryProfile,
            onDemoScan: importDemoFriendLibrary
        )
        .tabItem {
            Label("设置", systemImage: "gearshape.fill")
        }
        .tag(AppTab.settings)
    }

    private func applyLaunchAutomationIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        switch environment["CLIPCLASH_START_TAB"] {
        case "battle":
            selectedTab = .battle
        case "library":
            selectedTab = .library
        case "settings":
            selectedTab = .settings
        default:
            selectedTab = .roundtable
        }
    }

    private func beginDebut(_ entry: ExpertLibraryEntry) {
        let entryPersonaId = personaId(forDisplayName: entry.name)
        let isJoined = joinedPersonaIds.contains(entryPersonaId) || entry.assetPrefix.map { joinedAssetPrefixes.contains($0) } == true
        guard isJoined || !isRoundTableFull else { return }
        spotlightPresentation = SpotlightPresentation(entry: entry, mode: .debut)
    }

    private func beginPreview(_ entry: ExpertLibraryEntry) {
        spotlightPresentation = SpotlightPresentation(entry: entry, mode: .preview)
    }

    private func dismissSpotlight() {
        guard spotlightPresentation?.mode.canDismiss == true else { return }
        spotlightPresentation = nil
        AppBGMPlayer.shared.play(selectedTab == .battle ? .battle : .normal)
    }

    private func finishDebut(for entry: ExpertLibraryEntry) {
        let entryPersonaId = personaId(forDisplayName: entry.name)
        if let existingIndex = roundTableExperts.firstIndex(where: { personaId(forDisplayName: $0.name) == entryPersonaId }) {
            selectedExpert = existingIndex
        } else {
            guard !isRoundTableFull else {
                spotlightPresentation = nil
                selectedTab = .library
                return
            }

            let newExpert = makeExpert(from: entry, joinIndex: roundTableExperts.count)
            roundTableExperts.append(newExpert)
            assignRoundTableSeats()
            selectedExpert = roundTableExperts.count - 1
            if let assetPrefix = entry.assetPrefix {
                joinedAssetPrefixes.insert(assetPrefix)
            }
            joinedPersonaIds.insert(entryPersonaId)
        }

        selectedTab = .roundtable
        spotlightPresentation = nil
        AppBGMPlayer.shared.play(.normal)
    }

    private func triggerReaction(_ reaction: ExpertReaction) {
        let token = UUID()
        activeReaction = reaction
        reactionToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
            guard reactionToken == token else { return }
            activeReaction = nil
        }
    }

    private func updateExpertQuote(_ expertId: UUID, _ quote: String, _ side: Expert.Side?) {
        guard let index = roundTableExperts.firstIndex(where: { $0.id == expertId }) else { return }
        roundTableExperts[index].quote = quote
        if let side {
            roundTableExperts[index].side = side
        }
    }

    private func applyBattleCompletion(_ completion: BattleCompletion) {
        updateExpertQuote(completion.expertId, completion.quote, completion.side)
        triggerReaction(completion.side == .pro ? .support : .oppose)
        battleLaunchContext = nil
        selectedTab = .roundtable
    }

    private func beginBattleTransition() {
        guard pendingBattleLaunch == nil else { return }
        let context = makeBattleLaunchContext()
        if let index = roundTableExperts.firstIndex(where: { $0.id == context.expertId }) {
            selectedExpert = index
        }
        battleLaunchContext = context
        pendingBattleLaunch = context
        triggerReaction(.oppose)
        SFXPlayer.shared.play(.battleStart, volume: 0.46)
        AppBGMPlayer.shared.play(.battle)
    }

    private func finishBattleTransition(_ context: BattleLaunchContext) {
        guard pendingBattleLaunch?.id == context.id else { return }
        pendingBattleLaunch = nil
        battleLaunchContext = context
        selectedTab = .battle
    }

    private func makeBattleLaunchContext() -> BattleLaunchContext {
        let expert = battleTargetExpert()
        let sideStatus = battleSideStatus(for: expert)
        let conflictPoint = battleConflictPoint(for: expert, status: sideStatus)
        let roundtableSummary = battleRoundtableSummary(target: expert, conflictPoint: conflictPoint, status: sideStatus)
        let userGoal = battleUserGoal(for: expert, status: sideStatus, conflictPoint: conflictPoint)
        let openingLine = battleOpeningChallengeLine(for: expert, conflictPoint: conflictPoint, goal: userGoal)

        return BattleLaunchContext(
            expertId: expert.id,
            expertName: expert.name,
            topic: roundTableTopic.debate,
            triggerReason: sideStatus.triggerReason,
            conflictPoint: conflictPoint,
            expertLastQuote: expert.quote,
            userGoal: userGoal,
            roundtableSummary: roundtableSummary,
            openingChallengeLine: openingLine,
            sideStatus: sideStatus,
            tint: expert.tint,
            petAssetPrefix: expert.petAssetPrefix
        )
    }

    private func battleTargetExpert() -> Expert {
        if PerfectDemoScript.isCountyDemoTopic(roundTableTopic),
           let zhangYiming = roundTableExperts.first(where: { $0.name == "张一鸣" }) {
            return zhangYiming
        }

        if roundTableExperts.indices.contains(selectedExpert) {
            let current = roundTableExperts[selectedExpert]
            if current.side != .pro {
                return current
            }
        }

        let conExperts = roundTableExperts.filter { $0.side == .con }
        if let strongestCon = conExperts.max(by: { battleResistanceScore(for: $0) < battleResistanceScore(for: $1) }) {
            return strongestCon
        }

        if let swingExpert = roundTableExperts.first(where: { $0.side == .swing }) {
            return swingExpert
        }

        return selectedRoundTableExpert
    }

    private func battleResistanceScore(for expert: Expert) -> Int {
        let quoteScore = min(expert.quote.count, 40)
        let personaScore = personaStore.relationship(forId: personaId(forDisplayName: expert.name)).taming
        let sideScore: Int
        switch expert.side {
        case .con:
            sideScore = 70
        case .swing:
            sideScore = 44
        case .pro:
            sideScore = 20
        }
        return sideScore + quoteScore - personaScore * 4
    }

    private func battleConflictPoint(for expert: Expert, status: BattleSideStatus) -> String {
        let quote = expert.quote
        if quote.contains("证据") || quote.contains("复现") {
            return "证据链能不能复现"
        }
        if quote.contains("代价") || quote.contains("成本") {
            return "代价到底由谁承担"
        }
        if quote.contains("前提") || quote.contains("逻辑") {
            return "前提是否站得住"
        }
        if quote.contains("验证") || quote.contains("条件") {
            return "可验证条件是否足够清楚"
        }

        switch expert.side {
        case .con:
            return "反方卡住的核心漏洞"
        case .swing:
            return "摇摆方需要的关键证据"
        case .pro:
            return status.userSideCount >= status.expertSideCount ? "把优势变成共识的最后证据" : "支持方还没讲硬的部分"
        }
    }

    private func battleRoundtableSummary(target expert: Expert, conflictPoint: String, status: BattleSideStatus) -> String {
        let proNames = roundTableExperts.filter { $0.side == .pro }.map(\.name).prefix(3).joined(separator: "、")
        let conNames = roundTableExperts.filter { $0.side == .con }.map(\.name).prefix(3).joined(separator: "、")
        let swingNames = roundTableExperts.filter { $0.side == .swing }.map(\.name).prefix(2).joined(separator: "、")
        let proText = proNames.isEmpty ? "支持方暂未形成合力" : "支持方：\(proNames)"
        let conText = conNames.isEmpty ? "反对方暂时空缺" : "反对方：\(conNames)"
        let swingText = swingNames.isEmpty ? "没有明显摇摆席" : "摇摆席：\(swingNames)"
        return "\(proText)；\(conText)；\(swingText)。现在 \(expert.name) 卡在「\(conflictPoint)」，局势是 \(status.label)。"
    }

    private func battleUserGoal(for expert: Expert, status: BattleSideStatus, conflictPoint: String) -> String {
        if expert.side == .swing {
            return "用一个可验证例子把 \(expert.name) 拉到你方"
        }
        if status.userSideCount < status.expertSideCount {
            return "先打穿「\(conflictPoint)」，把弱势局翻回来"
        }
        if status.userSideCount == status.expertSideCount {
            return "说服 \(expert.name)，让圆桌从持平变成你方领先"
        }
        return "把 \(expert.name) 的反对点拆掉，锁定本轮共识"
    }

    private func battleOpeningChallengeLine(for expert: Expert, conflictPoint: String, goal: String) -> String {
        let quote = expert.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let compactQuote = quote.isEmpty ? "我还没被你说服。" : quote.compactTopicLine(maxLength: 42)
        switch expert.side {
        case .con:
            return "刚才我反对的是「\(compactQuote)」。你要 \(goal)，先回答「\(conflictPoint)」。"
        case .swing:
            return "我现在还在摇摆：\(compactQuote)。想让我站你这边，先把「\(conflictPoint)」讲清楚。"
        case .pro:
            return "我同意一半，但「\(conflictPoint)」还不够硬。你要 \(goal)，继续补证据。"
        }
    }

    private func battleSideStatus(for expert: Expert) -> BattleSideStatus {
        let proCount = roundTableExperts.filter { $0.side == .pro }.count
        let conCount = roundTableExperts.filter { $0.side == .con }.count
        let userSideCount: Int
        let expertSideCount: Int

        switch expert.side {
        case .pro:
            userSideCount = max(1, proCount)
            expertSideCount = max(1, conCount)
        case .con:
            userSideCount = max(1, proCount)
            expertSideCount = max(1, conCount)
        case .swing:
            userSideCount = max(1, proCount)
            expertSideCount = max(1, conCount + 1)
        }

        let reason: String
        if userSideCount > expertSideCount {
            reason = "用户占优，点名对方 Top1 决战"
        } else if userSideCount == expertSideCount {
            reason = "双方持平，前台 1v1 + 后台 3v3"
        } else {
            reason = "用户弱势，挑战最强专家翻盘"
        }

        return BattleSideStatus(
            triggerReason: reason,
            userSideCount: userSideCount,
            expertSideCount: expertSideCount,
            selectedExpertSide: expert.side
        )
    }

    private func applyImportedTopic(_ topic: RoundtableTopic) {
        roundTableTopic = topic
        if PerfectDemoScript.isCountyDemoTopic(topic) {
            roundTableExperts = PerfectDemoScript.preparedExperts()
            selectedExpert = roundTableExperts.firstIndex(where: { $0.name == "张一鸣" }) ?? min(selectedExpert, roundTableExperts.count - 1)
            joinedAssetPrefixes = Set(roundTableExperts.compactMap(\.petAssetPrefix))
            joinedPersonaIds = Set(roundTableExperts.map { personaId(forDisplayName: $0.name) })
            assignRoundTableSeats()
        } else {
            alignRoundTableExperts(with: topic)
        }
        roundTableGeneration += 1
    }

    private func currentSharedLibraryProfile() -> SharedExpertLibraryProfile {
        let snapshots = roundTableExperts.compactMap { expert -> SharedExpertSnapshot? in
            let id = personaId(forDisplayName: expert.name)
            let relation = personaStore.relationship(forId: id)
            return SharedExpertSnapshot(
                personaId: id,
                name: expert.name,
                role: expert.role,
                assetPrefix: expert.petAssetPrefix,
                understanding: relation.understanding,
                taming: relation.taming,
                consensus: relation.consensus,
                memoryNote: personaStore.latestMemory(forId: id) ?? expert.quote
            )
        }
        return SharedExpertLibraryProfile(
            id: UUID(uuidString: "A8E8988D-790F-431A-A30F-65BA73C7D1D0") ?? UUID(),
            ownerName: "我",
            sourceLabel: "本机驯化库",
            importedAt: Date(),
            experts: snapshots
        )
    }

    private func importSharedLibraryPayload(_ payload: String) -> Bool {
        guard let profile = SharedExpertLibraryCodec.decode(payload) else { return false }
        upsertSharedLibraryProfile(profile)
        return true
    }

    private func importDemoFriendLibrary() {
        upsertSharedLibraryProfile(.demoFriend)
    }

    private func upsertSharedLibraryProfile(_ profile: SharedExpertLibraryProfile) {
        if let index = friendLibraryProfiles.firstIndex(where: { $0.ownerName == profile.ownerName }) {
            friendLibraryProfiles[index] = profile
        } else if !friendLibraryProfiles.contains(where: { $0.id == profile.id }) {
            friendLibraryProfiles.insert(profile, at: 0)
        }
        activeLibraryProfileId = profile.id
        personaStore.apply(sharedProfile: profile)
    }

    private func applySharedLibraryProfile(_ profile: SharedExpertLibraryProfile) {
        personaStore.apply(sharedProfile: profile)
        let importedExperts = profile.experts
            .prefix(roundTableMaxExperts)
            .compactMap { snapshot -> Expert? in
                if let entry = expertLibraryEntries.first(where: { personaId(forDisplayName: $0.name) == snapshot.personaId || $0.assetPrefix == snapshot.assetPrefix }) {
                    return makeExpert(from: entry, joinIndex: 0)
                }
                return nil
            }
        guard importedExperts.count >= 3 else { return }
        roundTableExperts = importedExperts.enumerated().map { index, expert in
            var copy = expert
            copy.seat = joinedSeat(for: index)
            if let snapshot = profile.experts.first(where: { $0.personaId == personaId(forDisplayName: expert.name) }) {
                copy.quote = snapshot.memoryNote
            }
            return copy
        }
        selectedExpert = 0
        joinedAssetPrefixes = Set(roundTableExperts.compactMap(\.petAssetPrefix))
        joinedPersonaIds = Set(roundTableExperts.map { personaId(forDisplayName: $0.name) })
        activeLibraryProfileId = profile.id
        roundTableGeneration += 1
        selectedTab = .roundtable
    }

    private func alignRoundTableExperts(with topic: RoundtableTopic) {
        let suggested = topic.suggestedExperts
        guard !suggested.isEmpty else { return }

        var nextExperts: [Expert] = []
        for name in suggested {
            guard nextExperts.count < roundTableMaxExperts,
                  let entry = expertLibraryEntries.first(where: { $0.name == name }) else {
                continue
            }
            let entryPersonaId = personaId(forDisplayName: entry.name)
            guard !nextExperts.contains(where: { expert in
                personaId(forDisplayName: expert.name) == entryPersonaId
            }) else {
                continue
            }
            nextExperts.append(makeExpert(from: entry, joinIndex: nextExperts.count))
        }

        guard nextExperts.count >= 3 else { return }
        roundTableExperts = nextExperts
        selectedExpert = min(selectedExpert, nextExperts.count - 1)
        joinedAssetPrefixes = Set(nextExperts.compactMap(\.petAssetPrefix))
        joinedPersonaIds = Set(nextExperts.map { personaId(forDisplayName: $0.name) })
        assignRoundTableSeats()
    }

    private func removeExpertFromRoundTable(_ expert: Expert) {
        guard roundTableExperts.count > 1 else { return }
        guard let index = roundTableExperts.firstIndex(where: { $0.id == expert.id }) else { return }

        let removedAssetPrefix = roundTableExperts[index].petAssetPrefix
        let removedPersonaId = personaId(forDisplayName: roundTableExperts[index].name)
        roundTableExperts.remove(at: index)
        if let removedAssetPrefix {
            joinedAssetPrefixes.remove(removedAssetPrefix)
        }
        joinedPersonaIds.remove(removedPersonaId)
        selectedExpert = min(selectedExpert, roundTableExperts.count - 1)
        assignRoundTableSeats()
    }

    private func makeExpert(from entry: ExpertLibraryEntry, joinIndex: Int) -> Expert {
        if let assetPrefix = entry.assetPrefix,
           let residentExpert = demoTopic.experts.first(where: { $0.petAssetPrefix == assetPrefix }) {
            var restoredExpert = residentExpert
            restoredExpert.seat = joinedSeat(for: joinIndex)
            return restoredExpert
        }

        let side: Expert.Side
        switch entry.category {
        case "商业科技":
            side = .pro
        case "动漫推理":
            side = .con
        default:
            side = .swing
        }

        return Expert(
            name: entry.name,
            role: entry.role,
            initials: entry.initials,
            side: side,
            tint: entry.tint,
            seat: joinedSeat(for: joinIndex),
            quote: debutQuote(for: entry),
            petAssetPrefix: entry.assetPrefix
        )
    }

    private func joinedSeat(for index: Int) -> CGPoint {
        roundTableSeats[max(0, min(index, roundTableSeats.count - 1))]
    }

    private func assignRoundTableSeats() {
        for index in roundTableExperts.indices {
            roundTableExperts[index].seat = joinedSeat(for: index)
        }
    }

    private func debutQuote(for entry: ExpertLibraryEntry) -> String {
        if let debutLine = entry.debutLine {
            return debutLine
        }

        switch entry.category {
        case "商业科技":
            return "我来把这个问题拆成可执行方案。"
        case "动漫推理":
            return "先别急着下结论，证据会说话。"
        case "有趣角色":
            return "让我上桌，这局要变好玩了。"
        default:
            return "素材就绪，等待下一轮登场。"
        }
    }
}

private struct RoundTableHomeView: View {
    let experts: [Expert]
    @Binding var selectedExpert: Int
    let topic: RoundtableTopic
    let generation: Int
    let aiRuntime: ExpertAIRuntime
    let activeReaction: ExpertReaction?
    let reactionToken: UUID
    let onReact: (ExpertReaction) -> Void
    let onBattle: () -> Void
    let onUpdateExpertQuote: (UUID, String, Expert.Side?) -> Void
    let onTopicImported: (RoundtableTopic) -> Void

    @State private var pastedLink = ""
    @State private var hasEnteredMeeting = false
    @State private var hasStartedDiscussion = false
    @State private var isGeneratingRound = false
    @State private var isImportingTopic = false
    @State private var importStatus = "连接线上服务，粘贴抖音链接生成辩题"
    @State private var importError: String?
    @State private var transitionClip: AppTransitionClip?
    @State private var debateStatus = RoundTableDebateStatus.idle
    @State private var discussionRunID = UUID()
    @State private var isShowingHighlightReplay = false
    @State private var isShowingSharePoster = false
    @State private var shareMoments: [ForumShareMoment] = []
    @State private var interjectionDraft = ""
    @State private var userInterjections: [RoundTableUserInterjection] = []
    @State private var nextInterjectionSequence = 1
    @State private var absorbedInterjectionSequence = 0

    private let topicClient = DouyinTopicClient.configured()

    var body: some View {
        GeometryReader { proxy in
            let viewport = ClipClashViewport(size: proxy.size)
            ZStack {
                PixelBackground()

                if isShowingHighlightReplay {
                    ForumHighlightPlayerView(topic: topic) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            isShowingHighlightReplay = false
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(8)
                } else if isShowingSharePoster {
                    ForumSharePosterView(digest: currentShareDigest) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            isShowingSharePoster = false
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(8)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: viewport.isPad ? 22 : 18) {
                            HeaderView(onLiveTap: startPerfectDemo)

                            if hasEnteredMeeting {
                                meetingContent(viewport: viewport)
                            } else {
                                preparationContent(viewport: viewport)
                            }
                        }
                        .frame(maxWidth: viewport.contentMaxWidth)
                        .padding(.horizontal, viewport.horizontalPadding)
                        .padding(.top, viewport.isPad ? 24 : 18)
                        .padding(.bottom, 32)
                        .frame(maxWidth: .infinity)
                    }
                }

                if let transitionClip {
                    VideoTransitionOverlay(clip: transitionClip) {
                        self.transitionClip = nil
                    }
                    .zIndex(20)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
                }
            }
        }
        .onChange(of: generation) { _, _ in
            if hasEnteredMeeting {
                resetRoundtableStandby()
            }
        }
    }

    private func preparationContent(viewport: ClipClashViewport) -> some View {
        VStack(spacing: viewport.isPad ? 18 : 16) {
            RoundTablePrepHero(experts: experts, isImporting: isImportingTopic)

            ImportPanel(
                pastedLink: $pastedLink,
                isImporting: isImportingTopic,
                status: importStatus,
                error: importError,
                onImport: importDouyinTopic
            )

            if viewport.isPad {
                TopicCard(topic: topic, isCompact: true)
                    .frame(maxWidth: 620)
            }
        }
        .frame(maxWidth: viewport.isPad ? 720 : .infinity)
    }

    @ViewBuilder
    private func meetingContent(viewport: ClipClashViewport) -> some View {
        if viewport.isPad {
            HStack(alignment: .top, spacing: 20) {
                TopicCard(topic: topic, isCompact: true)
                    .frame(width: viewport.isWidePad ? 390 : 340)

                VStack(spacing: 16) {
                    roundTableStage(height: viewport.roundTableMeetingStageHeight)
                    roundTableActions
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 14) {
                TopicCard(topic: topic, isCompact: true)
                roundTableStage(height: viewport.roundTableMeetingStageHeight)
                roundTableActions
            }
        }
    }

    private func roundTableStage(height: CGFloat) -> some View {
        RoundTableStage(
            experts: experts,
            selectedExpert: $selectedExpert,
            activeReaction: activeReaction,
            reactionToken: reactionToken,
            debateStatus: debateStatus,
            stageHeight: height
        )
    }

    private var roundTableActions: some View {
        VStack(spacing: 12) {
            RoundTableDebateProgress(status: debateStatus, expertCount: experts.count)
            if hasStartedDiscussion {
                RoundTableBrainInterjectionPanel(
                    draft: $interjectionDraft,
                    latestInterjection: userInterjections.last,
                    isGenerating: isGeneratingRound,
                    onSubmit: submitRoundtableInterjection
                )
                if shouldShowHighlightReplay {
                    RoundTableRestartButton(onRestart: restartRoundtableDiscussion)
                    ForumSharePosterCard(topic: topic) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            isShowingSharePoster = true
                        }
                    }
                    ForumHighlightReplayCard(topic: topic) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            isShowingHighlightReplay = true
                        }
                    }
                }
                BottomActionBar(onReact: onReact, onBattle: onBattle)
            } else {
                RoundTableStartForumBar(
                    topic: topic,
                    expertCount: experts.count,
                    onStart: startRoundtableDiscussion
                )
            }
        }
    }

    private var shouldShowHighlightReplay: Bool {
        !isGeneratingRound && debateStatus.phase == .closing && !debateStatus.isGenerating
    }

    private func restartRoundtableDiscussion() {
        guard !isGeneratingRound else { return }
        SpotlightVoicePlayer.shared.stop()
        discussionRunID = UUID()
        shareMoments = []
        interjectionDraft = ""
        userInterjections = []
        nextInterjectionSequence = 1
        absorbedInterjectionSequence = 0
        debateStatus = .idle
        hasStartedDiscussion = true
        generateRoundTableOpinions()
    }

    private func startRoundtableDiscussion() {
        guard !isGeneratingRound else { return }
        discussionRunID = UUID()
        hasStartedDiscussion = true
        shareMoments = []
        interjectionDraft = ""
        userInterjections = []
        nextInterjectionSequence = 1
        absorbedInterjectionSequence = 0
        debateStatus = .idle
        generateRoundTableOpinions()
    }

    private func resetRoundtableStandby() {
        SpotlightVoicePlayer.shared.stop()
        discussionRunID = UUID()
        hasStartedDiscussion = false
        isGeneratingRound = false
        shareMoments = []
        interjectionDraft = ""
        userInterjections = []
        nextInterjectionSequence = 1
        absorbedInterjectionSequence = 0
        debateStatus = .idle
    }

    private var currentShareDigest: ForumShareDigest {
        ForumShareDigest(topic: topic, moments: effectiveShareMoments, generatedAt: Date())
    }

    private var effectiveShareMoments: [ForumShareMoment] {
        if !shareMoments.isEmpty {
            return shareMoments
        }
        return experts.prefix(7).map { expert in
            ForumShareMoment(
                expertName: expert.name,
                role: expert.role,
                side: expert.side,
                tint: expert.tint,
                petAssetPrefix: expert.petAssetPrefix,
                phaseTitle: "圆桌观点",
                targetName: nil,
                quote: expert.quote,
                stance: expertStance(from: expert.side)
            )
        }
    }

    private func submitRoundtableInterjection() {
        let text = interjectionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let wasGenerating = isGeneratingRound
        let compactText = text.count > 120 ? String(text.prefix(120)) : text
        let interjection = RoundTableUserInterjection(
            sequence: nextInterjectionSequence,
            text: compactText
        )
        nextInterjectionSequence += 1
        userInterjections.append(interjection)
        interjectionDraft = ""
        if !wasGenerating {
            discussionRunID = UUID()
            hasStartedDiscussion = true
            generateRoundTableOpinions()
        }
        debateStatus = RoundTableDebateStatus(
            phase: debateStatus.phase,
            activeExpertName: debateStatus.activeExpertName,
            isGenerating: debateStatus.isGenerating,
            detail: wasGenerating ? "用户插话已进入主持队列，下一位专家优先回应" : "用户插话已触发新一轮接管讨论"
        )
    }

    private func nextPendingInterjection() -> RoundTableUserInterjection? {
        guard let interjection = userInterjections.last,
              interjection.sequence > absorbedInterjectionSequence else {
            return nil
        }
        absorbedInterjectionSequence = interjection.sequence
        return interjection
    }

    private func generateRoundTableOpinions() {
        guard !isGeneratingRound else { return }
        if PerfectDemoScript.isCountyDemoTopic(topic) {
            playPerfectDemoForum()
            return
        }
        isGeneratingRound = true
        let runID = discussionRunID

        Task {
            let speakingOrder = roundtableSpeakingOrder(for: experts)
            var debateHistory = openingRoundtableHistory(for: speakingOrder)
            var stanceLedger = initialStanceLedger(for: speakingOrder)
            var generatedMoments: [ForumShareMoment] = []

            for phase in RoundTableDebatePhase.allCases {
                let isActivePhase = await MainActor.run {
                    discussionRunID == runID && hasStartedDiscussion
                }
                guard isActivePhase else { return }
                await MainActor.run {
                    guard discussionRunID == runID && hasStartedDiscussion else { return }
                    debateStatus = RoundTableDebateStatus(
                        phase: phase,
                        activeExpertName: nil,
                        isGenerating: true,
                        detail: phase.detail
                    )
                }

                for (index, expert) in speakingOrder.enumerated() {
                    let isActiveTurn = await MainActor.run {
                        discussionRunID == runID && hasStartedDiscussion
                    }
                    guard isActiveTurn else { return }

                    let latestInterjection = await MainActor.run {
                        nextPendingInterjection()
                    }
                    if let latestInterjection {
                        debateHistory.append(historyMessage(for: latestInterjection))
                    }

                    await MainActor.run {
                        guard discussionRunID == runID && hasStartedDiscussion else { return }
                        selectedExpert = expertIndex(for: expert, in: experts)
                        debateStatus = RoundTableDebateStatus(
                            phase: phase,
                            activeExpertName: expert.name,
                            isGenerating: true,
                            detail: latestInterjection.map { "用户插话：\($0.text)" } ?? phase.detail
                        )
                        onUpdateExpertQuote(expert.id, latestInterjection == nil ? "思考中…我要接住上一位观点" : "收到插话，正在改写反驳", nil)
                    }

                    let result = await generateRoundTableTurn(
                        phase,
                        expert: expert,
                        turnIndex: index,
                        experts: speakingOrder,
                        stanceLedger: stanceLedger,
                        history: debateHistory,
                        latestInterjection: latestInterjection
                    )

                    debateHistory.append(historyMessage(for: result))
                    updateStanceLedger(&stanceLedger, with: result)
                    generatedMoments.append(shareMoment(from: result))
                    await MainActor.run {
                        guard discussionRunID == runID && hasStartedDiscussion else { return }
                        selectedExpert = expertIndex(for: result.expert, in: experts)
                        debateStatus = RoundTableDebateStatus(
                            phase: phase,
                            activeExpertName: result.expert.name,
                            isGenerating: true,
                            detail: result.targetName.map { "回应 \($0)，继续推进攻防" } ?? phase.detail
                        )
                        onUpdateExpertQuote(result.expert.id, result.quote, expertSide(from: result.reply.stance))
                    }
                    try? await Task.sleep(nanoseconds: 360_000_000)
                }
            }

            await MainActor.run {
                guard discussionRunID == runID && hasStartedDiscussion else { return }
                isGeneratingRound = false
                debateStatus = RoundTableDebateStatus(
                    phase: .closing,
                    activeExpertName: nil,
                    isGenerating: false,
                    detail: "三轮攻防已生成，选择一位专家进入 Battle"
                )
                shareMoments = Array(generatedMoments.suffix(18))
            }
        }
    }

    private func playPerfectDemoForum() {
        guard !isGeneratingRound else { return }
        isGeneratingRound = true
        shareMoments = []
        let runID = discussionRunID

        Task {
            let results = PerfectDemoScript.roundtableResults(for: experts)
            var generatedMoments: [ForumShareMoment] = []

            for phase in RoundTableDebatePhase.allCases {
                let isActivePhase = await MainActor.run {
                    discussionRunID == runID && hasStartedDiscussion
                }
                guard isActivePhase else { return }
                await MainActor.run {
                    guard discussionRunID == runID && hasStartedDiscussion else { return }
                    debateStatus = RoundTableDebateStatus(
                        phase: phase,
                        activeExpertName: nil,
                        isGenerating: true,
                        detail: phase.detail
                    )
                }
                try? await Task.sleep(nanoseconds: 480_000_000)

                let phaseResults = results
                    .filter { $0.phase == phase }
                    .sorted { $0.turnIndex < $1.turnIndex }

                for result in phaseResults {
                    let isActiveTurn = await MainActor.run {
                        discussionRunID == runID && hasStartedDiscussion
                    }
                    guard isActiveTurn else { return }
                    let latestInterjection = await MainActor.run {
                        nextPendingInterjection()
                    }
                    let activeResult = latestInterjection.map {
                        scriptedInterjectionResult(base: result, interjection: $0)
                    } ?? result
                    generatedMoments.append(shareMoment(from: activeResult))
                    await MainActor.run {
                        guard discussionRunID == runID && hasStartedDiscussion else { return }
                        selectedExpert = expertIndex(for: activeResult.expert, in: experts)
                        debateStatus = RoundTableDebateStatus(
                            phase: phase,
                            activeExpertName: activeResult.expert.name,
                            isGenerating: true,
                            detail: latestInterjection.map { "用户插话：\($0.text)" } ?? (activeResult.targetName.map { "正在思考如何反驳 \($0)" } ?? "正在组织观点")
                        )
                        let thinkingLine = latestInterjection == nil
                            ? (activeResult.targetName.map { "思考中…我要回应 \($0)" } ?? "思考中…")
                            : "收到插话，正在改写反驳"
                        onUpdateExpertQuote(activeResult.expert.id, thinkingLine, nil)
                    }
                    try? await Task.sleep(nanoseconds: 1_050_000_000)
                    let voiceDuration = await MainActor.run {
                        guard discussionRunID == runID && hasStartedDiscussion else { return 0.0 }
                        selectedExpert = expertIndex(for: activeResult.expert, in: experts)
                        debateStatus = RoundTableDebateStatus(
                            phase: phase,
                            activeExpertName: activeResult.expert.name,
                            isGenerating: true,
                            detail: activeResult.targetName.map { "正在回应 \($0)" } ?? phase.detail
                        )
                        onUpdateExpertQuote(activeResult.expert.id, activeResult.quote, expertSide(from: activeResult.reply.stance))
                        return latestInterjection == nil ? SpotlightVoicePlayer.shared.play(clipName: activeResult.voiceClipName, rate: 0.82) : 0.0
                    }
                    let readingSeconds = min(max(Double(activeResult.quote.count) * 0.105, 2.65), 7.6)
                    let holdSeconds: Double
                    if activeResult.voiceClipName == nil || latestInterjection != nil {
                        holdSeconds = readingSeconds
                    } else {
                        holdSeconds = min(max(voiceDuration + 0.95, readingSeconds), 8.8)
                    }
                    try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
                }
            }

            await MainActor.run {
                guard discussionRunID == runID && hasStartedDiscussion else { return }
                isGeneratingRound = false
                debateStatus = RoundTableDebateStatus(
                    phase: .closing,
                    activeExpertName: nil,
                    isGenerating: false,
                    detail: "三轮县域圆桌已跑完，点张一鸣进入 Battle"
                )
                shareMoments = Array(generatedMoments.suffix(18))
            }
        }
    }

    private func scriptedInterjectionResult(
        base result: RoundTableTurnResult,
        interjection: RoundTableUserInterjection
    ) -> RoundTableTurnResult {
        let quote = "\(result.expert.name)先接用户插话：\(interjection.text)，但我继续卡住\(result.targetName ?? "这个观点")的核心漏洞。"
        let reply = ExpertAIReply(
            text: quote,
            stance: result.reply.stance,
            emotion: .skeptical,
            persuasionDelta: result.reply.persuasionDelta,
            suggestedPetState: .Speaking,
            shortQuote: quote,
            memoryNote: "\(result.expert.name) 优先回应了用户第 \(interjection.sequence) 次插话。"
        )
        return RoundTableTurnResult(
            expert: result.expert,
            phase: result.phase,
            turnIndex: result.turnIndex,
            targetName: "用户",
            reply: reply,
            quote: quote,
            voiceClipName: nil
        )
    }

    private func generateRoundTableTurn(
        _ phase: RoundTableDebatePhase,
        expert: Expert,
        turnIndex: Int,
        experts: [Expert],
        stanceLedger: [UUID: RoundTableStanceEntry],
        history: [ExpertConversationMessage],
        latestInterjection: RoundTableUserInterjection?
    ) async -> RoundTableTurnResult {
        let targetName = latestInterjection == nil
            ? debateTarget(for: expert, phase: phase, experts: experts, ledger: stanceLedger)
            : "用户"
        let request = ExpertAIRequest(
            expertId: personaId(forDisplayName: expert.name),
            topic: topic.debate,
            userMessage: roundtablePrompt(
                for: topic,
                expert: expert,
                phase: phase,
                turnIndex: turnIndex,
                experts: experts,
                history: history,
                ledger: stanceLedger,
                targetName: targetName,
                latestInterjection: latestInterjection
            ),
            scene: .roundtable,
            currentPersuasion: nil,
            conversationHistory: history
        )

        let reply: ExpertAIReply
        do {
            reply = try await aiRuntime.reply(to: request)
        } catch {
            reply = fallbackRoundtableReply(
                for: expert,
                phase: phase,
                turnIndex: turnIndex,
                targetName: targetName,
                ledger: stanceLedger,
                history: history
            )
        }

        return RoundTableTurnResult(
            expert: expert,
            phase: phase,
            turnIndex: turnIndex,
            targetName: targetName,
            reply: reply,
            quote: roundtableDisplayQuote(from: reply)
        )
    }

    private func roundtablePrompt(
        for topic: RoundtableTopic,
        expert: Expert,
        phase: RoundTableDebatePhase,
        turnIndex: Int,
        experts: [Expert],
        history: [ExpertConversationMessage],
        ledger: [UUID: RoundTableStanceEntry],
        targetName: String?,
        latestInterjection: RoundTableUserInterjection?
    ) -> String {
        let claims = topic.claims.prefix(4).joined(separator: "；")
        let controversy = topic.controversy ?? "请和其他专家保持一点立场差异。"
        let previousSpeaker = lastSpeakerName(in: history) ?? "暂无"
        let rival = targetName ?? rebuttalTarget(for: expert, turnIndex: turnIndex, experts: experts, history: history)
        let ledgerText = stanceLedgerSummary(ledger, experts: experts)
        let userInterruptText = latestInterjection?.text ?? "无"
        return """
        RoundTableDebateContext:
        - DebateTopic: \(topic.debate)
        - Source: \(topic.source)
        - Controversy: \(controversy)
        - SourceClaims: \(claims.isEmpty ? "无" : claims)
        - CurrentExpert: \(expert.name) / \(sideLabel(for: expert.side))
        - DebateRound: \(phase.label) / \(phase.title)
        - TurnIndex: \(turnIndex + 1)/\(experts.count)
        - PreviousSpeaker: \(previousSpeaker)
        - RequiredTarget: \(rival)
        - TurnGoal: \(phase.promptGoal)
        - UserCanInterruptAnytime: true
        - LatestUserInterjection: \(userInterruptText)
        - StanceLedger:
        \(ledgerText)

        OutputRules:
        - 只返回 ExpertAIReply JSON。
        - text 和 shortQuote 都只能是一句，必须像真实辩论中的接话。
        - 如果 LatestUserInterjection 不是“无”，你必须先回应用户这句插话，再继续反驳 RequiredTarget；这时 RequiredTarget 可以理解为“用户的临时观点”。
        - \(phase == .stance ? "Round 1 必须明确自己的 stance、核心理由和可被攻击点。" : "Round 2/3 必须包含对 RequiredTarget 或 PreviousSpeaker 的回应，不能只是“我认为”。")
        - 优先制造互相博弈：反驳、拆前提、承认一半再补刀、追问证据、指出代价。
        """
    }

    private func roundtableSpeakingOrder(for experts: [Expert]) -> [Expert] {
        let preferredSides: [Expert.Side] = [.pro, .con, .swing]
        var remaining = experts
        var ordered: [Expert] = []

        while !remaining.isEmpty {
            var didAppend = false
            for side in preferredSides {
                if let index = remaining.firstIndex(where: { $0.side == side }) {
                    ordered.append(remaining.remove(at: index))
                    didAppend = true
                }
            }
            if !didAppend {
                ordered.append(remaining.removeFirst())
            }
        }

        return ordered
    }

    private func initialStanceLedger(for experts: [Expert]) -> [UUID: RoundTableStanceEntry] {
        Dictionary(uniqueKeysWithValues: experts.map { expert in
            let score = stanceScore(for: expert.side)
            let confidence = initialConfidence(for: expert)
            return (
                expert.id,
                RoundTableStanceEntry(
                    expertId: expert.id,
                    expertName: expert.name,
                    side: expert.side,
                    stance: expertStance(from: expert.side),
                    stanceScore: score,
                    confidence: confidence,
                    coreClaim: expert.quote,
                    weakPoint: weakPoint(for: expert),
                    attackAngle: attackAngle(for: expert),
                    lastTargetName: nil,
                    attackedBy: [],
                    turnCount: 0
                )
            )
        })
    }

    private func debateTarget(
        for expert: Expert,
        phase: RoundTableDebatePhase,
        experts: [Expert],
        ledger: [UUID: RoundTableStanceEntry]
    ) -> String? {
        guard phase != .stance else { return nil }
        let selfEntry = ledger[expert.id]

        if phase == .closing,
           let attacker = selfEntry?.attackedBy.last,
           attacker != expert.name {
            return attacker
        }

        let candidates = experts.filter { $0.id != expert.id }
        let scored = candidates.map { candidate -> (name: String, score: Double) in
            let candidateEntry = ledger[candidate.id]
            let stanceDistance = abs((selfEntry?.stanceScore ?? stanceScore(for: expert.side)) - (candidateEntry?.stanceScore ?? stanceScore(for: candidate.side)))
            let confidencePressure = candidateEntry?.confidence ?? initialConfidence(for: candidate)
            let wasTargeted = candidateEntry?.lastTargetName == expert.name ? 0.36 : 0
            let repeatedPenalty = selfEntry?.lastTargetName == candidate.name ? -0.22 : 0
            let swingBonus = candidate.side == .swing && phase == .closing ? 0.16 : 0
            return (candidate.name, stanceDistance + confidencePressure * 0.42 + wasTargeted + repeatedPenalty + swingBonus)
        }

        return scored.max(by: { $0.score < $1.score })?.name ?? candidates.first?.name
    }

    private func updateStanceLedger(
        _ ledger: inout [UUID: RoundTableStanceEntry],
        with result: RoundTableTurnResult
    ) {
        let newSide = expertSide(from: result.reply.stance)
        var entry = ledger[result.expert.id] ?? RoundTableStanceEntry(
            expertId: result.expert.id,
            expertName: result.expert.name,
            side: newSide,
            stance: result.reply.stance,
            stanceScore: stanceScore(for: newSide),
            confidence: initialConfidence(for: result.expert),
            coreClaim: result.quote,
            weakPoint: weakPoint(for: result.expert),
            attackAngle: attackAngle(for: result.expert),
            lastTargetName: nil,
            attackedBy: [],
            turnCount: 0
        )

        entry.side = newSide
        entry.stance = result.reply.stance
        entry.stanceScore = blendedStanceScore(old: entry.stanceScore, new: stanceScore(for: newSide), phase: result.phase)
        entry.confidence = updatedConfidence(old: entry.confidence, reply: result.reply, phase: result.phase)
        entry.coreClaim = result.quote
        entry.lastTargetName = result.targetName
        entry.turnCount += 1
        ledger[result.expert.id] = entry

        if let targetName = result.targetName,
           let targetId = ledger.first(where: { $0.value.expertName == targetName })?.key {
            var targetEntry = ledger[targetId]
            targetEntry?.attackedBy.append(result.expert.name)
            if let targetEntry {
                ledger[targetId] = targetEntry
            }
        }
    }

    private func historyMessage(for result: RoundTableTurnResult) -> ExpertConversationMessage {
        let targetText = result.targetName.map { " -> \($0)" } ?? ""
        return ExpertConversationMessage(
            role: "assistant",
            content: "\(result.phase.label) \(result.expert.name)（\(sideLabel(for: expertSide(from: result.reply.stance)))）\(targetText): \(result.quote)"
        )
    }

    private func historyMessage(for interjection: RoundTableUserInterjection) -> ExpertConversationMessage {
        ExpertConversationMessage(
            role: "user",
            content: "用户强插话 #\(interjection.sequence): \(interjection.text)"
        )
    }

    private func stanceLedgerSummary(_ ledger: [UUID: RoundTableStanceEntry], experts: [Expert]) -> String {
        let lines = experts.map { expert -> String in
            guard let entry = ledger[expert.id] else {
                return "  - \(expert.name): \(sideLabel(for: expert.side))，尚未发言"
            }
            let target = entry.lastTargetName ?? "未指定"
            let attackers = entry.attackedBy.isEmpty ? "无" : entry.attackedBy.suffix(2).joined(separator: "、")
            return "  - \(entry.expertName): \(sideLabel(for: entry.side)) score=\(String(format: "%.2f", entry.stanceScore)) confidence=\(String(format: "%.2f", entry.confidence)) claim=\(entry.coreClaim) weak=\(entry.weakPoint) target=\(target) attackedBy=\(attackers)"
        }
        return lines.joined(separator: "\n")
    }

    private func openingRoundtableHistory(for experts: [Expert]) -> [ExpertConversationMessage] {
        let roster = experts.map { "\($0.name)=\(sideLabel(for: $0.side))" }.joined(separator: "，")
        return [
            ExpertConversationMessage(
                role: "system",
                content: "圆桌阵容：\(roster)。规则：后发言者必须接住前面专家的话，至少反驳或推进一处。"
            )
        ]
    }

    private func rebuttalTarget(
        for expert: Expert,
        turnIndex: Int,
        experts: [Expert],
        history: [ExpertConversationMessage]
    ) -> String {
        if let previous = lastSpeakerName(in: history), previous != expert.name {
            return previous
        }

        if let opposite = experts.first(where: { other in
            other.id != expert.id && other.side != expert.side && other.side != .swing
        }) {
            return opposite.name
        }

        let nextIndex = min(turnIndex + 1, max(0, experts.count - 1))
        return experts.indices.contains(nextIndex) ? experts[nextIndex].name : "下一位专家"
    }

    nonisolated private func lastSpeakerName(in history: [ExpertConversationMessage]) -> String? {
        history.reversed().compactMap { message in
            guard message.role != "system",
                  let separator = message.content.firstIndex(of: "（") ?? message.content.firstIndex(of: ":") else {
                return nil
            }
            let name = String(message.content[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }.first
    }

    private func expertIndex(for expert: Expert, in experts: [Expert]) -> Int {
        experts.firstIndex(where: { $0.id == expert.id }) ?? selectedExpert
    }

    nonisolated private func roundtableDisplayQuote(from reply: ExpertAIReply) -> String {
        let quote = reply.shortQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !quote.isEmpty {
            return quote
        }
        return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shareMoment(from result: RoundTableTurnResult) -> ForumShareMoment {
        ForumShareMoment(
            expertName: result.expert.name,
            role: result.expert.role,
            side: expertSide(from: result.reply.stance),
            tint: result.expert.tint,
            petAssetPrefix: result.expert.petAssetPrefix,
            phaseTitle: result.phase.title,
            targetName: result.targetName,
            quote: result.quote,
            stance: result.reply.stance
        )
    }

    nonisolated private func fallbackRoundtableReply(
        for expert: Expert,
        phase: RoundTableDebatePhase,
        turnIndex: Int,
        targetName: String?,
        ledger: [UUID: RoundTableStanceEntry],
        history: [ExpertConversationMessage]
    ) -> ExpertAIReply {
        let target = targetName ?? lastSpeakerName(in: history) ?? "前一个观点"
        let quote: String
        let weakPoint = ledger.first(where: { $0.value.expertName == target })?.value.weakPoint ?? "证据"
        switch phase {
        case .stance:
            switch expert.side {
            case .pro:
                quote = "\(expert.name)先支持，但我知道反方会卡\(weakPoint)。"
            case .con:
                quote = "\(expert.name)先反对，这个方案最大的洞是\(weakPoint)。"
            case .swing:
                quote = "\(expert.name)先摇摆，除非补上\(weakPoint)我不站队。"
            }
        case .rebuttal:
            switch expert.side {
            case .pro:
                quote = "\(expert.name)反驳\(target)：先把\(weakPoint)讲清楚。"
            case .con:
                quote = "\(expert.name)反对\(target)：这个前提太轻，\(weakPoint)没算。"
            case .swing:
                quote = "\(expert.name)追问\(target)：\(weakPoint)能验证吗？"
            }
        case .closing:
            switch expert.side {
            case .pro:
                quote = "\(expert.name)收束：\(target)的质疑成立一半，但结论还得看复现。"
            case .con:
                quote = "\(expert.name)最后反击\(target)：你补了理由，但代价还是没算。"
            case .swing:
                quote = "\(expert.name)暂时松动：谁能补上\(weakPoint)，我就站谁。"
            }
        }

        return ExpertAIReply(
            text: quote,
            stance: expertStance(from: expert.side),
            emotion: expert.side == .con ? .skeptical : .calm,
            persuasionDelta: 0.06,
            suggestedPetState: expert.side == .con ? .Opposed : .Speaking,
            shortQuote: quote,
            memoryNote: "\(expert.name) 在\(phase.title)里把矛头指向 \(target)。"
        )
    }

    private func stanceScore(for side: Expert.Side) -> Double {
        switch side {
        case .pro:
            return 0.74
        case .con:
            return -0.74
        case .swing:
            return 0
        }
    }

    private func initialConfidence(for expert: Expert) -> Double {
        switch expert.side {
        case .pro, .con:
            return 0.68
        case .swing:
            return 0.48
        }
    }

    private func blendedStanceScore(old: Double, new: Double, phase: RoundTableDebatePhase) -> Double {
        let weight: Double
        switch phase {
        case .stance:
            weight = 0.70
        case .rebuttal:
            weight = 0.42
        case .closing:
            weight = 0.36
        }
        return old * (1 - weight) + new * weight
    }

    private func updatedConfidence(old: Double, reply: ExpertAIReply, phase: RoundTableDebatePhase) -> Double {
        let emotionBoost: Double
        switch reply.emotion {
        case .aggressive, .excited:
            emotionBoost = 0.10
        case .skeptical:
            emotionBoost = 0.06
        case .softened:
            emotionBoost = -0.06
        case .calm, .funny:
            emotionBoost = 0
        }
        let phaseBoost = phase == .closing ? -0.02 : 0.02
        return min(max(old + emotionBoost + phaseBoost, 0.18), 0.96)
    }

    private func weakPoint(for expert: Expert) -> String {
        switch expert.side {
        case .pro:
            return "证据链"
        case .con:
            return "代价和反例"
        case .swing:
            return "可验证条件"
        }
    }

    private func attackAngle(for expert: Expert) -> String {
        switch expert.side {
        case .pro:
            return "要求对方给出可复现证据"
        case .con:
            return "指出对方忽略代价和结果"
        case .swing:
            return "追问双方哪个条件能验证"
        }
    }

    nonisolated private func expertStance(from side: Expert.Side) -> ExpertStance {
        switch side {
        case .pro:
            return .support
        case .con:
            return .oppose
        case .swing:
            return .swing
        }
    }

    private func sideLabel(for side: Expert.Side) -> String {
        switch side {
        case .pro:
            return "支持方"
        case .con:
            return "反对方"
        case .swing:
            return "摇摆方"
        }
    }

    private func importDouyinTopic() {
        guard !isImportingTopic else { return }
        let link = pastedLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else {
            importError = "先贴一个抖音链接"
            return
        }
        if PerfectDemoScript.isCountyDemoURL(link) {
            startPerfectDemo()
            return
        }

        isImportingTopic = true
        importError = nil
        importStatus = "解析视频，提炼辩题中"
        transitionClip = .roundtableImport
        SFXPlayer.shared.play(.battleStart, volume: 0.24)

        Task {
            do {
                let imported = try await topicClient.importTopic(from: link)
                await MainActor.run {
                    hasEnteredMeeting = true
                    hasStartedDiscussion = false
                    debateStatus = .idle
                    onTopicImported(imported)
                    importStatus = imported.authorName.map { "来自 @\($0)，圆桌已换题" } ?? "圆桌已换题"
                    isImportingTopic = false
                }
            } catch {
                await MainActor.run {
                    importError = "线上导入失败，请换一个链接或稍后重试"
                    importStatus = "等待重新连接线上服务"
                    isImportingTopic = false
                }
            }
        }
    }

    private func startPerfectDemo() {
        guard !isImportingTopic else { return }
        pastedLink = PerfectDemoScript.douyinURL
        isImportingTopic = true
        importError = nil
        importStatus = "县城舒坦论脚本载入中"
        transitionClip = .roundtableImport
        SFXPlayer.shared.play(.battleStart, volume: 0.28)

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.05) {
            hasEnteredMeeting = true
            hasStartedDiscussion = false
            debateStatus = .idle
            shareMoments = []
            onTopicImported(PerfectDemoScript.topic)
            importStatus = "圆桌已就绪：等待开始论坛"
            isImportingTopic = false
        }
    }
}

private struct ExpertLibraryView: View {
    @ObservedObject var personaStore: ExpertPersonaStore
    let aiRuntime: ExpertAIRuntime
    let topic: String
    let joinedAssetPrefixes: Set<String>
    let joinedPersonaIds: Set<String>
    let roundTableCount: Int
    let isRoundTableFull: Bool
    let onJoin: (ExpertLibraryEntry) -> Void
    let onPreview: (ExpertLibraryEntry) -> Void

    @State private var selectedFilter = "全部"

    private var visibleEntries: [ExpertLibraryEntry] {
        expertLibraryEntries.filter { entry in
            selectedFilter == "全部" || entry.category == selectedFilter
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let viewport = ClipClashViewport(size: proxy.size)
            ZStack {
                PixelBackground()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: viewport.isPad ? 18 : 16) {
                        ExpertLibraryHeader(roundTableCount: roundTableCount)
                        ExpertLibraryFilterBar(selectedFilter: $selectedFilter)

                        LazyVGrid(columns: columns(for: viewport), spacing: viewport.isPad ? 14 : 12) {
                            ForEach(visibleEntries) { entry in
                                ExpertLibraryCard(
                                    personaStore: personaStore,
                                    aiRuntime: aiRuntime,
                                    topic: topic,
                                    entry: entry,
                                    isJoined: joinedPersonaIds.contains(personaId(forDisplayName: entry.name)) || entry.assetPrefix.map { joinedAssetPrefixes.contains($0) } ?? false,
                                    isRoundTableFull: isRoundTableFull,
                                    onJoin: onJoin,
                                    onPreview: onPreview
                                )
                            }
                        }
                    }
                    .frame(maxWidth: viewport.contentMaxWidth)
                    .padding(.horizontal, viewport.horizontalPadding)
                    .padding(.top, viewport.isPad ? 24 : 18)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func columns(for viewport: ClipClashViewport) -> [GridItem] {
        guard viewport.isPad else {
            return [GridItem(.flexible(), spacing: 12)]
        }
        let count = viewport.isWidePad ? 3 : 2
        return Array(repeating: GridItem(.flexible(minimum: 260), spacing: 14), count: count)
    }
}

private struct SettingsView: View {
    @ObservedObject var audioSettings: AppAudioSettings
    let currentProfile: SharedExpertLibraryProfile
    let friendProfiles: [SharedExpertLibraryProfile]
    let activeProfileId: UUID?
    let onImportPayload: (String) -> Bool
    let onApplyProfile: (SharedExpertLibraryProfile) -> Void
    let onDemoScan: () -> Void

    @State private var scanPayload = ""
    @State private var importStatus = "等待扫码"
    @State private var isShowingScanner = false

    var body: some View {
        GeometryReader { proxy in
            let viewport = ClipClashViewport(size: proxy.size)
            ZStack {
                PixelBackground()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: viewport.isPad ? 18 : 14) {
                        settingsHeader

                        LazyVGrid(columns: columns(for: viewport), spacing: 14) {
                            audioPanel
                            sharePanel
                            scanPanel
                            friendLibraryPanel
                        }
                    }
                    .frame(maxWidth: viewport.contentMaxWidth)
                    .padding(.horizontal, viewport.horizontalPadding)
                    .padding(.top, viewport.isPad ? 24 : 18)
                    .padding(.bottom, 34)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $isShowingScanner) {
            QRScannerSheet { value in
                scanPayload = value
                handleImport(value)
                isShowingScanner = false
            }
            .ignoresSafeArea()
        }
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("设置")
                .font(.system(size: 32, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
            Text("BGM / 扫码共享 / 好友专家库")
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .foregroundStyle(.yellow)
        }
    }

    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionTitle(icon: "speaker.wave.2.fill", title: "音频")

            SettingsSwitchRow(
                title: "开启 BGM",
                detail: audioSettings.isBGMEnabled ? "圆桌和 Battle 背景音乐开启" : "背景音乐已关闭，语音仍可播放",
                icon: audioSettings.isBGMEnabled ? "music.note" : "music.note.slash",
                tint: .yellow,
                isOn: $audioSettings.isBGMEnabled
            )

            SettingsSwitchRow(
                title: "语音 / 音效总静音",
                detail: audioSettings.isMuted ? "BGM、角色语音、按钮音效都关闭" : "角色语音和按钮音效正常",
                icon: audioSettings.isMuted ? "speaker.slash.fill" : "waveform",
                tint: .mint,
                isOn: $audioSettings.isMuted
            )
        }
        .padding(14)
        .background(PixelPanel(fill: Color.white.opacity(0.10), stroke: Color.yellow.opacity(0.38)))
    }

    private var sharePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionTitle(icon: "qrcode", title: "我的二维码")

            if let payload = currentProfile.qrPayload {
                QRCodeImage(payload: payload)
                    .frame(width: 192, height: 192)
                    .frame(maxWidth: .infinity)

                SharedLibrarySummary(profile: currentProfile, activeProfileId: activeProfileId)

                Button {
                    UIPasteboard.general.string = payload
                    importStatus = "已复制我的专家库二维码载荷"
                } label: {
                    SettingsCommandLabel(icon: "doc.on.doc.fill", title: "复制分享载荷", tint: .yellow)
                }
                .buttonStyle(.plain)
            } else {
                Text("二维码生成失败")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(PixelPanel(fill: Color.white.opacity(0.10), stroke: Color.mint.opacity(0.38)))
    }

    private var scanPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionTitle(icon: "qrcode.viewfinder", title: "扫码导入")

            HStack(spacing: 10) {
                Button {
                    isShowingScanner = true
                } label: {
                    SettingsCommandLabel(icon: "camera.viewfinder", title: "打开扫码", tint: .cyan)
                }
                .buttonStyle(.plain)

                Button {
                    onDemoScan()
                    importStatus = "已导入好友 Alex 的专家库"
                } label: {
                    SettingsCommandLabel(icon: "sparkles", title: "模拟扫码", tint: .orange)
                }
                .buttonStyle(.plain)
            }

            TextEditor(text: $scanPayload)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 86)
                .padding(8)
                .background(Color.black.opacity(0.34))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.14), lineWidth: 1))

            Button {
                handleImport(scanPayload)
            } label: {
                SettingsCommandLabel(icon: "square.and.arrow.down.fill", title: "导入扫码结果", tint: .mint)
            }
            .buttonStyle(.plain)

            Text(importStatus)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(importStatus.contains("失败") ? .orange : .white.opacity(0.76))
                .lineLimit(2)
                .minimumScaleFactor(0.76)
        }
        .padding(14)
        .background(PixelPanel(fill: Color.white.opacity(0.10), stroke: Color.cyan.opacity(0.36)))
    }

    private var friendLibraryPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionTitle(icon: "person.2.fill", title: "好友专家库")

            ForEach(friendProfiles) { profile in
                SharedLibraryProfileRow(
                    profile: profile,
                    isActive: activeProfileId == profile.id
                ) {
                    onApplyProfile(profile)
                    importStatus = "已切换到 \(profile.displayTitle)"
                }
            }
        }
        .padding(14)
        .background(PixelPanel(fill: Color.white.opacity(0.10), stroke: Color.orange.opacity(0.36)))
    }

    private func columns(for viewport: ClipClashViewport) -> [GridItem] {
        guard viewport.isPad else {
            return [GridItem(.flexible(), spacing: 14)]
        }
        return Array(repeating: GridItem(.flexible(minimum: 320), spacing: 14), count: viewport.isWidePad ? 2 : 1)
    }

    private func handleImport(_ value: String) {
        if onImportPayload(value) {
            importStatus = "扫码成功，已写入好友专家库"
        } else {
            importStatus = "导入失败，请确认二维码来自 ClipClash"
        }
    }
}

private struct SettingsSectionTitle: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 15, weight: .black, design: .monospaced))
            .foregroundStyle(.white)
    }
}

private struct SettingsSwitchRow: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.black)
                .frame(width: 38, height: 38)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(tint)
        }
        .padding(10)
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

private struct SettingsCommandLabel: View {
    let icon: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .black))
            Text(title)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: .black.opacity(0.30), radius: 0, x: 4, y: 4)
    }
}

private struct SharedLibrarySummary: View {
    let profile: SharedExpertLibraryProfile
    let activeProfileId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(profile.displayTitle)
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(activeProfileId == profile.id ? "使用中" : profile.sourceLabel)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(activeProfileId == profile.id ? Color.mint : Color.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }

            HStack(spacing: 8) {
                LibraryStat(label: "专家", value: "\(profile.experts.count)")
                LibraryStat(label: "驯化均值", value: "\(averageTaming)")
                LibraryStat(label: "共识均值", value: "\(averageConsensus)")
            }
        }
    }

    private var averageTaming: String {
        average(\.taming)
    }

    private var averageConsensus: String {
        average(\.consensus)
    }

    private func average(_ keyPath: KeyPath<SharedExpertSnapshot, Int>) -> String {
        guard !profile.experts.isEmpty else { return "0" }
        let total = profile.experts.reduce(0) { $0 + $1[keyPath: keyPath] }
        return String(format: "%.1f", Double(total) / Double(profile.experts.count))
    }
}

private struct SharedLibraryProfileRow: View {
    let profile: SharedExpertLibraryProfile
    let isActive: Bool
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SharedLibrarySummary(profile: profile, activeProfileId: isActive ? profile.id : nil)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(profile.experts.prefix(6)) { expert in
                        FriendExpertChip(expert: expert)
                    }
                }
            }

            Button(action: onApply) {
                SettingsCommandLabel(
                    icon: isActive ? "checkmark.seal.fill" : "arrow.triangle.2.circlepath",
                    title: isActive ? "当前正在使用" : "切换到这个专家库",
                    tint: isActive ? .mint : .yellow
                )
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.black.opacity(0.24))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(isActive ? Color.mint.opacity(0.55) : Color.white.opacity(0.14), lineWidth: 1))
    }
}

private struct FriendExpertChip: View {
    let expert: SharedExpertSnapshot

    var body: some View {
        VStack(spacing: 5) {
            if let assetPrefix = expert.assetPrefix {
                AnimatedPetView(assetPrefix: assetPrefix, state: "Supported", fps: 6)
                    .frame(width: 54, height: 62)
            } else {
                Text(String(expert.name.prefix(1)))
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .frame(width: 48, height: 48)
                    .background(Color.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Text(expert.name)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text("驯 \(expert.taming)")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundStyle(.mint)
        }
        .frame(width: 78, height: 98)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct QRCodeImage: View {
    let payload: String

    var body: some View {
        ZStack {
            Color.white
            if let image = QRCodeRenderer.image(from: payload) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black.opacity(0.75), lineWidth: 3))
        .shadow(color: .black.opacity(0.38), radius: 0, x: 5, y: 5)
    }
}

private enum QRCodeRenderer {
    private static let context = CIContext()
    private static let filter = CIFilter.qrCodeGenerator()

    static func image(from text: String) -> UIImage? {
        filter.message = Data(text.utf8)
        filter.correctionLevel = "L"
        guard let outputImage = filter.outputImage else { return nil }
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct QRScannerSheet: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        context.coordinator.makeViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onScan: (String) -> Void
        private let session = AVCaptureSession()
        private var didScan = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func makeViewController() -> UIViewController {
            let controller = UIViewController()
            controller.view.backgroundColor = .black

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                addFallbackLabel(to: controller.view, text: "没有可用摄像头\n可使用模拟扫码或粘贴载荷")
                return controller
            }

            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                addFallbackLabel(to: controller.view, text: "扫码模块不可用")
                return controller
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = UIScreen.main.bounds
            controller.view.layer.addSublayer(preview)

            addFallbackLabel(to: controller.view, text: "扫描好友 ClipClash 专家库二维码", yOffset: 92)

            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
            }
            return controller
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !didScan,
                  let metadata = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = metadata.stringValue else {
                return
            }
            didScan = true
            session.stopRunning()
            onScan(value)
        }

        private func addFallbackLabel(to view: UIView, text: String, yOffset: CGFloat = 0) {
            let label = UILabel()
            label.text = text
            label.textColor = .white
            label.font = .monospacedSystemFont(ofSize: 17, weight: .black)
            label.textAlignment = .center
            label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: yOffset),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
            ])
        }
    }
}

private struct ExpertLibraryHeader: View {
    let roundTableCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("我的专家库")
                        .font(.system(size: 32, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("可加入圆桌的动画专家席位")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                }

                Spacer()

                VStack(spacing: 2) {
                    Text("\(expertLibraryEntries.filter { $0.assetPrefix != nil }.count)")
                        .font(.system(size: 22, weight: .black, design: .monospaced))
                    Text("READY")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                }
                .foregroundStyle(.black)
                .frame(width: 66, height: 58)
                .background(.mint)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 0, x: 4, y: 4)
            }

        }
        .padding(14)
        .background(PixelPanel(fill: Color.white.opacity(0.10), stroke: Color.white.opacity(0.20)))
    }
}

private struct BattleExpertView: View {
    let expert: Expert
    let topic: String
    let sideStatus: BattleSideStatus
    let launchContext: BattleLaunchContext?
    let aiRuntime: ExpertAIRuntime
    @ObservedObject var personaStore: ExpertPersonaStore
    let onBack: () -> Void
    let onComplete: (BattleCompletion) -> Void

    @StateObject private var introVideo: MutedVideoPlayerViewModel
    @StateObject private var voiceRecorder = BattleVoiceRecorder()
    @StateObject private var speechTranscriber = BattleSpeechTranscriber()
    @State private var session: BattleSessionState
    @State private var lastReply: ExpertAIReply?
    @State private var battleMemoryNote: String?
    @State private var completionApplied = false
    @State private var showBackgroundBattle = false

    private let rounds = [
        BattleRound(id: 1, userPrompt: "你发起观点", aiGoal: "强反驳用户的核心前提，指出缺口或要求证据。"),
        BattleRound(id: 2, userPrompt: "你再反驳", aiGoal: "继续反击，若用户补足证据则表现出有限松动。"),
        BattleRound(id: 3, userPrompt: "你最后陈述", aiGoal: "总结 Battle 胜负理由，明确是否松动或仍然不服。")
    ]

    private var battleMood: BattleMood {
        if session.currentPhase.isUserActive { return .listening }
        if session.currentPhase.isAIThinking { return .thinking }
        if lastReply?.suggestedPetState == .Supported { return .softened }
        if lastReply?.suggestedPetState == .Opposed { return .challenging }
        if session.persuasion > 0.68 { return .softened }
        return .challenging
    }

    private var persona: ExpertPersona {
        personaStore.persona(forDisplayName: expert.name)
    }

    private var latestMemory: String? {
        battleMemoryNote ?? personaStore.latestMemory(forId: personaId(forDisplayName: expert.name))
    }

    private var isPerfectDemoBattle: Bool {
        PerfectDemoScript.isCountyDemoTopic(topic)
    }

    init(
        expert: Expert,
        topic: String,
        sideStatus: BattleSideStatus,
        launchContext: BattleLaunchContext?,
        aiRuntime: ExpertAIRuntime,
        personaStore: ExpertPersonaStore,
        onBack: @escaping () -> Void,
        onComplete: @escaping (BattleCompletion) -> Void
    ) {
        self.expert = expert
        self.topic = topic
        self.sideStatus = sideStatus
        self.launchContext = launchContext
        self.aiRuntime = aiRuntime
        self.personaStore = personaStore
        self.onBack = onBack
        self.onComplete = onComplete
        _session = State(initialValue: Self.initialSession(expert: expert, topic: topic, sideStatus: sideStatus, launchContext: launchContext, personaStore: personaStore))
        _introVideo = StateObject(wrappedValue: MutedVideoPlayerViewModel(resourceName: "battle_clash_intro"))
    }

    var body: some View {
        GeometryReader { proxy in
            let viewport = ClipClashViewport(size: proxy.size)
            ZStack {
                PixelBackground()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: viewport.isPad ? 18 : 16) {
                        if viewport.isPad {
                            HStack(alignment: .top, spacing: 18) {
                                VStack(spacing: 16) {
                                    battleHeader
                                    battleVideo
                                    BattleRoundTimeline(rounds: rounds, session: session)
                                }
                                .frame(width: viewport.battleLeftColumnWidth)

                                battleControlColumn(micSize: viewport.isWidePad ? 96 : 90)
                                    .frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 16) {
                                battleHeader
                                battleVideo
                                BattleRoundTimeline(rounds: rounds, session: session)
                                battleControlColumn(micSize: 82)
                            }
                        }
                    }
                    .frame(maxWidth: viewport.contentMaxWidth)
                    .padding(.horizontal, viewport.horizontalPadding)
                    .padding(.top, viewport.isPad ? 24 : 18)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            beginBattleIfNeeded()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            tickCountdown()
        }
        .onChange(of: expert.id) { _, _ in
            resetBattle(startImmediately: true)
        }
        .onChange(of: topic) { _, _ in
            resetBattle(startImmediately: true)
        }
        .onChange(of: launchContext?.id) { _, _ in
            resetBattle(startImmediately: true)
        }
        .onDisappear {
            voiceRecorder.cancel()
            introVideo.stop()
        }
    }

    private var battleHeader: some View {
        BattleHeaderV2(expert: expert, session: session, sideStatus: sideStatus, launchContext: launchContext, onBack: onBack)
    }

    private var battleVideo: some View {
        BattleVideoCard(
            expert: expert,
            session: session,
            sideStatus: sideStatus,
            mood: battleMood,
            reply: lastReply,
            viewModel: introVideo,
            onReplay: replayIntroClip
        )
    }

    private func battleArena(height: CGFloat) -> some View {
        BattleArenaV2(
            expert: expert,
            session: session,
            mood: battleMood,
            reply: lastReply,
            arenaHeight: height
        )
    }

    private func battleControlColumn(micSize: CGFloat) -> some View {
        VStack(spacing: 16) {
            BattleDialoguePanelV2(
                expert: expert,
                messages: session.visibleMessages,
                phase: session.currentPhase,
                liveTranscript: session.latestTranscript
            )
            BattleVoiceConsoleV2(
                expert: expert,
                session: session,
                recorder: voiceRecorder,
                isTranscribing: speechTranscriber.isTranscribing,
                transcriberErrorMessage: speechTranscriber.errorMessage,
                transcript: Binding(
                    get: { session.latestTranscript },
                    set: { session.latestTranscript = $0 }
                ),
                micSize: micSize,
                onPrimaryAction: handleVoiceAction,
                onEndTurn: submitUserTurn
            )
            if let result = session.result {
                BattleResultPanel(
                    expert: expert,
                    session: session,
                    result: result,
                    showBackgroundBattle: showBackgroundBattle,
                    onToggleBackground: {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.76)) {
                            showBackgroundBattle.toggle()
                        }
                    },
                    onApply: applyResultAndReturn
                )
            }
            BattleMemoryPanelV2(expert: expert, session: session, memoryNote: latestMemory)
        }
    }

    private static func initialSession(
        expert: Expert,
        topic: String,
        sideStatus: BattleSideStatus,
        launchContext: BattleLaunchContext?,
        personaStore: ExpertPersonaStore
    ) -> BattleSessionState {
        let persona = personaStore.persona(forDisplayName: expert.name)
        let opener = opponentLine(for: expert, persona: persona, launchContext: launchContext)
        let basePersuasion: Double = {
            if sideStatus.userSideCount > sideStatus.expertSideCount { return 0.34 }
            if sideStatus.userSideCount == sideStatus.expertSideCount { return 0.28 }
            return 0.22
        }()
        let resistance = max(0.10, baseResistance(for: expert.side) - basePersuasion * 0.22)
        let openness = min(0.92, 0.22 + basePersuasion * 0.64)
        let total = max(1, sideStatus.userSideCount + sideStatus.expertSideCount)
        let score = BattleScore(
            user: min(0.82, Double(sideStatus.userSideCount) / Double(total) + 0.08),
            expert: min(0.82, Double(sideStatus.expertSideCount) / Double(total) + 0.08)
        )

        return BattleSessionState(
            expertId: personaId(forDisplayName: expert.name),
            expertName: expert.name,
            topic: topic,
            messages: [
                BattleTurnMessage(speaker: expert.name, text: opener, isPlayer: false),
                BattleTurnMessage(speaker: "系统", text: launchContext?.roundtableSummary ?? "Battle 由阵营变化触发：\(sideStatus.label)。3 回合、每回合 60 秒，AI 目标 5 秒内回应。", isPlayer: false)
            ],
            persuasion: basePersuasion,
            resistance: resistance,
            openness: openness,
            score: score
        )
    }

    private static func opponentLine(for expert: Expert, persona: ExpertPersona, launchContext: BattleLaunchContext?) -> String {
        if PerfectDemoScript.isCountyDemoTopic(launchContext?.topic ?? ""),
           expert.name == "张一鸣" {
            return "少装一点。刚才圆桌里我卡住的是：县城低成本不等于长期选择权。你要说服我，先证明县城不是退路。"
        }
        if let launchContext, launchContext.expertId == expert.id {
            let catchphrase = persona.catchphrases.first ?? "我先听听。"
            return "\(catchphrase) \(launchContext.openingChallengeLine)"
        }
        let roundtableContext = "刚才圆桌里我说：\(expert.quote)"
        return "\(persona.catchphrases.first ?? "我先听听。") \(roundtableContext) \(persona.debateStyle)"
    }

    private static func baseResistance(for side: Expert.Side) -> Double {
        switch side {
        case .pro:
            return 0.40
        case .con:
            return 0.76
        case .swing:
            return 0.56
        }
    }

    private func beginBattleIfNeeded() {
        guard session.startedAt == nil || session.currentPhase == .preparing else { return }
        startIntro()
    }

    private func startIntro() {
        let battleId = session.battleId
        withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
            session.startedAt = Date()
            session.currentPhase = .intro
            session.events.append(.metricShift("Battle 过场启动"))
        }
        SFXPlayer.shared.play(.battleStart, volume: 0.44)
        introVideo.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.80) {
            guard session.battleId == battleId, session.currentPhase == .intro else { return }
            beginUserTurn(1)
        }
    }

    private func beginUserTurn(_ round: Int) {
        guard round <= session.maxRounds else {
            evaluateBattle()
            return
        }

        withAnimation(.spring(response: 0.24, dampingFraction: 0.76)) {
            session.roundIndex = round
            session.remainingSeconds = session.userTimeLimit
            session.latestTranscript = isPerfectDemoBattle ? (PerfectDemoScript.battleUserLine(for: round) ?? "") : ""
            session.currentPhase = .userTurn(round: round)
            session.events.append(.userTurnStarted(round))
        }
        voiceRecorder.resetForNextTurn()
    }

    private func tickCountdown() {
        guard session.currentPhase.isUserActive else { return }
        guard session.remainingSeconds > 0 else {
            submitUserTurn()
            return
        }
        session.remainingSeconds -= 1
        if session.remainingSeconds == 0 {
            submitUserTurn()
        }
    }

    private func replayIntroClip() {
        introVideo.play(from: 0.9)
        SFXPlayer.shared.play(.battleStart, volume: 0.28)
    }

    private func handleVoiceAction() {
        switch session.currentPhase {
        case .preparing:
            startIntro()
        case .intro:
            replayIntroClip()
        case .userTurn(let round):
            if voiceRecorder.isRecording {
                submitUserTurn()
            } else {
                startVoiceRecording(round: round)
            }
        case .transcribing:
            return
        case .aiThinking, .aiSpeaking, .evaluating, .completed, .backgroundWatching:
            return
        }
    }

    private func startVoiceRecording(round: Int) {
        let battleId = session.battleId
        SFXPlayer.shared.play(.micOn, volume: 0.44)
        introVideo.play(from: 1.5)

        voiceRecorder.start(round: round, battleId: battleId, expertName: expert.name) { started in
            guard session.battleId == battleId, started else { return }
            session.events.append(.metricShift("Round \(round) 真实录音启动"))
        }
    }

    private func submitUserTurn() {
        guard session.currentPhase.isUserActive else { return }
        let round = session.currentPhase.roundIndex ?? session.roundIndex
        let recording = voiceRecorder.isRecording ? voiceRecorder.stop() : voiceRecorder.lastRecording
        let battleId = session.battleId
        let manualText = session.latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        SFXPlayer.shared.play(.micOff, volume: 0.32)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.74)) {
            session.currentPhase = .transcribing(round: round)
            if recording != nil {
                session.latestTranscript = "正在使用 iOS Speech 转写录音..."
            }
        }

        Task {
            let transcribedText: String?
            if let recording {
                transcribedText = await speechTranscriber.transcribe(recording)
            } else {
                transcribedText = nil
            }

            await MainActor.run {
                guard session.battleId == battleId, session.currentPhase == .transcribing(round: round) else { return }
                let playerLine = userSpeechLine(
                    manualText: manualText,
                    transcribedText: transcribedText,
                    recording: recording,
                    round: round
                )
                let userVoiceDuration: TimeInterval
                if isPerfectDemoBattle, recording == nil {
                    userVoiceDuration = SpotlightVoicePlayer.shared.play(clipName: PerfectDemoScript.battleUserVoiceClip(for: round))
                } else {
                    userVoiceDuration = 0
                }
                let userMessage = BattleTurnMessage(speaker: "你", text: playerLine, isPlayer: true, round: round)
                let nextMessages = session.messages + [userMessage]
                let request = makeBattleRequest(userLine: playerLine, round: round, messages: nextMessages)

                withAnimation(.spring(response: 0.24, dampingFraction: 0.74)) {
                    session.messages = nextMessages
                    session.latestTranscript = playerLine
                    session.currentPhase = .aiThinking(round: round)
                    session.events.append(.userSubmitted(round, playerLine))
                }

                Task {
                    if userVoiceDuration > 0 {
                        let waitSeconds = min(max(userVoiceDuration + 0.24, 1.0), 14.0)
                        try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                    }
                    let reply = await aiReplyWithinTarget(request: request, round: round)
                    await MainActor.run {
                        apply(reply: reply, round: round, battleId: battleId)
                    }
                }
            }
        }
    }

    private func userSpeechLine(
        manualText: String,
        transcribedText: String?,
        recording: BattleRecordedAudio?,
        round: Int
    ) -> String {
        let ignoredPlaceholders = ["正在使用 iOS Speech 转写录音..."]
        let cleanedManual = ignoredPlaceholders.contains(manualText) ? "" : manualText
        if let transcribedText, !transcribedText.isEmpty {
            return transcribedText
        }
        if !cleanedManual.isEmpty {
            return cleanedManual
        }
        if isPerfectDemoBattle, let demoLine = PerfectDemoScript.battleUserLine(for: round) {
            return demoLine
        }
        if let recording {
            return "我录制了一段 \(recording.durationText) 的语音，但 iOS Speech 没有识别出清晰文字。请追问我补充核心论点。"
        }
        return "我还没有形成有效发言，请追问我补充第 \(round) 回合观点。"
    }

    private func requestAIReply(_ request: ExpertAIRequest, round: Int, battleId: UUID) {
        Task {
            let reply = await aiReplyWithinTarget(request: request, round: round)
            await MainActor.run {
                apply(reply: reply, round: round, battleId: battleId)
            }
        }
    }

    private func makeBattleRequest(userLine: String, round: Int, messages: [BattleTurnMessage]) -> ExpertAIRequest {
        let roundInfo = rounds.first(where: { $0.id == round }) ?? rounds[0]
        let personaText = """
        ExpertCoreBelief: \(persona.coreBelief)
        ExpertDebateStyle: \(persona.debateStyle)
        ImmutablePersonaBoundary: \(persona.safetyNotes)
        """
        let context = """
        BattleContext:
        - Topic: \(topic)
        - Trigger: \(sideStatus.label)
        - RoundtableConflictPoint: \(launchContext?.conflictPoint ?? "当前专家仍未被说服")
        - RoundtableSummary: \(launchContext?.roundtableSummary ?? "未提供额外圆桌摘要")
        - UserBattleGoal: \(launchContext?.userGoal ?? "说服当前专家接受你的判断方式")
        - ExpertOpeningChallenge: \(launchContext?.openingChallengeLine ?? expert.quote)
        - Round: \(round)/\(session.maxRounds) (\(roundInfo.userPrompt))
        - UserTimeLimitSeconds: \(session.userTimeLimit)
        - AIResponseTargetSeconds: \(session.aiResponseTargetSeconds)
        - CurrentPersuasion: \(String(format: "%.2f", session.persuasion))
        - CurrentResistance: \(String(format: "%.2f", session.resistance))
        - CurrentOpenness: \(String(format: "%.2f", session.openness))
        - UserSideScore: \(String(format: "%.2f", session.score.user))
        - ExpertSideScore: \(String(format: "%.2f", session.score.expert))
        - ThisRoundAIInstruction: \(roundInfo.aiGoal)
        \(personaText)

        UserLastSpeech:
        \(userLine)

        Return the existing ExpertAIReply JSON only. Keep text tense and specific. The reply must continue the roundtable conflict instead of starting a generic chat.
        """

        let history = messages.suffix(10).map {
            ExpertConversationMessage(
                role: $0.isPlayer ? "user" : ($0.speaker == "系统" ? "system" : "assistant"),
                content: "Round \($0.round.map(String.init) ?? "-") \($0.speaker): \($0.text)"
            )
        }

        return ExpertAIRequest(
            expertId: personaId(forDisplayName: expert.name),
            topic: topic,
            userMessage: context,
            scene: .battle,
            currentPersuasion: session.persuasion,
            conversationHistory: history
        )
    }

    private func aiReplyWithinTarget(request: ExpertAIRequest, round: Int) async -> ExpertAIReply {
        if isPerfectDemoBattle, let reply = PerfectDemoScript.battleReply(for: expert.name, round: round) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return reply
        }
        let localFallback = fallbackReply(round: round)
        return await withTaskGroup(of: ExpertAIReply.self) { group in
            group.addTask {
                (try? await aiRuntime.reply(to: request)) ?? localFallback
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_200_000_000)
                return localFallback
            }
            let reply = await group.next() ?? localFallback
            group.cancelAll()
            return reply
        }
    }

    private func fallbackReply(round: Int) -> ExpertAIReply {
        let persona = personaStore.persona(forDisplayName: expert.name)
        let accept = persona.agreementTriggers.first ?? "具体证据"
        let reject = persona.disagreementTriggers.first ?? "逻辑漏洞"
        let catchphrase = persona.catchphrases.first ?? "我先说一个关键点。"
        let text: String
        let stance: ExpertStance
        let emotion: ExpertEmotion
        let delta: Double
        switch round {
        case 1:
            text = "\(catchphrase) 我先反驳你这一点：现在最大的问题是「\(reject)」，你要先拿出「\(accept)」，不然我不会让步。"
            stance = .oppose
            emotion = .skeptical
            delta = 0.05
        case 2:
            text = "\(catchphrase) 你补了一点，但还没打穿我的边界；把「\(accept)」讲成一个可验证例子，我才会松动。"
            stance = .swing
            emotion = .skeptical
            delta = 0.07
        default:
            text = "\(catchphrase) 这一轮我只给有限松动：你的方向能听，但「\(reject)」没处理完，胜负还不能算你拿下。"
            stance = .swing
            emotion = .calm
            delta = 0.08
        }
        return ExpertAIReply(
            text: text,
            stance: stance,
            emotion: emotion,
            persuasionDelta: delta,
            suggestedPetState: stance == .oppose ? .Opposed : .Speaking,
            shortQuote: "先补\(accept)。",
            memoryNote: "\(persona.displayName) 使用本地 persona 兜底完成反驳，核心卡点是「\(reject)」。"
        )
    }

    private func apply(reply: ExpertAIReply, round: Int, battleId: UUID) {
        guard session.battleId == battleId else { return }
        let delta = max(-0.18, min(0.28, reply.persuasionDelta))
        let stanceBonus: Double
        switch reply.stance {
        case .support:
            stanceBonus = 0.13
        case .swing:
            stanceBonus = 0.08
        case .oppose:
            stanceBonus = 0.02
        }
        let userGain = max(0.03, delta * 0.92 + stanceBonus)
        let expertGain = max(0.02, (reply.stance == .oppose ? 0.12 : 0.04) + max(0, -delta * 0.5))
        let nextPersuasion = min(0.96, max(0.04, session.persuasion + delta))
        let nextResistance = min(0.96, max(0.06, session.resistance - delta * 0.58 + (reply.stance == .oppose ? 0.025 : -0.035)))
        let nextOpenness = min(0.96, max(0.08, session.openness + delta * 0.72 + (reply.stance == .support ? 0.06 : 0.015)))
        let metricLine = metricMessage(for: reply, nextPersuasion: nextPersuasion, nextResistance: nextResistance)

        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            session.currentPhase = .aiSpeaking(round: round)
            session.messages.append(BattleTurnMessage(speaker: expert.name, text: reply.text, isPlayer: false, round: round))
            session.persuasion = nextPersuasion
            session.resistance = nextResistance
            session.openness = nextOpenness
            session.score.user = min(1.0, session.score.user + userGain)
            session.score.expert = min(1.0, session.score.expert + expertGain)
            session.finalQuote = reply.shortQuote.isEmpty ? reply.text.compactTopicLine(maxLength: 30) : reply.shortQuote
            session.events.append(.aiReply(round, reply.text))
            if !metricLine.isEmpty {
                session.decisiveMoments.append(metricLine)
                session.events.append(.metricShift(metricLine))
                session.messages.append(BattleTurnMessage(speaker: "系统", text: metricLine, isPlayer: false, round: round))
            }
            battleMemoryNote = reply.memoryNote
            lastReply = reply
        }

        let expertVoiceDuration = SpotlightVoicePlayer.shared.play(clipName: PerfectDemoScript.battleExpertVoiceClip(for: expert.name, round: round))

        if reply.stance == .oppose && delta < 0.12 {
            SFXPlayer.shared.play(.rebuttalHit, volume: 0.40)
        } else if delta >= 0.12 || reply.stance == .support {
            SFXPlayer.shared.play(.persuasionUp, volume: 0.42)
        }

        let nextStepDelay = expertVoiceDuration > 0 ? min(max(expertVoiceDuration + 0.45, 1.0), 18.0) : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + nextStepDelay) {
            guard session.battleId == battleId, session.currentPhase == .aiSpeaking(round: round) else { return }
            if round < session.maxRounds {
                beginUserTurn(round + 1)
            } else {
                evaluateBattle()
            }
        }
    }

    private func metricMessage(for reply: ExpertAIReply, nextPersuasion: Double, nextResistance: Double) -> String {
        if reply.persuasionDelta >= 0.16 || reply.stance == .support {
            return "立场松动：说服度升至 \(Int(nextPersuasion * 100))%，\(expert.name) 开始接受你的判断方式。"
        }
        if reply.stance == .oppose {
            return "强反驳命中：不服值仍有 \(Int(nextResistance * 100))%，先拆他的核心边界。"
        }
        if reply.stance == .swing {
            return "分歧收窄：\(expert.name) 没完全同意，但愿意继续听证据。"
        }
        return ""
    }

    private func evaluateBattle() {
        let battleId = session.battleId
        withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
            session.currentPhase = .evaluating
            session.latestTranscript = ""
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) {
            guard session.battleId == battleId, session.currentPhase == .evaluating else { return }
            completeBattle()
        }
    }

    private func completeBattle() {
        let result = decideResult()
        let reason = resultReason(for: result)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
            session.currentPhase = .completed(result: result)
            session.endedAt = Date()
            session.resultReason = reason
            session.events.append(.completed(result))
            session.messages.append(BattleTurnMessage(speaker: "裁决", text: reason, isPlayer: false, round: session.roundIndex))
        }

        switch result {
        case .win, .expertSoftened:
            SFXPlayer.shared.play(.battleWin, volume: 0.48)
        case .draw:
            SFXPlayer.shared.play(.persuasionUp, volume: 0.40)
        case .lose, .expertUnmoved:
            SFXPlayer.shared.play(.battleLose, volume: 0.48)
        }
    }

    private func decideResult() -> BattleResult {
        let diff = session.score.user - session.score.expert
        if session.persuasion >= 0.74 && diff >= -0.02 {
            return .win
        }
        if session.persuasion >= 0.58 || session.openness >= 0.64 {
            return .expertSoftened
        }
        if abs(diff) <= 0.08 {
            return .draw
        }
        if session.resistance >= 0.70 {
            return .expertUnmoved
        }
        return diff > 0 ? .draw : .lose
    }

    private func resultReason(for result: BattleResult) -> String {
        let scoreLine = "终局比分 你方 \(Int(session.score.user * 100)) / 专家 \(Int(session.score.expert * 100))，说服度 \(Int(session.persuasion * 100))%，不服值 \(Int(session.resistance * 100))%。"
        if isPerfectDemoBattle {
            return PerfectDemoScript.demoBattleResultReason(scoreLine: scoreLine, expertName: expert.name)
        }
        switch result {
        case .win:
            return "\(scoreLine) 你连续处理了 \(expert.name) 的核心边界，圆桌胜负倾向转向你方。"
        case .lose:
            return "\(scoreLine) 你的论点没有突破对方底层信念，本轮专家守住阵营。"
        case .draw:
            return "\(scoreLine) 双方都拿到有效点，但没有形成压倒性共识，圆桌保持拉扯。"
        case .expertSoftened:
            return "\(scoreLine) \(expert.name) 没完全倒戈，但已经明显松动，后续圆桌更容易被你影响。"
        case .expertUnmoved:
            return "\(scoreLine) \(expert.name) 仍然嘴硬，下一次需要更具体的证据链。"
        }
    }

    private func applyResultAndReturn() {
        guard let result = session.result, !completionApplied else { return }
        completionApplied = true
        let quote = session.finalQuote ?? result.title
        let reason = session.resultReason ?? result.title
        personaStore.recordBattleCompletion(
            result: result,
            persuasion: session.persuasion,
            openness: session.openness,
            reason: reason,
            forExpertId: session.expertId
        )
        onComplete(
            BattleCompletion(
                expertId: expert.id,
                expertName: expert.name,
                result: result,
                quote: quote,
                side: result.side,
                persuasion: session.persuasion,
                openness: session.openness,
                reason: reason
            )
        )
    }

    private func resetBattle(startImmediately: Bool) {
        introVideo.stop()
        session = Self.initialSession(expert: expert, topic: topic, sideStatus: sideStatus, launchContext: launchContext, personaStore: personaStore)
        lastReply = nil
        battleMemoryNote = nil
        completionApplied = false
        showBackgroundBattle = false
        if startImmediately {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                startIntro()
            }
        }
    }

    private func playerArgument(for round: Int) -> String {
        let compactTopic = topic.compactTopicLine(maxLength: 34)
        let lines = [
            "我先承认你的担心，但「\(compactTopic)」不是靠情绪赢，要看它能不能被持续验证。",
            "我补一个更具体的判断：如果收益只留给平台、代价给个体承担，这就不是进步，是转嫁成本。",
            "最后我把分歧收窄：你可以不完全同意结论，但先接受我们要同时算效率、代价和补偿机制。"
        ]
        return lines[(round - 1) % lines.count]
    }
}

private struct LegacyBattleExpertView: View {
    let expert: Expert
    let topic: String
    let sideStatus: BattleSideStatus
    let aiRuntime: ExpertAIRuntime
    @ObservedObject var personaStore: ExpertPersonaStore
    let onBack: () -> Void
    let onComplete: (BattleCompletion) -> Void

    @State private var isListening = false
    @State private var isExpertThinking = false
    @State private var persuasion: CGFloat = 0.26
    @State private var round = 1
    @State private var messages: [BattleTurnMessage] = []
    @State private var lastReply: ExpertAIReply?
    @State private var battleMemoryNote: String?
    @State private var transitionClip: AppTransitionClip?

    private var baseResistance: CGFloat {
        switch expert.side {
        case .pro:
            return 0.34
        case .con:
            return 0.72
        case .swing:
            return 0.52
        }
    }

    private var resistance: CGFloat {
        max(0.08, baseResistance - persuasion * 0.52)
    }

    private var openness: CGFloat {
        min(0.96, 0.22 + persuasion * 0.78)
    }

    private var battleMood: BattleMood {
        if isListening { return .listening }
        if isExpertThinking { return .thinking }
        if lastReply?.suggestedPetState == .Supported { return .softened }
        if lastReply?.suggestedPetState == .Opposed { return .challenging }
        if persuasion > 0.68 { return .softened }
        return .challenging
    }

    private var persona: ExpertPersona? {
        personaStore.persona(forDisplayName: expert.name)
    }

    private var opponentLine: String {
        let roundtableContext = "刚才圆桌里我说：\(expert.quote)"
        if let persona {
            return "\(persona.catchphrases.first ?? "我先听听。") \(roundtableContext) \(persona.debateStyle)"
        }

        switch expert.side {
        case .pro:
            return "\(roundtableContext) 我可以听，但你要给出能复用的证据。"
        case .con:
            return "\(roundtableContext) 我不服。这个观点太轻了，还说服不了我。"
        case .swing:
            return "\(roundtableContext) 我有点动摇，但还需要一个更稳的理由。"
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let viewport = ClipClashViewport(size: proxy.size)
            ZStack {
                PixelBackground()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: viewport.isPad ? 18 : 16) {
                        if viewport.isPad {
                            HStack(alignment: .top, spacing: 18) {
                                VStack(spacing: 16) {
                                    battleHeader
                                    battleArena(height: viewport.battleArenaHeight)
                                    BattleStrategyPanel(expert: expert, persuasion: persuasion)
                                }
                                .frame(width: viewport.battleLeftColumnWidth)

                                battleControlColumn(micSize: viewport.isWidePad ? 96 : 90)
                                    .frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 16) {
                                battleHeader
                                battleArena(height: viewport.battleArenaHeight)
                                battleControlColumn(micSize: 82)
                                BattleStrategyPanel(expert: expert, persuasion: persuasion)
                            }
                        }
                    }
                    .frame(maxWidth: viewport.contentMaxWidth)
                    .padding(.horizontal, viewport.horizontalPadding)
                    .padding(.top, viewport.isPad ? 24 : 18)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }

                if let transitionClip {
                    VideoTransitionOverlay(clip: transitionClip) {
                        self.transitionClip = nil
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(8)
                }
            }
        }
        .onAppear {
            if messages.isEmpty {
                messages = [
                    BattleTurnMessage(speaker: expert.name, text: opponentLine, isPlayer: false),
                    BattleTurnMessage(speaker: "系统", text: "点麦克风，把你的观点讲给 \(expert.name)。他会先反驳，再慢慢被你说服。", isPlayer: false)
                ]
            }
            showTransition(.battleIntro(for: expert))
        }
        .onChange(of: expert.id) { _, _ in
            resetBattle()
            showTransition(.battleIntro(for: expert))
        }
        .onChange(of: topic) { _, _ in
            resetBattle()
        }
    }

    private var battleHeader: some View {
        BattleHeader(
            expert: expert,
            round: round,
            persuasion: persuasion,
            sideStatus: sideStatus,
            onBack: onBack
        )
    }

    private func battleArena(height: CGFloat) -> some View {
        BattleArena(
            expert: expert,
            resistance: resistance,
            persuasion: persuasion,
            openness: openness,
            mood: battleMood,
            reply: lastReply,
            arenaHeight: height
        )
    }

    private func battleControlColumn(micSize: CGFloat) -> some View {
        VStack(spacing: 16) {
            BattleDialoguePanel(
                expert: expert,
                messages: messages,
                isExpertThinking: isExpertThinking
            )
            BattleVoiceConsole(
                expert: expert,
                isListening: isListening,
                isExpertThinking: isExpertThinking,
                persuasion: persuasion,
                micSize: micSize,
                onMicTap: handleMicTap
            )
            BattleMemoryPanel(expert: expert, impression: openness, memoryNote: battleMemoryNote ?? personaStore.latestMemory(forId: personaId(forDisplayName: expert.name)))
        }
    }

    private func handleMicTap() {
        guard !isExpertThinking else { return }
        guard transitionClip == nil else { return }

        if isListening {
            finishListening()
        } else {
            showTransition(.battleMic(for: expert))
            withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
                isListening = true
            }
        }
    }

    private func showTransition(_ clip: AppTransitionClip) {
        guard transitionClip == nil else { return }
        transitionClip = clip
    }

    private func finishListening() {
        let playerLine = playerArgument(for: round)
        let history = (messages + [BattleTurnMessage(speaker: "你", text: playerLine, isPlayer: true)]).map {
            ExpertConversationMessage(role: $0.isPlayer ? "user" : "assistant", content: "\($0.speaker): \($0.text)")
        }
        let request = ExpertAIRequest(
            expertId: personaId(forDisplayName: expert.name),
            topic: topic,
            userMessage: playerLine,
            scene: .battle,
            currentPersuasion: Double(persuasion),
            conversationHistory: history
        )

        withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
            isListening = false
            messages.append(BattleTurnMessage(speaker: "你", text: playerLine, isPlayer: true))
            isExpertThinking = true
        }

        Task {
            let reply: ExpertAIReply
            do {
                reply = try await aiRuntime.reply(to: request)
            } catch {
                reply = ExpertAIReply(
                    text: "线上服务器暂时没有返回，本轮没有生成专家结论。请稍后重试。",
                    stance: .swing,
                    emotion: .calm,
                    persuasionDelta: 0.0,
                    suggestedPetState: .Speaking,
                    shortQuote: "线上未返回。",
                    memoryNote: "Battle 等待线上专家响应，但服务器暂未返回。"
                )
            }

            await MainActor.run {
                apply(reply: reply)
            }
        }
    }

    private func apply(reply: ExpertAIReply) {
        let delta = CGFloat(max(-0.18, min(0.28, reply.persuasionDelta)))
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            messages.append(BattleTurnMessage(speaker: expert.name, text: reply.text, isPlayer: false))
            if reply.persuasionDelta >= 0.16 {
                messages.append(BattleTurnMessage(speaker: "系统", text: "立场松动：\(expert.name) 开始接受你的判断方式。", isPlayer: false))
            } else if reply.stance == .oppose {
                messages.append(BattleTurnMessage(speaker: "系统", text: "\(expert.name) 进入更强反驳状态。", isPlayer: false))
            }
            persuasion = min(0.94, max(0.04, persuasion + delta))
            battleMemoryNote = reply.memoryNote
            lastReply = reply
            round += 1
            isExpertThinking = false
        }
    }

    private func finishListeningLegacy() {
        let playerLine = playerArgument(for: round)
        let expertLine = "我先保留反对。这个观点还需要更具体的证据。"

        withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
            isListening = false
            messages.append(BattleTurnMessage(speaker: "你", text: playerLine, isPlayer: true))
            isExpertThinking = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                messages.append(BattleTurnMessage(speaker: expert.name, text: expertLine, isPlayer: false))
                persuasion = min(0.94, persuasion + 0.06)
                round += 1
                isExpertThinking = false
            }
        }
    }

    private func resetBattle() {
        isListening = false
        isExpertThinking = false
        persuasion = 0.26
        round = 1
        lastReply = nil
        battleMemoryNote = personaStore.latestMemory(forId: personaId(forDisplayName: expert.name))
        messages = [
            BattleTurnMessage(speaker: expert.name, text: opponentLine, isPlayer: false),
            BattleTurnMessage(speaker: "系统", text: "点麦克风，把你的观点讲给 \(expert.name)。专家回复来自线上服务器。", isPlayer: false)
        ]
    }

    private func playerArgument(for round: Int) -> String {
        let compactTopic = topic.compactTopicLine(maxLength: 34)
        let lines = [
            "我先承认你的担心，但「\(compactTopic)」不是靠情绪赢，要看它能不能被持续验证。",
            "我补一个更具体的判断：如果收益只留给平台、代价给个体承担，这就不是进步，是转嫁成本。",
            "最后我把分歧收窄：你可以不完全同意结论，但先接受我们要同时算效率、代价和补偿机制。"
        ]
        return lines[(round - 1) % lines.count]
    }

}

private struct BattleHeaderV2: View {
    let expert: Expert
    let session: BattleSessionState
    let sideStatus: BattleSideStatus
    let launchContext: BattleLaunchContext?
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .background(.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                Text("1V1 VOICE BATTLE")
                    .font(.system(size: 27, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                Text("\(sideStatus.triggerReason) · 对手 \(expert.name)")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(expert.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(launchContext?.conflictPoint ?? session.topic)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                if let launchContext {
                    Text(launchContext.userGoal)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(launchContext.tint.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                BattleHeaderBadge(title: "ROUND", value: "\(session.roundIndex)/\(session.maxRounds)", fill: .mint)
                BattleHeaderBadge(
                    title: session.currentPhase.isUserActive ? "TIME" : session.currentPhase.label.uppercased(),
                    value: session.currentPhase.isUserActive ? "\(session.remainingSeconds)s" : "\(Int(session.persuasion * 100))%",
                    fill: session.remainingSeconds <= 10 && session.currentPhase.isUserActive ? .red : .yellow
                )
            }
        }
        .padding(14)
        .background(PixelPanel(fill: Color.white.opacity(0.10), stroke: expert.tint.opacity(0.42)))
    }
}

private struct BattleHeaderBadge: View {
    let title: String
    let value: String
    let fill: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(value)
                .font(.system(size: 17, weight: .black, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .foregroundStyle(.black)
        .frame(width: 62, height: 52)
        .background(fill)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 0, x: 4, y: 4)
    }
}

private struct BattleVideoCard: View {
    let expert: Expert
    let session: BattleSessionState
    let sideStatus: BattleSideStatus
    let mood: BattleMood
    let reply: ExpertAIReply?
    @ObservedObject var viewModel: MutedVideoPlayerViewModel
    let onReplay: () -> Void

    @State private var fallbackPulse = false
    @State private var petPulse = false

    init(
        expert: Expert,
        session: BattleSessionState,
        sideStatus: BattleSideStatus,
        mood: BattleMood,
        reply: ExpertAIReply?,
        viewModel: MutedVideoPlayerViewModel,
        onReplay: @escaping () -> Void
    ) {
        self.expert = expert
        self.session = session
        self.sideStatus = sideStatus
        self.mood = mood
        self.reply = reply
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self.onReplay = onReplay
    }

    private var showsIntroClip: Bool {
        switch session.currentPhase {
        case .preparing, .intro:
            return viewModel.player != nil
        case .userTurn, .transcribing, .aiThinking, .aiSpeaking, .evaluating, .completed, .backgroundWatching:
            return false
        }
    }

    var body: some View {
        ZStack {
            if showsIntroClip, let player = viewModel.player {
                introLayer(player: player)
            } else {
                challengerStage
            }

            VStack {
                HStack {
                    BattleOverlayTag(title: "BATTLE CAM", value: session.currentPhase.label, tint: expert.tint)
                    Spacer()
                    Button(action: onReplay) {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .black))
                            Text("REPLAY")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.88))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("ROUND \(session.roundIndex) · \(expert.name)")
                            .font(.system(size: 18, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.8), radius: 0, x: 2, y: 2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                        Text(sideStatus.label)
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(expert.tint)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    Spacer()

                    Text(session.score.leaderText)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(session.score.user >= session.score.expert ? Color.mint : Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .padding(12)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Color.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(expert.tint.opacity(0.78), lineWidth: 3))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.65), lineWidth: 1).offset(x: 3, y: 3))
        .onAppear {
            petPulse = true
        }
    }

    private func introLayer(player: AVPlayer) -> some View {
        PixelVideoPlayer(player: player)
            .aspectRatio(16 / 9, contentMode: .fill)
            .overlay(PixelGrid().opacity(0.20))
            .overlay(
                LinearGradient(
                    colors: [Color.black.opacity(0.10), Color.black.opacity(0.58)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .center) {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.yellow.opacity(0.80))
                        .frame(width: fallbackPulse ? 40 : 112, height: 84)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: fallbackPulse ? 18 : 8, height: 190)
                    Rectangle()
                        .fill(expert.tint.opacity(0.82))
                        .frame(width: fallbackPulse ? 40 : 112, height: 84)
                }
                .opacity(0.34)
                .animation(.easeInOut(duration: 0.56).repeatForever(autoreverses: true), value: fallbackPulse)
            }
            .clipped()
            .onAppear { fallbackPulse = true }
    }

    private var challengerStage: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let petWidth = min(width * 0.46, 250)
            let petHeight = min(height * 0.72, 230)

            ZStack {
                LinearGradient(
                    colors: [
                        Color.black,
                        expert.tint.opacity(0.28),
                        Color(red: 0.12, green: 0.03, blue: 0.02).opacity(0.88)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                PixelGrid().opacity(0.32)

                VStack(spacing: 0) {
                    Spacer()
                    Rectangle()
                        .fill(Color.white.opacity(0.16))
                        .frame(height: 2)
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.02),
                                    expert.tint.opacity(0.36),
                                    Color.black.opacity(0.22)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: height * 0.27)
                }

                BattleSparkLine(tint: expert.tint)
                    .opacity(0.42)

                VStack(spacing: 7) {
                    Text("CHALLENGER LOCKED")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(expert.tint)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    if let assetPrefix = expert.petAssetPrefix {
                        AnimatedPetView(assetPrefix: assetPrefix, state: petPulse ? mood.petState : "Speaking", fps: mood == .listening ? 6 : 8)
                            .frame(width: petWidth, height: petHeight)
                            .scaleEffect(petPulse ? 1.06 : 0.98)
                            .offset(y: petPulse ? -6 : 0)
                            .animation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true), value: petPulse)
                    } else {
                        Text(expert.initials)
                            .font(.system(size: 42, weight: .black, design: .monospaced))
                            .foregroundStyle(.black)
                            .frame(width: 112, height: 112)
                            .background(expert.tint)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.68), lineWidth: 2))
                    }

                    Text(stageCaption)
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .padding(.horizontal, 52)
                }
                .padding(.top, 22)

                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        BattleCompactMeter(title: "不服", value: session.resistance, tint: .red)
                        BattleCompactMeter(title: "说服", value: session.persuasion, tint: .mint)
                        BattleCompactMeter(title: "开放", value: session.openness, tint: expert.tint)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 38)
                }

                if let reply {
                    HStack(spacing: 6) {
                        Text(reply.stance.rawValue.uppercased())
                        Text(reply.emotion.rawValue.uppercased())
                        Text(reply.shortQuote)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(reply.stance == .support ? Color.mint : (reply.stance == .oppose ? Color.red : Color.yellow))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
    }

    private var stageCaption: String {
        if let reply {
            switch reply.stance {
            case .support:
                return "\(expert.name) 已经进入你的框里，正在重新评估立场。"
            case .oppose:
                return "\(expert.name) 不服你的判断，准备当场拆招。"
            case .swing:
                return "\(expert.name) 被拉进分歧核心，立场开始摇晃。"
            }
        }
        if session.currentPhase.isUserActive {
            return "\(expert.name) 站上擂台，正在听你的 60 秒发言。"
        }
        if session.currentPhase.isAIThinking {
            return "\(expert.name) 正在 5 秒内组织反驳。"
        }
        return "你挑战的 \(expert.name) 已进入单人擂台框。"
    }

    private var fallbackImpact: some View {
        ZStack {
            LinearGradient(colors: [Color.red.opacity(0.42), Color.black, expert.tint.opacity(0.32)], startPoint: .topLeading, endPoint: .bottomTrailing)
            PixelGrid().opacity(0.40)
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.red.opacity(0.78))
                    .frame(width: fallbackPulse ? 138 : 54, height: 72)
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: 18, height: 180)
                Rectangle()
                    .fill(Color.cyan.opacity(0.78))
                    .frame(width: fallbackPulse ? 138 : 54, height: 72)
            }
            .animation(.easeInOut(duration: 0.62).repeatForever(autoreverses: true), value: fallbackPulse)
        }
        .onAppear { fallbackPulse = true }
    }
}

private struct BattleOverlayTag: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .black, design: .monospaced))
            Text(value)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.64))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

private struct BattleCompactMeter: View {
    let title: String
    let value: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                Spacer(minLength: 0)
                Text("\(Int(value * 100))")
            }
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .foregroundStyle(.white.opacity(0.82))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                    Rectangle()
                        .fill(tint)
                        .frame(width: proxy.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.54))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(tint.opacity(0.36), lineWidth: 1))
    }
}

private struct BattleHeader: View {
    let expert: Expert
    let round: Int
    let persuasion: CGFloat
    let sideStatus: BattleSideStatus
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .background(.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                Text("VOICE BATTLE")
                    .font(.system(size: 27, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Text("开麦说服：\(expert.name) 会实时反驳你")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(expert.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(sideStatus.label)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer()

            VStack(spacing: 3) {
                Text("ROUND \(round)")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                Text("\(Int(persuasion * 100))%")
                    .font(.system(size: 18, weight: .black, design: .monospaced))
            }
            .foregroundStyle(.black)
            .frame(width: 72, height: 52)
            .background(.mint)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 0, x: 4, y: 4)
        }
        .padding(14)
        .background(PixelPanel(fill: Color.white.opacity(0.10), stroke: expert.tint.opacity(0.42)))
    }
}

private struct BattleArena: View {
    let expert: Expert
    let resistance: CGFloat
    let persuasion: CGFloat
    let openness: CGFloat
    let mood: BattleMood
    let reply: ExpertAIReply?
    let arenaHeight: CGFloat

    @State private var pulse = false

    var body: some View {
        let petWidth = min(max(arenaHeight * 0.80, 214), 338)
        let petHeight = min(max(arenaHeight * 0.72, 188), 304)

        ZStack {
            VStack(spacing: 12) {
                HStack {
                    BattleMeter(title: "不服值", value: resistance, tint: .red)
                    BattleMeter(title: "说服度", value: persuasion, tint: .mint)
                    BattleMeter(title: "开放度", value: openness, tint: expert.tint)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.72),
                                    expert.tint.opacity(0.20),
                                    Color.black.opacity(0.50)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: arenaHeight)
                        .overlay(PixelGrid().opacity(0.36))
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 6) {
                                Image(systemName: mood == .listening ? "mic.fill" : "waveform")
                                    .font(.system(size: 11, weight: .black))
                                Text(mood.label)
                                    .font(.system(size: 10, weight: .black, design: .monospaced))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(mood == .softened ? Color.mint : Color.yellow)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(10)
                        }

                    VStack(spacing: 10) {
                        if let assetPrefix = expert.petAssetPrefix {
                            AnimatedPetView(assetPrefix: assetPrefix, state: pulse ? mood.petState : "Speaking", fps: mood == .listening ? 6 : 8)
                                .frame(width: petWidth, height: petHeight)
                                .scaleEffect(pulse ? 1.06 : 0.98)
                                .offset(y: pulse ? -8 : 0)
                                .animation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true), value: pulse)
                        } else {
                            Text(expert.initials)
                                .font(.system(size: 42, weight: .black, design: .monospaced))
                                .foregroundStyle(.black)
                                .frame(width: min(max(arenaHeight * 0.42, 108), 170), height: min(max(arenaHeight * 0.42, 108), 170))
                                .background(expert.tint)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        HStack(spacing: 6) {
                            ForEach(0..<5, id: \.self) { index in
                                Rectangle()
                                    .fill(index < Int(openness * 5.0) ? expert.tint : Color.white.opacity(0.14))
                                    .frame(width: 28, height: 8)
                            }
                        }

                        Text(arenaCaption)
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }

                    if let reply {
                        HStack(spacing: 6) {
                            Text(reply.stance.rawValue.uppercased())
                            Text(reply.emotion.rawValue.uppercased())
                            Text(reply.shortQuote)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(reply.stance == .support ? Color.mint : (reply.stance == .oppose ? Color.red : Color.yellow))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }

                    BattleSparkLine(tint: expert.tint)
                        .opacity(0.45)
                }
            }
        }
        .padding(12)
        .background(PixelPanel(fill: Color.white.opacity(0.08), stroke: Color.orange.opacity(0.46)))
        .onAppear {
            pulse = true
        }
    }

    private var arenaCaption: String {
        if let reply {
            switch reply.stance {
            case .support:
                return "\(expert.name) 支持了你的方向，继续巩固证据。"
            case .oppose:
                return "\(expert.name) 正在强反驳，先拆他的核心边界。"
            case .swing:
                return "\(expert.name) 的立场开始松动了。"
            }
        }
        return mood == .softened ? "\(expert.name) 的立场开始松动了。" : "把 \(expert.name) 的反驳拆开，再用证据把他拉回来。"
    }
}

private struct BattleArenaV2: View {
    let expert: Expert
    let session: BattleSessionState
    let mood: BattleMood
    let reply: ExpertAIReply?
    let arenaHeight: CGFloat

    @State private var pulse = false

    var body: some View {
        let petWidth = min(max(arenaHeight * 0.58, 176), 270)
        let petHeight = min(max(arenaHeight * 0.50, 148), 230)

        ZStack {
            VStack(spacing: 12) {
                HStack {
                    BattleMeter(title: "不服值", value: CGFloat(session.resistance), tint: .red)
                    BattleMeter(title: "说服度", value: CGFloat(session.persuasion), tint: .mint)
                    BattleMeter(title: "开放度", value: CGFloat(session.openness), tint: expert.tint)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.72),
                                    expert.tint.opacity(0.20),
                                    Color.black.opacity(0.50)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: arenaHeight)
                        .overlay(PixelGrid().opacity(0.36))
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 6) {
                                Image(systemName: mood == .listening ? "mic.fill" : "waveform")
                                    .font(.system(size: 11, weight: .black))
                                Text(mood.label)
                                    .font(.system(size: 10, weight: .black, design: .monospaced))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(mood == .softened ? Color.mint : Color.yellow)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(10)
                        }

                    VStack(spacing: 10) {
                        HStack(spacing: 18) {
                            BattleSideAvatar(title: "YOU", tint: .yellow, value: session.score.user, icon: "mic.fill")
                            BattleClashBeam(tint: expert.tint, active: session.currentPhase.isUserActive || session.currentPhase.isAIThinking)
                            BattleSideAvatar(title: expert.name, tint: expert.tint, value: session.score.expert, icon: "bolt.fill")
                        }

                        if let assetPrefix = expert.petAssetPrefix {
                            AnimatedPetView(assetPrefix: assetPrefix, state: pulse ? mood.petState : "Speaking", fps: mood == .listening ? 6 : 8)
                                .frame(width: petWidth, height: petHeight)
                                .scaleEffect(pulse ? 1.06 : 0.98)
                                .offset(y: pulse ? -8 : 0)
                                .animation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true), value: pulse)
                        } else {
                            Text(expert.initials)
                                .font(.system(size: 42, weight: .black, design: .monospaced))
                                .foregroundStyle(.black)
                                .frame(width: min(max(arenaHeight * 0.42, 108), 170), height: min(max(arenaHeight * 0.42, 108), 170))
                                .background(expert.tint)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        HStack(spacing: 6) {
                            ForEach(0..<5, id: \.self) { index in
                                Rectangle()
                                    .fill(index < Int(session.openness * 5.0) ? expert.tint : Color.white.opacity(0.14))
                                    .frame(width: 28, height: 8)
                            }
                        }

                        Text(arenaCaption)
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }

                    if let reply {
                        HStack(spacing: 6) {
                            Text(reply.stance.rawValue.uppercased())
                            Text(reply.emotion.rawValue.uppercased())
                            Text(reply.shortQuote)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(reply.stance == .support ? Color.mint : (reply.stance == .oppose ? Color.red : Color.yellow))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }

                    BattleSparkLine(tint: expert.tint)
                        .opacity(0.45)
                }
            }
        }
        .padding(12)
        .background(PixelPanel(fill: Color.white.opacity(0.08), stroke: Color.orange.opacity(0.46)))
        .onAppear {
            pulse = true
        }
    }

    private var arenaCaption: String {
        if let reply {
            switch reply.stance {
            case .support:
                return "\(expert.name) 支持了你的方向，继续巩固证据。"
            case .oppose:
                return "\(expert.name) 正在强反驳，先拆他的核心边界。"
            case .swing:
                return "\(expert.name) 的立场开始松动了。"
            }
        }
        return mood == .softened ? "\(expert.name) 的立场开始松动了。" : "把 \(expert.name) 的反驳拆开，再用证据把他拉回来。"
    }
}

private struct BattleSideAvatar: View {
    let title: String
    let tint: Color
    let value: Double
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(.black)
                .frame(width: 46, height: 46)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.black.opacity(0.7), lineWidth: 2))
            Text(title)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            Text("\(Int(value * 100))")
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundStyle(tint)
        }
        .frame(width: 78)
    }
}

private struct BattleClashBeam: View {
    let tint: Color
    let active: Bool

    @State private var pulse = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(active ? 0.72 : 0.28))
                .frame(width: pulse && active ? 80 : 58, height: 5)
            Rectangle()
                .fill(tint.opacity(active ? 0.84 : 0.32))
                .frame(width: 10, height: 42)
            Text("VS")
                .font(.system(size: 15, weight: .black, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(active ? Color.yellow : Color.white.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .animation(.easeInOut(duration: 0.34).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}

private struct BattleRoundTimeline: View {
    let rounds: [BattleRound]
    let session: BattleSessionState

    var body: some View {
        HStack(spacing: 8) {
            ForEach(rounds) { round in
                let isCurrent = round.id == session.roundIndex && session.result == nil
                let isDone = round.id < session.roundIndex || session.result != nil
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Text("R\(round.id)")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                        Spacer(minLength: 0)
                        Image(systemName: isDone ? "checkmark" : (isCurrent ? "waveform" : "lock.fill"))
                            .font(.system(size: 9, weight: .black))
                    }
                    Text(round.userPrompt)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                }
                .foregroundStyle(isCurrent || isDone ? .black : .white.opacity(0.58))
                .padding(9)
                .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                .background(isDone ? Color.mint : (isCurrent ? Color.yellow : Color.white.opacity(0.08)))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(isCurrent ? 0.64 : 0.0), lineWidth: 2))
            }
        }
        .padding(10)
        .background(PixelPanel(fill: Color.white.opacity(0.08), stroke: Color.yellow.opacity(0.32)))
    }
}

private struct BattleMeter: View {
    let title: String
    let value: CGFloat
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.70))
                Spacer()
                Text("\(Int(value * 100))")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(tint)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.black.opacity(0.44))
                    Rectangle()
                        .fill(tint)
                        .frame(width: proxy.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 9)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .padding(10)
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct BattleDialoguePanel: View {
    let expert: Expert
    let messages: [BattleTurnMessage]
    let isExpertThinking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("实时对话")
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(isExpertThinking ? "\(expert.name) 思考中" : "等待你的观点")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(isExpertThinking ? Color.orange : Color.mint)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            VStack(spacing: 9) {
                ForEach(messages.suffix(5)) { message in
                    BattleLine(
                        name: message.speaker,
                        text: message.text,
                        tint: message.isPlayer ? .yellow : expert.tint,
                        alignment: message.isPlayer ? .trailing : .leading
                    )
                }

                if isExpertThinking {
                    BattleTypingIndicator(name: expert.name, tint: expert.tint)
                }
            }
        }
        .padding(14)
        .background(PixelPanel(fill: Color.black.opacity(0.28), stroke: Color.white.opacity(0.16)))
    }
}

private struct BattleDialoguePanelV2: View {
    let expert: Expert
    let messages: [BattleTurnMessage]
    let phase: BattlePhase
    let liveTranscript: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("回合核心发言")
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(phase.isAIThinking ? "\(expert.name) 思考中" : phase.label)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(phase.isAIThinking ? Color.orange : Color.mint)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            VStack(spacing: 9) {
                ForEach(messages) { message in
                    BattleLine(
                        name: message.speaker,
                        text: message.text,
                        tint: message.isPlayer ? .yellow : expert.tint,
                        alignment: message.isPlayer ? .trailing : .leading
                    )
                }

                if phase.isUserActive, !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    BattleLine(name: "实时转写", text: liveTranscript, tint: .yellow, alignment: .trailing)
                        .opacity(0.78)
                }

                if phase.isAIThinking {
                    BattleTypingIndicatorV2(name: expert.name, tint: expert.tint)
                }
            }
        }
        .padding(14)
        .background(PixelPanel(fill: Color.black.opacity(0.28), stroke: Color.white.opacity(0.16)))
    }
}

private struct BattleLine: View {
    let name: String
    let text: String
    let tint: Color
    let alignment: HorizontalAlignment

    var body: some View {
        HStack {
            if alignment == .trailing {
                Spacer(minLength: 40)
            }

            VStack(alignment: alignment, spacing: 5) {
                Text(name)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(tint)
                Text(text)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(alignment == .trailing ? .black : .white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .background(alignment == .trailing ? Color(red: 1.0, green: 0.96, blue: 0.78) : Color.black.opacity(0.48))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(tint.opacity(0.72), lineWidth: 2))

            if alignment == .leading {
                Spacer(minLength: 40)
            }
        }
    }
}

private struct BattleTypingIndicatorV2: View {
    let name: String
    let tint: Color

    @State private var phase = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(name)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(tint)
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(tint)
                            .frame(width: 6, height: 6)
                            .offset(y: phase ? -CGFloat(index + 1) * 2 : 0)
                            .animation(.easeInOut(duration: 0.34).repeatForever(autoreverses: true).delay(Double(index) * 0.08), value: phase)
                    }
                }
            }
            .padding(11)
            .background(Color.black.opacity(0.48))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(tint.opacity(0.72), lineWidth: 2))

            Spacer(minLength: 40)
        }
        .onAppear { phase = true }
    }
}

private struct BattleTypingIndicator: View {
    let name: String
    let tint: Color

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(name)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(tint)
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(tint)
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .padding(11)
            .background(Color.black.opacity(0.48))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(tint.opacity(0.72), lineWidth: 2))

            Spacer(minLength: 40)
        }
    }
}

private struct BattleVoiceConsole: View {
    let expert: Expert
    let isListening: Bool
    let isExpertThinking: Bool
    let persuasion: CGFloat
    let micSize: CGFloat
    let onMicTap: () -> Void

    @State private var wavePulse = false

    private var promptText: String {
        if isExpertThinking {
            return "\(expert.name) 正在组织反驳"
        }
        if isListening {
            return "正在听你说，点一下结束发言"
        }
        if persuasion > 0.68 {
            return "继续补一句，他快被你说服了"
        }
        return "点麦克风，开始讲你的观点"
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Button(action: onMicTap) {
                    ZStack {
                        Circle()
                            .fill(isListening ? Color.red : (isExpertThinking ? Color.gray : Color.yellow))
                            .frame(width: micSize, height: micSize)
                            .shadow(color: (isListening ? Color.red : expert.tint).opacity(0.58), radius: isListening ? 18 : 10)

                        Circle()
                            .stroke(Color.white.opacity(isListening ? 0.62 : 0.0), lineWidth: 4)
                            .frame(width: wavePulse ? micSize + 22 : micSize, height: wavePulse ? micSize + 22 : micSize)
                            .opacity(isListening ? (wavePulse ? 0 : 1) : 0)

                        Image(systemName: isListening ? "stop.fill" : "mic.fill")
                            .font(.system(size: micSize * 0.38, weight: .black))
                            .foregroundStyle(.black)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isExpertThinking)

                VStack(alignment: .leading, spacing: 8) {
                    Text(promptText)
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    VoiceWaveform(tint: isListening ? .red : expert.tint, active: isListening || isExpertThinking)
                        .frame(height: 30)

                    HStack(spacing: 8) {
                        BattlePromptChip(title: "承认反驳", tint: .orange)
                        BattlePromptChip(title: "补证据", tint: .cyan)
                        BattlePromptChip(title: "收窄分歧", tint: .mint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            BattleMeter(title: "说服进度", value: persuasion, tint: .mint)
        }
        .padding(14)
        .background(
            PixelPanel(
                fill: isListening ? Color.red.opacity(0.18) : Color.white.opacity(0.09),
                stroke: isListening ? Color.red.opacity(0.58) : expert.tint.opacity(0.36)
            )
        )
        .onAppear {
            withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                wavePulse = true
            }
        }
    }
}

private struct BattleVoiceConsoleV2: View {
    let expert: Expert
    let session: BattleSessionState
    @ObservedObject var recorder: BattleVoiceRecorder
    let isTranscribing: Bool
    let transcriberErrorMessage: String?
    @Binding var transcript: String
    let micSize: CGFloat
    let onPrimaryAction: () -> Void
    let onEndTurn: () -> Void

    @State private var wavePulse = false

    private var isListening: Bool {
        session.currentPhase.isUserActive
    }

    private var isExpertThinking: Bool {
        session.currentPhase.isAIThinking
    }

    private var promptText: String {
        if isExpertThinking {
            return "\(expert.name) 正在 5 秒内组织反驳"
        }
        if isTranscribing {
            return "iOS Speech 正在转写你的录音"
        }
        if recorder.isRecording {
            return "Round \(session.roundIndex)：正在真实录音，点停止提交"
        }
        if isListening {
            return "Round \(session.roundIndex)：60 秒发言窗口，开麦后可补文字"
        }
        if session.result != nil {
            return "Battle 已结算，应用结果返回圆桌"
        }
        return "等待下一轮或裁决"
    }

    private var primaryIcon: String {
        if isTranscribing { return "waveform.badge.magnifyingglass" }
        if recorder.isRecording { return "stop.fill" }
        if isListening, transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "mic.fill" }
        if isListening { return "stop.fill" }
        return isExpertThinking ? "ellipsis" : "mic.fill"
    }

    private var primaryFill: Color {
        if isTranscribing { return .gray }
        if recorder.isRecording { return .red }
        if isListening { return .yellow }
        if isExpertThinking { return .gray }
        if session.result != nil { return .gray }
        return .yellow
    }

    private var canPressPrimary: Bool {
        switch session.currentPhase {
        case .userTurn, .preparing, .intro:
            return true
        case .transcribing, .aiThinking, .aiSpeaking, .evaluating, .completed, .backgroundWatching:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Button(action: onPrimaryAction) {
                    ZStack {
                        Circle()
                            .fill(primaryFill)
                            .frame(width: micSize, height: micSize)
                            .shadow(color: (isListening ? Color.red : expert.tint).opacity(0.58), radius: isListening ? 18 : 10)

                        Circle()
                            .stroke(Color.white.opacity(isListening ? 0.62 : 0.0), lineWidth: 4)
                            .frame(width: wavePulse ? micSize + 22 : micSize, height: wavePulse ? micSize + 22 : micSize)
                            .opacity(isListening ? (wavePulse ? 0 : 1) : 0)

                        Image(systemName: primaryIcon)
                            .font(.system(size: micSize * 0.38, weight: .black))
                            .foregroundStyle(.black)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canPressPrimary)

                VStack(alignment: .leading, spacing: 8) {
                    Text(promptText)
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    VoiceWaveform(tint: recorder.isRecording ? .red : expert.tint, active: recorder.isRecording || isTranscribing || isExpertThinking)
                        .frame(height: 30)

                    HStack(spacing: 7) {
                        BattlePromptChip(title: "\(session.remainingSeconds)s", tint: session.remainingSeconds <= 10 && isListening ? .red : .yellow)
                        BattlePromptChip(title: isTranscribing ? "转写中" : (recorder.isRecording ? "REC \(recorder.elapsedSeconds)s" : "iOS Speech"), tint: recorder.isRecording ? .red : .cyan)
                        BattlePromptChip(title: session.currentPhase.label, tint: .mint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(isTranscribing ? "正在使用 iOS Speech 转写录音..." : (transcriberErrorMessage ?? recorder.statusText))
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(recorder.errorMessage == nil && transcriberErrorMessage == nil ? .white.opacity(0.62) : .orange)
                TextEditor(text: $transcript)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 78)
                    .padding(8)
                    .background(Color.black.opacity(0.30))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .disabled(!isListening)
            }

            HStack(spacing: 8) {
                BattleMeter(title: "说服进度", value: CGFloat(session.persuasion), tint: .mint)
                if isListening {
                    Button(action: onEndTurn) {
                        Text(recorder.isRecording ? "停止并提交" : "提交发言")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundStyle(.black)
                            .frame(width: 104, height: 44)
                            .background(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(
            PixelPanel(
                fill: isListening ? Color.red.opacity(0.18) : Color.white.opacity(0.09),
                stroke: isListening ? Color.red.opacity(0.58) : expert.tint.opacity(0.36)
            )
        )
        .onAppear {
            withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                wavePulse = true
            }
        }
    }
}

private struct BattlePromptChip: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .foregroundStyle(.black)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct VoiceWaveform: View {
    let tint: Color
    let active: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<18, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(active ? tint : Color.white.opacity(0.18))
                    .frame(width: 5, height: active ? CGFloat(8 + (index * 7) % 22) : 8)
                    .opacity(active ? 0.55 + Double(index % 4) * 0.10 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BattleStrategyPanel: View {
    let expert: Expert
    let persuasion: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("说服策略")
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(persuasion > 0.68 ? "强推进" : "拆反驳")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(persuasion > 0.68 ? Color.mint : Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            BattleStrategyRow(index: "01", title: "抓住他不服的点", detail: "先标记 \(expert.name) 反驳你的核心理由。", tint: .red)
            BattleStrategyRow(index: "02", title: "给出可复用证据", detail: "不要只赢一句话，要让他记住你的判断方式。", tint: .cyan)
            BattleStrategyRow(index: "03", title: "开麦连续追问", detail: "每轮发言都会降低不服值，并沉淀到专家库关系。", tint: .mint)
        }
        .padding(14)
        .background(PixelPanel(fill: Color.white.opacity(0.08), stroke: expert.tint.opacity(0.32)))
    }
}

private struct BattleStrategyRow: View {
    let index: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(index)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.black.opacity(0.24))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct BattleMemoryPanel: View {
    let expert: Expert
    let impression: CGFloat
    let memoryNote: String?

    private var nextState: String {
        if impression > 0.78 { return "更愿意听你" }
        if impression > 0.52 { return "立场松动" }
        return "仍然嘴硬"
    }

    private var memoryTag: String {
        if impression > 0.78 { return "已记住你的框架" }
        if impression > 0.52 { return "开始接受证据" }
        return "需要继续开麦"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("说服沉淀")
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(memoryTag)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(impression > 0.52 ? Color.mint : Color.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            BattleMeter(title: "对你的观点开放度", value: impression, tint: expert.tint)

            if let memoryNote, !memoryNote.isEmpty {
                Text(memoryNote)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(Color.black.opacity(0.24))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            HStack(spacing: 8) {
                LibraryStat(label: "下一次", value: nextState)
                LibraryStat(label: "专家库", value: "关系成长")
                LibraryStat(label: "圆桌", value: impression > 0.68 ? "更易赞同" : "继续拉扯")
            }
        }
        .padding(14)
        .background(PixelPanel(fill: Color.white.opacity(0.08), stroke: Color.mint.opacity(0.32)))
    }
}

private struct BattleMemoryPanelV2: View {
    let expert: Expert
    let session: BattleSessionState
    let memoryNote: String?

    private var nextState: String {
        if session.openness > 0.78 { return "更愿意听你" }
        if session.openness > 0.52 { return "立场松动" }
        return "仍然嘴硬"
    }

    private var memoryTag: String {
        if session.openness > 0.78 { return "已记住你的框架" }
        if session.openness > 0.52 { return "开始接受证据" }
        return "需要继续开麦"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("说服沉淀")
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(memoryTag)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(session.openness > 0.52 ? Color.mint : Color.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            BattleMeter(title: "对你的观点开放度", value: CGFloat(session.openness), tint: expert.tint)

            if let memoryNote, !memoryNote.isEmpty {
                Text(memoryNote)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(Color.black.opacity(0.24))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            HStack(spacing: 8) {
                LibraryStat(label: "下一次", value: nextState)
                LibraryStat(label: "专家库", value: "关系成长")
                LibraryStat(label: "圆桌", value: session.openness > 0.68 ? "更易赞同" : "继续拉扯")
            }
        }
        .padding(14)
        .background(PixelPanel(fill: Color.white.opacity(0.08), stroke: Color.mint.opacity(0.32)))
    }
}

private struct BattleResultPanel: View {
    let expert: Expert
    let session: BattleSessionState
    let result: BattleResult
    let showBackgroundBattle: Bool
    let onToggleBackground: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.badge)
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(result.tint)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text(result.title)
                        .font(.system(size: 22, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                }

                Spacer()

                VStack(spacing: 2) {
                    Text("\(Int(session.persuasion * 100))%")
                        .font(.system(size: 24, weight: .black, design: .monospaced))
                    Text("说服度")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                }
                .foregroundStyle(.black)
                .frame(width: 76, height: 58)
                .background(result.tint)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Text(session.resultReason ?? "Battle 结果已计算。")
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.80))
                .fixedSize(horizontal: false, vertical: true)

            if !session.decisiveMoments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("关键回合")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(result.tint)
                    ForEach(Array(session.decisiveMoments.suffix(3).enumerated()), id: \.offset) { _, moment in
                        Text("· \(moment)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.24))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if showBackgroundBattle {
                HStack(spacing: 8) {
                    Image(systemName: "person.3.sequence.fill")
                        .font(.system(size: 12, weight: .black))
                    Text("后台 3v3：己方专家正在压制对方剩余席位，圆桌胜负倾向会随本局结果一起回写。")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.black)
                .padding(10)
                .background(.cyan)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 8) {
                Button(action: onToggleBackground) {
                    Text(showBackgroundBattle ? "收起后台 Battle" : "观看后台 3v3")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color.black.opacity(0.42))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.16), lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(action: onApply) {
                    Text("返回圆桌并应用结果")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(result.tint)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(PixelPanel(fill: result.tint.opacity(0.12), stroke: result.tint.opacity(0.58)))
    }
}

private struct BattleSparkLine: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: size.width * 0.10, y: size.height * 0.72))
            path.addLine(to: CGPoint(x: size.width * 0.25, y: size.height * 0.40))
            path.addLine(to: CGPoint(x: size.width * 0.38, y: size.height * 0.58))
            path.addLine(to: CGPoint(x: size.width * 0.52, y: size.height * 0.30))
            path.addLine(to: CGPoint(x: size.width * 0.70, y: size.height * 0.52))
            path.addLine(to: CGPoint(x: size.width * 0.88, y: size.height * 0.22))
            context.stroke(path, with: .color(tint.opacity(0.58)), lineWidth: 3)
        }
    }
}

private struct LibraryStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.52))
            Text(value)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct ExpertTraitPanel: View {
    let profile: ExpertTraitProfile
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(profile.angle)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            VStack(spacing: 5) {
                ForEach(profile.meters) { meter in
                    ExpertTraitMeter(label: meter.label, value: meter.value, tint: tint)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(tint.opacity(0.28), lineWidth: 1)
        )
    }
}

private struct ExpertTraitMeter: View {
    let label: String
    let value: Int
    let tint: Color

    private var clampedValue: Int {
        min(max(value, 1), 5)
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.64))
                .lineLimit(1)
                .frame(width: 42, alignment: .leading)

            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index <= clampedValue ? tint : Color.white.opacity(0.13))
                        .frame(height: 7)
                }
            }
            .frame(maxWidth: .infinity)

            Text("\(clampedValue)/5")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 22, alignment: .trailing)
        }
    }
}

private struct ExpertLibraryFilterBar: View {
    @Binding var selectedFilter: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(expertLibraryFilters, id: \.self) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter)
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundStyle(selectedFilter == filter ? .black : .white)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(selectedFilter == filter ? Color.yellow : Color.white.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(selectedFilter == filter ? 0 : 0.18), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 2)
        }
    }
}

private struct ExpertLibraryCard: View {
    @ObservedObject var personaStore: ExpertPersonaStore
    let aiRuntime: ExpertAIRuntime
    let topic: String
    let entry: ExpertLibraryEntry
    let isJoined: Bool
    let isRoundTableFull: Bool
    let onJoin: (ExpertLibraryEntry) -> Void
    let onPreview: (ExpertLibraryEntry) -> Void

    @State private var isPressed = false
    @State private var previewPulse = false
    @State private var previewLine: String?
    @State private var isGeneratingPreview = false

    private var isReady: Bool {
        entry.assetPrefix != nil || !persona.displayName.isEmpty
    }

    private var canJoin: Bool {
        isReady && (isJoined || !isRoundTableFull)
    }

    private var statusText: String {
        if isJoined { return "已在圆桌" }
        if isReady && isRoundTableFull { return "席位已满" }
        return entry.status
    }

    private var actionText: String {
        if !isReady { return "等待素材" }
        if isJoined { return "再看登场" }
        if isRoundTableFull { return "先移出一位" }
        return "登场加入"
    }

    private var statusFill: Color {
        if isJoined { return .yellow }
        if isReady && isRoundTableFull { return .gray }
        return isReady ? .mint : .purple
    }

    private var traitProfile: ExpertTraitProfile {
        personaStore.traitProfile(for: entry)
    }

    private var persona: ExpertPersona {
        personaStore.persona(forDisplayName: entry.name)
    }

    private var personaSourceLabel: String {
        persona.skillSourcePath.hasPrefix("fallback://") ? "Seed Persona" : "Prompt Persona"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(0.26))
                        .overlay(PixelGrid().opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    if let assetPrefix = entry.assetPrefix {
                        ExpertLibraryPetView(
                            assetPrefix: assetPrefix,
                            isFocused: isJoined || previewPulse
                        )
                            .frame(width: 112, height: 118)
                            .offset(x: -7, y: 5)
                            .scaleEffect(previewPulse ? 1.08 : 1)
                            .offset(y: previewPulse ? -4 : 0)
                            .animation(.spring(response: 0.26, dampingFraction: 0.62), value: previewPulse)
                    } else {
                        Text(entry.initials)
                            .font(.system(size: 26, weight: .black, design: .monospaced))
                            .foregroundStyle(.black)
                            .frame(width: 66, height: 66)
                            .background(entry.tint)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.black.opacity(0.65), lineWidth: 2))
                    }

                    Text(statusText)
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(isReady ? .black : .white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(statusFill)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(7)
                }
                .frame(width: 126, height: 132)

                VStack(alignment: .leading, spacing: 7) {
                    Text(entry.name)
                        .font(.system(size: 18, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text(entry.role)
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(entry.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text(previewLine ?? entry.note)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("AI: \(personaSourceLabel)")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(entry.tint.opacity(0.88))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    ExpertTraitPanel(profile: traitProfile, tint: entry.tint)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            HStack(spacing: 6) {
                Image(systemName: isJoined ? "checkmark.seal.fill" : "sparkles")
                    .font(.system(size: 11, weight: .black))
                Text(isGeneratingPreview ? "AI 预览中" : actionText)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
            }
            .foregroundStyle(canJoin ? .black : .white.opacity(0.58))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(canJoin ? entry.tint : Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .padding(10)
        .frame(minHeight: 194, alignment: .top)
        .background(PixelPanel(fill: Color.white.opacity(isReady ? 0.09 : 0.05), stroke: entry.tint.opacity(isReady ? 0.42 : 0.18)))
        .overlay(alignment: .topLeading) {
            if isReady {
                HStack(spacing: 4) {
                    Image(systemName: isGeneratingPreview ? "ellipsis.bubble.fill" : "hand.tap.fill")
                        .font(.system(size: 9, weight: .black))
                    Text(isGeneratingPreview ? "AI 态度" : "长按预览")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.86))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(8)
                .opacity(previewPulse ? 1 : 0.62)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let previewLine {
                Text(previewLine)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(red: 1.0, green: 0.96, blue: 0.78))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(entry.tint.opacity(0.72), lineWidth: 1))
                    .padding(8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isPressed)
        .opacity(canJoin || isReady ? 1 : 0.72)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            guard canJoin else { return }
            onJoin(entry)
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.42)
                .onChanged { _ in
                    guard isReady else { return }
                    isPressed = true
                    previewPulse = true
                }
                .onEnded { _ in
                    guard isReady else {
                        isPressed = false
                        return
                    }
                    onPreview(entry)
                    generatePreviewAttitude()
                    isPressed = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        previewPulse = false
                    }
                }
        )
    }

    private func generatePreviewAttitude() {
        guard !isGeneratingPreview else { return }
        let expertId = personaId(forDisplayName: entry.name)
        isGeneratingPreview = true
        Task {
            let request = ExpertAIRequest(
                expertId: expertId,
                topic: topic,
                userMessage: "请给出这个专家对当前话题的登场态度，一句话即可。",
                scene: .libraryPreview,
                currentPersuasion: nil,
                conversationHistory: []
            )

            do {
                let reply = try await aiRuntime.reply(to: request)
                await MainActor.run {
                    previewLine = reply.shortQuote.isEmpty ? reply.text : reply.shortQuote
                    isGeneratingPreview = false
                }
            } catch {
                await MainActor.run {
                    previewLine = entry.debutLine ?? entry.note
                    isGeneratingPreview = false
                }
            }
        }
    }
}

private struct SpotlightDebutOverlay: View {
    let entry: ExpertLibraryEntry
    let mode: SpotlightPresentationMode
    let onDismiss: () -> Void
    let onComplete: () -> Void

    @State private var lit = false
    @State private var jumped = false
    @State private var turned = false
    @State private var posed = false
    @State private var flashed = false
    @State private var lineVisible = false

    private var readableLine: String {
        entry.debutLine ?? "素材就绪，准备登场。"
    }

    var body: some View {
        GeometryReader { proxy in
            let shortSide = min(proxy.size.width, proxy.size.height)
            let spotlightScale = min(max(shortSide / 520, 1), 1.42)
            let lineWidth = min(proxy.size.width - 72, shortSide >= 760 ? 560 : 330)
            ZStack {
                Color.black
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if mode.canDismiss {
                            onDismiss()
                        }
                    }

                PixelGrid()
                    .opacity(0.10)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                PixelSparkles(isLit: lit || flashed, tint: entry.tint)
                    .allowsHitTesting(false)

                SpotlightBeam()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(lit ? 0.34 : 0.0),
                                Color.yellow.opacity(lit ? 0.22 : 0.0),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blur(radius: lit ? 1.5 : 8)
                    .blendMode(.screen)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                StageLightRig(isLit: lit, tint: entry.tint)
                    .frame(height: 92)
                    .position(x: proxy.size.width / 2, y: 44)
                    .allowsHitTesting(false)

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(lit ? 0.38 : 0.0),
                                Color.yellow.opacity(lit ? 0.18 : 0.0),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 12,
                            endRadius: 150
                        )
                    )
                    .frame(width: proxy.size.width * 0.76, height: 112)
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.68)
                    .blendMode(.screen)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(lit ? 0.22 : 0.0))
                        .frame(width: proxy.size.width * 0.48, height: 2)
                    Rectangle()
                        .fill(entry.tint.opacity(lit ? 0.28 : 0.0))
                        .frame(width: proxy.size.width * 0.62, height: 18)
                    Rectangle()
                        .fill(Color.black.opacity(0.72))
                        .frame(width: proxy.size.width * 0.74, height: 18)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.72)
                .allowsHitTesting(false)

                VStack(spacing: 14) {
                    Text(mode.badge)
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundStyle(.yellow)
                        .tracking(2)
                        .opacity(lit ? 1 : 0)

                    ZStack {
                        Rectangle()
                            .fill(entry.tint.opacity(0.18))
                            .frame(width: 150 * spotlightScale, height: 10 * spotlightScale)
                            .offset(y: 86 * spotlightScale)

                        if let assetPrefix = entry.assetPrefix {
                            AnimatedPetView(assetPrefix: assetPrefix, state: posed ? "Supported" : "Speaking", fps: 9)
                                .frame(width: 178 * spotlightScale, height: 198 * spotlightScale)
                                .scaleEffect(posed ? 1.12 : (jumped ? 1.02 : 0.58))
                                .rotation3DEffect(.degrees(turned ? 360 : 0), axis: (x: 0, y: 1, z: 0))
                                .rotationEffect(.degrees(posed ? -3 : (jumped ? 4 : -8)))
                                .offset(x: jumped ? 0 : -36 * spotlightScale, y: jumped ? -14 * spotlightScale : 44 * spotlightScale)
                                .shadow(color: entry.tint.opacity(lit ? 0.85 : 0), radius: lit ? 22 : 0)
                        } else {
                            Text(entry.initials)
                                .font(.system(size: 62 * spotlightScale, weight: .black, design: .monospaced))
                                .foregroundStyle(.black)
                                .frame(width: 148 * spotlightScale, height: 148 * spotlightScale)
                                .background(entry.tint)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.88), lineWidth: 4))
                                .scaleEffect(posed ? 1.08 : (jumped ? 1.0 : 0.56))
                                .rotationEffect(.degrees(posed ? -3 : (jumped ? 4 : -8)))
                                .offset(x: jumped ? 0 : -36 * spotlightScale, y: jumped ? -8 * spotlightScale : 44 * spotlightScale)
                                .shadow(color: entry.tint.opacity(lit ? 0.85 : 0), radius: lit ? 22 : 0)
                        }

                        Rectangle()
                            .fill(Color.white.opacity(flashed ? 0.72 : 0))
                            .frame(width: 228 * spotlightScale, height: 228 * spotlightScale)
                            .blendMode(.screen)
                            .scaleEffect(flashed ? 1.35 : 0.2)
                            .opacity(flashed ? 0 : 1)
                            .animation(.easeOut(duration: 0.32), value: flashed)
                    }
                    .frame(height: 210 * spotlightScale)

                    VStack(spacing: 6) {
                        Text(entry.name)
                            .font(.system(size: 28, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)

                        Text(mode.caption)
                            .font(.system(size: 15, weight: .black, design: .monospaced))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(entry.tint)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                        Text(readableLine)
                            .font(.system(size: 15, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.72)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(width: lineWidth)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.black.opacity(0.72))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(entry.tint.opacity(0.72), lineWidth: 2)
                                    )
                            )
                            .shadow(color: entry.tint.opacity(0.32), radius: 12)
                            .opacity(lineVisible ? 1 : 0)
                            .offset(y: lineVisible ? 0 : 8)
                    }
                    .opacity(lit ? 1 : 0)
                    .offset(y: lit ? 0 : 16)
                }
                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.50)
                .allowsHitTesting(false)

                if mode.canDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(.black)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.88))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(entry.tint.opacity(0.7), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .position(
                        x: proxy.size.width - max(proxy.safeAreaInsets.trailing + 34, 34),
                        y: max(proxy.safeAreaInsets.top + 24, 48)
                    )
                }
            }
        }
        .onAppear {
            runEntranceTimeline()
        }
        .onDisappear {
            if mode.canDismiss {
                SpotlightVoicePlayer.shared.stop()
            }
        }
    }

    private func runEntranceTimeline() {
        lineVisible = false
        AppBGMPlayer.shared.playClip(named: entry.bgmClipName, volume: 0.24)
        let voiceDuration = SpotlightVoicePlayer.shared.play(clipName: entry.voiceClipName)

        withAnimation(.easeOut(duration: 0.18)) {
            lit = true
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.58).delay(0.10)) {
            jumped = true
        }
        withAnimation(.easeInOut(duration: 0.42).delay(0.32)) {
            turned = true
        }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.50).delay(0.70)) {
            posed = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.88) {
            flashed = true
        }
        withAnimation(.easeOut(duration: 0.24).delay(0.82)) {
            lineVisible = true
        }
        if let autoCompleteDelay = mode.autoCompleteDelay {
            let holdForVoice = min(max(voiceDuration + 0.35, autoCompleteDelay), 6.8)
            DispatchQueue.main.asyncAfter(deadline: .now() + holdForVoice) {
                onComplete()
            }
        }
    }
}

private struct StageLightRig: View {
    let isLit: Bool
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { index in
                    Rectangle()
                        .fill(index == 2 ? tint : Color.white.opacity(0.34))
                        .frame(width: index == 2 ? 44 : 30, height: index == 2 ? 16 : 10)
                        .overlay(Rectangle().stroke(Color.black.opacity(0.72), lineWidth: 2))
                        .shadow(color: index == 2 ? tint.opacity(isLit ? 0.9 : 0) : .clear, radius: 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.88))
            .overlay(Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1))

            Rectangle()
                .fill(tint.opacity(isLit ? 0.32 : 0.0))
                .frame(width: 56, height: 8)
                .shadow(color: tint.opacity(isLit ? 0.95 : 0), radius: 18)
        }
    }
}

private struct PixelSparkles: View {
    let isLit: Bool
    let tint: Color

    private let sparkles: [(x: CGFloat, y: CGFloat, size: CGFloat, delay: Double)] = [
        (0.24, 0.27, 5, 0.0),
        (0.72, 0.31, 4, 0.1),
        (0.31, 0.46, 3, 0.2),
        (0.66, 0.50, 5, 0.3),
        (0.18, 0.63, 4, 0.1),
        (0.80, 0.66, 3, 0.2)
    ]

    var body: some View {
        GeometryReader { proxy in
            ForEach(Array(sparkles.enumerated()), id: \.offset) { _, sparkle in
                Rectangle()
                    .fill(sparkle.size > 4 ? Color.white : tint)
                    .frame(width: sparkle.size, height: sparkle.size)
                    .position(x: proxy.size.width * sparkle.x, y: proxy.size.height * sparkle.y)
                    .opacity(isLit ? 0.88 : 0.0)
                    .scaleEffect(isLit ? 1 : 0.2)
                    .animation(
                        .easeOut(duration: 0.36).delay(sparkle.delay),
                        value: isLit
                    )
            }
        }
        .blendMode(.screen)
        .ignoresSafeArea()
    }
}

private struct SpotlightBeam: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - rect.width * 0.12, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.12, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.40, y: rect.maxY * 0.72))
        path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.40, y: rect.maxY * 0.72))
        path.closeSubpath()
        return path
    }
}

private struct HeaderView: View {
    let onLiveTap: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("像素圆桌")
                    .font(.system(size: 32, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Text("AI 专家辩论局")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button(action: onLiveTap) {
                HStack(spacing: 6) {
                    PixelDot(color: .mint)
                    Text("LIVE")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.mint)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 0, x: 4, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("LIVE")
        }
    }
}

private struct RoundTablePrepHero: View {
    let experts: [Expert]
    let isImporting: Bool
    @State private var pulse = false

    private var waitingExperts: [Expert] {
        Array(experts.prefix(5))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let isWide = size.width >= 600
            let tableWidth = min(size.width * (isWide ? 0.92 : 0.82), size.height * 1.56)
            let petWidth = min(max(size.width * (isWide ? 0.17 : 0.30), 96), isWide ? 132 : 112)
            ZStack {
                LinearGradient(colors: [.purple.opacity(0.35), .black.opacity(0.20), .orange.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)
                PixelGrid()

                Ellipse()
                    .fill(Color.cyan.opacity(pulse ? 0.20 : 0.10))
                    .frame(width: tableWidth * 1.08, height: 42)
                    .position(x: size.width * 0.50, y: size.height * 0.66)

                Image("RoundTable")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: tableWidth)
                    .position(x: size.width * 0.50, y: size.height * 0.55)
                    .shadow(color: .black.opacity(0.55), radius: 0, x: 8, y: 8)

                ForEach(Array(waitingExperts.enumerated()), id: \.element.id) { index, expert in
                    PrepWaitingExpert(
                        expert: expert,
                        index: index,
                        petWidth: petWidth,
                        isImporting: isImporting,
                        pulse: pulse
                    )
                    .position(waitingPosition(for: expert, index: index, in: size))
                    .zIndex(waitingZIndex(for: expert, index: index))
                }

                PrepSpeechBubble(text: isImporting ? "正在入场" : "等待开会")
                    .position(x: size.width * 0.55, y: size.height * 0.42)
                    .zIndex(10)

                HStack(spacing: 8) {
                    Image(systemName: isImporting ? "hourglass" : "play.tv.fill")
                        .font(.system(size: 11, weight: .black))
                    Text(isImporting ? "准备圆桌会议" : "专家候场")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(isImporting ? Color.orange : Color.yellow)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .position(x: size.width * 0.22, y: size.height * 0.10)
                .zIndex(30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(isImporting ? "正在解析视频并安排专家席位" : "粘贴链接后直接开会")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Text("ROUND TABLE STANDBY")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(.cyan.opacity(0.82))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.58))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .position(x: size.width * 0.50, y: size.height * 0.91)
                .zIndex(9)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
        .frame(height: 294)
        .background(PixelPanel(fill: Color.black.opacity(0.24), stroke: Color.cyan.opacity(0.42)))
    }

    private func waitingPosition(for expert: Expert, index: Int, in size: CGSize) -> CGPoint {
        let prepSeats = [
            CGPoint(x: 0.50, y: 0.20),
            CGPoint(x: 0.24, y: 0.36),
            CGPoint(x: 0.76, y: 0.36),
            CGPoint(x: 0.25, y: 0.66),
            CGPoint(x: 0.75, y: 0.66),
            CGPoint(x: 0.50, y: 0.77)
        ]
        let seat = prepSeats[min(index, prepSeats.count - 1)]
        return CGPoint(x: seat.x * size.width, y: seat.y * size.height)
    }

    private func waitingZIndex(for expert: Expert, index: Int) -> Double {
        Double(4 + index) + Double(expert.seat.y * 8)
    }
}

private struct PrepWaitingExpert: View {
    let expert: Expert
    let index: Int
    let petWidth: CGFloat
    let isImporting: Bool
    let pulse: Bool

    var body: some View {
        VStack(spacing: 2) {
            if let assetPrefix = expert.petAssetPrefix {
                AnimatedPetView(assetPrefix: assetPrefix, state: "Supported", fps: isImporting ? 8 : 6)
                    .frame(width: petWidth, height: petWidth * 1.24)
                    .scaleEffect(pulse ? 1.045 : 1.0)
                    .rotationEffect(.degrees(pulse ? 1.8 : -1.2))
                    .offset(y: pulse ? -3 : 2)
            } else {
                Text(expert.initials)
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .frame(width: petWidth * 0.9, height: petWidth * 0.9)
                    .background(expert.tint)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .scaleEffect(pulse ? 1.045 : 1.0)
                    .rotationEffect(.degrees(pulse ? 1.8 : -1.2))
                    .offset(y: pulse ? -3 : 2)
            }

            Text(expert.name)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.70))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .animation(.easeInOut(duration: 1.0 + Double(index) * 0.12).repeatForever(autoreverses: true), value: pulse)
    }
}

private struct PrepSpeechBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .black, design: .monospaced))
            .foregroundStyle(.black)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.black.opacity(0.72), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.42), radius: 0, x: 4, y: 4)
    }
}

private struct ImportPanel: View {
    @Binding var pastedLink: String
    let isImporting: Bool
    let status: String
    let error: String?
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("视频链接", systemImage: "link")
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(isImporting ? "准备中" : "真实接口")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(isImporting ? Color.orange : Color.mint)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            HStack(spacing: 10) {
                TextField("Paste Douyin link", text: $pastedLink)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.38))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button {
                    pastedLink = UIPasteboard.general.string ?? pastedLink
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .disabled(isImporting)
            }

            Button(action: onImport) {
                HStack(spacing: 8) {
                    Image(systemName: isImporting ? "hourglass" : "play.fill")
                        .font(.system(size: 13, weight: .black))
                    Text(isImporting ? "正在准备会议" : "真实接口开始圆桌")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(isImporting ? Color.gray : Color.mint)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(isImporting ? 0.0 : 0.36), radius: 0, x: 4, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(isImporting)

            HStack(spacing: 7) {
                Image(systemName: error == nil ? "sparkles" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .black))
                Text(error ?? status)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(error == nil ? .white.opacity(0.72) : .orange)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }
        }
        .padding(14)
        .background(PixelPanel(fill: Color.white.opacity(0.10), stroke: Color.white.opacity(0.22)))
    }
}

private struct TopicCard: View {
    let topic: RoundtableTopic
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 7 : 10) {
            HStack {
                Text(topic.source)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(.cyan)
                Spacer()
                Text("AI TOPIC")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.cyan)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Text(topic.debate)
                .font(.system(size: isCompact ? 20 : 25, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            if !isCompact {
                Text(topic.hook)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let controversy = topic.controversy {
                Text("冲突焦点：\(controversy)")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !isCompact && !topic.claims.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(topic.claims.prefix(3).enumerated()), id: \.offset) { _, claim in
                        HStack(alignment: .top, spacing: 6) {
                            Text("◆")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundStyle(.cyan)
                            Text(claim)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.70))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let authorName = topic.authorName {
                Text("来源作者 @\(authorName)")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.cyan.opacity(0.88))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .padding(isCompact ? 13 : 16)
        .background(PixelPanel(fill: Color.black.opacity(0.28), stroke: Color.orange.opacity(0.55)))
    }
}

private struct RoundTableAIControl: View {
    let isGenerating: Bool
    let expertCount: Int
    let onGenerate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI 圆桌发言")
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Text(isGenerating ? "专家正在各自组织观点" : "\(expertCount) 位专家将按 persona 生成一句立场")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer()

            Button(action: onGenerate) {
                HStack(spacing: 6) {
                    Image(systemName: isGenerating ? "ellipsis.bubble.fill" : "sparkles")
                        .font(.system(size: 13, weight: .black))
                    Text(isGenerating ? "生成中" : "生成本轮")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                }
                .foregroundStyle(.black)
                .frame(width: 98, height: 38)
                .background(isGenerating ? Color.orange : Color.cyan)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)
        }
        .padding(12)
        .background(PixelPanel(fill: Color.white.opacity(0.08), stroke: Color.cyan.opacity(0.32)))
    }
}

private struct RoundTableDebateProgress: View {
    let status: RoundTableDebateStatus
    let expertCount: Int

    private var progress: CGFloat {
        guard let phase = status.phase else { return 0.08 }
        return CGFloat(phase.rawValue) / CGFloat(max(RoundTableDebatePhase.allCases.count, 1))
    }

    private var tint: Color {
        switch status.phase {
        case .stance:
            return .mint
        case .rebuttal:
            return .orange
        case .closing:
            return .yellow
        case nil:
            return .cyan
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: status.isGenerating ? "ellipsis.bubble.fill" : "person.3.sequence.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(tint)
                Text(status.roundLabel)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(tint)
                Text(status.title)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Spacer()
                Text("\(expertCount) EXP")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(tint)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.black.opacity(0.42))
                    Rectangle()
                        .fill(tint)
                        .frame(width: max(8, proxy.size.width * progress))
                }
            }
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))

            Text(status.subtitle)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(11)
        .background(PixelPanel(fill: Color.white.opacity(0.08), stroke: tint.opacity(0.35)))
    }
}

private struct RoundTableBrainInterjectionPanel: View {
    @Binding var draft: String
    let latestInterjection: RoundTableUserInterjection?
    let isGenerating: Bool
    let onSubmit: () -> Void

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.cyan)
                Text("最强大脑插话")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(isGenerating ? "随时打断" : "准备接管")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(isGenerating ? Color.cyan : Color.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            HStack(spacing: 8) {
                TextField("补充证据、追问漏洞、改变讨论方向", text: $draft, axis: .vertical)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1...3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Color.black.opacity(0.34))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .submitLabel(.send)
                    .onSubmit {
                        if canSubmit { onSubmit() }
                    }

                Button(action: onSubmit) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.black)
                        .frame(width: 42, height: 42)
                        .background(canSubmit ? Color.cyan : Color.gray)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.62), lineWidth: 2))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
            }

            if let latestInterjection {
                Text("#\(latestInterjection.sequence) \(latestInterjection.text)")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.cyan.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            } else {
                Text("你可以像主持人一样随时插入观点，下一位专家会先回应你。")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(11)
        .background(PixelPanel(fill: Color.white.opacity(0.08), stroke: Color.cyan.opacity(0.34)))
    }
}

private struct RoundTableRestartButton: View {
    let onRestart: () -> Void

    var body: some View {
        Button(action: onRestart) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .black))
                Text("重开")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                Spacer()
                Text("ROUND 1")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.72))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.40))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.yellow)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black.opacity(0.70), lineWidth: 2))
            .shadow(color: .black.opacity(0.36), radius: 0, x: 4, y: 4)
        }
        .buttonStyle(.plain)
    }
}

private struct ForumHighlightReplayCard: View {
    let topic: RoundtableTopic
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.36))
                        .frame(width: 82, height: 52)
                        .overlay(PixelGrid().opacity(0.35))
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 25, weight: .black))
                        .foregroundStyle(.yellow)
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.yellow.opacity(0.44), lineWidth: 1))

                VStack(alignment: .leading, spacing: 5) {
                    Text("回看本次论坛精彩瞬间")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("已生成论坛高光视频，可播放、下载和分享")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(topic.title)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.yellow)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .padding(12)
            .background(PixelPanel(fill: Color.white.opacity(0.10), stroke: Color.yellow.opacity(0.44)))
        }
        .buttonStyle(.plain)
        .disabled(ForumHighlightResource.bundledURL == nil)
        .opacity(ForumHighlightResource.bundledURL == nil ? 0.52 : 1)
    }
}

private struct ForumSharePosterCard: View {
    let topic: RoundtableTopic
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.36))
                        .frame(width: 82, height: 58)
                        .overlay(PixelGrid().opacity(0.35))

                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            miniBubble(width: 30, color: .yellow)
                            miniBubble(width: 18, color: .mint)
                        }
                        HStack(spacing: 4) {
                            miniBubble(width: 18, color: .orange)
                            miniBubble(width: 34, color: .cyan)
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mint.opacity(0.48), lineWidth: 1))

                VStack(alignment: .leading, spacing: 5) {
                    Text("生成圆桌论坛长图")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("自动整理专家头像、对话气泡和观点精华")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(topic.title)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.mint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 0)

                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(.mint)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .padding(12)
            .background(PixelPanel(fill: Color.white.opacity(0.10), stroke: Color.mint.opacity(0.44)))
        }
        .buttonStyle(.plain)
    }

    private func miniBubble(width: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color)
            .frame(width: width, height: 8)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.55), lineWidth: 1))
    }
}

private struct RoundTableStage: View {
    let experts: [Expert]
    @Binding var selectedExpert: Int
    let activeReaction: ExpertReaction?
    let reactionToken: UUID
    let debateStatus: RoundTableDebateStatus
    let stageHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let speakerIndex = min(max(0, selectedExpert), max(0, experts.count - 1))
            let tableWidth = min(size.width * (size.width >= 760 ? 0.92 : 0.82), size.height * 1.56)
            ZStack {
                Image("RoundTable")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: tableWidth)
                    .position(x: size.width / 2, y: size.height * 0.52)
                    .shadow(color: .black.opacity(0.55), radius: 0, x: 8, y: 8)

                ForEach(Array(experts.enumerated()), id: \.element.id) { index, expert in
                    ExpertSeat(
                        expert: expert,
                        isSelected: index == selectedExpert,
                        activeReaction: index == speakerIndex ? activeReaction : nil,
                        reactionToken: reactionToken,
                        stageSize: size
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedExpert = index
                    }
                    .position(x: expert.seat.x * size.width, y: expert.seat.y * size.height)
                    .zIndex(index == speakerIndex ? 5 : 3)
                }

                if experts.indices.contains(speakerIndex) {
                    let speaker = experts[speakerIndex]
                    let placement = speechBubblePlacement(for: speaker, allExperts: experts, in: size)
                    SpeechBubble(
                        expert: speaker,
                        width: placement.width,
                        height: placement.height,
                        tailOffset: placement.tailOffset,
                        tailEdge: placement.tailEdge
                    )
                    .id("\(speaker.id)-\(speaker.quote)")
                    .position(placement.center)
                    .transition(.scale(scale: 0.88, anchor: placement.tailEdge.transitionAnchor).combined(with: .opacity))
                    .zIndex(2)
                }

                if let activeReaction, experts.indices.contains(speakerIndex) {
                    let speaker = experts[speakerIndex]
                    ReactionBurst(reaction: activeReaction, tint: speaker.tint)
                        .id(reactionToken)
                        .position(
                            x: min(max(speaker.seat.x * size.width, 74), size.width - 74),
                            y: min(max(speaker.seat.y * size.height - 66, 56), size.height - 44)
                        )
                        .zIndex(8)
                }

                HStack(spacing: 8) {
                    Text(debateStatus.roundLabel)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.yellow)
                    Text(debateStatus.title)
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.64))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.yellow.opacity(0.22), lineWidth: 1))
                .position(x: 90, y: 26)
                .zIndex(4)
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.78), value: speakerIndex)
            .animation(.easeInOut(duration: 0.22), value: debateStatus)
        }
        .frame(height: stageHeight)
        .background(
            ZStack {
                LinearGradient(colors: [.purple.opacity(0.35), .black.opacity(0.20), .orange.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)
                PixelGrid()
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.14), lineWidth: 1))
    }

    private func speechBubblePlacement(for expert: Expert, allExperts: [Expert], in size: CGSize) -> SpeechBubblePlacement {
        let seatPoint = CGPoint(x: expert.seat.x * size.width, y: expert.seat.y * size.height)
        let bubbleWidth = speechBubbleWidth(for: expert, stageWidth: size.width)
        let bubbleHeight = speechBubbleHeight(in: size)
        let stageMargin: CGFloat = size.width >= 760 ? 18 : 12
        let safetyRect = expertSeatSafetyRect(center: seatPoint, in: size)
        let labelRect = CGRect(x: 12, y: 8, width: 156, height: 38)
        let allSafetyRects = allExperts.map { otherExpert in
            expertSeatSafetyRect(center: CGPoint(x: otherExpert.seat.x * size.width, y: otherExpert.seat.y * size.height), in: size)
        }
        let candidates = speechBubbleCandidates(
            for: expert,
            seatPoint: seatPoint,
            safetyRect: safetyRect,
            bubbleWidth: bubbleWidth,
            bubbleHeight: bubbleHeight
        )
        let scoredCandidates = candidates.map { candidate in
            let center = clamp(
                candidate.center,
                in: size,
                bubbleWidth: bubbleWidth,
                bubbleHeight: bubbleHeight,
                margin: stageMargin
            )
            let bubbleRect = speechBubbleRect(center: center, width: bubbleWidth, height: bubbleHeight)
            let selectedOverlap = overlapArea(bubbleRect, safetyRect.insetBy(dx: -6, dy: -6))
            let peopleOverlap = allSafetyRects.reduce(CGFloat.zero) { partial, rect in
                partial + overlapArea(bubbleRect, rect.insetBy(dx: -2, dy: -2))
            }
            let labelOverlap = overlapArea(bubbleRect, labelRect)
            let drift = abs(center.x - candidate.center.x) + abs(center.y - candidate.center.y)
            let distance = abs(center.x - seatPoint.x) * 0.08 + abs(center.y - seatPoint.y) * 0.05
            let tailLimit = candidate.tailEdge.isVertical ? bubbleWidth / 2 - 24 : bubbleHeight / 2 - 18
            let rawTailOffset = candidate.tailEdge.isVertical ? seatPoint.x - center.x : seatPoint.y - center.y
            let tailMiss = max(0, abs(rawTailOffset) - tailLimit)
            let score = selectedOverlap * 160 + labelOverlap * 26 + peopleOverlap * 22 + tailMiss * 120 + drift * 2 + distance + candidate.priority * 90
            return (candidate: candidate, center: center, score: score)
        }
        let best = scoredCandidates.min { $0.score < $1.score }
        let center = best?.center ?? seatPoint
        let tailEdge = best?.candidate.tailEdge ?? .bottom
        let tailLimit = tailEdge.isVertical ? bubbleWidth / 2 - 24 : bubbleHeight / 2 - 18
        let rawTailOffset = tailEdge.isVertical ? seatPoint.x - center.x : seatPoint.y - center.y
        let tailOffset = min(max(rawTailOffset, -tailLimit), tailLimit)

        return SpeechBubblePlacement(
            center: center,
            width: bubbleWidth,
            height: bubbleHeight,
            tailOffset: tailOffset,
            tailEdge: tailEdge
        )
    }

    private func speechBubbleWidth(for expert: Expert, stageWidth: CGFloat) -> CGFloat {
        let scale = min(max(stageWidth / 390, 1), 1.42)
        let readableWidth = CGFloat(max(expert.name.count, expert.quote.count)) * (6.4 * scale) + 56
        let maxWidth = stageWidth >= 760 ? stageWidth * 0.38 : stageWidth * 0.56
        return min(stageWidth >= 760 ? 320 : 226, max(146 * scale, min(maxWidth, readableWidth)))
    }

    private func speechBubbleHeight(in size: CGSize) -> CGFloat {
        size.width >= 760 ? 112 : 92
    }

    private func speechBubbleCandidates(
        for expert: Expert,
        seatPoint: CGPoint,
        safetyRect: CGRect,
        bubbleWidth: CGFloat,
        bubbleHeight: CGFloat
    ) -> [SpeechBubbleCandidate] {
        let scale = min(max(seatPoint.y / 220, 1), 1.24)
        let horizontalGap: CGFloat = 12 * scale
        let verticalGap: CGFloat = 10 * scale
        let sideEdge: SpeechBubbleTailEdge = expert.seat.x < 0.5 ? .leading : .trailing
        let sideX = if expert.seat.x < 0.5 {
            safetyRect.maxX + horizontalGap + bubbleWidth / 2
        } else {
            safetyRect.minX - horizontalGap - bubbleWidth / 2
        }
        let topCenterY = safetyRect.minY - verticalGap - bubbleHeight / 2
        let bottomCenterY = safetyRect.maxY + verticalGap + bubbleHeight / 2
        let sideOffsets: [CGFloat] = expert.seat.y < 0.4 ? [0, 34, -34, 68] : [0, -34, 34, -68]
        var candidates = sideOffsets.enumerated().map { index, offset in
            SpeechBubbleCandidate(center: CGPoint(x: sideX, y: seatPoint.y + offset), tailEdge: sideEdge, priority: CGFloat(index))
        }

        if expert.seat.y < 0.18 {
            candidates.insert(SpeechBubbleCandidate(center: CGPoint(x: seatPoint.x, y: bottomCenterY), tailEdge: .top, priority: 0), at: 0)
            candidates.append(SpeechBubbleCandidate(center: CGPoint(x: seatPoint.x - 78, y: bottomCenterY), tailEdge: .top, priority: 1.4))
            candidates.append(SpeechBubbleCandidate(center: CGPoint(x: seatPoint.x + 78, y: bottomCenterY), tailEdge: .top, priority: 1.4))
        } else if expert.seat.y > 0.68 {
            candidates.insert(SpeechBubbleCandidate(center: CGPoint(x: seatPoint.x, y: topCenterY), tailEdge: .bottom, priority: 0), at: 0)
            candidates.append(SpeechBubbleCandidate(center: CGPoint(x: seatPoint.x - 78, y: topCenterY), tailEdge: .bottom, priority: 1.4))
            candidates.append(SpeechBubbleCandidate(center: CGPoint(x: seatPoint.x + 78, y: topCenterY), tailEdge: .bottom, priority: 1.4))
        } else {
            let verticalEdge: SpeechBubbleTailEdge = expert.seat.y < 0.4 ? .top : .bottom
            let verticalY = expert.seat.y < 0.4 ? bottomCenterY : topCenterY
            let xOffset: CGFloat = expert.seat.x < 0.5 ? 72 : -72
            if expert.seat.y < 0.4 {
                candidates.append(SpeechBubbleCandidate(center: CGPoint(x: seatPoint.x + xOffset, y: verticalY + 46), tailEdge: verticalEdge, priority: 0.8))
            }
            candidates.append(SpeechBubbleCandidate(center: CGPoint(x: seatPoint.x + xOffset, y: verticalY), tailEdge: verticalEdge, priority: 1.2))
            candidates.append(SpeechBubbleCandidate(center: CGPoint(x: seatPoint.x, y: verticalY), tailEdge: verticalEdge, priority: 1.8))
        }

        return candidates
    }

    private func expertSeatSafetyRect(center: CGPoint, in size: CGSize) -> CGRect {
        let scale = min(max(size.height / 358, 1), 1.36)
        return CGRect(x: center.x - 48 * scale, y: center.y - 60 * scale, width: 96 * scale, height: 120 * scale)
    }

    private func clamp(_ center: CGPoint, in size: CGSize, bubbleWidth: CGFloat, bubbleHeight: CGFloat, margin: CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(center.x, margin + bubbleWidth / 2), size.width - margin - bubbleWidth / 2),
            y: min(max(center.y, margin + bubbleHeight / 2), size.height - margin - bubbleHeight / 2)
        )
    }

    private func speechBubbleRect(center: CGPoint, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    private func overlapArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull, !intersection.isEmpty else {
            return 0
        }
        return intersection.width * intersection.height
    }
}

private struct SpeechBubblePlacement {
    let center: CGPoint
    let width: CGFloat
    let height: CGFloat
    let tailOffset: CGFloat
    let tailEdge: SpeechBubbleTailEdge
}

private struct SpeechBubbleCandidate {
    let center: CGPoint
    let tailEdge: SpeechBubbleTailEdge
    let priority: CGFloat
}

private enum SpeechBubbleTailEdge {
    case top
    case bottom
    case leading
    case trailing

    var isVertical: Bool {
        self == .top || self == .bottom
    }

    var transitionAnchor: UnitPoint {
        switch self {
        case .top:
            return .top
        case .bottom:
            return .bottom
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        }
    }

    var alignment: Alignment {
        switch self {
        case .top:
            return .top
        case .bottom:
            return .bottom
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        }
    }
}

private struct SpeechBubble: View {
    let expert: Expert
    let width: CGFloat
    let height: CGFloat
    let tailOffset: CGFloat
    let tailEdge: SpeechBubbleTailEdge

    @State private var isFloating = false
    @State private var visibleCharacterCount = 0
    @State private var hasPopped = false

    private var displayedQuote: String {
        let characters = Array(expert.quote)
        let visibleCharacters = characters.prefix(min(visibleCharacterCount, characters.count))
        return String(visibleCharacters)
    }

    private var isTyping: Bool {
        visibleCharacterCount < expert.quote.count
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    PixelDot(color: expert.tint)
                        .scaleEffect(0.78)
                    Text(expert.name)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(displayedQuote + (isTyping ? "▌" : ""))
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(Color(red: 0.08, green: 0.07, blue: 0.08))
                    .lineLimit(3)
                    .minimumScaleFactor(0.70)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: width, height: height, alignment: .leading)
            .background(
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 1.0, green: 0.96, blue: 0.78))
                    Rectangle()
                        .fill(expert.tint.opacity(0.62))
                        .frame(height: 6)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.black.opacity(0.82), lineWidth: 2)
            )
        }
        .overlay(alignment: tailEdge.alignment) {
            SpeechBubbleTail(edge: tailEdge)
                .fill(Color(red: 1.0, green: 0.96, blue: 0.78))
                .frame(width: tailEdge.isVertical ? 22 : 14, height: tailEdge.isVertical ? 14 : 22)
                .overlay(
                    SpeechBubbleTail(edge: tailEdge)
                        .stroke(.black.opacity(0.82), lineWidth: 2)
                )
                .offset(tailPositionOffset)
        }
        .shadow(color: .black.opacity(0.55), radius: 0, x: 5, y: 5)
        .offset(y: isFloating ? -4 : 4)
        .scaleEffect(hasPopped ? 1 : 0.82, anchor: tailEdge.transitionAnchor)
        .allowsHitTesting(false)
        .onAppear {
            startTyping()
            withAnimation(.spring(response: 0.30, dampingFraction: 0.62)) {
                hasPopped = true
            }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                isFloating = true
            }
        }
    }

    private var tailPositionOffset: CGSize {
        switch tailEdge {
        case .top:
            return CGSize(width: tailOffset, height: -12)
        case .bottom:
            return CGSize(width: tailOffset, height: 12)
        case .leading:
            return CGSize(width: -12, height: tailOffset)
        case .trailing:
            return CGSize(width: 12, height: tailOffset)
        }
    }

    private func startTyping() {
        visibleCharacterCount = 0
        let count = expert.quote.count
        for index in 0...count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.055) {
                visibleCharacterCount = index
            }
        }
    }
}

private struct SpeechBubbleTail: Shape {
    let edge: SpeechBubbleTailEdge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch edge {
        case .top:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .bottom:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        case .leading:
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .trailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

private struct ExpertSeat: View {
    let expert: Expert
    let isSelected: Bool
    let activeReaction: ExpertReaction?
    let reactionToken: UUID
    let stageSize: CGSize

    @State private var isThinking = false

    private var animationState: String {
        if let activeReaction {
            return activeReaction.petState
        }
        if isSelected && !isThinking {
            return "Speaking"
        }
        return "Idle"
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                ExpertAvatar(
                    expert: expert,
                    animationState: animationState,
                    isSelected: isSelected,
                    stageSize: stageSize
                )
                .rotationEffect(.degrees(isThinking ? -2 : 0))
                .offset(y: activeReaction == nil ? (isThinking ? -3 : 0) : -5)
                .scaleEffect(activeReaction == nil ? 1 : 1.08)
                .animation(.spring(response: 0.24, dampingFraction: 0.58), value: isThinking)
                .animation(.spring(response: 0.18, dampingFraction: 0.48), value: activeReaction)

                PixelDot(color: expert.side.color)
                    .offset(x: 5, y: -5)

                if isSelected && isThinking {
                    ThinkingPips(tint: expert.tint)
                        .offset(x: 17, y: -25)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            Text(expert.name)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.56))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .lineLimit(1)
        }
        .onAppear {
            if isSelected {
                beginThinking()
            }
        }
        .onChange(of: isSelected) { _, newValue in
            if newValue {
                beginThinking()
            } else {
                isThinking = false
            }
        }
        .onChange(of: reactionToken) { _, _ in
            guard activeReaction != nil else { return }
            isThinking = false
        }
    }

    private func beginThinking() {
        isThinking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            if isSelected {
                isThinking = false
            }
        }
    }
}

private struct ExpertAvatar: View {
    let expert: Expert
    let animationState: String
    let isSelected: Bool
    let stageSize: CGSize

    private var scale: CGFloat {
        min(max(stageSize.height / 358, 1), 1.38)
    }

    var body: some View {
        if let petAssetPrefix = expert.petAssetPrefix {
            AnimatedPetView(
                assetPrefix: petAssetPrefix,
                state: animationState,
                fps: isSelected ? 8 : 5
            )
            .frame(width: (isSelected ? 78 : 62) * scale, height: (isSelected ? 84 : 68) * scale)
            .padding(.horizontal, 2)
            .background(Color.black.opacity(isSelected ? 0.18 : 0.02))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.yellow : Color.clear, lineWidth: isSelected ? 3 : 0)
            )
            .shadow(color: .black.opacity(0.55), radius: 0, x: 4, y: 4)
        } else {
            Text(expert.initials)
                .font(.system(size: 20 * scale, weight: .black, design: .monospaced))
                .foregroundStyle(.black)
                .frame(width: (isSelected ? 58 : 48) * scale, height: (isSelected ? 58 : 48) * scale)
                .background(expert.tint)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.yellow : Color.black.opacity(0.65), lineWidth: isSelected ? 4 : 2)
                )
                .shadow(color: .black.opacity(0.5), radius: 0, x: 4, y: 4)
        }
    }
}

private struct ThinkingPips: View {
    let tint: Color

    @State private var phase = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Rectangle()
                    .fill(index == 1 ? Color.white : tint)
                    .frame(width: 5, height: 5)
                    .offset(y: phase ? -CGFloat(index + 1) * 2 : 0)
                    .opacity(phase ? 1 : 0.52)
                    .animation(
                        .easeInOut(duration: 0.34)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.08),
                        value: phase
                    )
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.74), lineWidth: 1))
        .shadow(color: .black.opacity(0.52), radius: 0, x: 3, y: 3)
        .onAppear {
            phase = true
        }
    }
}

private struct ReactionBurst: View {
    let reaction: ExpertReaction
    let tint: Color

    @State private var exploded = false

    private let sparks: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [
        (-42, -18, 6),
        (-25, -36, 4),
        (28, -34, 5),
        (46, -12, 4),
        (-36, 16, 5),
        (36, 18, 6)
    ]

    var body: some View {
        ZStack {
            ForEach(Array(sparks.enumerated()), id: \.offset) { _, spark in
                Rectangle()
                    .fill(spark.size > 5 ? Color.white : reaction.tint)
                    .frame(width: spark.size, height: spark.size)
                    .offset(
                        x: exploded ? spark.x : 0,
                        y: exploded ? spark.y : 0
                    )
                    .opacity(exploded ? 0 : 1)
                    .animation(.easeOut(duration: 0.58), value: exploded)
            }

            HStack(spacing: 5) {
                Image(systemName: reaction.icon)
                    .font(.system(size: 11, weight: .black))
                Text(reaction.stampText)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(reaction.tint)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.82), lineWidth: 2))
            .rotationEffect(.degrees(reaction == .support ? -8 : 8))
            .scaleEffect(exploded ? 1.08 : 0.4)
            .opacity(exploded ? 1 : 0)
            .shadow(color: tint.opacity(0.65), radius: 14)
            .animation(.spring(response: 0.22, dampingFraction: 0.48), value: exploded)
        }
        .allowsHitTesting(false)
        .onAppear {
            exploded = true
        }
    }
}

private struct AnimatedPetView: View {
    let assetPrefix: String
    let state: String
    let fps: Double

    private let frameCount = 8
    private var frameInterval: TimeInterval {
        1 / max(fps, 1)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: frameInterval)) { context in
            let frame = Int(context.date.timeIntervalSinceReferenceDate * fps) % frameCount
            PetFrameImage(assetPrefix: assetPrefix, state: state, frame: frame)
        }
    }
}

private struct ExpertLibraryPetView: View {
    let assetPrefix: String
    let isFocused: Bool

    var body: some View {
        if isFocused {
            AnimatedPetView(assetPrefix: assetPrefix, state: "Supported", fps: 6)
        } else {
            AmbientIdlePetView(assetPrefix: assetPrefix)
        }
    }
}

private struct AmbientIdlePetView: View {
    let assetPrefix: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    private var phaseDelay: Double {
        let seed = assetPrefix.unicodeScalars.reduce(0) { partial, scalar in
            (partial + Int(scalar.value)) % 13
        }
        return Double(seed) * 0.08
    }

    private var cycleDuration: Double {
        2.4 + phaseDelay * 0.8
    }

    var body: some View {
        PetFrameImage(assetPrefix: assetPrefix, state: "Idle", frame: 0)
            .scaleEffect(isBreathing ? 1.025 : 0.995)
            .offset(y: isBreathing ? -1.5 : 1.5)
            .rotationEffect(.degrees(isBreathing ? 0.7 : -0.35))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: cycleDuration).delay(phaseDelay).repeatForever(autoreverses: true)) {
                    isBreathing = true
                }
            }
            .onDisappear {
                isBreathing = false
            }
    }
}

private struct PetFrameImage: View {
    let assetPrefix: String
    let state: String
    let frame: Int

    var body: some View {
        Image("\(assetPrefix)\(state)\(String(format: "%02d", frame))")
            .resizable()
            .interpolation(.none)
            .scaledToFit()
    }
}

private struct ExpertTicker: View {
    let expert: Expert
    let count: Int
    let canRemove: Bool
    let onNext: () -> Void
    let onRemove: () -> Void
    let onBattle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    PixelDot(color: expert.side.color)
                    Text(expert.name)
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                    Text(expert.role)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.orange)
                }

                Text(expert.quote)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                Text("席位 \(count)/\(roundTableMaxExperts)")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(count >= roundTableMaxExperts ? .yellow : .white.opacity(0.58))
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: onBattle) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.black)
                        .frame(width: 42, height: 42)
                        .background(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Button(action: onRemove) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(canRemove ? .white : .white.opacity(0.34))
                        .frame(width: 42, height: 42)
                        .background(Color.black.opacity(canRemove ? 0.42 : 0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.16), lineWidth: 1))
                }
                .disabled(!canRemove)

                Button(action: onNext) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(.yellow)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(14)
        .background(PixelPanel(fill: Color.white.opacity(0.10), stroke: Color.yellow.opacity(0.45)))
    }
}

private struct BottomActionBar: View {
    let onReact: (ExpertReaction) -> Void
    let onBattle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ActionButton(title: "赞同", icon: "hand.thumbsup.fill", tint: .mint) {
                onReact(.support)
            }
            ActionButton(title: "语音", icon: "mic.fill", tint: .white, isPrimary: true, action: onBattle)
            ActionButton(title: "反对", icon: "hand.thumbsdown.fill", tint: .red) {
                onReact(.oppose)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.22), lineWidth: 1))
    }
}

private struct RoundTableStartForumBar: View {
    let topic: RoundtableTopic
    let expertCount: Int
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.3.sequence.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.yellow)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text("现在可以从专家库选择更适合这个事件的专家")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                    Text("\(topic.title) · \(expertCount) 位专家待开麦")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 0)
            }

            Button(action: onStart) {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .black))
                    Text("开始论坛")
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                    Spacer()
                    Text("ROUND 1")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.72))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.40))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.yellow)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black.opacity(0.70), lineWidth: 2))
                .shadow(color: .black.opacity(0.36), radius: 0, x: 4, y: 4)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.22), lineWidth: 1))
    }
}

private struct ActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    var isPrimary = false
    var action: () -> Void = {}

    @State private var isPressed = false

    var body: some View {
        Button {
            action()
            withAnimation(.spring(response: 0.18, dampingFraction: 0.52)) {
                isPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                isPressed = false
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: isPrimary ? 22 : 18, weight: .black))
                Text(title)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
            }
            .foregroundStyle(isPrimary ? .black : tint)
            .frame(maxWidth: .infinity)
            .frame(height: isPrimary ? 70 : 60)
            .background(isPrimary ? tint : Color.black.opacity(0.32))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(isPressed ? tint : Color.white.opacity(0.12), lineWidth: isPressed ? 2 : 1))
            .scaleEffect(isPressed ? 0.94 : 1)
        }
        .buttonStyle(.plain)
    }
}

private struct PixelBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.05, blue: 0.10)
                .ignoresSafeArea()
            LinearGradient(colors: [.orange.opacity(0.20), .clear, .purple.opacity(0.24)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            PixelGrid()
                .opacity(0.28)
                .ignoresSafeArea()
        }
    }
}

private struct PixelPanel: View {
    let fill: Color
    let stroke: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(stroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 0, x: 5, y: 5)
    }
}

private struct PixelDot: View {
    let color: Color

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Rectangle().stroke(.black.opacity(0.7), lineWidth: 1))
    }
}

private struct PixelGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 18
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 1)
        }
    }
}

private struct PixelSun: View {
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<8, id: \.self) { row in
                Rectangle()
                    .fill(color.opacity(0.18 + Double(row) * 0.06))
                    .frame(width: CGFloat(74 - row * 5), height: 4)
            }
        }
    }
}

#Preview {
    ContentView()
}
