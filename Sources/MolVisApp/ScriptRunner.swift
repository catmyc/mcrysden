import Foundation

struct ScriptContext {
    var workingDirectory: URL
    var onOutput: (String) -> Void
    var commands: [String: ([String]) throws -> String]
}

enum ScriptError: Error, LocalizedError {
    case unknownCommand(String, Int)
    case commandFailed(String, Int, String)
    case missingArgument(String, Int)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command, let line):
            return "Line \(line): unknown command '\(command)'"
        case .commandFailed(let command, let line, let message):
            return "Line \(line): command '\(command)' failed: \(message)"
        case .missingArgument(let command, let line):
            return "Line \(line): command '\(command)' is missing a required argument"
        }
    }
}

/// Line-based embedded script interpreter. Each non-empty, non-comment line is
/// split into `command args...` by whitespace; surrounding double quotes are
/// stripped from each argument. `help` is built in; `quit` halts execution.
enum ScriptRunner {
    /// Resolve a script path argument against `workingDirectory`.
    ///
    /// A leading `~/` (or a bare `~`) and a leading `$HOME/` (or bare `$HOME`)
    /// expand to the user's home directory; absolute paths are taken as-is;
    /// everything else stays relative to the script's directory. This is pure
    /// string/URL work — no shell is ever spawned, so `$HOME` is the only
    /// variable recognized and no other shell syntax is interpreted.
    static func resolvePath(_ argument: String, workingDirectory: URL) -> URL {
        if let expanded = expandHome(argument) {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        if argument.hasPrefix("/") { return URL(fileURLWithPath: argument) }
        return workingDirectory.appendingPathComponent(argument)
    }

    /// Expand a leading `~`/`$HOME` prefix; nil when the argument has none.
    private static func expandHome(_ argument: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if argument == "~" || argument == "$HOME" { return home }
        if argument.hasPrefix("~/") {
            return home + "/" + String(argument.dropFirst(2))
        }
        if argument.hasPrefix("$HOME/") {
            return home + "/" + String(argument.dropFirst(6))
        }
        return nil
    }

    static func run(script: String, context: ScriptContext) throws -> String {
        var outputs: [String] = []
        for (index, line) in script.components(separatedBy: "\n").enumerated() {
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { continue }

            guard let (command, args) = tokenize(trimmed) else { continue }

            if command == "quit" {
                return outputs.joined(separator: "\n")
            } else if command == "help" {
                let listing = context.commands.keys.sorted().joined(separator: " ")
                let out = "commands: \(listing)"
                context.onOutput(out)
                outputs.append(out)
            } else {
                guard let fn = context.commands[command] else {
                    throw ScriptError.unknownCommand(command, lineNumber)
                }
                do {
                    let result = try fn(Array(args))
                    context.onOutput(result)
                    outputs.append(result)
                } catch {
                    throw ScriptError.commandFailed(command, lineNumber, error.localizedDescription)
                }
            }
        }
        return outputs.joined(separator: "\n")
    }
}

/// Split a line into `command args...`, respecting double-quoted runs that may
/// contain whitespace. Surrounding double quotes are stripped from each argument.
private func tokenize(_ line: String) -> (command: String, args: [String])? {
    var tokens: [String] = []
    var current = ""
    var inQuotes = false
    var ch = line.makeIterator()
    while let c = ch.next() {
        if inQuotes {
            if c == "\"" { inQuotes = false } else { current.append(c) }
        } else if c == "\"" {
            inQuotes = true
        } else if c == " " || c == "\t" {
            if !current.isEmpty { tokens.append(current); current = "" }
        } else {
            current.append(c)
        }
    }
    if !current.isEmpty { tokens.append(current) }
    guard let command = tokens.first else { return nil }
    return (command, Array(tokens.dropFirst()))
}
