// TapTarget / makeTapDescription のユニットテスト。
// Core Audio には触らない（`CATapDescription` を組んでプロパティを読むだけ）。

import CoreAudio
import Testing

@testable import RecCore

@Suite("makeTapDescription")
struct TapTargetTests {
    /// 3 variant に共通する設定（PLAN T2 の完了基準）。
    @Test("共通: name / isPrivate / muteBehavior", arguments: [
        TapTarget.system,
        TapTarget.processes([11, 22]),
        TapTarget.bundleIDs(["com.google.Chrome"], seed: [33]),
    ])
    func commonProperties(target: TapTarget) {
        let desc = makeTapDescription(target)
        #expect(desc.name == "rec-tap")
        #expect(desc.isPrivate)
        #expect(desc.muteBehavior == .unmuted)
    }

    /// uuid は毎回新規（aggregate の `kAudioSubTapUIDKey` と 1 対 1 に対応させるため）。
    @Test("uuid は呼ぶたびに別")
    func uuidIsFresh() {
        let a = makeTapDescription(.system)
        let b = makeTapDescription(.system)
        #expect(a.uuid != b.uuid)
    }

    @Test("system: 除外なしのグローバル tap、プロセス指定なし")
    func systemVariant() {
        let desc = makeTapDescription(.system)
        #expect(desc.processes.isEmpty)
        #expect(desc.bundleIDs.isEmpty)
    }

    @Test("processes: 渡した順に processes へ入り、restore が有効")
    func processesVariant() {
        let desc = makeTapDescription(.processes([11, 22, 33]))
        #expect(desc.processes == [11, 22, 33])
        #expect(desc.bundleIDs.isEmpty)
        #expect(desc.isProcessRestoreEnabled)
    }

    @Test("bundleIDs: bundleIDs と seed の両方が入り、restore が有効")
    func bundleIDsVariant() {
        let desc = makeTapDescription(.bundleIDs(["com.google.Chrome", "com.google.Chrome.helper"],
                                                 seed: [44, 55]))
        #expect(desc.bundleIDs == ["com.google.Chrome", "com.google.Chrome.helper"])
        #expect(desc.processes == [44, 55])
        #expect(desc.isProcessRestoreEnabled)
    }

    @Test("bundleIDs: seed なしなら processes は空")
    func bundleIDsWithoutSeed() {
        let desc = makeTapDescription(.bundleIDs(["com.google.Chrome"], seed: []))
        #expect(desc.bundleIDs == ["com.google.Chrome"])
        #expect(desc.processes.isEmpty)
        #expect(desc.isProcessRestoreEnabled)
    }

    /// 決めた事項 #2 の bundleIDs は T2 (0) の実測（`rec --list` に出るのは
    /// `com.google.Chrome` と `com.google.Chrome.helper` の 2 つだけ）に合わせて絞ってある。
    @Test("Chrome の既定値")
    func chromeDefaults() {
        #expect(Chrome.bundleIDPrefix == "com.google.Chrome")
        #expect(Chrome.bundleIDs == ["com.google.Chrome", "com.google.Chrome.helper"])
        #expect(Chrome.bundleIDs.allSatisfy { $0.hasPrefix(Chrome.bundleIDPrefix) })
    }
}
