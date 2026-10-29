public struct SpawnCmdArgs: CmdArgs, Equatable {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .spawn,
        help: spawn_help_generated,
        flags: [
            "--workspace": singleValueSubArgParser(\.workspace, "<workspace>", WorkspaceName.parse),
            "--pid": singleValueSubArgParser(\.pid, "<pid>") { raw in
                Int32(raw).flatMap { $0 > 1 ? $0 : nil }.toResult("Can't convert '\(raw)' to a process id")
            },
        ],
        posArgs: [ArgParser(\.command, parseSpawnedCommand, context: PosArgParserContext(argPlaceholderIfMandatory: nil))],
    )

    public var workspace: WorkspaceName? = nil
    public var pid: Int32? = nil
    /// Everything after `--`. Run by the CLI client, never sent to the server
    public var command: [String] = []
}

public func parseSpawnCmdArgs(_ args: StrArrSlice) -> ParsedCmd<SpawnCmdArgs> {
    parseSpecificCmdArgs(SpawnCmdArgs(rawArgs: args), args)
        .filter("Mandatory option is not specified (--workspace)") { $0.workspace != nil }
        .filter("Either '-- <command>' or '--pid <pid>' must be specified, but not both") { $0.command.isEmpty == ($0.pid != nil) }
}

private func parseSpawnedCommand(i: PosArgParserInput) -> ParsedCliArgs<[String]> {
    guard i.arg == "--" else { return .fail("Expected: --. Got: \(i.arg.singleQuoted)", advanceBy: 0) }
    let command = (i.index + 1 ..< i.args.count).map { i.args[$0] }
    return command.isEmpty
        ? .fail("'--' must be followed by '<command>'", advanceBy: 1)
        : .succ(command, advanceBy: i.args.count - i.index)
}
