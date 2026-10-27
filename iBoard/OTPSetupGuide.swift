import Foundation

/// Content of the guided OTP setup (ROADMAP F6, M6-04). Pure data so the wording can be unit-tested.
/// Source of truth for the flow: the device-verified setup in ROADMAP P-27 (iPhone 12, iOS 27.0).
enum OTPTrigger: String, CaseIterable, Identifiable, Sendable {
    case message
    case email
    var id: String { rawValue }
    var title: String { self == .message ? "Text message" : "Email" }
}

struct OTPSetupStep: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let detail: String
    /// Where to tap, in order. Rendered as a breadcrumb of chips (the "illustration").
    let path: [String]
    /// Extra caution shown under the step; nil when none.
    let note: String?
}

enum OTPSetupGuide {
    static let intentName = "Capture Verification Code"
    static let messageField = "Message Text"
    static let senderField = "Sender"

    static func steps(for trigger: OTPTrigger) -> [OTPSetupStep] {
        let isMail = trigger == .email
        let condition = isMail ? "Subject Contains" : "Message Contains"
        let senderWhere = isMail ? "the Sender or Account filter" : "the Sender filter"
        return [
            OTPSetupStep(
                id: 1,
                title: "Start a new automation",
                detail: "Open the Shortcuts app, go to Automation and tap the plus button. "
                    + "Choose the Automation chip, then Communication, then \(isMail ? "Email" : "Message").",
                path: ["Shortcuts", "Automation", "+", "Automation", "Communication", isMail ? "Email" : "Message"],
                note: nil),
            OTPSetupStep(
                id: 2,
                title: "Set the trigger conditions",
                detail: "Set the condition \"\(condition)\" to the word code. "
                    + "Then set \(senderWhere) to the real sender of your codes."
                    + (isMail ? " Email codes arrive as the subject; iBoard reads the subject as the message." : ""),
                path: [condition, "code", isMail ? "Sender / Account" : "Sender"],
                note: "The sender must match the real sender exactly. In our device test an email automation "
                    + "did not run when the filter named a different account than the one the mail came from."),
            OTPSetupStep(
                id: 3,
                title: "Run it automatically",
                detail: "Choose Run Immediately: turn Automation on and turn Confirm Before Run off, "
                    + "so codes are captured without a prompt and without opening iBoard.",
                path: ["Automation: On", "Confirm Before Run: Off"],
                note: nil),
            OTPSetupStep(
                id: 4,
                title: "Add the iBoard action",
                detail: "Tap Next, search for iBoard and add the action \"\(intentName)\".",
                path: ["Next", "Search: iBoard", intentName],
                note: nil),
            OTPSetupStep(
                id: 5,
                title: "Pass the message to iBoard",
                detail: "Set the \(messageField) field to the trigger's Message and the \(senderField) field to the "
                    + "trigger's Sender: tap each field and pick the variable from the trigger. Then tap Done.",
                path: ["\(messageField) = Message", "\(senderField) = Sender", "Done"],
                note: "iBoard reads the code in memory and stores only the code, a sender label and the time, "
                    + "for 10 minutes. The message text is never saved."),
            OTPSetupStep(
                id: 6,
                title: "Check it worked",
                detail: "When a matching \(isMail ? "email" : "text") arrives, a \"Running <automation name>\" banner "
                    + "appears. The code then shows in the iBoard suggestion strip. Use the self-test next.",
                path: ["Banner: Running…", "Code chip in iBoard"],
                note: "After you restart the phone, open the Shortcuts app once. Until you do, the first "
                    + "message may not be handled (it runs once Shortcuts opens)."),
        ]
    }

    /// Sample text for the self-test. Contains the trigger word so the automation fires.
    static let selfTestSampleMessage = "iBoard test: your verification code is 482913"
}

/// What works with and without Full Access, from device measurements (ROADMAP P-23).
enum FullAccessMatrix {
    struct Row: Equatable, Sendable { let feature: String; let withoutFullAccess: Bool; let note: String? }

    static let rows: [Row] = [
        Row(feature: "Typing, suggestions, swipe, themes", withoutFullAccess: true, note: nil),
        Row(feature: "Your settings from the iBoard app", withoutFullAccess: true, note: nil),
        Row(feature: "Verification codes in the strip", withoutFullAccess: true,
            note: "The Shortcuts automation writes the code; the keyboard only reads it."),
        Row(feature: "Key click sounds", withoutFullAccess: true, note: "Needs Keyboard Feedback > Sound on."),
        Row(feature: "Learning from what you type", withoutFullAccess: true,
            note: "Kept inside the keyboard; the app's dictionary list stays empty."),
        Row(feature: "Haptic feedback", withoutFullAccess: false, note: nil),
        Row(feature: "Clipboard features", withoutFullAccess: false, note: nil),
        Row(feature: "Showing learned words in the app, sync", withoutFullAccess: false, note: nil),
    ]
}
