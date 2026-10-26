/// A verification code found in a message. Holds only the code, never the message body.
public struct ExtractedCode: Sendable, Equatable, Hashable {
    /// The code to insert, e.g. `482913` or `G-123456`.
    public let code: String
    /// Heuristic confidence in 0...1.
    public let confidence: Double

    public init(code: String, confidence: Double) {
        self.code = code
        self.confidence = confidence
    }
}

/// Pure, stateless OTP extractor (ROADMAP F6). No I/O, no logging, no persistence of the input.
public enum OTPParser {
    public static func extract(from message: String) -> ExtractedCode? {
        var scanner = Scanner(message)
        return scanner.run()
    }
}

// MARK: - Implementation

private struct Keyword: Sendable {
    let text: [Unicode.Scalar]
    let strong: Bool
    let ascii: Bool
    init(_ t: String, strong: Bool) {
        text = Array(t.unicodeScalars)
        self.strong = strong
        ascii = t.unicodeScalars.allSatisfy { $0.isASCII }
    }
}

private let keywords: [Keyword] = [
    Keyword("otp", strong: true), Keyword("verification", strong: true), Keyword("verify", strong: true),
    Keyword("passcode", strong: true), Keyword("one time", strong: true), Keyword("one-time", strong: true),
    Keyword("authentication", strong: true), Keyword("ओटीपी", strong: true), Keyword("सत्यापन", strong: true),
    Keyword("code", strong: false), Keyword("pin", strong: false), Keyword("password", strong: false),
    Keyword("login", strong: false), Keyword("log in", strong: false), Keyword("sign in", strong: false),
    Keyword("security", strong: false), Keyword("कोड", strong: false), Keyword("पासवर्ड", strong: false),
    Keyword("पिन", strong: false),
]

private let precedingStopWords: [String] = [
    "rs", "inr", "usd", "eur", "gbp", "aed", "rupees", "rupee", "amount", "amt", "bal", "balance", "avl", "mrp",
    "price", "total", "ref", "reference", "refno", "txn", "txnid", "transaction", "utr", "rrn", "order", "orderid",
    "id", "no", "number", "invoice", "awb", "tracking", "a/c", "ac", "acct", "account", "card", "ending", "call",
    "dial", "helpline", "whatsapp", "contact", "tollfree", "toll free", "phone", "mobile", "mob", "tel",
    "pincode", "pin code", "zipcode", "zip code", "zip", "postal code", "postcode", "promo code", "coupon code",
    "discount code", "referral code", "gift code", "booking", "pnr", "case", "ticket", "request",
]

private let followingStopWords: Set<String> = [
    "rs", "inr", "rupees", "usd", "dollars", "points", "pts", "km", "kg", "min", "mins", "minutes", "minute", "sec",
    "secs", "seconds", "hrs", "hr", "hours", "hour", "days", "day", "am", "pm", "per", "times", "digit", "digits",
    "users", "items", "kb", "mb", "gb",
]

private let months: [String] = [
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
]
private let promoWords: [String] = ["coupon", "promo", "voucher", "discount", "cashback", "% off", "flat "]

private struct Candidate {
    var start: Int
    var end: Int
    var code: String
    var mixed: Bool
    var gPrefix: Bool
}

private struct Match {
    var gap: Int
    var cand: Candidate
    var strong: Bool
    var hasKeyword: Bool
}

private struct Scanner {
    let s: [Unicode.Scalar]
    let low: [Unicode.Scalar]

    init(_ message: String) {
        s = Array(message.unicodeScalars)
        low = s.map { sc in
            let m = sc.properties.lowercaseMapping.unicodeScalars
            return m.count == 1 ? m.first! : sc
        }
    }

