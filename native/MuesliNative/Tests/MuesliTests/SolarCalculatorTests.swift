import Testing
import Foundation
import MuesliCore

@Suite("SolarCalculator")
struct SolarCalculatorTests {

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    @Test("sunrise/sunset at the equator/prime-meridian equinox land near 06:00/18:00 UTC")
    func equatorEquinoxIsSelfVerifying() {
        // At lat=0, lon=0, near an equinox: day length is ~12h and local solar time
        // is ~UTC, so sunrise/sunset should be within a few minutes of 06:00/18:00 UTC
        // regardless of longitude sign convention — this doesn't depend on memorized
        // real-world sunrise times for any particular city/date.
        let date = utcDate(2026, 3, 20, 12, 0)
        let result = SolarCalculator.sunriseSunset(latitude: 0, longitude: 0, date: date)
        #expect(result != nil)
        guard let (sunrise, sunset) = result else { return }
        let startOfDay = utcDate(2026, 3, 20, 0, 0)
        let sunriseMinutes = sunrise.timeIntervalSince(startOfDay) / 60
        let sunsetMinutes = sunset.timeIntervalSince(startOfDay) / 60
        #expect(abs(sunriseMinutes - 360) < 20) // ~06:00 UTC
        #expect(abs(sunsetMinutes - 1080) < 20) // ~18:00 UTC
        #expect(sunset > sunrise)
    }

    @Test("further west sunrise/sunset occur later in UTC")
    func longitudeSignConvention() {
        // A location further west (more negative longitude, standard geographic
        // convention) should see the sun rise and set later in UTC clock time.
        let date = utcDate(2026, 3, 20, 12, 0)
        guard let greenwich = SolarCalculator.sunriseSunset(latitude: 0, longitude: 0, date: date),
              let west = SolarCalculator.sunriseSunset(latitude: 0, longitude: -90, date: date) else {
            Issue.record("expected sunrise/sunset to resolve")
            return
        }
        #expect(west.sunrise > greenwich.sunrise)
        #expect(west.sunset > greenwich.sunset)
    }

    @Test("midday is never night")
    func middayIsDaytime() {
        let midday = utcDate(2026, 3, 15, 20, 0) // ~noon PDT
        #expect(SolarCalculator.isNight(latitude: 37.7749, longitude: -122.4194, date: midday) == false)
    }

    @Test("midnight is night away from polar extremes")
    func midnightIsNight() {
        let midnight = utcDate(2026, 3, 15, 8, 0) // ~midnight PDT
        #expect(SolarCalculator.isNight(latitude: 37.7749, longitude: -122.4194, date: midnight) == true)
    }

    @Test("polar day at the pole never registers as night")
    func polarDayDefaultsToFalse() {
        let summerAtPole = utcDate(2026, 6, 21, 12, 0)
        #expect(SolarCalculator.isNight(latitude: 89.9, longitude: 0, date: summerAtPole) == false)
    }
}
