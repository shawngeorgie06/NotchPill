import Foundation

struct QuestionOptionChoice: Equatable, Identifiable {
    var id: String { "\(keycap)-\(label)" }
    let keycap: String
    let label: String
    let description: String?
    let isRecommended: Bool
    let keystroke: String
    let appendsReturn: Bool

    init(
        keycap: String,
        label: String,
        description: String? = nil,
        isRecommended: Bool = false,
        keystroke: String? = nil,
        appendsReturn: Bool = true
    ) {
        self.keycap = keycap
        self.label = label
        self.description = description
        self.isRecommended = isRecommended
        self.keystroke = keystroke ?? keycap
        self.appendsReturn = appendsReturn
    }

    var answer: AgentAnswer {
        AgentAnswer(label: label, keystroke: keystroke, appendsReturn: appendsReturn)
    }

    /// Plan "Revise" is not a keystroke — it opens the composer so the hook
    /// gets a reason rather than a bare `.ask` verdict.
    var opensPlanRevision: Bool { keystroke.lowercased() == "revise" }
}

struct ParsedQuestion: Equatable {
    let headline: String
    let options: [QuestionOptionChoice]
    let hasOther: Bool
}

enum QuestionParser {
    /// Parses a waiting alert into a structured question with options matching
    /// Fetch's mid-plan interactive format.
    static func parse(alert: DevReadyAlert) -> ParsedQuestion? {
        guard alert.kind == .waiting else { return nil }

        // 1. Permission requests (PreToolUse hook)
        if let request = alert.permissionRequest {
            if request.isPlan {
                return ParsedQuestion(
                    headline: "Review execution plan",
                    options: [
                        QuestionOptionChoice(
                            keycap: "1",
                            label: "Approve",
                            description: "Proceed with the suggested plan",
                            isRecommended: true,
                            keystroke: "allow"
                        ),
                        QuestionOptionChoice(
                            keycap: "2",
                            label: "Revise",
                            description: "Request plan adjustments",
                            isRecommended: false,
                            keystroke: "revise"
                        )
                    ],
                    hasOther: true
                )
            } else {
                return ParsedQuestion(
                    headline: request.summary,
                    options: [
                        QuestionOptionChoice(
                            keycap: "1",
                            label: "Allow",
                            description: "Grant permission for this action",
                            isRecommended: true,
                            keystroke: "allow"
                        ),
                        QuestionOptionChoice(
                            keycap: "2",
                            label: "Deny",
                            description: "Block execution",
                            isRecommended: false,
                            keystroke: "deny"
                        )
                    ],
                    hasOther: false
                )
            }
        }

        // 2. Questions with multi-line numbered options (e.g. Claude Code AskUser)
        if let rawText = alert.questionText, !rawText.isEmpty {
            if let parsed = parseNumberedList(rawText) {
                return parsed
            }
        }

        // 3. Explicit answers declared in answerSpec (e.g. Yes:y|No:n or choice labels)
        let answers = alert.answers
        if !answers.isEmpty {
            let headline = alert.questionText ?? alert.displayTitle
            var options: [QuestionOptionChoice] = []
            for (idx, ans) in answers.enumerated() {
                var label = ans.label
                var isRec = false
                if label.localizedCaseInsensitiveContains("(recommended)") {
                    isRec = true
                    label = label.replacingOccurrences(of: "(recommended)", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: .whitespaces)
                }
                let keycap: String
                if ans.keystroke.count == 1 {
                    keycap = ans.keystroke.uppercased()
                } else {
                    keycap = String(idx + 1)
                }
                options.append(QuestionOptionChoice(
                    keycap: keycap,
                    label: label,
                    description: nil,
                    isRecommended: isRec,
                    keystroke: ans.keystroke,
                    appendsReturn: ans.appendsReturn
                ))
            }
            return ParsedQuestion(
                headline: headline,
                options: options,
                hasOther: true
            )
        }

        // 4. Fallback question without predefined options
        if let question = alert.questionText {
            return ParsedQuestion(
                headline: question,
                options: [],
                hasOther: true
            )
        }

        return nil
    }

    private static func parseNumberedList(_ text: String) -> ParsedQuestion? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else { return nil }

        var headlineLines: [String] = []
        struct RawOpt {
            var num: String
            var title: String
            var isRec: Bool
            var desc: [String] = []
        }
        var rawOptions: [RawOpt] = []

        guard let pattern = try? NSRegularExpression(pattern: #"^([0-9]+)[\.\)]\s*(.+)$"#) else {
            return nil
        }

        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = pattern.firstMatch(in: line, range: range) {
                if let numRange = Range(match.range(at: 1), in: line),
                   let titleRange = Range(match.range(at: 2), in: line) {
                    let num = String(line[numRange])
                    var title = String(line[titleRange])
                    var isRec = false
                    if title.localizedCaseInsensitiveContains("(recommended)") {
                        isRec = true
                        title = title.replacingOccurrences(of: "(recommended)", with: "", options: .caseInsensitive)
                            .trimmingCharacters(in: .whitespaces)
                    }
                    rawOptions.append(RawOpt(num: num, title: title, isRec: isRec))
                    continue
                }
            }
            if !rawOptions.isEmpty {
                rawOptions[rawOptions.count - 1].desc.append(line)
            } else {
                headlineLines.append(line)
            }
        }

        guard !rawOptions.isEmpty else { return nil }

        let headline = headlineLines.isEmpty ? "Question" : headlineLines.joined(separator: " ")
        let options = rawOptions.map { opt in
            let desc = opt.desc.isEmpty ? nil : opt.desc.joined(separator: " ")
            return QuestionOptionChoice(
                keycap: opt.num,
                label: opt.title,
                description: desc,
                isRecommended: opt.isRec,
                keystroke: opt.num
            )
        }

        return ParsedQuestion(
            headline: headline,
            options: options,
            hasOther: true
        )
    }
}
