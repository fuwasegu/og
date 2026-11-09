import Testing
@testable import OgCore

@Suite struct DebugStateMachineTests {
    @Test func stepStaysSteppingUntilNextStop() {
        var m = DebugStateMachine()
        let r1 = m.launch()
        #expect(r1)
        #expect(!m.canInspect)
        let r2 = m.launched()
        #expect(r2)
        let r3 = m.step()
        #expect(!r3, "cannot step while running")
        let r4 = m.stopped()
        #expect(r4)
        #expect(m.canInspect)
        let epoch = m.stopEpoch
        let r5 = m.step()
        #expect(r5)
        #expect(m.phase == .stepping)
        #expect(!m.canInspect, "DES-4: no inspection while stepping")
        let r6 = m.resume()
        #expect(!r6, "cannot resume while stepping")
        let r7 = m.stopped()
        #expect(r7)
        #expect(m.stopEpoch == epoch + 1)
        let r8 = m.resume()
        #expect(r8)
        #expect(m.phase == .running)
    }

    @Test func exitDuringStepEndsSession() {
        var m = DebugStateMachine()
        m.launch(); m.launched(); m.stopped(); m.step()
        m.terminated()
        #expect(m.phase == .terminated)
        #expect(!m.isLive)
        let r9 = m.stopped()
        #expect(!r9, "no stop after termination")
        let r10 = m.launch()
        #expect(r10, "a terminated machine can be relaunched")
    }
}

@Suite struct BreakpointLedgerTests {
    @Test func convertsToOneBasedAndClearsRemovedFiles() {
        var l = BreakpointLedger()
        let first = l.update(desired: ["/p/a.go": [4, 0], "/p/b.go": [9]])
        #expect(first == [BreakpointRequest(path: "/p/a.go", lines: [1, 5]), BreakpointRequest(path: "/p/b.go", lines: [10])])
        #expect(l.update(desired: ["/p/a.go": [0, 4], "/p/b.go": [9]]).isEmpty, "unchanged files are not re-sent")
        let second = l.update(desired: ["/p/a.go": [0]])
        #expect(second == [BreakpointRequest(path: "/p/a.go", lines: [1]), BreakpointRequest(path: "/p/b.go", lines: [])])
        #expect(l.update(desired: ["/p/a.go": []]) == [BreakpointRequest(path: "/p/a.go", lines: [])])
    }

    @Test func autoContinuesAtRemovedBreakpointByID() {
        var l = BreakpointLedger()
        let reqs = l.update(desired: ["/p/main.go": [19, 30]])
        l.record(reqs[0], acks: [BreakpointAck(id: 1, line: 20, verified: true), BreakpointAck(id: 2, line: 31, verified: true)])
        #expect(!l.shouldAutoContinue(reason: "breakpoint", hitBreakpointIDs: [1], path: "/p/main.go", line: 20))
        _ = l.update(desired: ["/p/main.go": [30]])   // user removed line 20 (0-based 19)
        #expect(l.shouldAutoContinue(reason: "breakpoint", hitBreakpointIDs: [1], path: "/p/main.go", line: 20))
        #expect(!l.shouldAutoContinue(reason: "breakpoint", hitBreakpointIDs: [2], path: "/p/main.go", line: 31))
        #expect(!l.shouldAutoContinue(reason: "step", hitBreakpointIDs: [1], path: "/p/main.go", line: 20), "only breakpoint stops")
    }

    @Test func locationFallbackHandlesMovedBreakpoints() {
        var l = BreakpointLedger()
        // The user put a breakpoint on a blank line 12 (0-based 11); delve moved it to line 13.
        let reqs = l.update(desired: ["/p/main.go": [11]])
        l.record(reqs[0], acks: [BreakpointAck(id: nil, line: 13, verified: true)])
        #expect(!l.shouldAutoContinue(reason: "breakpoint", hitBreakpointIDs: [], path: "/p/main.go", line: 13),
                "a moved breakpoint the user still has must pause")
        _ = l.update(desired: [:])
        #expect(l.shouldAutoContinue(reason: "breakpoint", hitBreakpointIDs: [], path: "/p/main.go", line: 13))
        #expect(!l.shouldAutoContinue(reason: "breakpoint", hitBreakpointIDs: [], path: "/p/other.go", line: 13),
                "unknown breakpoints pause (when in doubt, stop)")
        #expect(!l.shouldAutoContinue(reason: "breakpoint", hitBreakpointIDs: [99], path: nil, line: 1))
    }
}

@Suite struct DAPParsingTests {
    @Test func parsesDelveListenLine() {
        let a = DelveListenAddress.parse("DAP server listening at: 127.0.0.1:54321\n")
        #expect(a?.host == "127.0.0.1")
        #expect(a?.port == 54321)
        #expect(DelveListenAddress.parse("DAP server listening at: [::1]:4000")?.host == "::1")
        #expect(DelveListenAddress.parse("starting…") == nil)
        #expect(DelveListenAddress.parse("DAP server listening at: 127.0.0.1:") == nil)
    }

    @Test func launchArgumentsPerTarget() {
        let main = DAPLaunch.arguments(target: .main, directory: "/p/cmd", title: "go run cmd")
        #expect(main["mode"] == "debug")
        #expect(main["program"] == "/p/cmd")
        #expect(main["args"] == nil)
        let test = DAPLaunch.arguments(target: .test(name: "TestAdd"), directory: "/p", title: "test TestAdd")
        #expect(test["mode"] == "test")
        #expect(test["args"] == ["-test.run", "^TestAdd$"])
        #expect(DAPLaunch.arguments(target: .test(name: nil), directory: "/p", title: "t")["args"] == nil)
        let bench = DAPLaunch.arguments(target: .bench(name: "BenchmarkX"), directory: "/p", title: "b")
        #expect(bench["args"] == ["-test.run", "^$", "-test.bench", "^BenchmarkX$"])
    }

    @Test func decodesFramesVariablesAndScopes() {
        let frame = DAPStackFrame(json: ["id": 7, "name": "main.main", "line": 20, "column": 2, "source": ["path": "/p/main.go"]])
        #expect(frame?.line0 == 19)
        #expect(frame?.path == "/p/main.go")
        #expect(DAPStackFrame(json: ["id": 8, "name": "runtime.goexit", "line": 0, "source": ["path": ""]])?.path == nil)
        let v = DAPVariable(json: ["name": "p", "value": "main.Point {X: 1}", "type": "main.Point", "variablesReference": 3])
        #expect(v?.variablesReference == 3)
        #expect(DAPScope(json: ["name": "Locals", "variablesReference": 1000])?.expensive == false)
        let stop = DAPStop(reason: "step", description: nil, threadID: 1, frames: [
            DAPStackFrame(id: 1, name: "asm", path: nil, line: 0, column: 0),
            DAPStackFrame(id: 2, name: "main.f", path: "/p/f.go", line: 3, column: 1),
        ])
        #expect(stop.topFrameWithSource?.id == 2)
    }
}
