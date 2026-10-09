import Foundation

struct WorkspaceSearchOptions: Equatable {
    var query = ""
    var caseSensitive = false
    var wholeWord = false
    var regex = false
    var includeIgnored = false
    var include = ""
    var exclude = ""

    var isEmpty: Bool { query.isEmpty }
}

struct WorkspaceSearchLine: Identifiable, Equatable {
    let number: Int
    let text: String
    /// UTF-16 ranges of matches within `text`; empty for context lines.
    let matches: [NSRange]
    var id: Int { number }
}

struct WorkspaceSearchFile: Identifiable, Equatable {
    let path: String
    /// Lines grouped into excerpts; each excerpt is a run of consecutive line numbers.
    let excerpts: [[WorkspaceSearchLine]]
    let matchCount: Int
    var id: String { path }
}

struct WorkspaceSearchResult: Equatable {
    let files: [WorkspaceSearchFile]
    let matchCount: Int
    let truncated: Bool
}

/// One match, addressed so Replace Next can find it again in the file.
struct WorkspaceSearchMatchRef: Hashable {
    let path: String
    let line: Int
    let occurrence: Int
}

enum WorkspaceSearch {
    static let contextLines = 2
    /// Output lines kept from the search tool, including context; mirrors Zed's ~10k match cap.
    static let maximumOutputLines = 40_000

    static func expression(for options: WorkspaceSearchOptions) throws -> NSRegularExpression {
        var pattern = options.regex ? options.query : NSRegularExpression.escapedPattern(for: options.query)
        if options.wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        do {
            return try NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw WorkspaceFileError.message("Invalid regular expression")
        }
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func search(_ options: WorkspaceSearchOptions, at location: WorkspaceFileLocation) throws -> WorkspaceSearchResult {
        let expression = try expression(for: options)
        let data = try WorkspaceFiles.shell(script(for: options), at: location, limit: 24_000_000)
        return parse(data, expression: expression)
    }

    // MARK: - Shell script

    /// Comma-separated globs; commas inside braces belong to the glob.
    static func globs(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        for character in value {
            switch character {
            case "{": depth += 1; current.append(character)
            case "}": depth = max(0, depth - 1); current.append(character)
            case "," where depth == 0:
                result.append(current)
                current = ""
            default: current.append(character)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.flatMap(expandBraces)
    }

    /// Expands `{a,b}` alternatives, which Git pathspecs do not understand.
    static func expandBraces(_ glob: String) -> [String] {
        guard let open = glob.firstIndex(of: "{"),
              let close = glob[open...].firstIndex(of: "}") else { return [glob] }
        let prefix = glob[..<open]
        let suffix = glob[glob.index(after: close)...]
        return glob[glob.index(after: open)..<close].split(separator: ",", omittingEmptySubsequences: false)
            .flatMap { expandBraces(String(prefix) + $0 + String(suffix)) }
    }

    /// A glob without a slash matches at any depth, like .gitignore.
    private static func pathspec(_ glob: String, exclude: Bool) -> String {
        let trimmed = glob.hasPrefix("/") ? String(glob.dropFirst()) : glob
        let anywhere = glob.contains("/") ? trimmed : "**/" + trimmed
        return exclude ? ":(exclude,glob)\(anywhere)" : ":(glob)\(anywhere)"
    }

    static func script(for options: WorkspaceSearchOptions) -> String {
        let q = WorkspaceFiles.quote
        var flags = ["-n", "-I", "-z", "-C", String(contextLines)]
        if !options.caseSensitive { flags.append("-i") }
        let include = globs(options.include)
        let exclude = globs(options.exclude)

        var gitFlags = ["--untracked"] + flags
        if options.includeIgnored { gitFlags.append("--no-exclude-standard") }
        let pathspecs = ["."] + include.map { pathspec($0, exclude: false) } + exclude.map { pathspec($0, exclude: true) }
        let specs = (include.isEmpty ? pathspecs : Array(pathspecs.dropFirst())).map(q).joined(separator: " ")
        // Word boundaries are applied by the expression, so the tool only prefilters lines.
        let pattern = q(options.query)
        let gitRegex = options.regex ? "-P" : "-F"

        var grepFlags = ["-r", "--null"] + flags.filter { $0 != "-z" } + [options.regex ? "-E" : "-F", "--exclude-dir=.git"]
        grepFlags += include.map { "--include=" + ($0 as NSString).lastPathComponent }
        grepFlags += exclude.map { "--exclude=" + ($0 as NSString).lastPathComponent }

        return """
        tmp=$(mktemp) || exit 3
        trap 'rm -f "$tmp" "$tmp.err"' EXIT
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          git grep \(gitFlags.map(q).joined(separator: " ")) \(gitRegex) -e \(pattern) -- \(specs) >"$tmp" 2>"$tmp.err"
          status=$?
          if [ "$status" -gt 1 ] && [ \(q(gitRegex)) = '-P' ] && grep -qi 'perl' "$tmp.err"; then
            git grep \(gitFlags.map(q).joined(separator: " ")) -E -e \(pattern) -- \(specs) >"$tmp" 2>"$tmp.err"
            status=$?
          fi
        else
          grep \(grepFlags.map(q).joined(separator: " ")) -e \(pattern) . >"$tmp" 2>"$tmp.err"
          status=$?
        fi
        if [ "$status" -gt 1 ]; then cat "$tmp.err" >&2; exit "$status"; fi
        wc -l < "$tmp" | tr -d ' '
        head -n \(maximumOutputLines) "$tmp"
        """
    }

    // MARK: - Parsing

    /// Parses `git grep -z` (path NUL line NUL text) and `grep --null` (path NUL line [:-] text).
    static func parse(_ data: Data, expression: NSRegularExpression) -> WorkspaceSearchResult {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        // The script prints the output line count first; skip anything SSH wrote before it.
        var total = 0
        while let first = lines.first {
            lines.removeFirst()
            if let count = Int(first.trimmingCharacters(in: .whitespaces)) { total = count; break }
        }

        var order: [String] = []
        var byPath: [String: [Int: String]] = [:]
        for record in lines where record != "--" && !record.isEmpty {
            guard let nul = record.firstIndex(of: "\0") else { continue }
            var path = String(record[..<nul])
            if path.hasPrefix("./") { path.removeFirst(2) }
            let rest = record[record.index(after: nul)...]
            let digits = rest.prefix { $0.isNumber }
            guard let number = Int(digits), digits.endIndex < rest.endIndex else { continue }
            let body = String(rest[rest.index(after: digits.endIndex)...])
            if byPath[path] == nil { order.append(path) }
            byPath[path, default: [:]][number] = body
        }

        var files: [WorkspaceSearchFile] = []
        var matchCount = 0
        for path in order {
            guard let numbered = byPath[path] else { continue }
            var excerpts: [[WorkspaceSearchLine]] = []
            var fileMatches = 0
            for number in numbered.keys.sorted() {
                let body = numbered[number] ?? ""
                let ranges = expression.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length))
                    .map(\.range).filter { $0.length > 0 }
                fileMatches += ranges.count
                let line = WorkspaceSearchLine(number: number, text: body, matches: ranges)
                if let last = excerpts.last?.last, last.number == number - 1 {
                    excerpts[excerpts.count - 1].append(line)
                } else {
                    excerpts.append([line])
                }
            }
            // Drop excerpts that only hold context, e.g. when the tool and the expression disagree.
            excerpts = excerpts.filter { $0.contains { !$0.matches.isEmpty } }
            guard fileMatches > 0 else { continue }
            files.append(WorkspaceSearchFile(path: path, excerpts: excerpts, matchCount: fileMatches))
            matchCount += fileMatches
        }
        return WorkspaceSearchResult(files: files, matchCount: matchCount,
                                     truncated: total > maximumOutputLines)
    }

    // MARK: - Replace

    /// Expands the replacement like Zed: `$1` captures and `\n`, `\t`, `\\` escapes in regex
    /// mode, literal text otherwise.
    static func template(_ replacement: String, regex: Bool) -> String {
        guard regex else { return NSRegularExpression.escapedTemplate(for: replacement) }
        var result = ""
        var iterator = replacement.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else { result.append(character); continue }
            switch iterator.next() {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "\\": result.append("\\\\")
            case let other?: result.append("\\"); result.append(other)
            case nil: result.append("\\\\")
            }
        }
        return result
    }

