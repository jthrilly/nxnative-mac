// ProgressFormat against the NSP script's hms, amount and Progress._count (the expected strings are what the Python functions print for the same inputs)
import Foundation
import Testing
@testable import ConverterCore

struct ProgressFormatTests {
    @Test func duration() {
        let cases: [(Double, String)] = [(0, "0:00"), (7, "0:07"), (59.9, "0:59"), (60, "1:00"), (725, "12:05"), (3599, "59:59"), (3600, "1:00:00"), (3723, "1:02:03"),
                                         (36061, "10:01:01"), (-5, "0:00"), (.nan, "0:00")]
        for (s, want) in cases { #expect(ProgressFormat.duration(s) == want, "\(s)") }
    }

    @Test func bytes() {
        let cases: [(Double, String)] = [(0, "0.0 KB"), (1023, "1.0 KB"), (3072, "3.0 KB"), (536_870_912, "512.0 MB"), (1_073_741_823, "1024.0 MB"),
                                         (2_040_109_465.6, "1.9 GB"), (1_073_741_824, "1.0 GB"), (5_497_558_138_880, "5120.0 GB")]
        for (v, want) in cases { #expect(ProgressFormat.bytes(v) == want, "\(v)") }
    }

    @Test func count() {
        func s(_ done: Double?, _ total: Double? = nil, _ unit: String = "", est: Bool = false) -> ProgressSample {
            ProgressSample(k: 1, name: "", step: "", done: done, total: total, unit: unit, estimated: est)
        }
        let cases: [(ProgressSample, String)] = [
            (s(nil), ""), (s(2301, nil, "files"), "2,301 files"), (s(2301), "2,301"), (s(1203, 19592, "shaders"), "1,203/19,592 shaders"),
            (s(1203, 19592, "shaders", est: true), "1,203/~19,592 shaders"), (s(2_040_109_465, 4_831_838_208, "B", est: true), "1.9/~4.5 GB"),
            (s(524_288_000, 2_147_483_648, "B"), "0.5/2.0 GB"), (s(3, 0, "DLC"), "3 DLC"), (s(0, 10, "files", est: true), "0/~10 files"),
            (s(5_242_880, nil, "B"), "5.0 MB"), (s(12, 40), "12/40"), (s(1_234_567), "1,234,567"),
        ]
        for (sample, want) in cases { #expect(ProgressFormat.count(sample) == want) }
    }

    @Test func percent() {
        #expect(ProgressFormat.percent(0.42) == "42%")
        #expect(ProgressFormat.percent(0) == "0%")
        #expect(ProgressFormat.percent(0.99) == "99%")
        #expect(ProgressFormat.percent(1) == "100%")
    }

    @Test func grouped() {
        #expect(ProgressFormat.grouped(999) == "999")
        #expect(ProgressFormat.grouped(1000) == "1,000")
        #expect(ProgressFormat.grouped(1234.5) == "1,234.5")
        #expect(ProgressFormat.grouped(-1234) == "-1,234")
    }
}
