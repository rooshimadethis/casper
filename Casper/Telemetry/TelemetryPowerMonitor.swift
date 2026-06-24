import Foundation
import IOKit
import IOKit.ps

/// Protocol definition to decouple power and idle monitoring for testing.
protocol TelemetryPowerMonitoring: Sendable {
    func isUserIdle(threshold: TimeInterval?) -> Bool
    var isConnectedToACPower: Bool { get }
}

/// Monitors system-wide idle state and AC power connection status on macOS.
final class TelemetryPowerMonitor: TelemetryPowerMonitoring {
    
    /// Default idle duration of 10 minutes (600 seconds).
    private let defaultIdleThreshold: TimeInterval = 600.0

    /// Returns the system-wide idle time (in seconds) since the last keyboard or mouse event.
    var systemIdleTime: TimeInterval {
        var idleTime: TimeInterval = 0
        var iterator: io_iterator_t = 0
        // Use 0 as default master port/main port for compatibility
        let result = IOServiceGetMatchingServices(0, IOServiceMatching("IOHIDSystem"), &iterator)
        if result == kIOReturnSuccess {
            let service = io_iterator_t(IOIteratorNext(iterator))
            if service != 0 {
                var properties: Unmanaged<CFMutableDictionary>?
                let propResult = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
                if propResult == kIOReturnSuccess, let props = properties?.takeRetainedValue() as? [String: Any] {
                    if let idleTimeNanoseconds = props["HIDIdleTime"] as? UInt64 {
                        idleTime = TimeInterval(idleTimeNanoseconds) / 1_000_000_000.0
                    }
                }
                IOObjectRelease(service)
            }
            IOObjectRelease(iterator)
        }
        return idleTime
    }

    /// Checks if the user is currently considered idle based on the specified threshold.
    func isUserIdle(threshold: TimeInterval? = nil) -> Bool {
        let activeThreshold = threshold ?? defaultIdleThreshold
        return systemIdleTime >= activeThreshold
    }

    /// Checks if the device is currently connected to AC power (charger plugged in).
    var isConnectedToACPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let powerSourceState = description[kIOPSPowerSourceStateKey] as? String {
                if powerSourceState == kIOPSACPowerValue {
                    return true
                }
            }
        }
        return false
    }
}
