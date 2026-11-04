import Testing

@testable import RecCore

/// T1 の目的は「Swift Testing が走る土台ができたこと」の確認。
/// 本番の契約（ExitCode / DelayLine / SessionPolicy …）のテストは T3 以降が足す。
@Test func recErrorKeepsItsDescription() {
    let error = RecError(description: "boom")
    #expect(error.description == "boom")
}
