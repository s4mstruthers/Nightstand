import AppKit

/// Adds Nightstand's MCP server to AI assistants installed on this Mac, so nobody has to edit configuration by hand.
enum AssistantConnector {
    enum Status: Equatable {
        case notInstalled, notConnected, connected
        /// Connected, but to a copy of Nightstand somewhere else (for example before it was moved to Applications).
        case connectedElsewhere
    }

    enum Failure: LocalizedError {
        case unreadableConfiguration, commandFailed

        var errorDescription: String? {
            switch self {
            case .unreadableConfiguration:
                "Its configuration file couldn't be read, so Nightstand left it alone. Use the manual set-up below."
            case .commandFailed: "Claude Code didn't accept the change. Use the manual set-up below."
            }
        }
    }

    static let serverName = "nightstand"
    static var executable: String {
        Bundle.main.executablePath ?? "/Applications/Nightstand.app/Contents/MacOS/Nightstand"
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// How a configuration file with an `mcpServers` section refers to Nightstand.
    static func status(in config: URL, executable: String) -> Status {
        guard let data = try? Data(contentsOf: config),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (root["mcpServers"] as? [String: Any])?[serverName] as? [String: Any] else {
            return .notConnected
        }
        return entry["command"] as? String == executable ? .connected : .connectedElsewhere
    }

    // MARK: Claude Desktop

    static var desktopConfig: URL {
        home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json")
    }

    static var desktopInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil
            || FileManager.default.fileExists(atPath: desktopConfig.deletingLastPathComponent().path)
    }

    static func desktopStatus() -> Status {
        desktopInstalled ? status(in: desktopConfig, executable: executable) : .notInstalled
    }

    /// Adds, or with `connect` false removes, the Nightstand entry, leaving everything else in the file as it is.
    static func setDesktop(connected connect: Bool, config: URL = desktopConfig,
                           executable: String = executable) throws {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: config), !data.allSatisfy(\.isASCIIWhitespace) {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.unreadableConfiguration
            }
            root = existing
            let backup = config.deletingLastPathComponent().appending(path: "claude_desktop_config.before-nightstand.json")
            if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: config, to: backup) }
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = connect ? ["command": executable, "args": ["--mcp"]] : nil
        root["mcpServers"] = servers
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
            .write(to: config, options: .atomic)
    }

    // MARK: Claude Code

    static var codeConfig: URL { home.appending(path: ".claude.json") }

    /// Apps don't inherit the shell's PATH, so look where Claude Code is usually installed.
    static var codeCLI: URL? {
        ["\(home.path)/.local/bin/claude", "\(home.path)/.claude/local/claude", "/opt/homebrew/bin/claude",
         "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func codeStatus() -> Status {
        codeCLI == nil ? .notInstalled : status(in: codeConfig, executable: executable)
    }

    static func codeArguments(connected connect: Bool, executable: String) -> [String] {
        connect ? ["mcp", "add", "--scope", "user", serverName, "--", executable, "--mcp"]
            : ["mcp", "remove", "--scope", "user", serverName]
    }

    /// Goes through Claude Code's own command rather than editing its settings file, which it rewrites itself.
    static func setCode(connected connect: Bool, cli: URL? = codeCLI, executable: String = executable,
                        environment: [String: String] = [:]) throws {
        guard let cli else { throw Failure.commandFailed }
        // `add` refuses to replace an entry, so clear any old one first.
        if connect { _ = try? run(cli, codeArguments(connected: false, executable: executable), environment) }
        try run(cli, codeArguments(connected: connect, executable: executable), environment)
    }

    private static func run(_ cli: URL, _ arguments: [String], _ extra: [String: String]) throws {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Installs through npm are scripts that need `node` on the PATH.
        environment["PATH"] = "\(cli.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:"
            + (environment["PATH"] ?? "/usr/bin:/bin")
        environment.merge(extra) { _, new in new }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.commandFailed }
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }
}
