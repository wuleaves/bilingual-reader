import SwiftUI
import Translation
import NaturalLanguage

func appleLanguageCode(_ name: String) -> String {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let aliases = ["简体中文": "zh-Hans", "中文": "zh-Hans", "繁体中文": "zh-Hant", "繁體中文": "zh-Hant", "英语": "en", "英文": "en", "english": "en", "日语": "ja", "韩语": "ko", "法语": "fr", "德语": "de", "西班牙语": "es", "俄语": "ru", "葡萄牙语": "pt", "意大利语": "it"]
    return aliases[value.lowercased()] ?? value
}

// Short PDF headers and author lines rarely provide enough language evidence.
func appleSourceLanguage(_ text: String, context: String) -> String? {
    func detect(_ value: String) -> String? {
        let recognizer = NLLanguageRecognizer(); recognizer.processString(value)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first,
              best.value >= 0.8 else { return nil }
        return best.key.rawValue
    }
    let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    if letters >= 40, let language = detect(text) { return language }
    if !context.isEmpty, let language = detect(context) { return language }
    // PDF extraction can interleave columns; vote over substantial lines as a fallback.
    var votes: [String: Int] = [:]
    for line in context.components(separatedBy: .newlines) where line.count >= 40 {
        if let code = detect(line) { votes[code, default: 0] += line.count }
    }
    let ranked = votes.sorted { $0.value > $1.value }
    if let first = ranked.first, first.value >= 100,
       Double(first.value) / Double(max(1, votes.values.reduce(0, +))) >= 0.8 { return first.key }
    return nil
}
func resolvedAppleSource(explicit: String?, page: String?, fragment: () -> String?) -> String? {
    if let explicit, !explicit.isEmpty { return appleLanguageCode(explicit) }
    if let page { return page }
    return fragment()
}
func appleTranslationFailure(_ error: Error, stage: String) -> Error {
    if error is CancellationError { return error }
    let detail = error as NSError
    return TranslationError(message: "苹果翻译失败（\(stage)）。\n\(detail.localizedDescription)\n错误标识：\(detail.domain) / \(detail.code)\n可在翻译设置中测试连接；若系统询问语言或下载语言包，请完成提示后重试。")
}

@MainActor final class AppleTranslationBridge: ObservableObject {
    struct Request: Identifiable {
        let id: UUID
        let text: String
        let target: String
        let source: String?
    }
    @Published var pending: Request?
    private var languageCache: [String: String] = [:]
    private var continuation: CheckedContinuation<String, Error>?
    func translate(_ text: String, target: String, context: String = "", source: String? = nil) async throws -> String {
        guard #available(macOS 15.0, *) else { throw TranslationError(message: "苹果系统翻译需要 macOS 15 或更新版本。") }
        try Task.checkCancellation()
        guard pending == nil else { throw TranslationError(message: "苹果翻译正在处理上一段，请稍后重试。") }
        let contextID = digest(Data(context.utf8))
        let pageLanguage = context.isEmpty ? nil : (languageCache[contextID] ?? appleSourceLanguage("", context: context))
        if let pageLanguage { languageCache[contextID] = pageLanguage }
        let resolved = resolvedAppleSource(explicit: source, page: pageLanguage) {
            appleSourceLanguage(text, context: "")
        }
        guard let resolved else {
            throw TranslationError(message: "无法可靠识别原文语言。请打开翻译设置，将原文语言设为英语（或文档实际语言），然后继续翻译。")
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                continuation = waiter
                pending = Request(id: id, text: text, target: appleLanguageCode(target), source: resolved)
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, result: .failure(CancellationError())) }
        }
    }
    func finish(_ id: UUID, result: Result<String, Error>) {
        guard pending?.id == id else { return }
        let waiter = continuation
        continuation = nil; pending = nil
        waiter?.resume(with: result)
    }
}

@available(macOS 15.0, *)
struct AppleTranslationHost: View {
    @ObservedObject var bridge: AppleTranslationBridge
    var body: some View {
        Group {
            if let request = bridge.pending {
                AppleTranslationRequestView(bridge: bridge, request: request).id(request.id)
            }
        }
    }
}

