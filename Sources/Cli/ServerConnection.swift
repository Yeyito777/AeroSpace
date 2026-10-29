import Common
import Darwin
import Foundation

/// Blocking client side of the server socket protocol (see NWConnectionEx.swift for the server side).
/// NWConnection needs ~20 ms to become ready, which is most of the time of a short command
final class ServerConnection {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    deinit { close(fd) }

    static func connect(path: String) -> Result<ServerConnection, ConnectionError> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return .failure(.posix(errno)) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC) // `aerospace spawn` execs the command
        let connection = ServerConnection(fd: fd)
        var noSigPipe: Int32 = 1
        if unsafe setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            return .failure(.posix(errno))
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        if pathBytes.count > MemoryLayout.size(ofValue: addr.sun_path) {
            return .failure(.pathTooLong(path))
        }
        unsafe withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            unsafe pathBytes.withUnsafeBytes { src in unsafe dst.copyMemory(from: src) }
        }
        let result = unsafe withUnsafePointer(to: &addr) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                unsafe Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 { return .failure(.posix(errno)) }
        return .success(connection)
    }

    /// The pid of the server process
    var peerPid: pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        return unsafe getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 ? pid : nil
    }

    /// Same handshake as NWConnection.initConnection
    func initConnection() -> ConnectionError? {
        if let error = writeUInt32(SOCKET_PROTOCOL_VERSION) { return error }
        switch readUInt32() {
            case .success(let serverVersion) where serverVersion != SOCKET_PROTOCOL_VERSION:
                return .incompatibleServer(
                    """
                    Client SOCKET_PROTOCOL_VERSION: \(SOCKET_PROTOCOL_VERSION)
                    Server SOCKET_PROTOCOL_VERSION: \(serverVersion)

                    The client and server versions are incompatible. (Potential fix: restart AeroSpace)
                    """,
                )
            case .success: return nil
            case .failure(let error): return error
        }
    }

    func writeAtomic(_ msg: Codable) -> ConnectionError? {
        let payload = Result { try JSONEncoder().encode(msg) }.getOrDie()
        var data = unsafe withUnsafeBytes(of: UInt32(payload.count)) { pointer in unsafe Data(pointer) }
        data.append(payload)
        return write(data)
    }

    func readNonAtomic() -> Result<Data, ConnectionError> {
        readUInt32().flatMap { read(bytes: Int($0)) }
    }

    private func writeUInt32(_ int: UInt32) -> ConnectionError? {
        write(unsafe withUnsafeBytes(of: int) { pointer in unsafe Data(pointer) })
    }

    private func readUInt32() -> Result<UInt32, ConnectionError> {
        read(bytes: 4).map { data in
            unsafe data.withUnsafeBytes { pointer in unsafe pointer.loadUnaligned(as: UInt32.self) }
        }
    }

    private func write(_ data: Data) -> ConnectionError? {
        var offset = 0
        while offset < data.count {
            let written = unsafe data.withUnsafeBytes { pointer in
                unsafe Darwin.write(fd, pointer.baseAddress.orDie().advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return .posix(errno)
            }
            offset += written
        }
        return nil
    }

    private func read(bytes size: Int) -> Result<Data, ConnectionError> {
        var data = Data(count: size)
        var offset = 0
        while offset < size {
            let count = unsafe data.withUnsafeMutableBytes { pointer in
                unsafe Darwin.read(fd, pointer.baseAddress.orDie().advanced(by: offset), size - offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(.posix(errno))
            }
            if count == 0 { return .failure(.closedByServer) }
            offset += count
        }
        return .success(data)
    }

    enum ConnectionError: Error, CustomStringConvertible {
        case posix(Int32)
        case closedByServer
        case pathTooLong(String)
        case incompatibleServer(String)

        var description: String {
            switch self {
                case .posix(let code): unsafe String(cString: strerror(code))
                case .closedByServer: "Connection closed by the server"
                case .pathTooLong(let path): "Socket path is too long: \(path)"
                case .incompatibleServer(let msg): msg
            }
        }
    }
}
