// FakeRunner — テスト用の `ScriptRunner`。`osascript` を起動せず、呼び出しを記録して用意した結果を返す。
//
// 方針: 観測しやすさを優先して状態は `var` で素直に公開する。テストは単一スレッドから触る前提
// （`FakeWriter` / `FakeHAL` と同じ）。

import Foundation

@testable import RecCore

final class FakeRunner: ScriptRunner, @unchecked Sendable {
    /// `run` 1 回分の引数。
    struct Call: Equatable {
        let script: String
        let arguments: [String]
    }

    /// これまでの呼び出し（古い順）。
    var calls: [Call] = []

    /// 先頭から 1 つずつ取り出して返す結果。空になったら `defaultResult` を返す。
    var results: [Result<ScriptResult, Error>] = []

    /// `results` が空のときに返す結果。
    var defaultResult = ScriptResult(status: 0, stdout: "", stderr: "")

    /// 非 nil なら `results` より優先し、呼び出しごとに結果を決める。
    var handler: ((Call) throws -> ScriptResult)?

    init() {}

    /// 成功（status 0）の stdout を 1 件積む。
    func enqueue(stdout: String) {
        results.append(.success(ScriptResult(status: 0, stdout: stdout, stderr: "")))
    }

    /// 失敗（非 0）の stderr を 1 件積む。
    func enqueue(status: Int32, stderr: String) {
        results.append(.success(ScriptResult(status: status, stdout: "", stderr: stderr)))
    }

    /// 結果を 1 件積む。
    func enqueue(_ result: ScriptResult) {
        results.append(.success(result))
    }

    /// `run` が throw するエラーを 1 件積む（プロセス起動失敗の再現）。
    func enqueue(error: Error) {
        results.append(.failure(error))
    }

    func run(script: String, arguments: [String]) throws -> ScriptResult {
        let call = Call(script: script, arguments: arguments)
        calls.append(call)
        if let handler {
            return try handler(call)
        }
        guard !results.isEmpty else { return defaultResult }
        return try results.removeFirst().get()
    }
}
