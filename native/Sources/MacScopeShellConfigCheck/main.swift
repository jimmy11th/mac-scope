import Darwin
import Foundation
import MacScopeShellCore

var failures: [String] = []

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    failures.append(message)
  }
}

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func makeExecutable(at url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  _ = FileManager.default.createFile(
    atPath: url.path,
    contents: Data("#!/bin/sh\n".utf8)
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755],
    ofItemAtPath: url.path
  )
}

do {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let project = root.appendingPathComponent("project", isDirectory: true)
  let uv = root.appendingPathComponent("bin/uv")
  try FileManager.default.createDirectory(
    at: project.appendingPathComponent("src/macscope", isDirectory: true),
    withIntermediateDirectories: true
  )
  _ = FileManager.default.createFile(
    atPath: project.appendingPathComponent("pyproject.toml").path,
    contents: Data()
  )
  try makeExecutable(at: uv)

  let configuration = try LaunchConfiguration.resolve(
    environment: [
      "MACSCOPE_PROJECT_ROOT": project.path,
      "MACSCOPE_UV_PATH": uv.path,
      "PATH": "/usr/bin",
    ],
    bundleInfo: [:],
    bundleURL: root.appendingPathComponent("MacScope.app", isDirectory: true),
    currentDirectoryURL: root,
    homeDirectoryURL: root
  )

  expect(configuration.executableURL == uv, "development uv override")
  expect(
    configuration.arguments == ["run", "--project", project.path, "macscope"],
    "development launch arguments"
  )
  expect(configuration.currentDirectoryURL == project, "development working directory")
  expect(
    configuration.environment.contains("TERM=xterm-256color"),
    "terminal environment"
  )
  expect(
    configuration.environment.contains("MACSCOPE_NATIVE_SHELL=1"),
    "native shell environment"
  )
  expect(
    configuration.environment.contains("MACSCOPE_HOST_PID=\(getpid())"),
    "native host process identifier"
  )
} catch {
  failures.append("development configuration: \(error.localizedDescription)")
}

do {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let executable = root.appendingPathComponent("macscope")
  let workingDirectory = root.appendingPathComponent("data", isDirectory: true)
  try makeExecutable(at: executable)
  try FileManager.default.createDirectory(
    at: workingDirectory,
    withIntermediateDirectories: true
  )

  let configuration = try LaunchConfiguration.resolve(
    environment: [
      "MACSCOPE_EXECUTABLE": executable.path,
      "MACSCOPE_ARGUMENTS_JSON": "[\"--demo\",\"value with spaces\"]",
      "MACSCOPE_WORKING_DIRECTORY": workingDirectory.path,
    ],
    bundleInfo: [:],
    bundleURL: root.appendingPathComponent("MacScope.app", isDirectory: true),
    currentDirectoryURL: root,
    homeDirectoryURL: root
  )

  expect(configuration.executableURL == executable, "explicit executable")
  expect(
    configuration.arguments == ["--demo", "value with spaces"],
    "explicit JSON arguments"
  )
  expect(configuration.currentDirectoryURL == workingDirectory, "explicit working directory")
} catch {
  failures.append("explicit configuration: \(error.localizedDescription)")
}

do {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let executable = root.appendingPathComponent("macscope")
  try makeExecutable(at: executable)

  do {
    _ = try LaunchConfiguration.resolve(
      environment: [
        "MACSCOPE_EXECUTABLE": executable.path,
        "MACSCOPE_ARGUMENTS_JSON": "not-json",
      ],
      bundleInfo: [:],
      bundleURL: root.appendingPathComponent("MacScope.app", isDirectory: true),
      currentDirectoryURL: root,
      homeDirectoryURL: root
    )
    failures.append("invalid JSON arguments were accepted")
  } catch {
    expect(
      error.localizedDescription
        == LaunchConfigurationError.invalidArguments.localizedDescription,
      "invalid JSON error"
    )
  }
} catch {
  failures.append("invalid argument configuration: \(error.localizedDescription)")
}

expect(ProcessTermination(waitStatus: 0) == .exited(0), "successful wait status")
expect(ProcessTermination(waitStatus: 36608) == .exited(143), "encoded exit status")
expect(ProcessTermination(waitStatus: 15) == .signaled(15), "signal wait status")
expect(ProcessTermination(waitStatus: nil) == .unavailable, "missing wait status")

if failures.isEmpty {
  print("MacScope native launch configuration checks passed.")
  exit(EXIT_SUCCESS)
}

for failure in failures {
  fputs("FAIL: \(failure)\n", stderr)
}
exit(EXIT_FAILURE)
