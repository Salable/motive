import Foundation

/// What kind of answer a question invites, and how the renderer should offer
/// it. Deliberately a flat record of primitives rather than a nested tree: the
/// same constraint MCP's elicitation schema adopts, and for the same reason —
/// every surface that has to render one of these stays simple.
public struct ResponseSpec: Codable, Equatable, Sendable {
    public enum Form: String, Codable, Sendable, CaseIterable {
        /// Two buttons. Both are answers — "no" is `accepted` with
        /// `confirmed: false`, not a refusal.
        case confirm
        /// One button per option.
        case choice
        /// A composer field.
        case text
    }

    public static let minChoices = 2
    public static let maxChoices = 6
    /// A question may outlive any reasonable session, but not forever.
    public static let maxTimeoutMS = 3_600_000

    public let form: Form
    /// `choice` only.
    public let choices: [String]?
    /// `text` only.
    public let placeholder: String?
    /// `confirm` only; the renderer supplies defaults when absent.
    public let yesLabel: String?
    public let noLabel: String?
    /// Milliseconds until the question expires on its own. Nil parks it
    /// indefinitely — we impose no deadline of our own, so an asker who wants
    /// one declares it here.
    public let timeoutMS: Int?

    public init(
        form: Form,
        choices: [String]? = nil,
        placeholder: String? = nil,
        yesLabel: String? = nil,
        noLabel: String? = nil,
        timeoutMS: Int? = nil
    ) {
        self.form = form
        self.choices = choices
        self.placeholder = placeholder
        self.yesLabel = yesLabel
        self.noLabel = noLabel
        self.timeoutMS = timeoutMS
    }

    enum CodingKeys: String, CodingKey {
        case form, choices, placeholder, yesLabel, noLabel
        // Wire spelling matches the codebase's other millisecond fields
        // (`ttl`, `duration`, `ms`, `hold`) — bare, no unit suffix.
        case timeoutMS = "timeout"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .form)
        guard let form = Form(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .form,
                in: container,
                debugDescription: "unknown response form '\(raw)' "
                    + "(valid: \(Form.allCases.map(\.rawValue).joined(separator: ", ")))"
            )
        }
        self.form = form
        choices = try container.decodeIfPresent([String].self, forKey: .choices)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        yesLabel = try container.decodeIfPresent(String.self, forKey: .yesLabel)
        noLabel = try container.decodeIfPresent(String.self, forKey: .noLabel)
        timeoutMS = try container.decodeIfPresent(Int.self, forKey: .timeoutMS)
    }

    /// Loud validation, in the house style: reject with the valid vocabulary
    /// rather than silently normalising.
    public func validate() -> ControlFailure? {
        switch form {
        case .choice:
            let options = choices ?? []
            guard options.count >= Self.minChoices, options.count <= Self.maxChoices else {
                return ControlFailure(error: "invalid_choices", valid: nil)
            }
            guard options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else {
                return ControlFailure(error: "invalid_choices", valid: nil)
            }
            guard Set(options).count == options.count else {
                return ControlFailure(error: "duplicate_choices", valid: nil)
            }
        case .confirm, .text:
            // `choices` on a non-choice form is a mistake worth naming: it
            // reads as though options were offered when none will render.
            if choices != nil {
                return ControlFailure(error: "choices_not_allowed", valid: [Form.choice.rawValue])
            }
        }
        if let timeoutMS, timeoutMS <= 0 {
            return ControlFailure(error: "invalid_timeout", valid: nil)
        }
        return nil
    }

    /// Clamped, so a caller cannot park a question past the ceiling.
    public var timeout: TimeInterval? {
        timeoutMS.map { TimeInterval(min($0, Self.maxTimeoutMS)) / 1_000 }
    }
}

/// What the human actually answered. Encodes flat so a reader can pull the one
/// field its form implies without unwrapping a discriminator.
public enum AnswerContent: Equatable, Sendable, Codable {
    case confirm(Bool)
    case choice(String, index: Int)
    case text(String)

    public static let maxTextLength = 1_000

    enum CodingKeys: String, CodingKey {
        case confirmed, choice, choiceIndex, text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let confirmed = try container.decodeIfPresent(Bool.self, forKey: .confirmed) {
            self = .confirm(confirmed)
        } else if let choice = try container.decodeIfPresent(String.self, forKey: .choice) {
            let index = try container.decodeIfPresent(Int.self, forKey: .choiceIndex) ?? 0
            self = .choice(choice, index: index)
        } else if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .confirmed,
                in: container,
                debugDescription: "answer must carry one of: confirmed, choice, text"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .confirm(let value):
            try container.encode(value, forKey: .confirmed)
        case .choice(let value, let index):
            try container.encode(value, forKey: .choice)
            try container.encode(index, forKey: .choiceIndex)
        case .text(let value):
            try container.encode(value, forKey: .text)
        }
    }

    /// The form this content answers, for matching against the question's spec.
    public var form: ResponseSpec.Form {
        switch self {
        case .confirm: return .confirm
        case .choice: return .choice
        case .text: return .text
        }
    }
}

/// How an answer reached us. `voice` arrives through exactly the same path as
/// `typed` — transcription is an input method, not a separate feature.
public enum AnswerChannel: String, Codable, Sendable {
    case typed
    case voice
}

