/// A standalone modifier gesture commits only on release. Repeated edges do
/// not reopen it, and any chord invalidates the entire press/release cycle.
struct ModifierToggleGesture {
    private(set) var isDown = false
    private var joined = false

    mutating func press() {
        guard !isDown else { return }
        isDown = true
        joined = false
    }

    mutating func chord() {
        if isDown { joined = true }
    }

    mutating func release() -> Bool {
        let valid = isDown && !joined
        reset()
        return valid
    }

    mutating func reset() {
        isDown = false
        joined = false
    }
}