@available(macOS 15.0, *)
private struct AppleTranslationRequestView: View {
    let bridge: AppleTranslationBridge
    let request: AppleTranslationBridge.Request
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(source: request.source.map { Locale.Language(identifier: $0) }, target: Locale.Language(identifier: request.target)) { session in
                var stage = "检查语言"
                do {
                    let availability = LanguageAvailability()
                    let target = Locale.Language(identifier: request.target)
                    if let code = request.source {
                        let source = Locale.Language(identifier: code)
                        if source.minimalIdentifier == target.minimalIdentifier {
                            bridge.finish(request.id, result: .success(request.text)); return
                        }
                        let status = await availability.status(from: source, to: target)
                        guard status != .unsupported else { throw TranslationError(message: "当前语言组合不受苹果系统支持：\(code) → \(request.target)。如果原文是英文，请在翻译设置中将原文语言设为英语后重试。") }
                        stage = "准备语言包"
                        if status != .installed { try await session.prepareTranslation() }
                    }
                    // With no reliable source language, let the session present its language picker.
                    // status(for:to:) cannot present that UI and fails on short PDF headers.
                    stage = "翻译文字"
                    let response = try await session.translate(request.text)
                    try Task.checkCancellation()
                    guard !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw TranslationError(message: "苹果系统翻译未返回有效译文。")
                    }
                    bridge.finish(request.id, result: .success(response.targetText))
                } catch {
                    bridge.finish(request.id, result: .failure(appleTranslationFailure(error, stage: stage)))
                }
            }
    }
}

@MainActor func appleBridgeTests() async throws {
    guard #available(macOS 15.0, *) else { print("SKIP: Apple bridge requires macOS 15"); return }
    let context = "This research evaluates clinical patient outcomes and validates a predictive machine learning model in intensive care units."
    check(appleSourceLanguage("Biomed Environ Sci, 2026; 39(7): 769-784", context: context) == "en")
    check(appleSourceLanguage("769", context: "") == nil)
    check(resolvedAppleSource(explicit: nil, page: "en", fragment: { "fi" }) == "en")
    check(resolvedAppleSource(explicit: "ja", page: "en", fragment: { "fi" }) == "ja")
    check(resolvedAppleSource(explicit: nil, page: nil, fragment: { "fr" }) == "fr")
    print("PASS: explicit > whole-page > fragment language precedence, Finnish false-positive regression")
    let failure = appleTranslationFailure(NSError(domain: "TranslationErrorDomain", code: 21), stage: "检查语言")
    check(failure.localizedDescription.contains("21"))
    check(appleTranslationFailure(CancellationError(), stage: "翻译") is CancellationError)
    print("PASS: short-header page language fallback, unknown-language deferral, diagnostic detail")
    let bridge = AppleTranslationBridge()
    func waitPending() async throws -> AppleTranslationBridge.Request {
        for _ in 0..<1000 {
            if let request = bridge.pending { return request }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw TranslationError(message: "Test request did not start")
    }
    do { _ = try await bridge.translate("769", target: "简体中文"); fatalError("Unknown language should not open system UI") }
    catch { check(bridge.pending == nil) }
    let first = Task { try await bridge.translate("Hello", target: "简体中文", source: "en") }
    let request = try await waitPending()
    check(request.target == "zh-Hans")
    check(request.source == "en")
    bridge.finish(UUID(), result: .success("stale"))
    check(bridge.pending?.id == request.id)
    bridge.finish(request.id, result: .success("你好"))
    check(try await first.value == "你好")
    check(bridge.pending == nil)
    let contextual = Task { try await bridge.translate("Tämä on suomalainen teksti, joka käsittelee sairaalan tutkimusta ja potilaiden hoitoa.", target: "简体中文", context: context) }
    let contextualRequest = try await waitPending()
    check(contextualRequest.source == "en")
    bridge.finish(contextualRequest.id, result: .success("测试译文"))
    check(try await contextual.value == "测试译文")
    let cancelled = Task { try await bridge.translate("Cancel", target: "英语", source: "zh-Hans") }
    let oldRequest = try await waitPending()
    cancelled.cancel()
    do { _ = try await cancelled.value; fatalError("Cancellation ignored") } catch is CancellationError {} 
    check(bridge.pending == nil)
    let retry = Task { try await bridge.translate("Retry", target: "日语", source: "en") }
    let newRequest = try await waitPending()
    bridge.finish(oldRequest.id, result: .success("stale"))
    check(bridge.pending?.id == newRequest.id)
    bridge.finish(newRequest.id, result: .failure(TranslationError(message: "test failure")))
    do { _ = try await retry.value; fatalError("Error ignored") } catch { check(error.localizedDescription == "test failure") }
    check(bridge.pending == nil)
    print("PASS: Apple bridge completion, cancellation, retry, stale response isolation and error propagation (no model invocation)")
}
