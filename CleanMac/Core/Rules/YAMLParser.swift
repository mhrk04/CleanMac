//
//  YAMLValue.swift
//  CleanMac
//
//  A minimal YAML subset value type and parser. We deliberately avoid taking a
//  dependency on Yams — the rule packs we ship only need nested mappings,
//  sequences, scalars, comments, and inline flow sequences. This parser
//  supports exactly that and nothing more.
//
//  Supported:
//    - Block mappings keyed by unquoted or quoted scalars
//    - Block sequences with `- item` (including sequences of mappings)
//    - Flow sequences: [a, b, c]
//    - Scalars: string (quoted or plain), bool, int, double, null
//    - Comments starting with `#` (whole-line and trailing on plain scalars)
//    - Indentation-based nesting (spaces only, tabs rejected)
//
//  Not supported (would require a real YAML implementation):
//    - Anchors / aliases (&a, *a)
//    - Multi-line block scalars (|, >)
//    - Tags (!!str, !!int)
//    - Flow mappings nested in flow sequences
//    - Complex keys
//

import Foundation

/// A parsed YAML value.
public indirect enum YAMLValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case list([YAMLValue])
    case map([String: YAMLValue])

    // MARK: - Typed accessors

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: return nil
            }
        case .int(let i): return i != 0
        default: return nil
        }
    }

    public var listValue: [YAMLValue]? {
        if case .list(let xs) = self { return xs }
        return nil
    }

    public var mapValue: [String: YAMLValue]? {
        if case .map(let m) = self { return m }
        return nil
    }

    public var stringList: [String]? {
        guard case .list(let xs) = self else { return nil }
        var out: [String] = []
        out.reserveCapacity(xs.count)
        for x in xs {
            guard let s = x.stringValue else { return nil }
            out.append(s)
        }
        return out
    }

    public subscript(key: String) -> YAMLValue? {
        if case .map(let m) = self { return m[key] }
        return nil
    }
}

// MARK: - Errors

public enum YAMLParseError: Error, CustomStringConvertible, Equatable {
    case tabIndentation(line: Int)
    case unexpectedIndentation(line: Int, expected: Int, found: Int)
    case missingKey(line: Int)
    case unterminatedQuote(line: Int)
    case invalidFlowSequence(line: Int)
    case duplicateKey(String, line: Int)
    case emptyDocument

    public var description: String {
        switch self {
        case .tabIndentation(let l):
            return "Line \(l): tab characters are not allowed for indentation."
        case .unexpectedIndentation(let l, let e, let f):
            return "Line \(l): unexpected indentation (expected \(e), found \(f))."
        case .missingKey(let l):
            return "Line \(l): expected 'key: value' or '- item'."
        case .unterminatedQuote(let l):
            return "Line \(l): unterminated quoted string."
        case .invalidFlowSequence(let l):
            return "Line \(l): malformed flow sequence."
        case .duplicateKey(let k, let l):
            return "Line \(l): duplicate key '\(k)'."
        case .emptyDocument:
            return "Document is empty."
        }
    }
}

// MARK: - Parser

public struct YAMLParser: Sendable {

    public init() {}

    /// Parse a YAML document from a UTF-8 string.
    public func parse(_ text: String) throws -> YAMLValue {
        let rawLines = text.components(separatedBy: "\n")
        var lines: [Line] = []
        lines.reserveCapacity(rawLines.count)

        for (idx, raw) in rawLines.enumerated() {
            let lineNo = idx + 1
            // Reject tabs used for indentation (allowed inside quoted strings,
            // but we don't produce those).
            if raw.hasPrefix("\t") || raw.contains(where: { $0 == "\t" }) {
                let leading = raw.prefix(while: { $0 == " " || $0 == "\t" })
                if leading.contains("\t") {
                    throw YAMLParseError.tabIndentation(line: lineNo)
                }
            }
            let stripped = stripComment(raw)
            // Skip fully empty lines.
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let indent = stripped.prefix(while: { $0 == " " }).count
            let content = String(stripped.dropFirst(indent)).trimmingCharacters(in: .whitespaces)
            lines.append(Line(number: lineNo, indent: indent, content: content))
        }

        if lines.isEmpty { return .map([:]) }

        var cursor = 0
        let rootIndent = lines[0].indent
        let value = try parseNode(lines: lines, cursor: &cursor, indent: rootIndent)
        // Trailing junk at the top level is a parse error.
        if cursor < lines.count {
            throw YAMLParseError.unexpectedIndentation(
                line: lines[cursor].number,
                expected: rootIndent,
                found: lines[cursor].indent
            )
        }
        return value
    }

    // MARK: - Internals

    private struct Line {
        let number: Int
        let indent: Int
        let content: String
    }

