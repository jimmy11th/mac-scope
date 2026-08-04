import Foundation
import Testing
@testable import MacScopeNative

@Suite("Mihomo configuration")
struct MihomoConfigurationTests {
  @Test("Direct rules are inserted first and remain idempotent")
  func directRules() throws {
    let source = "mixed-port: 7890\nrules:\n  - MATCH,Proxy\n"
    let once = try MihomoConfiguration.addDirectRules(
      to: source,
      domains: ["tcb.cloud.tencent.com", "API.Example.com"]
    )
    let twice = try MihomoConfiguration.addDirectRules(
      to: once,
      domains: ["tcb.cloud.tencent.com", "api.example.com"]
    )

    #expect(once == twice)
    #expect(once.contains("rules:\n  - DOMAIN-SUFFIX,tcb.cloud.tencent.com,DIRECT"))
    #expect(once.contains("  - DOMAIN-SUFFIX,api.example.com,DIRECT"))
  }

  @Test("Configs without a top-level rules section are rejected")
  func refusesMissingRules() {
    #expect(throws: MihomoError.self) {
      _ = try MihomoConfiguration.addDirectRules(
        to: "mixed-port: 7890\n",
        domains: ["example.com"]
      )
    }
  }

  @Test("Only loopback controllers are accepted")
  func controllerSecurity() throws {
    let loopback = try MihomoConfiguration.controller(
      from: "external-controller: 0.0.0.0:9090\nsecret: local-secret\n"
    )
    #expect(loopback.baseURL.host == "127.0.0.1")
    #expect(loopback.secret == "local-secret")

    #expect(throws: MihomoError.self) {
      _ = try MihomoConfiguration.controller(
        from: "external-controller: 192.168.1.20:9090\nsecret: do-not-send\n"
      )
    }
  }

  @Test("Legacy Warrior route blocks migrate to MacScope markers")
  func migratesLegacyBindings() throws {
    let source = """
      rules:
        # warrior-local-services:site-routes:start
        - DOMAIN-SUFFIX,old.example.com,Node A
        # warrior-local-services:site-routes:end
        - MATCH,Proxy
      """
    let updated = try MihomoConfiguration.applyingBindings(
      to: source,
      bindings: [MihomoSiteBinding(domain: "new.example.com", outbound: "Node B")],
      directDomains: []
    )
    let bindings = try MihomoConfiguration.extractedBindings(from: updated)

    #expect(!updated.contains("warrior-local-services:site-routes"))
    #expect(updated.contains("macscope:site-routes:start"))
    #expect(bindings == [MihomoSiteBinding(domain: "new.example.com", outbound: "Node B")])
  }

  @Test("Domain normalization rejects ambiguous input")
  func domainValidation() throws {
    #expect(try MihomoConfiguration.normalizeDomains(["One.Example.com, two.example.com"]) == [
      "one.example.com", "two.example.com",
    ])
    #expect(throws: MihomoError.self) {
      _ = try MihomoConfiguration.normalizeDomains(["bad..example.com"])
    }
  }
}
