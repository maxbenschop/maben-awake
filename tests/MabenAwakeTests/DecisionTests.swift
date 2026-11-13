import XCTest
@testable import MabenAwake

final class PresenceTests: XCTestCase {
    func testLidClosedWithoutDisplayIsAway() {
        let p = Decision.presence(lidClosed: true, externalDisplay: false, screenLocked: false, freezeWhileLocked: false)
        XCTAssertTrue(p.lidAway)
        XCTAssertTrue(p.away)
    }

    func testClamshellWithExternalDisplayIsNotAway() {
        let p = Decision.presence(lidClosed: true, externalDisplay: true, screenLocked: false, freezeWhileLocked: true)
        XCTAssertFalse(p.away)
    }

    func testLockedScreenCountsOnlyWhenAsked() {
        XCTAssertFalse(Decision.presence(lidClosed: false, externalDisplay: false, screenLocked: true, freezeWhileLocked: false).away)
        let p = Decision.presence(lidClosed: false, externalDisplay: false, screenLocked: true, freezeWhileLocked: true)
        XCTAssertTrue(p.away)
        XCTAssertTrue(p.lockedAway)
        XCTAssertFalse(p.lidAway, "a locked screen is not a closed lid: no dimming, no lock on open")
    }
}

final class HeatTests: XCTestCase {
    func testSeriousHeatWhileAwayStopsKeepingAwake() {
        XCTAssertTrue(Decision.overheated(current: false, heatApplies: true, serious: true))
    }

    func testCoolingDownWhileStillAwayKeepsTheCutoff() {
        XCTAssertTrue(Decision.overheated(current: true, heatApplies: true, serious: false))
    }

    func testComingBackClearsTheCutoff() {
        XCTAssertFalse(Decision.overheated(current: true, heatApplies: false, serious: true))
    }
}

final class PowerTests: XCTestCase {
    private func input(manual: Bool = false, requests: Bool = true, overheated: Bool = false, lidMode: Bool = true,
                       helper: Bool = true, lowBattery: Bool = false, lidAway: Bool = false, unlocked: Bool = true) -> Decision.PowerInput {
        .init(manual: manual, hasRequests: requests, overheated: overheated, lidClosedMode: lidMode,
              lidHelperInstalled: helper, lowBattery: lowBattery, batteryCutoff: 20, lidAway: lidAway,
              keepUnlockedWhenClosed: unlocked)
    }

    func testNothingAskedMeansSleep() {
        let p = Decision.power(input(requests: false))
        XCTAssertFalse(p.keepAwake)
        XCTAssertFalse(p.blockLidSleep)
        XCTAssertEqual(p.lidLine, "closed-lid sleep: allowed (not keeping awake)")
    }

    func testRequestKeepsAwakeAndBlocksLidSleep() {
        let p = Decision.power(input())
        XCTAssertTrue(p.keepAwake)
        XCTAssertTrue(p.blockLidSleep)
        XCTAssertEqual(p.lidLine, "closed-lid sleep: blocked")
    }

    func testManualKeepsAwakeWithoutRequests() {
        XCTAssertTrue(Decision.power(input(manual: true, requests: false)).keepAwake)
    }

    func testHeatWins() {
        let p = Decision.power(input(manual: true, overheated: true))
        XCTAssertFalse(p.keepAwake)
        XCTAssertFalse(p.blockLidSleep)
    }

    func testLowBatteryAllowsLidSleepButStaysAwake() {
        let p = Decision.power(input(lowBattery: true))
        XCTAssertTrue(p.keepAwake)
        XCTAssertFalse(p.blockLidSleep)
        XCTAssertEqual(p.lidLine, "closed-lid sleep: allowed (battery below 20%)")
    }

    func testLidReasons() {
        XCTAssertEqual(Decision.power(input(lidMode: false)).lidLine, "closed-lid sleep: allowed (lid-closed mode is off)")
        XCTAssertEqual(Decision.power(input(helper: false)).lidLine, "closed-lid sleep: allowed (lid helper not installed)")
    }

    func testScreenKeptOnOnlyWithTheLidClosed() {
        XCTAssertFalse(Decision.power(input(lidAway: false)).keepScreenOn, "never with the lid open")
        XCTAssertTrue(Decision.power(input(lidAway: true)).keepScreenOn)
        XCTAssertFalse(Decision.power(input(lidAway: true, unlocked: false)).keepScreenOn)
        XCTAssertFalse(Decision.power(input(requests: false, lidAway: true)).keepScreenOn)
    }
}

