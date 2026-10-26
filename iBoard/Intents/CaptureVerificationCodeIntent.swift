import AppIntents
import IBoardOTP

/// Called by the bundled "iBoard SMS Codes" / "iBoard Email Codes" automations (ROADMAP F6).
/// Runs headless (no app launch). Only the extracted code, a sender label and a timestamp are
/// stored in the App Group; the message text is parsed in memory and never persisted or logged.
struct CaptureVerificationCodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Verification Code"
    static let description = IntentDescription(
        "Finds a verification code in a message and makes it available in the iBoard keyboard.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Message Text")
    var text: String

    @Parameter(title: "Sender")
    var sender: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Capture code from \(\.$text) sent by \(\.$sender)")
    }

    func perform() async throws -> some IntentResult {
        // Result is intentionally discarded: nothing about the message is returned or logged.
        _ = OTPWriter().capture(text: text, sender: sender)
        return .result()
    }
}
