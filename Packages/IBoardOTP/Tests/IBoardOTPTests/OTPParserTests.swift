import Testing
@testable import IBoardOTP

@Test func moduleNameMatches() {
    #expect(IBoardOTP.moduleName == "IBoardOTP")
}

@Test func corpusAccuracyAndNoFalsePositives() {
    var correct = 0, falsePositives = 0, positiveTotal = 0, negativeTotal = 0
    var failedIndexes: [Int] = []
    for (i, e) in otpCorpus.enumerated() {
        let got = OTPParser.extract(from: e.message)?.code
        if e.expected == nil {
            negativeTotal += 1
            if got != nil { falsePositives += 1 }
        } else {
            positiveTotal += 1
        }
        if got == e.expected { correct += 1 } else { failedIndexes.append(i) }
    }
    let accuracy = Double(correct) / Double(otpCorpus.count)
    // Counts and indexes only; never message bodies.
    print("OTP corpus: total=\(otpCorpus.count) positives=\(positiveTotal) negatives=\(negativeTotal) correct=\(correct) falsePositives=\(falsePositives) accuracy=\(accuracy) failedIndexes=\(failedIndexes)")
    #expect(otpCorpus.count >= 120)
    #expect(accuracy >= 0.99)
    #expect(falsePositives == 0)
}

@Test func basicCases() {
    #expect(OTPParser.extract(from: "G-123456 is your Google verification code.")?.code == "G-123456")
    #expect((OTPParser.extract(from: "Your OTP is 4821")?.confidence ?? 0) > 0.9)
    #expect(OTPParser.extract(from: "") == nil)
}
