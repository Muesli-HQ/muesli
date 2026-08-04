import Foundation

/// Computes sunrise/sunset times from latitude/longitude using the NOAA solar
/// position algorithm (https://gml.noaa.gov/grad/solcalc/solareqns.PDF).
/// Pure and deterministic — no location services, no network access.
public enum SolarCalculator {
    /// Returns the UTC sunrise and sunset instants for the given day at the given
    /// coordinates. Returns nil for latitudes experiencing polar day/night on that date.
    public static func sunriseSunset(latitude: Double, longitude: Double, date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> (sunrise: Date, sunset: Date)? {
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let dayOfYear = Double(utcCalendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let latRad = latitude * .pi / 180

        let fractionalYear = 2 * .pi / 365 * (dayOfYear - 1)
        let eqTime = 229.18 * (0.000075
            + 0.001868 * cos(fractionalYear)
            - 0.032077 * sin(fractionalYear)
            - 0.014615 * cos(2 * fractionalYear)
            - 0.040849 * sin(2 * fractionalYear))
        let decl = 0.006918
            - 0.399912 * cos(fractionalYear)
            + 0.070257 * sin(fractionalYear)
            - 0.006758 * cos(2 * fractionalYear)
            + 0.000907 * sin(2 * fractionalYear)
            - 0.002697 * cos(3 * fractionalYear)
            + 0.00148 * sin(3 * fractionalYear)

        let zenith = 90.833 * .pi / 180
        let cosHourAngle = (cos(zenith) / (cos(latRad) * cos(decl))) - tan(latRad) * tan(decl)
        guard cosHourAngle >= -1, cosHourAngle <= 1 else {
            // Polar day (sun never sets) or polar night (sun never rises).
            return nil
        }
        let hourAngle = acos(cosHourAngle) * 180 / .pi

        let sunriseMinutesUTC = 720 - 4 * (longitude + hourAngle) - eqTime
        let sunsetMinutesUTC = 720 - 4 * (longitude - hourAngle) - eqTime

        guard let startOfDay = utcCalendar.date(bySettingHour: 0, minute: 0, second: 0, of: date) else {
            return nil
        }
        let sunrise = startOfDay.addingTimeInterval(sunriseMinutesUTC * 60)
        let sunset = startOfDay.addingTimeInterval(sunsetMinutesUTC * 60)
        return (sunrise, sunset)
    }

    /// True when `date` falls after sunset or before sunrise at the given coordinates.
    /// Defaults to `false` (daytime) for polar day/night edge cases rather than
    /// leaving the app stuck in one theme indefinitely.
    public static func isNight(latitude: Double, longitude: Double, date: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        guard let (sunrise, sunset) = sunriseSunset(latitude: latitude, longitude: longitude, date: date, calendar: calendar) else {
            return false
        }
        return date < sunrise || date >= sunset
    }
}
