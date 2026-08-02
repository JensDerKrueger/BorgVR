import Foundation

enum CommandResultCode: Int {
    case success = 0
    case finished
    case triggerLoop
    case waitingNoop
    case fileOpenFailed
    case unknownCommand
    case invalidArguments

    case unmatchedRepeat
    case unmatchedEndrepeat

    case unmatchedIf
    case unmatchedElse
    case unmatchedEndif

    case callbackError
}

extension CommandResultCode: CustomStringConvertible {
    var description: String {
        switch self {
        case .success: return "success"
        case .finished: return "finished"
        case .triggerLoop: return "triggerLoop"
        case .waitingNoop: return "waitingNoop"
        case .fileOpenFailed: return "fileOpenFailed"
        case .unknownCommand: return "unknownCommand"
        case .invalidArguments: return "invalidArguments"
        case .unmatchedRepeat: return "unmatchedRepeat"
        case .unmatchedEndrepeat: return "unmatchedEndrepeat"
        case .unmatchedIf: return "unmatchedIf"
        case .unmatchedElse: return "unmatchedElse"
        case .unmatchedEndif: return "unmatchedEndif"
        case .callbackError: return "callbackError"
        }
    }
}

enum ArgType {
    case int
    case int64
    case uint32
    case bool
    case float
    case double
    case string
    case restString
}

enum CommandArg {
    case int(Int)
    case int64(Int64)
    case uint32(UInt32)
    case bool(Bool)
    case float(Float)
    case double(Double)
    case string(String)
    case strings([String])
}

final class CommandInterpreter {
    typealias CommandCallback = ([CommandArg]) -> CommandResultCode
    typealias UnknownCommandCallback = (_ command: String, _ args: [String]) -> CommandResultCode

    private struct CommandOverload {
        let signature: [ArgType]
        let callback: CommandCallback?
    }

    private enum InstructionKind {
        case separator
        case command
        case repeatStart
        case repeatEnd
        case ifStart
        case ifElse
        case ifEnd
    }

    private struct Instruction {
        var kind: InstructionKind = .command
        var tokens: [String] = []
        var matchIndex: Int = -1
        var elseIndex: Int = -1
        var lineNumber: Int = 0
    }

    private struct LoopFrame {
        var startIndex: Int = 0
        var endIndex: Int = 0
        var remaining: Int64 = 0
        var iterationIndex: Int64 = 0
        var counterVarName: String = ""
        var savedCounterVar: String?
        var hadSavedCounterVar: Bool = false
    }

    private var commandMap: [String: [CommandOverload]] = [:]
    private var unknownCommandHandler: UnknownCommandCallback?

    private var instructions: [Instruction] = []
    private var instructionIndex: Int = 0

    private var noopActive = false
    private var noopUntil = Date()

    private var loopStack: [LoopFrame] = []
    private var variables: [String: String] = [:]

    private(set) var lastErrorLine: Int?

    init() {}

    @discardableResult
    func registerCommand(_ commandName: String,
                         _ signature: [ArgType],
                         _ callback: CommandCallback? = nil) -> CommandResultCode {
        let overload = CommandOverload(signature: signature, callback: callback)
        commandMap[commandName, default: []].append(overload)
        return .success
    }

    func setUnknownCommandHandler(_ callback: UnknownCommandCallback?) {
        unknownCommandHandler = callback
    }

    func loadFromFile(_ filePath: String) -> CommandResultCode {
        do {
            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            return loadFromString(content)
        } catch {
            return .fileOpenFailed
        }
    }

    func loadFromString(_ commands: String) -> CommandResultCode {
        let lines = commands.components(separatedBy: .newlines)
        return parseFromLines(lines)
    }