    /// Parse a node (mapping or sequence) whose first line is at `lines[cursor]`
    /// with indentation exactly equal to `indent`.
    private func parseNode(lines: [Line], cursor: inout Int, indent: Int) throws -> YAMLValue {
        guard cursor < lines.count else { return .null }
        let first = lines[cursor]
        if first.indent < indent {
            return .null
        }
        if first.content.hasPrefix("- ") || first.content == "-" {
            return try parseSequence(lines: lines, cursor: &cursor, indent: first.indent)
        }
        return try parseMapping(lines: lines, cursor: &cursor, indent: first.indent)
    }

    private func parseMapping(lines: [Line], cursor: inout Int, indent: Int) throws -> YAMLValue {
        var result: [String: YAMLValue] = [:]

        while cursor < lines.count {
            let line = lines[cursor]
            if line.indent < indent { break }
            if line.indent > indent {
                throw YAMLParseError.unexpectedIndentation(
                    line: line.number, expected: indent, found: line.indent
                )
            }
            if line.content.hasPrefix("- ") { break }   // sequence at same level ends the map

            let (key, rest) = try splitKeyValue(line)
            cursor += 1

            if rest.isEmpty {
                // Value is either nested on following indented lines, or null.
                if cursor < lines.count, lines[cursor].indent > indent {
                    let childIndent = lines[cursor].indent
                    let child = try parseNode(lines: lines, cursor: &cursor, indent: childIndent)
                    if result[key] != nil {
                        throw YAMLParseError.duplicateKey(key, line: line.number)
                    }
                    result[key] = child
                } else {
                    if result[key] != nil {
                        throw YAMLParseError.duplicateKey(key, line: line.number)
                    }
                    result[key] = .null
                }
            } else if rest.hasPrefix("[") {
                let value = try parseFlowSequence(rest, line: line.number)
                if result[key] != nil {
                    throw YAMLParseError.duplicateKey(key, line: line.number)
                }
                result[key] = value
            } else {
                let value = parseScalar(rest)
                if result[key] != nil {
                    throw YAMLParseError.duplicateKey(key, line: line.number)
                }
                result[key] = value
            }
        }

        return .map(result)
    }

    private func parseSequence(lines: [Line], cursor: inout Int, indent: Int) throws -> YAMLValue {
        var items: [YAMLValue] = []

        while cursor < lines.count {
            let line = lines[cursor]
            if line.indent < indent { break }
            if line.indent > indent {
                throw YAMLParseError.unexpectedIndentation(
                    line: line.number, expected: indent, found: line.indent
                )
            }
            guard line.content.hasPrefix("-") else { break }

            // Strip the leading "- " (or just "-" for empty items).
            let afterDash = line.content.dropFirst(1)
            let body = afterDash.hasPrefix(" ")
                ? String(afterDash.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                : String(afterDash)

            cursor += 1

            if body.isEmpty {
                // Nested block on following lines.
                if cursor < lines.count, lines[cursor].indent > indent {
                    let childIndent = lines[cursor].indent
                    let child = try parseNode(lines: lines, cursor: &cursor, indent: childIndent)
                    items.append(child)
                } else {
                    items.append(.null)
                }
                continue
            }

            if body.hasPrefix("[") {
                items.append(try parseFlowSequence(body, line: line.number))
                continue
            }

            // Check whether the body itself is `key: value` — a compact mapping
            // item. Any following lines with indent > current indent belong to
            // this mapping.
            if let (key, rest) = trySplitKeyValue(body) {
                var map: [String: YAMLValue] = [:]

                // Effective indent of the compact mapping = position of the
                // first key on this line (dash + space + indent).
                let compactIndent = indent + 2

                if rest.isEmpty {
                    if cursor < lines.count, lines[cursor].indent > compactIndent {
                        let childIndent = lines[cursor].indent
                        map[key] = try parseNode(lines: lines, cursor: &cursor, indent: childIndent)
                    } else if cursor < lines.count, lines[cursor].indent == compactIndent,
                              !lines[cursor].content.hasPrefix("- ") {
                        map[key] = try parseNode(lines: lines, cursor: &cursor, indent: compactIndent)
                    } else {
                        map[key] = .null
                    }
                } else if rest.hasPrefix("[") {
                    map[key] = try parseFlowSequence(rest, line: line.number)
                } else {
                    map[key] = parseScalar(rest)
                }

                // Continue absorbing sibling keys of this compact mapping.
                while cursor < lines.count {
                    let nxt = lines[cursor]
                    if nxt.indent < compactIndent { break }
                    if nxt.indent > compactIndent {
                        throw YAMLParseError.unexpectedIndentation(
                            line: nxt.number, expected: compactIndent, found: nxt.indent
                        )
                    }
                    if nxt.content.hasPrefix("- ") { break }

                    let (k2, r2) = try splitKeyValue(nxt)
                    cursor += 1

                    if r2.isEmpty {
                        if cursor < lines.count, lines[cursor].indent > compactIndent {
                            let childIndent = lines[cursor].indent
                            map[k2] = try parseNode(lines: lines, cursor: &cursor, indent: childIndent)
                        } else {
                            map[k2] = .null
                        }
                    } else if r2.hasPrefix("[") {
                        map[k2] = try parseFlowSequence(r2, line: nxt.number)
                    } else {
                        map[k2] = parseScalar(r2)
                    }
                }

                items.append(.map(map))
            } else {
                // Plain scalar item.
                items.append(parseScalar(body))
            }
        }

        return .list(items)
    }

    private func splitKeyValue(_ line: Line) throws -> (String, String) {
        guard let (k, v) = trySplitKeyValue(line.content) else {
            throw YAMLParseError.missingKey(line: line.number)
        }
        return (k, v)
    }

    /// Split `content` on the first top-level `: ` (colon followed by space or
    /// end-of-string), respecting quoted keys. Returns nil if no colon exists.
    private func trySplitKeyValue(_ content: String) -> (String, String)? {
        var inSingle = false
        var inDouble = false
        var idx = content.startIndex

        while idx < content.endIndex {
            let c = content[idx]
            if c == "'" && !inDouble { inSingle.toggle() }
            else if c == "\"" && !inSingle { inDouble.toggle() }
            else if c == ":" && !inSingle && !inDouble {
                let next = content.index(after: idx)
                if next == content.endIndex {
                    let key = unquote(String(content[content.startIndex..<idx]))
                    return (key, "")
                }
                if content[next] == " " {
                    let key = unquote(String(content[content.startIndex..<idx]))
                    let value = String(content[content.index(after: next)...])
                        .trimmingCharacters(in: .whitespaces)
                    return (key, value)
                }
            }
            idx = content.index(after: idx)
        }
        return nil
    }

    private func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2 {
            if (t.hasPrefix("\"") && t.hasSuffix("\"")) ||
               (t.hasPrefix("'") && t.hasSuffix("'")) {
                return String(t.dropFirst().dropLast())
            }
        }
        return t
    }

