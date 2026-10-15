import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(os)
import os
#endif

/// How much memory the app is using and how much iOS will still allow it, for the log. iOS ends
/// an app that passes its allowance without warning, so the numbers next to a memory warning
/// say how close that was.
public enum MemoryUse {
    /// The app's physical footprint in megabytes (what iOS counts), or nil where it can't be read.
    public static var footprintMB: Int? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
        #else
        return nil
        #endif
    }

    /// Megabytes the app may still use before iOS ends it, or nil where it can't be read.
    public static var remainingMB: Int? {
        #if os(iOS)
        return Int(os_proc_available_memory() / 1_048_576)
        #else
        return nil
        #endif
    }

    /// "using 4120 MB, 1880 MB left" or as much of that as can be read.
    public static var summary: String {
        var parts: [String] = []
        if let used = footprintMB { parts.append("using \(used) MB") }
        if let left = remainingMB { parts.append("\(left) MB left") }
        return parts.isEmpty ? "memory unknown" : parts.joined(separator: ", ")
    }
}
