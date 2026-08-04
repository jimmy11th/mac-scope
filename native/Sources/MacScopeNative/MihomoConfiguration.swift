import Foundation

struct MihomoControllerConfiguration: Equatable, Sendable {
  var baseURL: URL
  var secret: String
}

enum MihomoConfiguration {
  static let managedRoutesStart = "# macscope:site-routes:start"
  static let managedRoutesEnd = "# macscope:site-routes:end"
  static let legacyRoutesStart = "# warrior-local-services:site-routes:start"
  static let legacyRoutesEnd = "# warrior-local-services:site-routes:end"

  static func normalizeDomains(_ values: [String]) throws -> [String] {
    var result: [String] = []
    for value in values.flatMap({ $0.components(separatedBy: CharacterSet(charactersIn: ",; \t\r\n")) }) {
      let domain = value.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        .lowercased()
      guard !domain.isEmpty else { continue }
      let allowed = domain.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0)
      }
      guard
        allowed,
        !domain.hasPrefix("-"),
        !domain.hasSuffix("-"),
        !domain.contains("..")
      else { throw MihomoError.invalidDomain(value) }
      if !result.contains(domain) { result.append(domain) }
    }
    return result
  }

  static func controller(from source: String) throws -> MihomoControllerConfiguration {
    guard let configured = yamlScalar("external-controller", in: source), !configured.isEmpty else {
      throw MihomoError.invalidController("The Mihomo config must define external-controller.")
    }
    var address = configured
    if address.hasPrefix("0.0.0.0:") {
      address = "127.0.0.1:" + address.dropFirst("0.0.0.0:".count)
    } else if address.hasPrefix("[::]:") {
      address = "[::1]:" + address.dropFirst("[::]:".count)
    }
    if !address.hasPrefix("http://") && !address.hasPrefix("https://") {
      address = "http://\(address)"
    }
    guard let url = URL(string: address), let host = url.host?.lowercased() else {
      throw MihomoError.invalidController("external-controller is not a valid address.")
    }
    guard host == "127.0.0.1" || host == "::1" || host == "localhost" else {
      throw MihomoError.invalidController(
        "external-controller must use a loopback address; its secret will not be sent remotely."
      )
    }
    return MihomoControllerConfiguration(
      baseURL: url,
      secret: yamlScalar("secret", in: source) ?? ""
    )
  }

  static func addDirectRules(to source: String, domains: [String]) throws -> String {
    let normalized = try normalizeDomains(domains)
    var lines = source.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
    guard let rulesIndex = topLevelRulesIndex(in: lines) else {
      throw MihomoError.invalidConfiguration(
        "The config has no top-level rules section; routing semantics were not changed."
      )
    }
    var insertionIndex = rulesIndex + 1
    for domain in normalized {
      let rule = "DOMAIN-SUFFIX,\(domain),DIRECT"
      if lines.contains(where: { normalizedRule($0) == rule }) { continue }
      lines.insert("  - \(rule)", at: insertionIndex)
      insertionIndex += 1
    }
    return lines.joined(separator: "\n")
  }

  static func applyingBindings(
    to source: String,
    bindings: [MihomoSiteBinding],
    directDomains: [String]
  ) throws -> String {
    let normalizedBindings = try normalizeBindings(bindings)
    var lines = source.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
    guard let rulesIndex = topLevelRulesIndex(in: lines) else {
      throw MihomoError.invalidConfiguration(
        "The config has no top-level rules section; routing semantics were not changed."
      )
    }
    try removeManagedBlock(start: managedRoutesStart, end: managedRoutesEnd, from: &lines)
    try removeManagedBlock(start: legacyRoutesStart, end: legacyRoutesEnd, from: &lines)
    guard !normalizedBindings.isEmpty else { return lines.joined(separator: "\n") }

    let directSet = Set(try normalizeDomains(directDomains))
    var insertionIndex = rulesIndex + 1
    while insertionIndex < lines.count {
      let rule = normalizedRule(lines[insertionIndex])
      let fields = rule.split(separator: ",", omittingEmptySubsequences: false)
      guard
        fields.count == 3,
        fields[0] == "DOMAIN-SUFFIX",
        fields[2] == "DIRECT",
        directSet.contains(String(fields[1]).lowercased())
      else { break }
      insertionIndex += 1
    }

    let block = ["  \(managedRoutesStart)"]
      + normalizedBindings.map { "  - DOMAIN-SUFFIX,\($0.domain),\($0.outbound)" }
      + ["  \(managedRoutesEnd)"]
    lines.insert(contentsOf: block, at: insertionIndex)
    return lines.joined(separator: "\n")
  }

  static func extractedBindings(from source: String) throws -> [MihomoSiteBinding] {
    let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
    for markers in [
      (managedRoutesStart, managedRoutesEnd),
      (legacyRoutesStart, legacyRoutesEnd),
    ] {
      let start = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == markers.0 }
      let end = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == markers.1 }
      if start == nil && end == nil { continue }
      guard let start, let end, end > start else {
        throw MihomoError.invalidConfiguration("The managed site-route markers are damaged.")
      }
      return try normalizeBindings(lines[(start + 1)..<end].compactMap { line in
        let fields = normalizedRule(line).split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "DOMAIN-SUFFIX" else { return nil }
        return MihomoSiteBinding(domain: String(fields[1]), outbound: String(fields[2]))
      })
    }
    return []
  }

  private static func normalizeBindings(
    _ bindings: [MihomoSiteBinding]
  ) throws -> [MihomoSiteBinding] {
    var result: [MihomoSiteBinding] = []
    for binding in bindings {
      guard let domain = try normalizeDomains([binding.domain]).first else {
        throw MihomoError.invalidBinding("A site binding requires a domain.")
      }
      let outbound = binding.outbound.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        !outbound.isEmpty,
        outbound.count <= 128,
        outbound.rangeOfCharacter(from: CharacterSet(charactersIn: ",\t\r\n")) == nil
      else { throw MihomoError.invalidBinding("The outbound name is invalid.") }
      let item = MihomoSiteBinding(domain: domain, outbound: outbound)
      if let index = result.firstIndex(where: { $0.domain == domain }) {
        result[index] = item
      } else {
        result.append(item)
      }
    }
    return result
  }

  private static func yamlScalar(_ key: String, in source: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: key)
    guard
      let expression = try? NSRegularExpression(
        pattern: "(?m)^\\s*\(escaped)\\s*:\\s*['\\\"]?([^'\\\"#\\r\\n]+)"
      )
    else { return nil }
    let range = NSRange(source.startIndex..., in: source)
    guard
      let match = expression.firstMatch(in: source, range: range),
      let valueRange = Range(match.range(at: 1), in: source)
    else { return nil }
    return source[valueRange].trimmingCharacters(in: .whitespaces)
  }

  private static func topLevelRulesIndex(in lines: [String]) -> Int? {
    lines.firstIndex { line in
      guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { return false }
      let value = line.split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
      return value == "rules:"
    }
  }

  private static func normalizedRule(_ line: String) -> String {
    var value = line.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("-") {
      value.removeFirst()
      value = value.trimmingCharacters(in: .whitespaces)
    }
    return value
  }

  private static func removeManagedBlock(
    start markerStart: String,
    end markerEnd: String,
    from lines: inout [String]
  ) throws {
    let start = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == markerStart }
    let end = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == markerEnd }
    guard start != nil || end != nil else { return }
    guard let start, let end, end >= start else {
      throw MihomoError.invalidConfiguration("The managed site-route markers are damaged.")
    }
    lines.removeSubrange(start...end)
  }
}
