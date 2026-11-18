import Foundation
import PhotoPartKit
import SketchCore

extension PhotoPartError {
    /// User-facing text; pin/bus cases look the pin's name up in `draft` when it carries an id.
    func message(in draft: PhotoPartDraft? = nil) -> String {
        func pinName(_ id: String) -> String {
            let name = draft?.pins.first(where: { $0.id == id })?.name ?? ""
            return name.trimmingCharacters(in: .whitespaces).isEmpty ? id : name
        }
        switch self {
        case .undecodableImage: return "The photo or its saved studio data can't be read."
        case .emptyMask: return "Nothing is selected. Keep at least part of the photo."
        case .traceTooShort: return "The outline is too short. Draw around the whole part."
        case .missingScale: return "Set the scale: mark two points or enter the overall width."
        case .calibrationTooShort: return "The two scale points are too close together. Place them further apart."
        case .invalidDistance: return "Enter a distance greater than 0 mm."
        case .partTooLarge:
            return "The part is larger than \(Int(PartDefinition.maxExtent)) mm. Check the scale."
        case .pinOutside(let name): return "Pin \(name) is outside the part."
        case .emptyPinName(let id):
            guard let i = draft?.pins.firstIndex(where: { $0.id == id }) else { return "A pin has no name." }
            return "Pin \(i + 1) has no name."
        case .duplicatePinName(let name): return "More than one pin is named \(name)."
        case .unknownBusMember(let id): return "A bus refers to a missing pin (\(id))."
        case .pinInTwoBuses(let id): return "Pin \(pinName(id)) is in more than one bus."
        case .emptyTitle: return "Give the part a title in Details."
        case .maskSizeMismatch: return "The saved cutout doesn't match the photo."
        case .cutoutUnavailable: return "Automatic cutout isn't available on this device."
        case .noForeground: return "No part was found in the photo."
        }
    }
}

extension StudioStep {
    var title: String {
        switch self {
        case .cutout: "Cutout"
        case .refine: "Refine"
        case .crop: "Crop"
        case .scale: "Scale"
        case .pins: "Pins"
        case .details: "Details"
        }
    }
}

extension PinRole {
    /// `PinRole` is not `CaseIterable`; picker order.
    static let pickerCases: [PinRole] = [.power, .ground, .digital, .analog, .i2cSDA, .i2cSCL, .spi, .uart, .other]

    var title: String {
        switch self {
        case .power: "Power"
        case .ground: "Ground"
        case .digital: "Digital"
        case .analog: "Analog"
        case .i2cSDA: "I²C SDA"
        case .i2cSCL: "I²C SCL"
        case .spi: "SPI"
        case .uart: "UART"
        case .other: "Other"
        }
    }
}

extension ConnectorKind {
    static let pickerCases: [ConnectorKind] = [.male, .female, .pad]

    var title: String {
        switch self {
        case .male: "Male"
        case .female: "Female"
        case .pad: "Pad"
        }
    }
}

extension PhotoPartDraft {
    /// Per-pin problem text keyed by pin id (outside the part, missing/duplicate name, in two buses).
    func pinIssues() -> [String: String] {
        let out = outputSize(), eps = 1e-6
        var nameCounts: [String: Int] = [:]
        for pin in pins { nameCounts[pin.trimmedName.lowercased(), default: 0] += 1 }
        var busCounts: [String: Int] = [:]
        for bus in buses { for id in bus { busCounts[id, default: 0] += 1 } }
        var issues: [String: String] = [:]
        for pin in pins {
            let p = toOutput(pin.position)
            let name = pin.trimmedName
            if !(p.x >= -eps && p.y >= -eps && p.x <= out.x + eps && p.y <= out.y + eps) {
                issues[pin.id] = "Outside the part"
            } else if name.isEmpty {
                issues[pin.id] = "Needs a name"
            } else if nameCounts[name.lowercased(), default: 0] > 1 {
                issues[pin.id] = "Duplicate name"
            } else if busCounts[pin.id, default: 0] > 1 {
                issues[pin.id] = "In more than one bus"
            }
        }
        return issues
    }
}

extension DraftPin {
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}