/// Why a question ended without an answer. Distinguishing these matters: the
/// human walking away is a different signal from the asker withdrawing.
public enum QuestionCancelReason: String, Codable, Sendable {
    /// The human dismissed the bubble without choosing.
    case dismissed
    /// `skip` ended the current item.
    case skipped
    /// `clear-queue` / `play-script` wiped the queue.
    case flushed
    /// The asker withdrew it via `cancel-question`.
    case withdrawn
}

/// Terminal vocabulary borrowed from MCP elicitation's three-action model,
/// plus `expired` for an asker-declared deadline elapsing.
public enum QuestionStatus: String, Codable, Sendable {
    case awaiting
    case accepted
    case declined
    case cancelled
    case expired

    public var isTerminal: Bool { self != .awaiting }
}

/// How a question ended.
public enum QuestionResolution: Equatable, Sendable {
    case accepted(AnswerContent, via: AnswerChannel)
    case declined(via: AnswerChannel)
    case cancelled(QuestionCancelReason)
    case expired

    public var status: QuestionStatus {
        switch self {
        case .accepted: return .accepted
        case .declined: return .declined
        case .cancelled: return .cancelled
        case .expired: return .expired
        }
    }
}

/// The full life of one question — asked, presented, resolved. This is both
/// what an agent polls and what we persist, so it carries every timestamp a
/// reader might reasonably want rather than making them correlate events.
public struct QuestionRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let respond: ResponseSpec
    /// When the asker posed it — not when it reached the head. The count badge
    /// needs to know about question two the moment it is admitted.
    public let askedAt: Date
    /// When it reached the head and took the attention surface.
    public var presentedAt: Date?
    public var expiresAt: Date?
    public var status: QuestionStatus
    public var resolvedAt: Date?
    public var answer: AnswerContent?
    public var via: AnswerChannel?
    public var cancelReason: QuestionCancelReason?

    public init(
        id: String,
        text: String,
        respond: ResponseSpec,
        askedAt: Date,
        presentedAt: Date? = nil,
        expiresAt: Date? = nil,
        status: QuestionStatus = .awaiting,
        resolvedAt: Date? = nil,
        answer: AnswerContent? = nil,
        via: AnswerChannel? = nil,
        cancelReason: QuestionCancelReason? = nil
    ) {
        self.id = id
        self.text = text
        self.respond = respond
        self.askedAt = askedAt
        self.presentedAt = presentedAt
        self.expiresAt = expiresAt
        self.status = status
        self.resolvedAt = resolvedAt
        self.answer = answer
        self.via = via
        self.cancelReason = cancelReason
    }

    public var isOutstanding: Bool { !status.isTerminal }

    /// Apply a terminal outcome. Returns a copy so callers can keep the
    /// pre-resolution record for comparison.
    public func resolved(_ resolution: QuestionResolution, at date: Date) -> QuestionRecord {
        var copy = self
        copy.status = resolution.status
        copy.resolvedAt = date
        switch resolution {
        case .accepted(let content, let via):
            copy.answer = content
            copy.via = via
        case .declined(let via):
            copy.via = via
        case .cancelled(let reason):
            copy.cancelReason = reason
        case .expired:
            break
        }
        return copy
    }

    /// Turn something the human said out loud into an answer to *this*
    /// question, or nil when it doesn't match.
    ///
    /// Lives here rather than in the UI so it is testable and so typed and
    /// spoken answers cannot drift apart: both end up as the same
    /// `AnswerContent`, differing only in the channel that produced them.
    public func interpret(spoken text: String) -> AnswerContent? {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !said.isEmpty else { return nil }

        switch respond.form {
        case .text:
            return .text(text.trimmingCharacters(in: .whitespacesAndNewlines))

        case .confirm:
            // Match the labels the human is actually looking at first — if a
            // button says "Ship it", saying "ship it" should press it.
            if let yes = respond.yesLabel?.lowercased(), said.contains(yes) { return .confirm(true) }
            if let no = respond.noLabel?.lowercased(), said.contains(no) { return .confirm(false) }
            let affirmatives = ["yes", "yeah", "yep", "sure", "ok", "okay", "go ahead", "do it"]
            let negatives = ["no", "nope", "don't", "do not", "stop", "cancel", "hold off"]
            if negatives.contains(where: { said.contains($0) }) { return .confirm(false) }
            if affirmatives.contains(where: { said.contains($0) }) { return .confirm(true) }
            return nil

        case .choice:
            let options = respond.choices ?? []
            // Exact match wins over containment, so "prod" doesn't match
            // "production" when both are offered.
            if let index = options.firstIndex(where: { $0.lowercased() == said }) {
                return .choice(options[index], index: index)
            }
            let matches = options.enumerated().filter { said.contains($0.element.lowercased()) }
            guard matches.count == 1, let match = matches.first else { return nil }
            return .choice(match.element, index: match.offset)
        }
    }

    /// Validate an answer against what this question actually asked for.
    /// Returns nil when the content is acceptable.
    public func validate(_ content: AnswerContent) -> ControlFailure? {
        guard content.form == respond.form else {
            return ControlFailure(error: "answer_form_mismatch", valid: [respond.form.rawValue])
        }
        switch content {
        case .confirm:
            return nil
        case .choice(let value, _):
            let options = respond.choices ?? []
            return options.contains(value)
                ? nil
                : ControlFailure(error: "invalid_choice", valid: options)
        case .text(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return ControlFailure(error: "empty_answer", valid: nil)
            }
            if trimmed.count > AnswerContent.maxTextLength {
                return ControlFailure(error: "answer_too_long", valid: nil)
            }
            return nil
        }
    }
}
