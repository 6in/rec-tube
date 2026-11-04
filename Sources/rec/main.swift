// rec — 入口。引数を読んでモードを選ぶだけ。
//
// このファイルは T9 で `RecCore.CLI` + `RecordingSession` に置き換える。
// 現状は移動元（`git show main:rec.swift` のトップレベル部分）をそのまま写したもので、
// 終了コードは 0 / 1 の 2 種類しかない（PLAN「決めた事項」#3 の表は T3 以降で実装する）。

import Foundation
import RecCore

var app: String?
var url: String?
var outPath: String?
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--app": app = it.next()
    case "--url": url = it.next()
    case "-o": outPath = it.next()
    case "--list":
        do {
            for p in try audioProcesses() where !p.bundle.isEmpty {
                print("\(p.running ? "▶" : " ") \(p.bundle)")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown arg: \(a)\n".utf8))
        exit(1)
    }
}

let path: String = outPath ?? {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return "rec-\(f.string(from: Date())).m4a"
}()

do {
    if let url {
        try recordURL(url, path: path)
    } else if let app {
        let targets = try audioProcesses().filter { $0.bundle.hasPrefix(app) }.map(\.id)
        guard !targets.isEmpty else {
            throw RecError(code: .usage,
                           message: "'\(app)' に一致する音声プロセスがありません。再生後に --list で確認してください。")
        }
        try recordLive(targets: targets, path: path)
    } else {
        try recordLive(targets: nil, path: path)
    }
} catch let e as RecError {
    // T3 で `RecError` が終了コードを持つようになったので、ここでそのまま使う（配線の一本化は T9）。
    FileHandle.standardError.write(Data("error: \(e.message)\n".utf8))
    exit(e.code.rawValue)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(ExitCode.coreAudio.rawValue)
}
