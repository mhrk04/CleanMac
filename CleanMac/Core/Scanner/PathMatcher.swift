//
//  PathMatcher.swift
//  CleanMac
//
//  Glob matching + template variable expansion for rule paths.
//
//  Supported pattern syntax (a subset of zsh globs, sufficient for our rules):
//    ~             expands to the current user's home directory
//    $HOME         same as ~
//    {varName}     substituted from the provided context (e.g. {bundleId})
//    *             matches any characters within a single path segment
//    **            matches any characters across segments (recursive)
//    ?             matches exactly one character within a segment
//    [...]         character class (POSIX-ish, no negation with [!...])
//
//  Matching is always against absolute, standardised paths.
//

import Foundation

public struct PathMatcher: Sendable {

    /// Values for `{varName}` substitutions.
    public struct Context: Sendable, Equatable {
        public var home: String
        public var variables: [String: String]

        public init(home: String = NSHomeDirectory(), variables: [String: String] = [:]) {
            self.home = home
            self.variables = variables
        }

        public static let empty = Context(home: NSHomeDirectory(), variables: [:])

        /// Return a copy with `key` set to `value`.
        public func setting(_ key: String, to value: String) -> Context {
            var v = variables
            v[key] = value
            return Context(home: home, variables: v)
        }
    }

    public init() {}

    // MARK: - Expansion

    /// Expand `~`, `$HOME`, and `{varName}` placeholders in `pattern`.
    /// Unknown variables are substituted with the empty string, which lets
    /// rules like `~/{bundleId}` degrade gracefully when the caller forgot
    /// to supply a context.
    public func expand(_ pattern: String, context: Context = .empty) -> String {
        var out = pattern

        // Template variables first (before ~ expansion so a variable can
        // contain a ~ if it really wants to).
        if out.contains("{") {
            out = substituteVariables(out, context: context)
        }

        // Home expansion.
        if out == "~" {
            return context.home
        }
        if out.hasPrefix("~/") {
            return context.home + String(out.dropFirst(1))
        }
        if out.hasPrefix("$HOME/") {
            return context.home + String(out.dropFirst(5))
        }
        if out == "$HOME" {
            return context.home
        }

        return out
    }