final class FreezeTests: XCTestCase {
    private func app(_ mode: AppMode, pid: pid_t = 100, requested: Bool = false, dev: Bool = false, starting: Bool = false) -> Decision.App {
        .init(pid: pid, mode: mode, requested: requested, isDevBuild: dev, starting: starting)
    }

    private func input(freezing: Bool = true, working: Bool = false, present: Bool = false, frontmost: pid_t? = nil,
                       resumed: Set<pid_t> = [], keep: Set<pid_t> = []) -> Decision.FreezeInput {
        .init(freezing: freezing, aiWorking: working, userPresent: present, frontmost: frontmost,
              userResumed: resumed, keepAwake: keep)
    }

    func testNothingFreezesWhenNotFreezing() {
        XCTAssertFalse(Decision.shouldFreeze(app(.onDemand), input(freezing: false)))
    }

    func testAlwaysOnNeverFreezes() {
        XCTAssertFalse(Decision.shouldFreeze(app(.always), input()))
    }

    func testOnDemandFreezesUntilRequested() {
        XCTAssertTrue(Decision.shouldFreeze(app(.onDemand), input()))
        XCTAssertTrue(Decision.shouldFreeze(app(.onDemand), input(working: true)), "an AI working isn't a request")
        XCTAssertFalse(Decision.shouldFreeze(app(.onDemand, requested: true), input()))
    }

    func testWhileAIFollowsTheAI() {
        XCTAssertTrue(Decision.shouldFreeze(app(.whileAI), input()))
        XCTAssertFalse(Decision.shouldFreeze(app(.whileAI), input(working: true)))
        XCTAssertFalse(Decision.shouldFreeze(app(.whileAI, requested: true), input()))
    }

    func testDevBuildStaysAwakeOnlyWhileAnAIWorks() {
        XCTAssertFalse(Decision.shouldFreeze(app(.onDemand, dev: true), input(working: true)))
        XCTAssertTrue(Decision.shouldFreeze(app(.onDemand, dev: true), input(working: false)))
    }

    func testStartingAppsAreLeftAlone() {
        XCTAssertFalse(Decision.shouldFreeze(app(.onDemand, starting: true), input()))
    }

    func testAIHostsAndCleanupAreKeptAwake() {
        XCTAssertFalse(Decision.shouldFreeze(app(.onDemand, pid: 7), input(keep: [7])))
    }

    func testTheAppTheUserIsUsing() {
        XCTAssertFalse(Decision.shouldFreeze(app(.onDemand, pid: 5), input(present: true, frontmost: 5)))
        XCTAssertFalse(Decision.shouldFreeze(app(.onDemand, pid: 5), input(present: true, resumed: [5])))
        XCTAssertTrue(Decision.shouldFreeze(app(.onDemand, pid: 5), input(present: false, frontmost: 5)),
                      "frontmost only protects an app while someone is at the Mac")
    }
}

final class ProcessTableTests: XCTestCase {
    /// app 100 → child 101 → grandchild 102; XPC service 200 (launchd's child,
    /// responsible 100) → its child 201; another app 300 that 100 launched;
    /// an agent 400 started from 101 with a child 401; an unrelated process 500.
    private let table = ProcessTable(entries: [
        100: .init(parent: 1, responsible: 100),
        101: .init(parent: 100, responsible: 100),
        102: .init(parent: 101, responsible: 100),
        200: .init(parent: 1, responsible: 100),
        201: .init(parent: 200, responsible: 100),
        300: .init(parent: 100, responsible: 100),
        400: .init(parent: 101, responsible: 100),
        401: .init(parent: 400, responsible: 100),
        500: .init(parent: 1, responsible: 500),
    ])

    func testChildrenAndResponsibleHelpers() {
        XCTAssertEqual(table.helpers(of: 100, excluding: []), [101, 102, 200, 201, 300, 400, 401])
    }

    func testOtherAppsAndAgentsAreSkippedWithWhatTheyStarted() {
        XCTAssertEqual(table.helpers(of: 100, excluding: [300, 400]), [101, 102, 200, 201])
    }

    func testAnAppWithoutHelpers() {
        XCTAssertEqual(table.helpers(of: 500, excluding: []), [])
    }

    func testNeverLaunchdOrTheAppItself() {
        let odd = ProcessTable(entries: [
            1: .init(parent: 0, responsible: 9),
            9: .init(parent: 1, responsible: 9),
            10: .init(parent: 9, responsible: 9),
        ])
        XCTAssertEqual(odd.helpers(of: 9, excluding: []), [10])
    }