    func runBatch(validateOnly: Bool = false) -> CommandResultCode {
        if noopActive {
            if Date() < noopUntil {
                return .waitingNoop
            }
            noopActive = false
        }

        if instructionIndex >= instructions.count {
            return .finished
        }

        var executedAny = false

        while instructionIndex < instructions.count {
            let instruction = instructions[instructionIndex]

            if instruction.kind == .separator {
                instructionIndex += 1

                if !executedAny {
                    continue
                }

                var hasMoreCommands = false
                for i in instructionIndex..<instructions.count {
                    if instructions[i].kind != .separator {
                        hasMoreCommands = true
                        break
                    }
                }
                return hasMoreCommands ? .success : .finished
            }

            if instruction.kind == .ifStart {
                var condValue = false
                let ev = evalIfCondition(instruction, outValue: &condValue)
                if ev != .success {
                    lastErrorLine = instruction.lineNumber
                    return ev
                }

                if condValue {
                    instructionIndex += 1
                } else {
                    let skip = skipToAfterIfFalse(instructionIndex)
                    if skip != .success {
                        lastErrorLine = instruction.lineNumber
                        return skip
                    }
                }
                continue
            }

            if instruction.kind == .ifElse {
                if instruction.matchIndex == -1 {
                    lastErrorLine = instruction.lineNumber
                    return .invalidArguments
                }
                instructionIndex = instruction.matchIndex + 1
                continue
            }

            if instruction.kind == .ifEnd {
                instructionIndex += 1
                continue
            }

            if instruction.kind == .repeatStart {
                let t = instruction.tokens
                var hasCounter = false
                var counterToken = ""

                if t.count == 2 {
                    hasCounter = false
                } else if t.count == 4 && t[2] == "as" {
                    hasCounter = true
                    counterToken = t[3]
                } else {
                    lastErrorLine = instruction.lineNumber
                    return .invalidArguments
                }

                var countArg = [t[1]]
                let substCount = substituteVariablesInPlace(&countArg)
                if substCount != .success {
                    lastErrorLine = instruction.lineNumber
                    return substCount
                }

                guard let countOpt = parseLoopCount(countArg[0]), countOpt >= 0 else {
                    lastErrorLine = instruction.lineNumber
                    return .invalidArguments
                }
                let count = countOpt

                if count == 0 {
                    let skip = skipToAfterMatchingEndRepeat(instructionIndex)
                    if skip != .success {
                        lastErrorLine = instruction.lineNumber
                        return skip
                    }
                    continue
                }

                if instruction.matchIndex == -1 {
                    lastErrorLine = instruction.lineNumber
                    return .invalidArguments
                }

                var frame = LoopFrame()
                frame.startIndex = instructionIndex + 1
                frame.endIndex = instruction.matchIndex
                frame.remaining = count
                frame.iterationIndex = 0

                if hasCounter {
                    guard let nameOpt = extractVarName(counterToken), !nameOpt.isEmpty else {
                        lastErrorLine = instruction.lineNumber
                        return .invalidArguments
                    }
                    frame.counterVarName = nameOpt

                    if let prev = variables[frame.counterVarName] {
                        frame.savedCounterVar = prev
                        frame.hadSavedCounterVar = true
                    } else {
                        frame.savedCounterVar = nil
                        frame.hadSavedCounterVar = false
                    }

                    setVariable(frame.counterVarName, "0")
                }

                loopStack.append(frame)
                instructionIndex += 1
                continue
            }

            if instruction.kind == .repeatEnd {
                if loopStack.isEmpty {
                    lastErrorLine = instruction.lineNumber
                    return .invalidArguments
                }

                var frame = loopStack[loopStack.count - 1]
                if frame.endIndex != instructionIndex {
                    lastErrorLine = instruction.lineNumber
                    return .invalidArguments
                }

                frame.remaining -= 1

                if frame.remaining > 0 {
                    frame.iterationIndex += 1

                    if !frame.counterVarName.isEmpty {
                        setVariable(frame.counterVarName, String(frame.iterationIndex))
                    }

                    loopStack[loopStack.count - 1] = frame
                    instructionIndex = frame.startIndex
                } else {
                    if !frame.counterVarName.isEmpty {
                        if frame.hadSavedCounterVar, let saved = frame.savedCounterVar {
                            setVariable(frame.counterVarName, saved)
                        } else {
                            unsetVariable(frame.counterVarName)
                        }
                    }

                    loopStack.removeLast()
                    instructionIndex += 1
                }
                continue
            }

            executedAny = true

            if instruction.tokens.isEmpty {
                lastErrorLine = instruction.lineNumber
                return .invalidArguments
            }

            let command = instruction.tokens[0]
            var args = Array(instruction.tokens.dropFirst())

            let substArgs = substituteVariablesInPlace(&args)
            if substArgs != .success {
                lastErrorLine = instruction.lineNumber
                return substArgs
            }

            if command == "noop" {
                if args.count != 1 {
                    lastErrorLine = instruction.lineNumber
                    return .invalidArguments
                }

                if validateOnly {
                    instructionIndex += 1
                    continue
                }

                guard let milliseconds = Int64(args[0]) else {
                    lastErrorLine = instruction.lineNumber
                    return .invalidArguments
                }

                if milliseconds > 0 {
                    noopUntil = Date().addingTimeInterval(Double(milliseconds) / 1000.0)
                    noopActive = true
                    instructionIndex += 1
                    return .waitingNoop
                }

                instructionIndex += 1
                continue
            }

            if command == "set" {
                if args.count < 2 {
                    lastErrorLine = instruction.lineNumber
                    return .invalidArguments
                }

                let name = args[0]
                let rhs = Array(args.dropFirst())

                if rhs.count == 1 {
                    setVariable(name, rhs[0])
                } else {
                    var value: Int64 = 0
                    let ev = evalIntegerExpression(rhs, outValue: &value)
                    if ev != .success {
                        lastErrorLine = instruction.lineNumber
                        return ev
                    }
                    setVariable(name, String(value))
                }

                instructionIndex += 1
                continue
            }

            if command == "unset" {
                if args.count != 1 {
                    lastErrorLine = instruction.lineNumber
                    return .invalidArguments
                }
                unsetVariable(args[0])
                instructionIndex += 1
                continue
            }

            let result = executeCommand(command, args)
            if result != .success {
                lastErrorLine = instruction.lineNumber
                return result
            }

            instructionIndex += 1
        }

        return .finished
    }

