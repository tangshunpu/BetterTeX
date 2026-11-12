import XCTest
@testable import BetterTeXCore

final class ToolchainTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX shell tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func discover(rc: String, inherited: [String: String] = [:]) throws -> Toolchain {
        try rc.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        var environment = inherited
        environment["HOME"] = directory.path
        environment["ZDOTDIR"] = directory.path
        environment["SHELL"] = "/bin/zsh"
        environment["PATH"] = "/usr/bin:/bin"
        return Toolchain.discover(environment: environment)
    }

    func testUnconfiguredNetworkStaysDirect() throws {
        let tools = try discover(rc: "export PATH=\"/direct tools/bin:$PATH\"")
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"] {
            XCTAssertNil(tools.environment[key], key)
        }
        XCTAssertTrue(tools.environment["PATH"]?.hasPrefix("/direct tools/bin:") == true)
    }

    func testFinderLaunchPassesShellProxiesToChildProcess() throws {
        let tools = try discover(rc: """
        printf 'shell startup message\\n'
        export PATH="/custom tools/bin:$PATH"
        export HTTP_PROXY='http://127.0.0.1:7890'
        export HTTPS_PROXY='http://127.0.0.1:7890'
        export https_proxy='http://127.0.0.1:7891'
        export NO_PROXY='localhost,127.0.0.1,::1,.local'
        export UNRELATED_SECRET='must-not-be-imported'
        """)
        XCTAssertTrue(tools.environment["PATH"]?.hasPrefix("/custom tools/bin:") == true)
        XCTAssertNil(tools.environment["UNRELATED_SECRET"])
        // Exercise the same launch path used by ClaudeTurn, starting without GUI proxy exports.
        let result = try ProcessRunner().run("/bin/sh", ["-c", "printf '%s\\n' \"$HTTP_PROXY\" \"$HTTPS_PROXY\" \"$https_proxy\" \"$NO_PROXY\""], environment: tools.environment)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.output, "http://127.0.0.1:7890\nhttp://127.0.0.1:7890\nhttp://127.0.0.1:7891\nlocalhost,127.0.0.1,::1,.local\n")
    }

    func testShellCanReplaceUnsetOrEmptyInheritedProxySettings() throws {
        let tools = try discover(rc: """
        export HTTPS_PROXY='http://proxy.example:8080/?a=b'
        unset https_proxy
        export NO_PROXY=''
        export no_proxy='localhost
        example.test'
        """, inherited: ["HTTPS_PROXY": "http://old:8080", "https_proxy": "http://old:8080", "NO_PROXY": "*", "EXISTING_VALUE": "retained"])
        XCTAssertEqual(tools.environment["HTTPS_PROXY"], "http://proxy.example:8080/?a=b")
        XCTAssertNil(tools.environment["https_proxy"])
        XCTAssertEqual(tools.environment["NO_PROXY"], "")
        XCTAssertEqual(tools.environment["no_proxy"], "localhost\nexample.test")
        XCTAssertEqual(tools.environment["EXISTING_VALUE"], "retained")
    }

    func testFailedShellPreservesInheritedEnvironmentAndToolFallbacks() {
        let tools = Toolchain.discover(environment: ["SHELL": "/missing/bettertex-shell", "PATH": "/custom/bin", "HTTPS_PROXY": "http://127.0.0.1:7890"])
        XCTAssertEqual(tools.environment["HTTPS_PROXY"], "http://127.0.0.1:7890")
        XCTAssertTrue(tools.environment["PATH"]?.hasPrefix("/custom/bin:") == true)
        XCTAssertNotNil(tools["git"])
    }
}