    func testTheRealTableFindsOurOwnChild() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }
        let me = getpid()
        XCTAssertTrue(ProcessTable.current().helpers(of: me, excluding: []).contains(child.processIdentifier))
    }
}

final class CrashLoopTests: XCTestCase {
    func testAFewStartsAreFine() {
        let (starts, looping) = CrashLoop.record(start: 1000, after: [900, 950])
        XCTAssertEqual(starts, [900, 950, 1000])
        XCTAssertFalse(looping)
    }

    func testFourStartsInThreeMinutesIsALoop() {
        XCTAssertTrue(CrashLoop.record(start: 1000, after: [900, 950, 990]).looping)
    }

    func testOldStartsDontCount() {
        let (starts, looping) = CrashLoop.record(start: 1000, after: [500, 600, 700, 990])
        XCTAssertEqual(starts, [990, 1000])
        XCTAssertFalse(looping)
    }

    func testStartsFromTheFutureDontCount() {
        // A clock set back must not leave starts that never expire.
        XCTAssertEqual(CrashLoop.record(start: 1000, after: [5000, 5001, 5002]).starts, [1000])
    }
}

final class AwayTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testSummaryAddsUpTimeKeptAwakeAndSkipsSleep() throws {
        var tracker = AwayTracker(start: t0, battery: 86)
        var t = t0
        for _ in 0..<200 {   // 10 minutes of checks every 3 s, an agent working
            t += 3
            tracker.record(at: t, keepingAwake: true, agents: ["Claude Code"], otherRequests: false, frozen: 3, stoppedBecause: nil)
        }
        t += 3600   // the Mac slept for an hour
        tracker.record(at: t, keepingAwake: true, agents: ["Claude Code", "Codex"], otherRequests: true, frozen: 5, stoppedBecause: nil)
        let summary = try XCTUnwrap(tracker.finish(at: t, battery: 61))
        XCTAssertEqual(summary.keptAwake, 600, accuracy: 0.1)
        XCTAssertEqual(summary.agents, ["Claude Code", "Codex"])
        XCTAssertEqual(summary.mostFrozen, 5)
        XCTAssertEqual(summary.text, "Away 1 h 10 m · kept awake 10 m · Claude Code and Codex worked · 5 apps frozen · battery 86% → 61%")
    }

    func testShortOrIdleAbsencesAreNotWorthShowing() {
        var tracker = AwayTracker(start: t0, battery: nil)
        tracker.record(at: t0 + 3, keepingAwake: true, agents: [], otherRequests: false, frozen: 0, stoppedBecause: nil)
        XCTAssertNil(tracker.finish(at: t0 + 60, battery: nil), "under two minutes")
        let idle = AwayTracker(start: t0, battery: nil)
        XCTAssertNil(idle.finish(at: t0 + 3600, battery: nil), "never kept awake")
    }

    func testAStopIsAlwaysReported() throws {
        var tracker = AwayTracker(start: t0, battery: 22)
        tracker.record(at: t0 + 3, keepingAwake: true, agents: [], otherRequests: true, frozen: 0, stoppedBecause: "the battery fell below 20%")
        tracker.record(at: t0 + 6, keepingAwake: true, agents: [], otherRequests: false, frozen: 0, stoppedBecause: "it got too hot")
        let summary = try XCTUnwrap(tracker.finish(at: t0 + 600, battery: 19))
        XCTAssertEqual(summary.stoppedBecause, "the battery fell below 20%", "the first reason counts")
        XCTAssertEqual(summary.text, "Away 10 m · a script ran · battery 22% → 19%")
    }

    func testThreeAgents() {
        let s = AwaySummary(duration: 300, keptAwake: 0, agents: ["A", "B", "C"], otherRequests: false,
                            mostFrozen: 1, batteryStart: nil, batteryEnd: nil, stoppedBecause: nil)
        XCTAssertEqual(s.text, "Away 5 m · A, B and C worked · 1 app frozen")
    }
}

final class LeaseTests: XCTestCase {
    func testWhatCountsAsWork() {
        func lease(_ name: String, app: String? = nil) -> Lease { Lease(name: name, expires: .distantFuture, app: app, owner: 0) }
        XCTAssertTrue(lease("claude-3f2a").isWork)
        XCTAssertTrue(lease("tests").isWork, "awake run")
        XCTAssertFalse(lease("claude-3f2a-bg").isWork)
        XCTAssertFalse(lease("claude-3f2a-wakeup").isWork)
        XCTAssertFalse(lease("need-Dia-1", app: "Dia").isWork)
    }
}
