import XCTest
@testable import NotificationTicker

final class QuietHoursScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testOvernightScheduleIncludesLateNightAndEarlyMorning() {
        let schedule = QuietHoursSchedule(startMinutes: 23 * 60, endMinutes: 7 * 60)

        XCTAssertTrue(schedule.contains(date(hour: 23, minute: 30), calendar: calendar))
        XCTAssertTrue(schedule.contains(date(hour: 6, minute: 59), calendar: calendar))
        XCTAssertFalse(schedule.contains(date(hour: 7, minute: 0), calendar: calendar))
        XCTAssertFalse(schedule.contains(date(hour: 12, minute: 0), calendar: calendar))
    }

    func testSameDayScheduleUsesExclusiveEndTime() {
        let schedule = QuietHoursSchedule(startMinutes: 13 * 60, endMinutes: 15 * 60 + 30)

        XCTAssertFalse(schedule.contains(date(hour: 12, minute: 59), calendar: calendar))
        XCTAssertTrue(schedule.contains(date(hour: 13, minute: 0), calendar: calendar))
        XCTAssertTrue(schedule.contains(date(hour: 15, minute: 29), calendar: calendar))
        XCTAssertFalse(schedule.contains(date(hour: 15, minute: 30), calendar: calendar))
    }

    func testEqualStartAndEndMeansAllDayQuiet() {
        let schedule = QuietHoursSchedule(startMinutes: 8 * 60, endMinutes: 8 * 60)

        XCTAssertTrue(schedule.contains(date(hour: 0, minute: 0), calendar: calendar))
        XCTAssertTrue(schedule.contains(date(hour: 12, minute: 0), calendar: calendar))
    }

    private func date(hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 21, hour: hour, minute: minute))!
    }
}
