// Console.swift — 人向けの 1 行を出す口。**これが唯一の stderr の出口**（PLAN F2）。
//
// なぜ `FileHandle.standardError` の `write(_:)` を使わないか:
//   - fd 2 が閉じている（`2>&-`）とき `FileHandle` の `write(_:)` は NSException を投げ、
//     Swift からは捕まえられないので **SIGABRT でプロセスが死ぬ**（E13）
//   - パイプの読み手が先に閉じると EPIPE で同じことが起きる（E14。SIGPIPE 自体は
//     `Sources/rec/main.swift` と `Sources/rec-probe/main.swift` の先頭で無視する）
//
// 断言（この関数の契約）:
//   - `line + "\n"` を UTF-8 で fd 2 に `write(2)` のループで書く
//   - `EINTR` は再試行する
//   - それ以外の失敗（EPIPE / EBADF / EAGAIN など）は**黙って捨てる**（throw も crash もしない）
//   - `write(2)` が 0 を返したらループを抜ける（無限ループにしない）
//
// 追従先: 人向けの行を増やすときはここを通す（`rg -n 'standardError\.write' Sources` が 0 行であること）。

import Darwin

/// 人向けの 1 行を stderr（fd 2）に改行付きで書く。**失敗しても何も起きない**。
public func writeStderr(_ line: String) {
    let bytes = Array((line + "\n").utf8)
    bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let written = write(2, base + offset, buffer.count - offset)
            if written > 0 {
                offset += written
                continue
            }
            // 0 = これ以上進まない（無限ループを避けて諦める）。
            if written == 0 { return }
            // シグナルで割り込まれただけなら書き直す。
            if errno == EINTR { continue }
            // EPIPE / EBADF / EAGAIN など: 人向けの行は落としてよい（プロセスは殺さない）。
            return
        }
    }
}
