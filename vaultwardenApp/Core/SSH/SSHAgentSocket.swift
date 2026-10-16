#if os(macOS)
import Darwin
import Foundation

/// AF_UNIX only: no TCP listener and no private key storage.
nonisolated final class SSHAgentSocket: @unchecked Sendable {
    typealias Handler = @Sendable (Data) async -> Data
    private let queue = DispatchQueue(label: "Vaultwarden.SSHAgent.accept")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let clientLock = NSLock()
    private var clients: Set<Int32> = []
    private var listener: Int32 = -1
    private var lockFile: Int32 = -1
    private var source: DispatchSourceRead?
    private var ownedPath: String?
    private var socketIdentity: (device: dev_t, inode: ino_t)?
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
        queue.setSpecific(key: queueKey, value: true)
    }
    deinit { stop() }

    func start(at path: String) throws {
        try queue.sync {
            guard listener == -1, path.utf8.count < 104 else { throw SSHAgentError.unavailable }
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var metadata = stat()
            guard lstat(directory.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == geteuid(),
                  metadata.st_mode & 0o077 == 0 else { throw SSHAgentError.unavailable }
            let lockFD = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lockFD >= 0 else { throw SSHAgentError.unavailable }
            guard fstat(lockFD, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0,
                  flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                close(lockFD)
                throw SSHAgentError.unavailable
            }
            lockFile = lockFD
            do {
                try removeStaleSocket(at: path)
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { throw SSHAgentError.unavailable }
                listener = fd
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                var address = try Self.address(path)
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard result == 0 else { throw SSHAgentError.unavailable }
                ownedPath = path
                guard lstat(path, &metadata) == 0 else { throw SSHAgentError.unavailable }
                socketIdentity = (metadata.st_dev, metadata.st_ino)
                guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { throw SSHAgentError.unavailable }
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.acceptClients() }
                self.source = source
                source.resume()
            } catch {
                stopOnQueue()
                throw error
            }
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true { stopOnQueue() }
        else { queue.sync { stopOnQueue() } }
    }

    private func stopOnQueue() {
        source?.cancel()
        source = nil
        if listener >= 0 { close(listener); listener = -1 }
        clientLock.lock()
        for client in clients { shutdown(client, SHUT_RDWR) }
        clientLock.unlock()
        if let path = ownedPath, let identity = socketIdentity {
            var metadata = stat()
            if lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK,
               metadata.st_dev == identity.device, metadata.st_ino == identity.inode {
                unlink(path)
            }
        }
        ownedPath = nil
        socketIdentity = nil
        if lockFile >= 0 { close(lockFile); lockFile = -1 }
    }

    private func removeStaleSocket(at path: String) throws {
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            guard errno == ENOENT else { throw SSHAgentError.unavailable }
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFSOCK, metadata.st_uid == geteuid() else {
            throw SSHAgentError.unavailable
        }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw SSHAgentError.unavailable }
        defer { close(probe) }
        guard fcntl(probe, F_SETFL, O_NONBLOCK) >= 0 else { throw SSHAgentError.unavailable }
        var address = try Self.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result != 0, errno == ECONNREFUSED, unlink(path) == 0 else { throw SSHAgentError.unavailable }
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SSHAgentError.unavailable }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        return address
    }

    private func acceptClients() {
        while listener >= 0 {
            let client = accept(listener, nil, nil)
            if client < 0 { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); continue }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            _ = fcntl(client, F_SETFL, 0)
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            clientLock.lock()
            let allowed = clients.count < 8
            if allowed { clients.insert(client) }
            clientLock.unlock()
            guard allowed else { close(client); continue }
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            clientLock.lock()
            clients.remove(fd)
            close(fd)
            clientLock.unlock()
        }
        // Bound connection lifetime and outstanding work from untrusted local clients.
        for _ in 0..<128 {
            let readDeadline = DispatchTime.now() + 10
            guard let prefix = readExactly(4, from: fd, deadline: readDeadline) else { return }
            var reader = SSHWireReader(data: prefix)
            guard let count = try? reader.uint32(), count > 0,
                  count <= SSHAgentRequest.maximumFrameSize,
                  let request = readExactly(Int(count), from: fd, deadline: readDeadline) else { return }
            let result = ResponseBox()
            let completed = DispatchSemaphore(value: 0)
            let task = Task { [handler] in
                let response = await handler(request)
                result.set(response)
                completed.signal()
            }
            let deadline = DispatchTime.now() + 65
            var received = false
            while DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds {
                if completed.wait(timeout: .now() + 0.1) == .success { received = true; break }
                var descriptor = pollfd(fd: fd, events: Int16(POLLHUP | POLLERR), revents: 0)
                if poll(&descriptor, 1, 0) > 0, descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    task.cancel()
                    return
                }
            }
            guard received else { task.cancel(); return }
            let response = result.get()
            guard response.count <= SSHAgentRequest.maximumFrameSize,
                  writeAll(SSHWire.uint32(UInt32(response.count)) + response, to: fd) else { return }
        }
    }

    private func readExactly(_ count: Int, from fd: Int32, deadline: DispatchTime) -> Data? {
        var data = Data(count: count)
        let success = data.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < count {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline.uptimeNanoseconds else { return false }
                let remaining = Int32(min(10_000, (deadline.uptimeNanoseconds - now) / 1_000_000 + 1))
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, remaining)
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0, descriptor.revents & Int16(POLLIN) != 0 else { return false }
                let result = recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return false }
                offset += result
            }
            return true
        }
        return success ? data : nil
    }
    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let result = send(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return false }
                offset += result
            }
            return true
        }
    }
}

private nonisolated final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = SSHAgentRequest.failure
    func set(_ value: Data) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
}
#endif
