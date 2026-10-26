/// Module marker; key/strip rendering and the touch state machine land in M1 (UIKit-only code goes behind
/// `#if canImport(UIKit)` so the package still builds on macOS).
public enum IBoardUI {
    public static let moduleName = "IBoardUI"
}