    /// Parse `[a, b, c]` into `.list`.
    private func parseFlowSequence(_ raw: String, line: Int) throws -> YAMLValue {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("[") && s.hasSuffix("]") else {
            throw YAMLParseError.invalidFlowSequence(line: line)
        }
        s.removeFirst()
        s.removeLast()

        if s.trimmingCharacters(in: .whitespaces).isEmpty {
            return .list([])
        }

        var items: [YAMLValue] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var depth = 0

        for c in s {
            if c == "'" && !inDouble { inSingle.toggle(); current.append(c); continue }
            if c == "\"" && !inSingle { inDouble.toggle(); current.append(c); continue }
            if !inSingle && !inDouble {
                if c == "[" { depth += 1; current.append(c); continue }
                if c == "]" { depth -= 1; current.append(c); continue }
                if c == "," && depth == 0 {
                    items.append(parseScalar(current.trimmingCharacters(in: .whitespaces)))
                    current = ""
                    continue
                }
            }
            current.append(c)
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { items.append(parseScalar(tail)) }
        return .list(items)
    }

    /// Parse a plain or quoted scalar.
    private func parseScalar(_ raw: String) -> YAMLValue {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return .null }

        // Quoted string.
        if s.count >= 2 {
            if s.hasPrefix("\"") && s.hasSuffix("\"") {
                return .string(unescape(String(s.dropFirst().dropLast())))
            }
            if s.hasPrefix("'") && s.hasSuffix("'") {
                // YAML single-quoted strings escape ' by doubling it.
                let inner = String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
                return .string(inner)
            }
        }

        // Null / bool / number.
        switch s.lowercased() {
        case "null", "~": return .null
        case "true", "yes", "on": return .bool(true)
        case "false", "no", "off": return .bool(false)
        default: break
        }
        if let i = Int(s) { return .int(i) }
        if let d = Double(s) { return .double(d) }
        return .string(s)
    }

    private func unescape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var iter = s.makeIterator()
        while let c = iter.next() {
            if c == "\\" {
                guard let n = iter.next() else { out.append(c); break }
                switch n {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case "'": out.append("'")
                case "0": out.append("\0")
                default: out.append(n)
                }
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Remove a trailing `#...` comment from a raw line, respecting quotes.
    private func stripComment(_ raw: String) -> String {
        var inSingle = false
        var inDouble = false
        var out = ""
        for c in raw {
            if c == "'" && !inDouble { inSingle.toggle(); out.append(c); continue }
            if c == "\"" && !inSingle { inDouble.toggle(); out.append(c); continue }
            if c == "#" && !inSingle && !inDouble {
                // Only treat as a comment when at line start or preceded by whitespace.
                if out.isEmpty || out.last == " " || out.last == "\t" {
                    break
                }
            }
            out.append(c)
        }
        return out
    }
}