    func reset() {
        instructions.removeAll()
        instructionIndex = 0
        noopActive = false
        loopStack.removeAll()
    }

    func getLastInstructionIndex() -> Int {
        instructionIndex
    }

    func setVariable(_ name: String, _ value: String) {
        variables[name] = value
    }

    func hasVariable(_ name: String) -> Bool {
        variables[name] != nil
    }

    func getVariable(_ name: String) -> String? {
        variables[name]
    }

    func unsetVariable(_ name: String) {
        variables.removeValue(forKey: name)
    }

    func clearVariables() {
        variables.removeAll()
    }

    private func executeCommand(_ command: String, _ args: [String]) -> CommandResultCode {
        guard let overloads = commandMap[command] else {
            if let unknown = unknownCommandHandler {
                return unknown(command, args)
            }
            return .unknownCommand
        }

        for overload in overloads {
            guard let parsed = parseArgs(args, signature: overload.signature) else {
                continue
            }
            if let callback = overload.callback {
                return callback(parsed)
            }
            return .success
        }

        return .invalidArguments
    }

    private func parseArgs(_ args: [String], signature: [ArgType]) -> [CommandArg]? {
        if signature.last == .restString {
            let fixedCount = signature.count - 1
            if args.count < fixedCount { return nil }
            var parsed: [CommandArg] = []
            for i in 0..<fixedCount {
                guard let arg = parseArg(args[i], type: signature[i]) else { return nil }
                parsed.append(arg)
            }
            let rest = Array(args.dropFirst(fixedCount))
            parsed.append(.strings(rest))
            return parsed
        } else {
            if args.count != signature.count { return nil }
            var parsed: [CommandArg] = []
            for (index, type) in signature.enumerated() {
                guard let arg = parseArg(args[index], type: type) else { return nil }
                parsed.append(arg)
            }
            return parsed
        }
    }

