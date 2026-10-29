import Foundation
import os

/// Times switches between the window's views (Notes → Calendar, …): wall-clock and CPU time until the new view is on
/// screen, and the app's memory after. Each switch is an interval in Instruments' Points of Interest and a log line:
///   log stream --predicate 'subsystem == "com.memorynotes.app" AND category == "perf"'
@MainActor
enum Perf {
    private static let log = Logger(subsystem: "com.memorynotes.app", category: "perf")
    private static let signposter = OSSignposter(subsystem: "com.memorynotes.app", category: .pointsOfInterest)
    private static var running: (name: String, interval: OSSignpostIntervalState, wall: UInt64, cpu: UInt64)?

    static func begin(_ name: String) {
        if let running { signposter.endInterval("Switch", running.interval) }  // a newer switch replaces it
        running = (name, signposter.beginInterval("Switch", id: signposter.makeSignpostID(), "\(name, privacy: .public)"),
                   clock_gettime_nsec_np(CLOCK_UPTIME_RAW), clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID))
    }

    /// From the new view's onAppear. The next main-queue turn comes after SwiftUI has laid it out and committed it.
    static func end() {
        DispatchQueue.main.async {
            guard let r = running else { return }
            running = nil
            signposter.endInterval("Switch", r.interval)
            let wall = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - r.wall) / 1e6
            let cpu = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - r.cpu) / 1e6  // all threads
            log.notice("\(r.name, privacy: .public): \(wall, format: .fixed(precision: 0)) ms, CPU \(cpu, format: .fixed(precision: 0)) ms, memory \(footprintMB) MB")
        }
    }

    /// What Activity Monitor shows as the app's Memory.
    private static var footprintMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : -1
    }
}
