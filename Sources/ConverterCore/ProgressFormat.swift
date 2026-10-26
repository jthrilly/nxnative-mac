// Text like the NSP script's console (scripts/build_ipa_from_nsp.py hms, amount and Progress._count), with "," grouping whatever the user's locale
import Foundation

public enum ProgressFormat {
    public static func duration(_ seconds: Double) -> String {
        let s = seconds.isFinite && seconds > 0 ? Int(min(seconds, 1e12)) : 0
        let h = s / 3600, m = s / 60 % 60
        return h > 0 ? "\(h):\(pad(m)):\(pad(s % 60))" : "\(m):\(pad(s % 60))"
    }

    public static func bytes(_ value: Double) -> String {
        let (unit, divisor) = sizeUnit(value)
        return String(format: "%.1f", value / divisor) + " " + unit
    }

    public static func count(_ sample: ProgressSample) -> String {
        guard let done = sample.done else { return "" }
        guard let total = sample.total, total != 0 else {
            return sample.unit == "B" ? bytes(done) : grouped(done) + (sample.unit.isEmpty ? "" : " " + sample.unit)
        }
        let t = sample.estimated ? "~" : ""
        if sample.unit == "B" {
            let (unit, divisor) = sizeUnit(total)
            return String(format: "%.1f", done / divisor) + "/" + t + String(format: "%.1f", total / divisor) + " " + unit
        }
        return grouped(done) + "/" + t + grouped(total) + (sample.unit.isEmpty ? "" : " " + sample.unit)
    }

    public static func percent(_ fraction: Double) -> String { String(format: "%.0f%%", fraction * 100) }

    private static func pad(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }

    private static func sizeUnit(_ v: Double) -> (String, Double) {
        v >= 1_073_741_824 ? ("GB", 1_073_741_824) : v >= 1_048_576 ? ("MB", 1_048_576) : ("KB", 1024)
    }

    // Python's f'{v:,}': an integer count with "," every three digits; a fractional one keeps its fraction
    static func grouped(_ v: Double) -> String {
        guard v.isFinite, v.magnitude < 9e15 else { return "\(v)" }
        let whole = v.rounded(.towardZero)
        var digits = String(Int64(whole).magnitude)
        var out = ""
        while digits.count > 3 { out = "," + digits.suffix(3) + out; digits.removeLast(3) }
        out = (v < 0 ? "-" : "") + digits + out
        if whole == v { return out }
        let frac = "\(v.magnitude)"
        return frac.firstIndex(of: ".").map { out + frac[$0...] } ?? out
    }
}
