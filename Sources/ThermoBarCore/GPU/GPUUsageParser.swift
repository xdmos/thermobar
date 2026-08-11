import Foundation

enum GPUUsageParser {
    static func maximumPercent(in accelerators: [[String: Any]], key: String) -> Double? {
        accelerators.compactMap { accelerator in
            percent(from: accelerator[key])
        }.max()
    }

    private static func percent(from value: Any?) -> Double? {
        guard let number = value as? NSNumber else {
            return nil
        }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }

        let percent = number.doubleValue
        guard percent.isFinite, (0 ... 100).contains(percent) else {
            return nil
        }
        return percent
    }
}