    private func parseArg(_ value: String, type: ArgType) -> CommandArg? {
        switch type {
        case .int:
            guard let v = Int(value) else { return nil }
            return .int(v)
        case .int64:
            guard let v = Int64(value) else { return nil }
            return .int64(v)
        case .uint32:
            guard let v = UInt32(value) else { return nil }
            return .uint32(v)
        case .bool:
            if value == "1" || value == "true" || value == "on" || value == "yes" { return .bool(true) }
            if value == "0" || value == "false" || value == "off" || value == "no" { return .bool(false) }
            return nil
        case .float:
            guard let v = Float(value) else { return nil }
            return .float(v)
        case .double:
            guard let v = Double(value) else { return nil }
            return .double(v)
        case .string:
            return .string(value)
        case .restString:
            return nil
        }
    }

    private func substituteVariablesInPlace(_ args: inout [String]) -> CommandResultCode {
        for index in args.indices {
            guard let replaced = substituteToken(args[index]) else {
                return .invalidArguments
            }
            args[index] = replaced
        }
        return .success
    }

    private func substituteToken(_ token: String) -> String? {
        if token.isEmpty { return token }
        if !token.contains("$") { return token }

        var result = ""
        var index = token.startIndex

        while index < token.endIndex {
            if token[index] != "$" {
                result.append(token[index])
                index = token.index(after: index)
                continue
            }

            let nextIndex = token.index(after: index)
            if nextIndex == token.endIndex {
                return nil
            }

            if token[nextIndex] == "$" {
                result.append("$")
                index = token.index(after: nextIndex)
                continue
            }

            if token[nextIndex] == "{" {
                guard let closingBrace = token[token.index(after: nextIndex)...].firstIndex(of: "}") else {
                    return nil
                }

                let nameStart = token.index(after: nextIndex)
                let name = String(token[nameStart..<closingBrace])
                guard let value = variables[name] else {
                    return nil
                }
                result.append(value)
                index = token.index(after: closingBrace)
                continue
            }

            var endIndex = nextIndex
            guard isVariableNameStart(token[endIndex]) else {
                return nil
            }

            endIndex = token.index(after: endIndex)
            while endIndex < token.endIndex, isVariableNameBody(token[endIndex]) {
                endIndex = token.index(after: endIndex)
            }

            let name = String(token[nextIndex..<endIndex])
            guard let value = variables[name] else {
                return nil
            }
            result.append(value)
            index = endIndex
        }

        return result
    }

    private func parseFromLines(_ lines: [String]) -> CommandResultCode {
        instructions.removeAll()
        instructionIndex = 0
        noopActive = false
        loopStack.removeAll()
        lastErrorLine = nil

        var lastWasSeparator = false

        for (idx, rawLine) in lines.enumerated() {
            let lineNumber = idx + 1
            var line = rawLine

            if let hashIndex = line.firstIndex(of: "#") {
                line = String(line[..<hashIndex])
            }

            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedLine.isEmpty {
                let hadHash = rawLine.contains("#")
                if !instructions.isEmpty && !lastWasSeparator && !hadHash {
                    var sep = Instruction()
                    sep.kind = .separator
                    sep.lineNumber = lineNumber
                    instructions.append(sep)
                    lastWasSeparator = true
                }
                continue
            }

            let tokens = tokenize(trimmedLine)
            if tokens.isEmpty { continue }

            var inst = Instruction()
            inst.lineNumber = lineNumber

            switch tokens[0] {
            case "repeat":
                inst.kind = .repeatStart
                inst.tokens = tokens
                instructions.append(inst)
                lastWasSeparator = false
                continue
            case "endrepeat":
                inst.kind = .repeatEnd
                inst.tokens = tokens
                instructions.append(inst)
                lastWasSeparator = false
                continue
            case "if":
                inst.kind = .ifStart
                inst.tokens = tokens
                instructions.append(inst)
                lastWasSeparator = false
                continue
            case "else":
                inst.kind = .ifElse
                inst.tokens = tokens
                instructions.append(inst)
                lastWasSeparator = false
                continue
            case "endif":
                inst.kind = .ifEnd
                inst.tokens = tokens
                instructions.append(inst)
                lastWasSeparator = false
                continue
            default:
                inst.kind = .command
                inst.tokens = tokens
                instructions.append(inst)
                lastWasSeparator = false
            }
        }

        let rep = buildRepeatPairing()
        if rep != .success { return rep }

        return buildIfPairing()
    }

