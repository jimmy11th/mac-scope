import Foundation
import Testing
@testable import MacScopeNative

@Suite("Developer Services profiles")
struct DeveloperServicesModelsTests {
  @Test("Legacy string and argument commands both decode")
  func commandCompatibility() throws {
    let arguments = try JSONDecoder().decode(
      DeveloperCommand.self,
      from: Data(#"["pnpm","run","dev"]"#.utf8)
    )
    let shell = try JSONDecoder().decode(
      DeveloperCommand.self,
      from: Data(#""pnpm run dev""#.utf8)
    )

    #expect(arguments == .arguments(["pnpm", "run", "dev"]))
    #expect(shell == .shell("pnpm run dev"))
  }

  @Test("Warrior profiles decode without rewriting")
  func profileCompatibility() throws {
    let source = #"""
      {
        "id": "local",
        "name": "Local",
        "root": "/tmp/project",
        "readyPattern": "compiled successfully",
        "services": [
          { "id": "sim", "cwd": "apps/sim", "command": ["pnpm", "run", "dev"], "port": 8080 }
        ]
      }
      """#
    let profile = try JSONDecoder().decode(
      DeveloperServiceProfile.self,
      from: Data(source.utf8)
    )

    #expect(profile.id == "local")
    #expect(profile.services.first?.id == "sim")
    #expect(profile.defaultReadyPattern == "compiled successfully")
  }
}
