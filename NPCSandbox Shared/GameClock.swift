import Foundation

class GameClock {
    private(set) var hour: Int
    private(set) var minute: Int
    var minutesPerSecond: Double = 30.0

    private var accumulator: TimeInterval = 0

    var timeString: String {
        String(format: "%02d:%02d", hour, minute)
    }

    var totalMinutes: Int {
        hour * 60 + minute
    }

    init(hour: Int = 6, minute: Int = 0) {
        self.hour = hour
        self.minute = minute
    }

    @discardableResult
    func advance(by dt: TimeInterval) -> Bool {
        accumulator += dt * minutesPerSecond
        var ticked = false
        while accumulator >= 1.0 {
            accumulator -= 1.0
            minute += 1
            if minute >= 60 {
                minute = 0
                hour += 1
                if hour >= 24 {
                    hour = 0
                }
            }
            ticked = true
        }
        return ticked
    }
}
