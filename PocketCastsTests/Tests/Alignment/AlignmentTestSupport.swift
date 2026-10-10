import Foundation

extension Array {
    /// Bounds-checked element. The test host is the app, so a trapping subscript crashes the host;
    /// a missing element must fail the assertion instead.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