    func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }
    func isLetter(_ c: Unicode.Scalar) -> Bool { (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122) }
    func isAlnum(_ c: Unicode.Scalar) -> Bool { isDigit(c) || isLetter(c) }
    func isUpper(_ c: Unicode.Scalar) -> Bool { c.value >= 65 && c.value <= 90 }
    func str(_ a: ArraySlice<Unicode.Scalar>) -> String {
        var r = String.UnicodeScalarView()
        r.append(contentsOf: a)
        return String(r)
    }

    mutating func run() -> ExtractedCode? {
        guard !s.isEmpty else { return nil }
        let kws = findKeywords()
        let cands = findCandidates()
        var best: Match?
        for c in cands {
            guard accept(c) else { continue }
            var gap = Int.max
            var strong = false
            for k in kws {
                let g: Int
                if k.end <= c.start { g = c.start - k.end } else if k.start >= c.end { g = k.start - c.end } else { g = 0 }
                if g < gap { gap = g; strong = k.strong }
            }
            var hasKeyword = true
            if gap == Int.max {
                guard c.gPrefix else { continue }
                gap = 1000
                hasKeyword = false
            } else {
                let limit = strong ? 70 : 45
                if gap > limit || (c.mixed && gap > 30) { continue }
            }
            if best == nil || gap < best!.gap {
                best = Match(gap: gap, cand: c, strong: strong, hasKeyword: hasKeyword)
            }
        }
        guard let b = best else { return nil }
        if b.hasKeyword && !b.strong && !kws.contains(where: { $0.strong }) {
            let text = str(low[...])
            if promoWords.contains(where: { text.contains($0) }) { return nil }
        }
        let conf: Double
        if !b.hasKeyword { conf = 0.6 }
        else if b.strong && b.gap <= 40 { conf = 0.95 }
        else if b.gap <= 25 { conf = 0.85 }
        else { conf = 0.7 }
        return ExtractedCode(code: b.cand.code, confidence: conf)
    }

    func findKeywords() -> [(start: Int, end: Int, strong: Bool)] {
        var out: [(start: Int, end: Int, strong: Bool)] = []
        for k in keywords {
            let n = k.text.count
            guard low.count >= n else { continue }
            var i = 0
            while i + n <= low.count {
                if Array(low[i..<(i + n)]) == k.text {
                    var ok = true
                    if k.ascii {
                        if i > 0 && isLetter(low[i - 1]) { ok = false }
                        if i + n < low.count && isLetter(low[i + n]) {
                            // allow plural "otps"/"codes"
                            let plural = low[i + n] == "s" && !(i + n + 1 < low.count && isLetter(low[i + n + 1]))
                            if !plural { ok = false }
                        }
                    }
                    if ok { out.append((i, i + n, k.strong)) }
                    i += n
                } else { i += 1 }
            }
        }
        return out
    }

    func findCandidates() -> [Candidate] {
        var toks: [(Int, Int)] = []
        var i = 0
        while i < s.count {
            if isAlnum(s[i]) {
                var j = i
                while j < s.count && isAlnum(s[j]) { j += 1 }
                toks.append((i, j)); i = j
            } else { i += 1 }
        }
        var out: [Candidate] = []
        var k = 0
        while k < toks.count {
            let (a, b) = toks[k]
            let len = b - a
            let slice = s[a..<b]
            if slice.allSatisfy(isDigit) {
                // spaced pair: 123 456 / 1234-5678
                if (len == 3 || len == 4), k + 1 < toks.count, toks[k + 1].0 == b + 1,
                   s[b] == " " || s[b] == "-", toks[k + 1].1 - toks[k + 1].0 == len,
                   s[toks[k + 1].0..<toks[k + 1].1].allSatisfy(isDigit) {
                    let e = toks[k + 1].1
                    let more = e + 1 < s.count && (s[e] == " " || s[e] == "-") && isDigit(s[e + 1])
                    if !more {
                        out.append(Candidate(start: a, end: e, code: str(s[a..<b]) + str(s[toks[k + 1].0..<e]), mixed: false, gPrefix: false))
                        k += 2; continue
                    }
                }
                if (4...8).contains(len) {
                    var c = Candidate(start: a, end: b, code: str(slice), mixed: false, gPrefix: false)
                    if a >= 2, s[a - 1] == "-", s[a - 2] == "G", (a < 3 || !isAlnum(s[a - 3])) {
                        c.start = a - 2; c.code = "G-" + c.code; c.gPrefix = true
                    }
                    out.append(c)
                }
            } else if (5...8).contains(len), slice.allSatisfy(isAlnum), slice.contains(where: isDigit),
                      slice.contains(where: isLetter), slice.allSatisfy({ !isLetter($0) || isUpper($0) }) {
                var runs = 1
                var prevIsDigit = isDigit(s[a])
                for c in slice.dropFirst() where isDigit(c) != prevIsDigit { runs += 1; prevIsDigit = isDigit(c) }
                let t = str(low[a..<b])
                let banned = t.hasPrefix("rs") || t.hasPrefix("inr") || t.hasPrefix("usd") || t.hasPrefix("xx")
                if runs >= 3 && !banned {
                    out.append(Candidate(start: a, end: b, code: str(slice), mixed: true, gPrefix: false))
                }
            }
            k += 1
        }
        return out
    }

    func accept(_ c: Candidate) -> Bool {
        let start = c.start, end = c.end
        let plainStart = c.gPrefix ? start + 2 : start
        if plainStart > 0 {
            let prev = s[plainStart - 1]
            if "+*#$€£₹@".unicodeScalars.contains(prev) { return false }
            if !c.gPrefix {
                if "/.,:".unicodeScalars.contains(prev), plainStart >= 2, isDigit(s[plainStart - 2]) { return false }
                if prev == "-" {
                    if plainStart >= 2, isDigit(s[plainStart - 2]) { return false }
                    var w = plainStart - 2
                    while w >= 0 && isLetter(s[w]) { w -= 1 }
                    let word = str(low[(w + 1)..<(plainStart - 1)])
                    if !word.isEmpty && !["otp", "code", "pin"].contains(word) { return false }
                }
            }
        }
        if end < s.count {
            let next = s[end]
            if "/.,:-".unicodeScalars.contains(next), end + 1 < s.count, isDigit(s[end + 1]) { return false }
            if next == "/", end + 1 < s.count, s[end + 1] == "-" { return false }
            if next == "%" { return false }
        }
        var p = plainStart
        let seps = " :#.-=()[]'\"\u{00A0}".unicodeScalars
        while p > 0 && seps.contains(low[p - 1]) { p -= 1 }
        if p > 0, "$€£₹".unicodeScalars.contains(s[p - 1]) { return false }
        let beforeScalars = Array(low[max(0, p - 20)..<p])
        let before = str(beforeScalars[...])
        for w in precedingStopWords where before.hasSuffix(w) {
            let idx = beforeScalars.count - w.unicodeScalars.count
            if idx <= 0 || !isLetter(beforeScalars[idx - 1]) { return false }
        }
        var q = end
        while q < s.count && s[q] == " " { q += 1 }
        if q < s.count, s[q] == "%" { return false }
        if q < s.count, isLetter(low[q]), !c.mixed {
            var r = q
            while r < s.count && isLetter(low[r]) { r += 1 }
            if followingStopWords.contains(str(low[q..<r])) { return false }
        }
        if !c.mixed && !c.gPrefix {
            let ds = Array(c.code.unicodeScalars)
            let n = ds.count
            // phone-like continuation "1800 123 4567" (not a spaced 3+3 / 4+4 pair)
            if n == end - start, end + 3 < s.count, s[end] == " ", isDigit(s[end + 1]), isDigit(s[end + 2]), isDigit(s[end + 3]) {
                return false
            }
            func num(_ r: Range<Int>) -> Int { Int(str(ds[r])) ?? 0 }
            if n == 4 {
                let y = num(0..<4)
                if (1900...2099).contains(y) {
                    let ctx = str(low[max(0, start - 14)..<min(low.count, end + 14)])
                    if months.contains(where: { ctx.contains($0) }) { return false }
                    if ["year", "in", "fy", "since"].contains(where: { before.hasSuffix($0) }) { return false }
                }
            }
            if n == 8 {
                let y = num(0..<4), m = num(4..<6), d = num(6..<8)
                if (1900...2099).contains(y), (1...12).contains(m), (1...31).contains(d) { return false }
                let d2 = num(0..<2), m2 = num(2..<4), y2 = num(4..<8)
                if (1...31).contains(d2), (1...12).contains(m2), (1900...2099).contains(y2) { return false }
            }
        }
        return true
    }
}
