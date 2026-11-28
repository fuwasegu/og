/// Stage of an in-flight Docs panel search (Issue #35).
public enum DocsSearchStage: Sendable, Equatable {
    case idle
    case searching(isRefresh: Bool)
    case synthesizing

    /// User-facing status text shown beside the spinner while active.
    public var label: String? {
        switch self {
        case .idle:
            return nil
        case .searching(isRefresh: false):
            return "検索中…"
        case .searching(isRefresh: true):
            return "再検索中…"
        case .synthesizing:
            return "回答を生成中…"
        }
    }
}

/// Timer / visibility action produced by `DocsSearchIndicatorState`.
public enum DocsSearchIndicatorAction: Sendable, Equatable {
    case none
    case scheduleShow(generation: Int, delayMs: Int)
    case scheduleHide(generation: Int, delayMs: Int)
    case hideNow
}

/// Pure, testable state machine for the Docs search progress indicator (Issue #35).
///
/// Prevents flicker on fast searches via `showDelayMs` (spinner does not appear if
/// the search finishes before the delay) and `minVisibleMs` (once shown, the spinner
/// remains visible briefly so it does not flash for a single frame).
public struct DocsSearchIndicatorState: Sendable, Equatable {
    public static let defaultShowDelayMs = 150
    public static let defaultMinVisibleMs = 250

    public let showDelayMs: Int
    public let minVisibleMs: Int

    public private(set) var generation: Int = 0
    public private(set) var stage: DocsSearchStage = .idle
    public private(set) var isVisible: Bool = false

    private var shownAtMs: Int?
    private var displayedLabel: String?

    public init(
        showDelayMs: Int = defaultShowDelayMs,
        minVisibleMs: Int = defaultMinVisibleMs
    ) {
        self.showDelayMs = max(0, showDelayMs)
        self.minVisibleMs = max(0, minVisibleMs)
    }

    /// Label to display while `isVisible` is true; preserves the last active label
    /// during the minimum-visible wind-down so text does not blink empty.
    public var currentLabel: String? {
        guard isVisible else { return nil }
        return stage.label ?? displayedLabel
    }

    /// Starts a new search generation.
    public mutating func beginSearch(
        generation: Int,
        isRefresh: Bool,
        nowMs: Int
    ) -> DocsSearchIndicatorAction {
        guard generation >= self.generation else { return .none }
        self.generation = generation
        self.stage = .searching(isRefresh: isRefresh)
        self.displayedLabel = self.stage.label

        if isVisible {
            // Already visible (e.g. rapid re-search); keep spinning smoothly without hiding.
            self.shownAtMs = nowMs
            return .none
        }
        if showDelayMs == 0 {
            self.isVisible = true
            self.shownAtMs = nowMs
            return .none
        }
        return .scheduleShow(generation: generation, delayMs: showDelayMs)
    }

    /// Advances the active generation from retrieval to Phase 3 LLM answer synthesis.
    public mutating func beginSynthesis(
        generation: Int,
        nowMs: Int
    ) -> DocsSearchIndicatorAction {
        guard generation == self.generation, stage != .idle else { return .none }
        self.stage = .synthesizing
        self.displayedLabel = self.stage.label
        if !isVisible && showDelayMs == 0 {
            self.isVisible = true
            self.shownAtMs = nowMs
        }
        return .none
    }

    /// Invoked when the scheduled show delay timer fires.
    /// Returns `true` if visibility changed to `true`.
    @discardableResult
    public mutating func showDelayElapsed(generation: Int, nowMs: Int) -> Bool {
        guard generation == self.generation, stage != .idle, !isVisible else { return false }
        self.isVisible = true
        self.shownAtMs = nowMs
        self.displayedLabel = self.stage.label
        return true
    }

    /// Completes (or immediately cancels) the given search generation.
    public mutating func finish(
        generation: Int,
        immediate: Bool = false,
        nowMs: Int
    ) -> DocsSearchIndicatorAction {
        guard generation == self.generation else { return .none }
        self.stage = .idle

        if immediate || !isVisible {
            self.isVisible = false
            self.shownAtMs = nil
            self.displayedLabel = nil
            return .hideNow
        }

        let elapsed = max(0, nowMs - (shownAtMs ?? nowMs))
        let remaining = minVisibleMs - elapsed
        if remaining > 0 {
            return .scheduleHide(generation: generation, delayMs: remaining)
        }
        self.isVisible = false
        self.shownAtMs = nil
        self.displayedLabel = nil
        return .hideNow
    }

    /// Invoked when the scheduled minimum-visible hide timer fires.
    /// Returns `true` if visibility changed to `false`.
    @discardableResult
    public mutating func hideDelayElapsed(generation: Int) -> Bool {
        guard generation == self.generation, stage == .idle, isVisible else { return false }
        self.isVisible = false
        self.shownAtMs = nil
        self.displayedLabel = nil
        return true
    }

    /// Immediately clears indicator state (e.g. empty query or workspace reset).
    public mutating func reset(generation: Int? = nil) -> DocsSearchIndicatorAction {
        if let generation {
            self.generation = max(self.generation, generation)
        }
        self.stage = .idle
        let wasVisible = self.isVisible
        self.isVisible = false
        self.shownAtMs = nil
        self.displayedLabel = nil
        return wasVisible ? .hideNow : .none
    }
}
