import Foundation

// Pull history off the band: per-minute activity (steps, heart rate, SpO2) and sleep. Both use
// the same pattern: ask how many records cover [start, end], then fetch them one by one. Nothing
// is acknowledged or deleted on the band. Port of openband/sync.py, plus the post-auth reads the
// CLI does.

struct HuaweiHistory: Equatable {
    var minutes: [HuaweiMinuteSample] = []
    var sleep: [HuaweiSleepSpan] = []
    var errors: [String] = []
}

struct HuaweiDeviceDetails: Equatable {
    var product: HuaweiProductInfo
    var battery: Int
}

@MainActor
func huaweiFetchHistory(_ channel: HuaweiChannel, start: Date, end: Date,
                        progress: ((String, Int) -> Void)? = nil) async throws -> HuaweiHistory {
    var h = HuaweiHistory()
    let from = Int(start.timeIntervalSince1970), to = Int(end.timeIntervalSince1970)

    try await huaweiRecords(channel, count: HuaweiCommands.stepCountID, data: HuaweiCommands.stepDataID,
                            start: from, end: to, history: &h) { t, index, h in
        let r = try HuaweiCommands.parseStepData(t)
        if r.number != index { h.errors.append("asked for activity record \(index), got \(r.number)") }
        h.errors += r.problems
        h.minutes += r.samples
        progress?("activity", h.minutes.count)
    }
    try await huaweiRecords(channel, count: HuaweiCommands.sleepCountID, data: HuaweiCommands.sleepDataID,
                            start: from, end: to, history: &h) { t, index, h in
        let r = try HuaweiCommands.parseSleepData(t)
        if r.number != index { h.errors.append("asked for sleep record \(index), got \(r.number)") }
        h.sleep += r.spans
        progress?("sleep", h.sleep.count)
    }
    h.minutes.sort { $0.timestamp < $1.timestamp }
    h.sleep.sort { $0.start < $1.start }
    return h
}

@MainActor
private func huaweiRecords(_ channel: HuaweiChannel, count countCommand: UInt8, data dataCommand: UInt8, start: Int, end: Int,
                           history h: inout HuaweiHistory,
                           each: (HuaweiTLV, Int, inout HuaweiHistory) throws -> Void) async throws {
    let count: Int
    do {
        count = try HuaweiCommands.parseMessageCount(try await channel.request(
            HuaweiCommands.messageCount(command: countCommand, start: start, end: end)))
    } catch let HuaweiError.refused(id, code) {
        // The band refuses the count when it has no records in the window.
        channel.onLog?("no records for \(id): error \(code)")
        return
    }
    channel.onLog?(String(format: "%d records for %02x", count, countCommand))
    for i in 0 ..< count {
        let t = try await channel.request(HuaweiCommands.messageData(command: dataCommand, index: i))
        try each(t, i, &h)
    }
}

/// Product info and battery, the first encrypted reads after auth.
@MainActor
func huaweiAfterAuth(_ channel: HuaweiChannel) async throws -> HuaweiDeviceDetails {
    let product = HuaweiCommands.parseProductInfo(try await channel.request(HuaweiCommands.productInfo()))
    let battery = try HuaweiCommands.parseBattery(try await channel.request(HuaweiCommands.battery()))
    return HuaweiDeviceDetails(product: product, battery: battery)
}

@MainActor
func huaweiSetTime(_ channel: HuaweiChannel, now: Date = Date(), timeZone: TimeZone = .current) async throws {
    _ = try await channel.request(HuaweiCommands.setTime(now, timeZone: timeZone))
}

@MainActor
func huaweiFitnessTotals(_ channel: HuaweiChannel) async throws -> HuaweiTotals {
    try HuaweiCommands.parseFitnessTotals(try await channel.request(HuaweiCommands.fitnessTotals()))
}
