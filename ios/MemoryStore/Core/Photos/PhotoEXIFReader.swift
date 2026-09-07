import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PhotoEXIFInfo: Equatable {
    var takenAt: Date?
    var placeName: String?
    var cameraMake: String?
    var cameraModel: String?
    var focalLengthMM: Double?
    var aperture: Double?
    var shutterSeconds: Double?
    var iso: Int?

    var cameraLine: String? {
        let make = (cameraMake ?? "").trimmingCharacters(in: .whitespaces)
        let model = (cameraModel ?? "").trimmingCharacters(in: .whitespaces)
        if make.isEmpty && model.isEmpty { return nil }
        if model.lowercased().contains(make.lowercased()), !make.isEmpty {
            return model
        }
        return [make, model].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var exposureLine: String? {
        var parts: [String] = []
        if let f = focalLengthMM { parts.append(String(format: "%.0fmm", f)) }
        if let a = aperture { parts.append(String(format: "F%.1f", a)) }
        if let s = shutterSeconds {
            if s >= 1 { parts.append(String(format: "%.1fs", s)) }
            else { parts.append("1/\(max(1, Int((1.0 / s).rounded())))s") }
        }
        if let iso { parts.append("ISO\(iso)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}

enum PhotoEXIFReader {
    static func read(from data: Data) -> PhotoEXIFInfo {
        var info = PhotoEXIFInfo()
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return info }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return info }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                info.takenAt = parseExifDate(dateStr)
            }
            if let f = exif[kCGImagePropertyExifFocalLength] as? Double { info.focalLengthMM = f }
            if let a = exif[kCGImagePropertyExifFNumber] as? Double { info.aperture = a }
            if let s = exif[kCGImagePropertyExifExposureTime] as? Double { info.shutterSeconds = s }
            if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoArr.first {
                info.iso = iso
            }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            info.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
            info.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
            if info.takenAt == nil, let dateStr = tiff[kCGImagePropertyTIFFDateTime] as? String {
                info.takenAt = parseExifDate(dateStr)
            }
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            // keep place empty; GPS reverse geocode is optional / heavy — use server place_name
            _ = gps
        }
        return info
    }

    private static func parseExifDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }
}