    /// Replaces every match in one file, or only `occurrence` on `line` (1-based) when given.
    /// Saving checks the version read here, so a file changed meanwhile is rejected.
    @discardableResult
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func replace(in path: String, options: WorkspaceSearchOptions, replacement: String,
                        only target: WorkspaceSearchMatchRef? = nil,
                        at location: WorkspaceFileLocation) throws -> Int {
        let expression = try expression(for: options)
        let contents = try WorkspaceFiles.read(path, at: location)
        let text = contents.text as NSString
        let template = template(replacement, regex: options.regex)
        var matches = expression.matches(in: contents.text, range: NSRange(location: 0, length: text.length))
            .filter { $0.range.length > 0 }
        if let target {
            guard let lineRange = range(ofLine: target.line, in: text) else {
                throw WorkspaceFileError.message("\(path) changed since the search; search again")
            }
            let onLine = matches.filter { NSLocationInRange($0.range.location, lineRange) }
            guard target.occurrence < onLine.count else {
                throw WorkspaceFileError.message("\(path) changed since the search; search again")
            }
            matches = [onLine[target.occurrence]]
        }
        guard !matches.isEmpty else { return 0 }
        let output = NSMutableString(string: contents.text)
        for match in matches.reversed() {
            let value = expression.replacementString(for: match, in: contents.text, offset: 0, template: template)
            output.replaceCharacters(in: match.range, with: value)
        }
        _ = try WorkspaceFiles.save(output as String, path: path, expectedVersion: contents.version, at: location)
        return matches.count
    }

    /// UTF-16 range of a 1-based line, excluding its newline.
    static func range(ofLine line: Int, in text: NSString) -> NSRange? {
        var current = 1
        var location = 0
        while current < line {
            let next = text.range(of: "\n", options: [], range: NSRange(location: location, length: text.length - location))
            guard next.location != NSNotFound else { return nil }
            location = next.location + 1
            current += 1
        }
        let end = text.range(of: "\n", options: [], range: NSRange(location: location, length: text.length - location))
        return NSRange(location: location, length: (end.location == NSNotFound ? text.length : end.location) - location)
    }
}
