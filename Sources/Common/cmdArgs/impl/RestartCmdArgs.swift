public struct RestartCmdArgs: CmdArgs, Equatable {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .restart,
        help: restart_help_generated,
        flags: [
            "--install": singleValueSubArgParser(\.installBundlePath, "<app-bundle>") { path in
                // The server doesn't know the working directory of the client
                path.starts(with: "/") ? .success(path) : .failure("<app-bundle> must be an absolute path")
            },
        ],
        posArgs: [],
    )

    public var installBundlePath: String? = nil
}
