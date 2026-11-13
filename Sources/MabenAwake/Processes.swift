import Darwin
import Foundation

extension ProcessTable {
    /// macOS's private `responsibility_get_pid_responsible_for_pid` (libquarantine,
    /// part of libSystem). It is what Activity Monitor and the privacy prompts use
    /// to tell which app a helper works for. nil if a future macOS drops it; then
    /// only child processes count as helpers, as before 1.7.
    private static let responsibleFor: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// The processes of the current user, right now.
    static func current() -> ProcessTable {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let uid = getuid()
        var entries: [pid_t: Entry] = [:]
        for pid in pids.prefix(max(0, count)) where pid > 1 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            let responsible = responsibleFor?(pid) ?? pid
            entries[pid] = Entry(parent: pid_t(info.pbi_ppid), responsible: responsible > 0 ? responsible : pid)
        }
        return ProcessTable(entries: entries)
    }
}
