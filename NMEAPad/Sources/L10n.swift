import Foundation
import NMEACore

func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return arguments.isEmpty ? format : String(format: format, locale: Locale.current, arguments: arguments)
}

extension FixQuality {
    var localizedLabel: String {
        switch self {
        case .invalid: return L("fix.invalid")
        case .gps: return L("fix.gps")
        case .differential: return L("fix.dgps")
        case .pps: return L("fix.pps")
        case .rtkFixed: return L("fix.rtk_fixed")
        case .rtkFloat: return L("fix.rtk_float")
        case .estimated: return L("fix.estimated")
        case .manual: return L("fix.manual")
        case .simulation: return L("fix.simulation")
        }
    }
}

extension Constellation {
    var localizedLabel: String {
        switch self {
        case .unknown: return L("constellation.other")
        default: return rawValue
        }
    }
}