    private func substituteVariables(_ input: String, context: Context) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c == "{" {
                // Find matching '}' on the same "word".
                if let close = input[i...].firstIndex(of: "}") {
                    let key = String(input[input.index(after: i)..<close])
                    let replacement = context.variables[key] ?? ""
                    out.append(replacement)
                    i = input.index(after: close)
                    continue
                }
            }
            out.append(c)
            i = input.index(after: i)
        }
        return out
    }

    // MARK: - Matching

    /// Test whether an absolute path matches a glob pattern.
    /// Both `path` and `pattern` are canonicalised before comparison, so a
    /// rule written as `/private/var/...` matches a path reported as `/var/...`
    /// and vice versa.
    public func matches(path: String, pattern: String, context: Context = .empty) -> Bool {
        let expanded = canonicalizePattern(expand(pattern, context: context))
        let regex = compile(expanded)
        let standard = standardize(path)
        return regex.firstMatch(in: standard, range: NSRange(standard.startIndex..., in: standard)) != nil
    }

    /// Test whether any pattern in `patterns` matches.
    public func matchesAny(path: String, patterns: [String], context: Context = .empty) -> Bool {
        for p in patterns where matches(path: path, pattern: p, context: context) {
            return true
        }
        return false
    }

    /// Compile a glob (already expanded) into an anchored NSRegularExpression.
    /// Exposed for callers that need to match many paths against the same
    /// pattern without re-expanding — see `CompiledGlob`.
    public func compile(_ expandedPattern: String) -> NSRegularExpression {
        let regexSource = globToRegex(expandedPattern)
        // Anchored, case-sensitive (APFS is case-insensitive by default but
        // preserving case in the pattern is the safer default).
        return (try? NSRegularExpression(pattern: regexSource, options: [.anchorsMatchLines]))
            ?? NSRegularExpression()
    }

    /// Pre-compile a list of patterns for repeated use.
    public func compileAll(_ patterns: [String], context: Context = .empty) -> CompiledGlob {
        CompiledGlob(patterns: patterns, context: context, matcher: self)
    }

    /// Convert a glob string into a regex source string.
    /// Package-visible for unit testing.
    func globToRegex(_ glob: String) -> String {
        var out = "^"
        var i = glob.startIndex

        while i < glob.endIndex {
            let c = glob[i]
            switch c {
            case "*":
                let next = glob.index(after: i)
                if next < glob.endIndex, glob[next] == "*" {
                    // '**' — recursive. Consume optional trailing slash so
                    // '/foo/**' matches '/foo' itself as well as descendants.
                    let j = glob.index(after: next)
                    if j < glob.endIndex, glob[j] == "/" {
                        // '**/' can match zero segments.
                        out.append("(?:.*/)?")
                        i = glob.index(after: j)
                        continue
                    } else if j == glob.endIndex, out.hasSuffix("/") {
                        // Terminal '**': fold the separating slash into the
                        // group so '/foo/**' matches '/foo' *and* '/foo/bar'.
                        out.removeLast()
                        out.append("(?:/.*)?")
                        i = j
                        continue
                    } else {
                        out.append(".*")
                        i = j
                        continue
                    }
                } else {
                    // '*' within a segment.
                    out.append("[^/]*")
                    i = next
                    continue
                }

            case "?":
                out.append("[^/]")

            case "[":
                // Character class: pass through until matching ']'.
                if let close = glob[i...].firstIndex(of: "]"), close > i {
                    var cls = "["
                    let innerStart = glob.index(after: i)
                    if innerStart < close, glob[innerStart] == "!" {
                        cls.append("^")
                        cls.append(contentsOf: glob[glob.index(after: innerStart)..<close])
                    } else {
                        cls.append(contentsOf: glob[innerStart..<close])
                    }
                    cls.append("]")
                    out.append(cls)
                    i = glob.index(after: close)
                    continue
                } else {
                    out.append("\\[")
                }

            // Regex metacharacters that need escaping.
            case ".", "+", "(", ")", "|", "^", "$", "\\", "{", "}":
                out.append("\\")
                out.append(c)

            default:
                out.append(c)
            }
            i = glob.index(after: i)
        }
        out.append("$")
        return out
    }

    /// Standardise an absolute path: resolve `~`, `.`, `..`, and trailing `/`.
    /// Does NOT hit the disk — no symlink resolution.
    ///
    /// The `/private` prefix is collapsed deterministically. `NSString`'s
    /// `standardizingPath` only strips it when the path currently exists, so
    /// leaving that alone would make the same logical location standardise two
    /// different ways depending on disk state — unacceptable for a safety
    /// decision, and a silent match failure for rules that spell the prefix in
    /// the opposite way to the enumerator.
    public func standardize(_ path: String) -> String {
        var p = path
        if p.hasPrefix("~") {
            p = NSHomeDirectory() + String(p.dropFirst(1))
        }
        p = (p as NSString).standardizingPath
        p = Self.stripPrivatePrefix(p)
        // standardizingPath keeps a trailing slash for "/", strip elsewhere.
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Canonicalise an already-expanded glob *pattern* so it can be compared
    /// against `standardize`d paths. Only the deterministic part of
    /// `standardize` applies here: `standardizingPath` would probe the disk and
    /// try to resolve `..`, which is meaningless for a string that still
    /// contains wildcards.
    fileprivate func canonicalizePattern(_ pattern: String) -> String {
        Self.stripPrivatePrefix(pattern)
    }

    /// `/private/var/x` → `/var/x`. Bare `/private` is a real directory and is
    /// left alone; collapsing it to `/` would turn it into the volume root.
    private static func stripPrivatePrefix(_ path: String) -> String {
        guard path.hasPrefix("/private/") else { return path }
        return String(path.dropFirst("/private".count))
    }
}

// MARK: - CompiledGlob

/// A bundle of pre-expanded, pre-compiled patterns. Use when testing many
/// paths against the same rule set.
///
/// Marked `@unchecked Sendable` because the compiled `NSRegularExpression`
/// values are built once in `init` and only ever read afterwards, and because
/// the Sendable annotation on `NSRegularExpression` varies between SDKs.
public struct CompiledGlob: @unchecked Sendable {
    public let patterns: [String]
    private let regexes: [NSRegularExpression]
    private let context: PathMatcher.Context
    private let matcher: PathMatcher

    init(patterns: [String], context: PathMatcher.Context, matcher: PathMatcher) {
        self.patterns = patterns
        self.context = context
        self.matcher = matcher
        let expanded = patterns.map { matcher.canonicalizePattern(matcher.expand($0, context: context)) }
        self.regexes = expanded.map { matcher.compile($0) }
    }

    /// Whether any pattern matches. `path` is standardised internally.
    public func matches(_ path: String) -> Bool {
        // Same standardisation as `PathMatcher.matches`, otherwise the two
        // entry points can disagree about `/private`-aliased paths.
        let std = matcher.standardize(path)
        let ns = NSRange(std.startIndex..., in: std)
        for r in regexes where r.firstMatch(in: std, range: ns) != nil {
            return true
        }
        return false
    }

    public var isEmpty: Bool { regexes.isEmpty }
    public var count: Int { regexes.count }
}
