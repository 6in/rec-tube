import Darwin
import Testing

@testable import RecCore

/// PLAN「決めた事項」#3 の仕様表（終了コードと停止理由）をそのまま検証する。
/// 期待値は実装ではなく仕様表から書いている。食い違ったら実装のバグ。

// MARK: - ExitCode の rawValue

/// 仕様表の code 列と `ExitCode.rawValue` が一致すること。
@Test(
    "ExitCode rawValue matches the spec table",
    arguments: [
        (ExitCode.ok, Int32(0)),
        (ExitCode.usage, Int32(1)),
        (ExitCode.chromeUnavailable, Int32(2)),
        (ExitCode.liveStream, Int32(3)),
        (ExitCode.silent, Int32(4)),
        (ExitCode.interrupted, Int32(5)),
        (ExitCode.pageLost, Int32(6)),
        (ExitCode.outputUnavailable, Int32(7)),
        (ExitCode.coreAudio, Int32(8)),
        (ExitCode.signalHUP, Int32(129)),
        (ExitCode.signalINT, Int32(130)),
        (ExitCode.signalTERM, Int32(143)),
    ]
)
func exitCodeRawValue(code: ExitCode, expected: Int32) {
    #expect(code.rawValue == expected)
}

/// 仕様表は 12 行なので `allCases` も 12 個であること（増減の検知）。
@Test("ExitCode.allCases has exactly the 12 rows of the spec table")
func exitCodeCaseCount() {
    #expect(ExitCode.allCases.count == 12)
}

// MARK: - StopReason から ExitCode への写像

/// 仕様表の `StopReason` 列（`.signal` 以外の 14 case）が対応する `ExitCode` を返すこと。
@Test(
    "StopReason maps to the exit code in the spec table",
    arguments: [
        // 0 / .ok
        (StopReason.ended, ExitCode.ok),
        (StopReason.nextVideo, ExitCode.ok),
        // 3 / .liveStream
        (StopReason.liveStream, ExitCode.liveStream),
        // 4 / .silent
        (StopReason.permissionSuspected, ExitCode.silent),
        // 5 / .interrupted
        (StopReason.deviceChanged, ExitCode.interrupted),
        (StopReason.sleep, ExitCode.interrupted),
        (StopReason.serviceRestarted, ExitCode.interrupted),
        (StopReason.ioStopped, ExitCode.interrupted),
        (StopReason.deviceDied, ExitCode.interrupted),
        (StopReason.tapStalled, ExitCode.interrupted),
        // 6 / .pageLost
        (StopReason.tabClosed, ExitCode.pageLost),
        (StopReason.pageUnavailable, ExitCode.pageLost),
        (StopReason.pageUnresponsive, ExitCode.pageLost),
        // 7 / .outputUnavailable
        (StopReason.writeFailed, ExitCode.outputUnavailable),
    ]
)
func stopReasonExitCode(reason: StopReason, expected: ExitCode) {
    #expect(reason.exitCode == expected)
}

/// `.signal(sig)` は仕様表どおり 128 + sig の `ExitCode` を返すこと（HUP / INT / TERM）。
@Test(
    "StopReason.signal maps to 128 + signal number",
    arguments: [
        (SIGHUP, ExitCode.signalHUP),
        (SIGINT, ExitCode.signalINT),
        (SIGTERM, ExitCode.signalTERM),
    ]
)
func stopReasonSignalExitCode(signal: Int32, expected: ExitCode) {
    let reason = StopReason.signal(signal)
    #expect(reason.exitCode == expected)
    #expect(reason.exitCode.rawValue == 128 + signal)
}
