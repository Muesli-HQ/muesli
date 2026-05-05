import Testing
@testable import MuesliNativeApp

@Suite("Computer Use executor")
struct ComputerUseExecutorTests {
    @Test("maps common app aliases to bundle identifiers")
    @MainActor
    func commonAppAliases() {
        #expect(ComputerUseExecutor.bundleIdentifierAlias(for: "Google Chrome") == "com.google.Chrome")
        #expect(ComputerUseExecutor.bundleIdentifierAlias(for: "chrome") == "com.google.Chrome")
        #expect(ComputerUseExecutor.bundleIdentifierAlias(for: "VS Code") == "com.microsoft.VSCode")
    }

    @Test("maps spoken key names to virtual key codes")
    @MainActor
    func spokenKeyNames() {
        #expect(ComputerUseExecutor.keyCode(for: "l") == 37)
        #expect(ComputerUseExecutor.keyCode(for: "enter") == 36)
        #expect(ComputerUseExecutor.keyCode(for: "left arrow") == 123)
    }
}