    private func buildRepeatPairing() -> CommandResultCode {
        var stack: [Int] = []

        for i in 0..<instructions.count {
            if instructions[i].kind == .repeatStart {
                stack.append(i)
            } else if instructions[i].kind == .repeatEnd {
                if stack.isEmpty {
                    lastErrorLine = instructions[i].lineNumber
                    return .unmatchedEndrepeat
                }

                let startIdx = stack.removeLast()
                instructions[startIdx].matchIndex = i
                instructions[i].matchIndex = startIdx
            }
        }

        if let last = stack.last {
            lastErrorLine = instructions[last].lineNumber
            return .unmatchedRepeat
        }

        return .success
    }

    private func skipToAfterMatchingEndRepeat(_ repeatStartIndex: Int) -> CommandResultCode {
        guard repeatStartIndex < instructions.count else { return .invalidArguments }
        let inst = instructions[repeatStartIndex]
        guard inst.kind == .repeatStart else { return .invalidArguments }
        guard inst.matchIndex != -1 else { return .invalidArguments }

        instructionIndex = inst.matchIndex + 1
        return .success
    }

    private func buildIfPairing() -> CommandResultCode {
        var ifStack: [Int] = []

        for i in 0..<instructions.count {
            let inst = instructions[i]

            if inst.kind == .ifStart {
                ifStack.append(i)
                continue
            }

            if inst.kind == .ifElse {
                if ifStack.isEmpty {
                    lastErrorLine = inst.lineNumber
                    return .unmatchedElse
                }
                let ifIndex = ifStack.last!
                if instructions[ifIndex].elseIndex != -1 {
                    lastErrorLine = inst.lineNumber
                    return .invalidArguments
                }
                instructions[ifIndex].elseIndex = i
                continue
            }

            if inst.kind == .ifEnd {
                if ifStack.isEmpty {
                    lastErrorLine = inst.lineNumber
                    return .unmatchedEndif
                }

                let ifIdx = ifStack.removeLast()
                instructions[ifIdx].matchIndex = i
                instructions[i].matchIndex = ifIdx

                if instructions[ifIdx].elseIndex != -1 {
                    let elseIdx = instructions[ifIdx].elseIndex
                    instructions[elseIdx].matchIndex = i
                }
            }
        }

        if let last = ifStack.last {
            lastErrorLine = instructions[last].lineNumber
            return .unmatchedIf
        }

        return .success
    }

    private func skipToAfterMatchingEndif(_ ifStartIndex: Int) -> CommandResultCode {
        guard ifStartIndex < instructions.count else { return .invalidArguments }
        let inst = instructions[ifStartIndex]
        guard inst.kind == .ifStart else { return .invalidArguments }
        guard inst.matchIndex != -1 else { return .invalidArguments }

        instructionIndex = inst.matchIndex + 1
        return .success
    }

    private func skipToAfterIfFalse(_ ifStartIndex: Int) -> CommandResultCode {
        guard ifStartIndex < instructions.count else { return .invalidArguments }
        let inst = instructions[ifStartIndex]
        guard inst.kind == .ifStart else { return .invalidArguments }

        if inst.elseIndex != -1 {
            instructionIndex = inst.elseIndex + 1
            return .success
        }

        return skipToAfterMatchingEndif(ifStartIndex)
    }

