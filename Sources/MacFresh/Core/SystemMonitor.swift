import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps
import Observation

struct BatteryInfo: Sendable {
    var percent: Double
    var charging: Bool
    var onAC: Bool
    var cycleCount: Int?
    var health: Double?  // max capacity / design capacity
    var timeRemaining: Int?  // minutes
}

struct ProcessUsage: Identifiable, Sendable {
    let pid: Int32
    let name: String
    let cpu: Double
    let memory: Int64
    var id: Int32 { pid }
}

@MainActor
@Observable
final class SystemMonitor {
    static let shared = SystemMonitor()

    var cpu: Double = 0
    var memoryUsed: Int64 = 0
    var memoryTotal: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    var memoryPressure: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    var diskTotal: Int64 = 0
    var diskFree: Int64 = 0
    var netIn: Double = 0
    var netOut: Double = 0
    var battery: BatteryInfo?
    var uptime: TimeInterval = 0
    var topProcesses: [ProcessUsage] = []

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var prevTicks: (used: UInt64, total: UInt64)?
    @ObservationIgnored private var prevNet: (inB: UInt64, outB: UInt64, at: Date)?
    @ObservationIgnored private var tick = 0

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var machineName: String { Host.current().localizedName ?? L("Mac") }

    var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return L("Apple Silicon") }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    func refresh() {
        cpu = readCPU()
        memoryUsed = readMemoryUsed()
        let d = FS.diskSpace()
        diskTotal = d.total
        diskFree = d.free
        readNetwork()
        uptime = ProcessInfo.processInfo.systemUptime
        tick += 1
        if tick % 5 == 1 { battery = Self.readBattery() }
        if tick % 3 == 1 {
            Task.detached(priority: .utility) {
                let procs = SystemMonitor.readTopProcesses(limit: 8)
                await MainActor.run { SystemMonitor.shared.topProcesses = procs }
            }
        }
    }

    // MARK: CPU

    private func readCPU() -> Double {
        var numCPUs: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &count) == KERN_SUCCESS,
              let info else { return cpu }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }
        var used: UInt64 = 0, total: UInt64 = 0
        for i in 0..<Int(numCPUs) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let sys = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            used += user + sys + nice
            total += user + sys + nice + idle
        }
        defer { prevTicks = (used, total) }
        guard let prev = prevTicks, total > prev.total else { return cpu }
        return min(1, Double(used &- prev.used) / Double(total - prev.total))
    }

    // MARK: Memory

    private func readMemoryUsed() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return memoryUsed }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return Int64(used)
    }

    // MARK: Network

    private func readNetwork() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return }
        defer { freeifaddrs(ifaddr) }
        var inB: UInt64 = 0, outB: UInt64 = 0
        var ptr = ifaddr
        while let p = ptr {
            let name = String(cString: p.pointee.ifa_name)
            if let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               !name.hasPrefix("lo"), !name.hasPrefix("utun"), !name.hasPrefix("awdl"),
               let data = p.pointee.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                inB += UInt64(d.ifi_ibytes)
                outB += UInt64(d.ifi_obytes)
            }
            ptr = p.pointee.ifa_next
        }
        let now = Date()
        if let prev = prevNet {
            let dt = now.timeIntervalSince(prev.at)
            if dt > 0 {
                netIn = inB >= prev.inB ? Double(inB - prev.inB) / dt : 0
                netOut = outB >= prev.outB ? Double(outB - prev.outB) / dt : 0
            }
        }
        prevNet = (inB, outB, now)
    }

    // MARK: Battery

    nonisolated static func readBattery() -> BatteryInfo? {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cap = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            var info = BatteryInfo(
                percent: max > 0 ? Double(cap) / Double(max) : 0,
                charging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                onAC: (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                cycleCount: nil, health: nil,
                timeRemaining: (desc[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil })
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func prop(_ k: String) -> Int? {
                    IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? Int
                }
                info.cycleCount = prop("CycleCount")
                if let design = prop("DesignCapacity"), design > 0,
                   let maxCap = prop("AppleRawMaxCapacity") ?? prop("NominalChargeCapacity") {
                    info.health = min(1, Double(maxCap) / Double(design))
                }
            }
            return info
        }
        return nil
    }

    // MARK: Processes

    nonisolated static func readTopProcesses(limit: Int) -> [ProcessUsage] {
        let r = Shell.run("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm=", "-r"])
        var out: [ProcessUsage] = []
        for line in r.output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
                  let rss = Int64(parts[2]) else { continue }
            if pid == 0 { continue }
            out.append(ProcessUsage(pid: pid, name: String(parts[3]), cpu: cpu, memory: rss * 1024))
            if out.count >= limit { break }
        }
        return out
    }

    nonisolated static func readTopMemoryProcesses(limit: Int) -> [ProcessUsage] {
        let r = Shell.run("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm=", "-m"])
        var out: [ProcessUsage] = []
        for line in r.output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
                  let rss = Int64(parts[2]) else { continue }
            if pid == 0 { continue }
            out.append(ProcessUsage(pid: pid, name: String(parts[3]), cpu: cpu, memory: rss * 1024))
            if out.count >= limit { break }
        }
        return out
    }
}
