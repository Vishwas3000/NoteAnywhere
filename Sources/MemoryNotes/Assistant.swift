import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One-click edits with Apple Intelligence's on-device model (macOS 26+). Nothing leaves the Mac.
/// Used by the app's editors and, through the native host, by the browser overlay.
enum Assistant {
    enum Action: String, CaseIterable {
        case proofread, improve, shorten, checklist, title

        var instruction: String {
            switch self {
            case .proofread: "Fix spelling, grammar and punctuation. Change nothing else: keep the wording, tone and meaning."
            case .improve: "Rewrite it to be clearer and better organized. Keep the meaning, the facts and the author's voice."
            case .shorten: "Make it shorter and more concise. Keep every important fact, name, number and link."
            case .checklist: "Turn it into a Markdown checklist of concrete action items, one per line, each starting with \"- [ ] \"."
            case .title: "Write a short title (at most 7 words) for this note. Reply with the title only, no quotes or punctuation at the end."
            }
        }
    }

    struct Failure: LocalizedError { let errorDescription: String? }

    /// Why the model can't run, or nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return "Apple Intelligence needs macOS 26 or later." }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to use this."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready. Try again in a few minutes."
        case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
        case .unavailable: return "Apple Intelligence isn't available right now."
        }
        #else
        return "This build doesn't include Apple Intelligence."
        #endif
    }

    /// Returns the rewritten Markdown. For `.title`, returns just the title.
    static func run(_ action: Action, on markdown: String) async throws -> String {
        if let reason = unavailableReason { throw Failure(errorDescription: reason) }
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(errorDescription: "Write something first.")
        }
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw Failure(errorDescription: unavailableReason) }
        let session = LanguageModelSession(instructions: """
            You edit personal notes written in Markdown. \(action.instruction)
            Keep Markdown formatting (headings, lists, checkboxes, links, code) unless asked to change it.
            Reply with the result only: no preamble, no explanation, no surrounding code fence.
            """)
        do {
            let reply = try await session.respond(to: markdown).content
            return clean(reply)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw Failure(errorDescription: "This note is too long for the on-device model. Select a part of it and try again.")
            case .guardrailViolation: throw Failure(errorDescription: "Apple Intelligence declined to rewrite this text.")
            default: throw Failure(errorDescription: "Apple Intelligence couldn't finish: \(error.localizedDescription)")
            }
        }
        #else
        throw Failure(errorDescription: unavailableReason)
        #endif
    }

    /// Models sometimes wrap the answer in a fence or quotes anyway.
    static func clean(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 {
            text = String(text.dropFirst(3).dropLast(3)).replacing(#/^(markdown|md)?\n/#, with: "")
        }
        if text.count > 1, let first = text.first, let last = text.last, "\"“".contains(first), "\"”".contains(last) {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
