import Testing
@testable import OgCore

@Suite("DocsSearchIndicatorState")
struct DocsSearchIndicatorTests {
    @Test("Fast search finishing before showDelay never displays spinner")
    func fastSearchAvoidsFlicker() {
        var state = DocsSearchIndicatorState(showDelayMs: 150, minVisibleMs: 250)

        let startAction = state.beginSearch(generation: 1, isRefresh: false, nowMs: 0)
        #expect(startAction == .scheduleShow(generation: 1, delayMs: 150))
        #expect(!state.isVisible)
        #expect(state.currentLabel == nil)

        // Finishes at 40ms before show delay elapses.
        let finishAction = state.finish(generation: 1, nowMs: 40)
        #expect(finishAction == .hideNow)
        #expect(!state.isVisible)
        #expect(state.stage == .idle)

        // Late show timer firing after finish is ignored.
        let lateShown = state.showDelayElapsed(generation: 1, nowMs: 150)
        #expect(!lateShown)
        #expect(!state.isVisible)
    }

    @Test("Medium search respects minimum visible duration after showing")
    func mediumSearchHoldsMinimumVisibleDuration() {
        var state = DocsSearchIndicatorState(showDelayMs: 150, minVisibleMs: 250)

        _ = state.beginSearch(generation: 1, isRefresh: false, nowMs: 100)
        let shown = state.showDelayElapsed(generation: 1, nowMs: 250)
        #expect(shown)
        #expect(state.isVisible)
        #expect(state.currentLabel == "検索中…")

        // Search finishes 50ms after spinner became visible; must hold for remaining 200ms.
        let finishAction = state.finish(generation: 1, nowMs: 300)
        #expect(finishAction == .scheduleHide(generation: 1, delayMs: 200))
        #expect(state.isVisible)
        #expect(state.currentLabel == "検索中…")

        // Hide timer fires -> hides cleanly.
        let hidden = state.hideDelayElapsed(generation: 1)
        #expect(hidden)
        #expect(!state.isVisible)
        #expect(state.currentLabel == nil)
    }

    @Test("Long search hides immediately upon completion")
    func longSearchHidesImmediately() {
        var state = DocsSearchIndicatorState(showDelayMs: 150, minVisibleMs: 250)

        _ = state.beginSearch(generation: 1, isRefresh: false, nowMs: 0)
        let shown = state.showDelayElapsed(generation: 1, nowMs: 150)
        #expect(shown)
        #expect(state.isVisible)

        let finishAction = state.finish(generation: 1, nowMs: 800)
        #expect(finishAction == .hideNow)
        #expect(!state.isVisible)
        #expect(state.currentLabel == nil)
    }

    @Test("Refresh search uses re-searching label and Phase 3 transitions to synthesizing")
    func refreshAndSynthesisLabels() {
        var state = DocsSearchIndicatorState(showDelayMs: 150, minVisibleMs: 250)

        let a1 = state.beginSearch(generation: 2, isRefresh: true, nowMs: 0)
        #expect(a1 == .scheduleShow(generation: 2, delayMs: 150))
        let shown = state.showDelayElapsed(generation: 2, nowMs: 150)
        #expect(shown)
        #expect(state.currentLabel == "再検索中…")

        // Retrieval completes and Phase 3 synthesis begins.
        let a2 = state.beginSynthesis(generation: 2, nowMs: 220)
        #expect(a2 == .none)
        #expect(state.isVisible)
        #expect(state.currentLabel == "回答を生成中…")

        let a3 = state.finish(generation: 2, nowMs: 1200)
        #expect(a3 == .hideNow)
        #expect(!state.isVisible)
    }

    @Test("Fast retrieval followed by slow synthesis displays synthesizing spinner after showDelay")
    func fastRetrievalThenSlowSynthesisShowsSpinner() {
        var state = DocsSearchIndicatorState(showDelayMs: 150, minVisibleMs: 250)

        _ = state.beginSearch(generation: 1, isRefresh: false, nowMs: 0)
        // Retrieval finishes at 30ms and enters synthesis while showDelay timer is still pending.
        _ = state.beginSynthesis(generation: 1, nowMs: 30)
        #expect(!state.isVisible)

        // At 150ms the original show timer fires and displays the synthesizing label.
        let shown = state.showDelayElapsed(generation: 1, nowMs: 150)
        #expect(shown)
        #expect(state.isVisible)
        #expect(state.currentLabel == "回答を生成中…")

        let done = state.finish(generation: 1, nowMs: 900)
        #expect(done == .hideNow)
        #expect(!state.isVisible)
    }

    @Test("Stale generation completion and hide timers cannot disturb a newer search")
    func staleGenerationsAreIgnored() {
        var state = DocsSearchIndicatorState(showDelayMs: 150, minVisibleMs: 250)

        _ = state.beginSearch(generation: 1, isRefresh: false, nowMs: 0)
        let shown = state.showDelayElapsed(generation: 1, nowMs: 150)
        #expect(shown)
        // Finish gen 1 early so it schedules a hide timer.
        let hideGen1 = state.finish(generation: 1, nowMs: 200)
        #expect(hideGen1 == .scheduleHide(generation: 1, delayMs: 200))

        // Before hide timer fires, user starts gen 2 (re-search).
        let startGen2 = state.beginSearch(generation: 2, isRefresh: true, nowMs: 250)
        #expect(startGen2 == .none)
        #expect(state.isVisible)
        #expect(state.currentLabel == "再検索中…")

        // Stale hide timer for gen 1 fires -> ignored.
        let staleHide = state.hideDelayElapsed(generation: 1)
        #expect(!staleHide)
        #expect(state.isVisible)

        // Stale finish for gen 1 -> ignored.
        let staleFinish = state.finish(generation: 1, nowMs: 300)
        #expect(staleFinish == .none)
        #expect(state.isVisible)

        // Gen 2 finishes immediately on cancel.
        let cancelGen2 = state.finish(generation: 2, immediate: true, nowMs: 320)
        #expect(cancelGen2 == .hideNow)
        #expect(!state.isVisible)
    }

    @Test("Immediate finish and reset hide visible spinner without waiting and allow subsequent searches")
    func immediateFinishAndReset() {
        var state = DocsSearchIndicatorState(showDelayMs: 150, minVisibleMs: 250)

        _ = state.beginSearch(generation: 1, isRefresh: false, nowMs: 0)
        let shown = state.showDelayElapsed(generation: 1, nowMs: 150)
        #expect(shown)
        #expect(state.isVisible)

        let reset1 = state.reset(generation: 2)
        #expect(reset1 == .hideNow)
        #expect(!state.isVisible)
        #expect(state.stage == .idle)

        // Repeated empty resets must not block subsequent search generations.
        let reset2 = state.reset(generation: 3)
        #expect(reset2 == .none)
        let next = state.beginSearch(generation: 4, isRefresh: false, nowMs: 200)
        #expect(next == .scheduleShow(generation: 4, delayMs: 150))
        let shownNext = state.showDelayElapsed(generation: 4, nowMs: 350)
        #expect(shownNext)
        #expect(state.isVisible)
        #expect(state.currentLabel == "検索中…")
    }
}