    private func evalIfCondition(_ ifInst: Instruction, outValue: inout Bool) -> CommandResultCode {
        if ifInst.kind != .ifStart { return .invalidArguments }
        if ifInst.tokens.count < 2 { return .invalidArguments }

        var cond = Array(ifInst.tokens.dropFirst())
        let subst = substituteVariablesInPlace(&cond)
        if subst != .success { return subst }

        if cond.count == 1 {
            let v = cond[0]
            if let i = parseIntStrict(v) {
                outValue = (i != 0)
                return .success
            }

            if let b = parseBool(v) {
                outValue = b
                return .success
            }

            return .invalidArguments
        }

        if cond.count == 3 {
            let lhs = cond[0]
            let op = cond[1]
            let rhs = cond[2]

            if !isIfOp(op) { return .invalidArguments }

            let li = parseIntStrict(lhs)
            let ri = parseIntStrict(rhs)

            if let li = li, let ri = ri {
                switch op {
                case "==": outValue = li == ri
                case "!=": outValue = li != ri
                case "<": outValue = li < ri
                case "<=": outValue = li <= ri
                case ">": outValue = li > ri
                case ">=": outValue = li >= ri
                default: return .invalidArguments
                }
                return .success
            }

            if op == "==" {
                outValue = (lhs == rhs)
                return .success
            }
            if op == "!=" {
                outValue = (lhs != rhs)
                return .success
            }

            return .invalidArguments
        }

        return .invalidArguments
    }

    private func parseLoopCount(_ token: String) -> Int64? {
        parseIntStrict(token)
    }

    private func evalIntegerExpression(_ exprTokens: [String], outValue: inout Int64) -> CommandResultCode {
        if exprTokens.isEmpty { return .invalidArguments }

        var output: [String] = []
        var ops: [String] = []

        func flushOps(_ minPrec: Int) {
            while let last = ops.last, precedence(last) >= minPrec {
                output.append(last)
                ops.removeLast()
            }
        }

        for t in exprTokens {
            if isOpToken(t) {
                let p = precedence(t)
                flushOps(p)
                ops.append(t)
            } else {
                if parseIntStrict(t) == nil {
                    return .invalidArguments
                }
                output.append(t)
            }
        }

        while let last = ops.last {
            output.append(last)
            ops.removeLast()
        }

        var stack: [Int64] = []
        for t in output {
            if !isOpToken(t) {
                guard let v = parseIntStrict(t) else { return .invalidArguments }
                stack.append(v)
                continue
            }

            if stack.count < 2 { return .invalidArguments }
            let b = stack.removeLast()
            let a = stack.removeLast()

            guard let r = applyOp(a, b, t) else { return .invalidArguments }
            stack.append(r)
        }

        if stack.count != 1 { return .invalidArguments }
        outValue = stack[0]
        return .success
    }

    private func tokenize(_ line: String) -> [String] {
        line.split { $0.isWhitespace }.map(String.init)
    }

    private func parseIntStrict(_ s: String) -> Int64? {
        Int64(s)
    }

    private func parseBool(_ s: String) -> Bool? {
        if s == "1" || s == "true" || s == "on" || s == "yes" { return true }
        if s == "0" || s == "false" || s == "off" || s == "no" { return false }
        return nil
    }

    private func isOpToken(_ t: String) -> Bool {
        t == "+" || t == "-" || t == "*" || t == "/"
    }

    private func precedence(_ op: String) -> Int {
        if op == "*" || op == "/" { return 2 }
        if op == "+" || op == "-" { return 1 }
        return 0
    }

    private func applyOp(_ a: Int64, _ b: Int64, _ op: String) -> Int64? {
        switch op {
        case "+": return a + b
        case "-": return a - b
        case "*": return a * b
        case "/":
            if b == 0 { return nil }
            return a / b
        default:
            return nil
        }
    }

    private func extractVarName(_ token: String) -> String? {
        if token.isEmpty { return nil }
        if !token.hasPrefix("$") {
            return token
        }

        if token.count >= 2 && !token.dropFirst().hasPrefix("{") {
            return String(token.dropFirst())
        }

        if token.count >= 4, token.hasPrefix("${"), token.hasSuffix("}") {
            let start = token.index(token.startIndex, offsetBy: 2)
            let end = token.index(before: token.endIndex)
            return String(token[start..<end])
        }

        return nil
    }

    private func isVariableNameStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private func isVariableNameBody(_ character: Character) -> Bool {
        isVariableNameStart(character) || character.isNumber
    }

    private func isIfOp(_ op: String) -> Bool {
        return op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">="
    }
}


/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in the
 Software without restriction, including without limitation the rights to use, copy,
 modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
 to permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
