import XCTest

final class BuildScriptTests: XCTestCase {
  func testBuildScriptBehaviorSuite() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let script = root.appendingPathComponent("scripts/test_build_sh.sh")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    XCTAssertEqual(process.terminationStatus, 0, "build.sh 行为测试失败")
  }
}
