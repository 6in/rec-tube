import Testing

@testable import RecCore

/// T1 の目的は「Swift Testing が走る土台ができたこと」の確認。
/// 本番の契約（ExitCode / DelayLine / SessionPolicy …）のテストは T3 以降が足す。
///
/// T3 で `RecError` が `description` から `code` + `message` に変わったので、期待値を合わせた。
@Test func recErrorKeepsItsCodeAndMessage() {
    let error = RecError(code: .outputUnavailable, message: "boom")
    #expect(error.code == .outputUnavailable)
    #expect(error.message == "boom")
}
