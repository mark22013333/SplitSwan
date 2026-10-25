import Foundation
import Darwin

struct RootCallerIdentity: Equatable {
    let pid: pid_t
    let parent: pid_t
    let startedSeconds: Int
    let startedMicroseconds: Int

    static func read(_ pid: pid_t) -> Self? {
        var information = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, UInt32(query.count), &information, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride, information.kp_proc.p_pid == pid,
              Int32(information.kp_proc.p_stat) != SZOMB else { return nil }
        let started = information.kp_proc.p_un.__p_starttime
        return Self(pid: pid, parent: information.kp_eproc.e_ppid,
                    startedSeconds: Int(started.tv_sec), startedMicroseconds: Int(started.tv_usec))
    }
}

struct RootCallerChain {
    let identities: [RootCallerIdentity]

    init?(parent: pid_t, read: (pid_t) -> RootCallerIdentity?) {
        var next = parent
        var values: [RootCallerIdentity] = []
        while next > 1 {
            guard values.count < 32, !values.contains(where: { $0.pid == next }),
                  let identity = read(next) else { return nil }
            values.append(identity)
            next = identity.parent
        }
        guard next == 1, !values.isEmpty else { return nil }
        identities = values
    }

    func isAlive(read: (pid_t) -> RootCallerIdentity?) -> Bool {
        identities.allSatisfy { read($0.pid) == $0 }
    }
}

// Track kernel ancestry through sudo, including start times so PID reuse cannot adopt a new caller.
final class RootOperationLifetime: @unchecked Sendable {
    static let shared = RootOperationLifetime()
    private let mutex = NSLock()
    private var cancelled = false
    private var recovery = false
    private var deadline = Date().addingTimeInterval(105)
    private let caller = RootCallerChain(parent: getppid(), read: RootCallerIdentity.read)
    private var sources: [DispatchSourceSignal] = []

    func start() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                self?.mutex.lock(); self?.cancelled = true; self?.mutex.unlock()
            }
            source.resume(); sources.append(source)
        }
    }
    var shouldStop: Bool {
        mutex.lock(); defer { mutex.unlock() }
        return Date() >= deadline || (!recovery && (cancelled || caller?.isAlive(read: RootCallerIdentity.read) != true))
    }
    func beginRecovery() {
        mutex.lock(); defer { mutex.unlock() }
        if !recovery {
            recovery = true
            deadline = Date().addingTimeInterval(25)
        }
    }
}
