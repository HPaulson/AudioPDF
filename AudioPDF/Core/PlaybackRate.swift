import Foundation

public enum PlaybackRate {
    public static func normalize(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0.5), 2) : 1
    }
}
