import SwiftUI

/// Logos for well-known Chinese service senders (carriers, banks, couriers).
///
/// Exact numbers only: a matching prefix is not a sender identity, and the logo is
/// visual identification, not sender authentication. Contact names and photos win.
/// Mapping and asset sources: docs/SMSCarrierIcons.md (ported from 2020cqyd's PR).
enum SMSServiceBrand: String, CaseIterable, Sendable {
    case mobile = "SMSCarrierMobile", unicom = "SMSCarrierUnicom", telecom = "SMSCarrierTelecom"
    case icbc = "SMSServiceICBC", ccb = "SMSServiceCCB", abc = "SMSServiceABC"
    case boc = "SMSServiceBOC", bocom = "SMSServiceBOCOM"
    case cmb = "SMSServiceCMB", minsheng = "SMSServiceMinsheng"
    case sf = "SMSServiceSF", jd = "SMSServiceJD", zto = "SMSServiceZTO", yto = "SMSServiceYTO"

    var displayName: String {
        switch self {
        case .mobile: return "中国移动"
        case .unicom: return "中国联通"
        case .telecom: return "中国电信"
        case .icbc: return "工商银行"
        case .ccb: return "建设银行"
        case .abc: return "农业银行"
        case .boc: return "中国银行"
        case .bocom: return "交通银行"
        case .cmb: return "招商银行"
        case .minsheng: return "民生银行"
        case .sf: return "顺丰速运"
        case .jd: return "京东物流"
        case .zto: return "中通快递"
        case .yto: return "圆通速递"
        }
    }

    static func match(_ sender: String) -> SMSServiceBrand? {
        let allowed = CharacterSet(charactersIn: "+0123456789 -()")
        let value = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !value.dropFirst().contains("+") else { return nil }
        var digits = value.filter { $0.isASCII && $0.isNumber }
        if value.hasPrefix("+86") { digits = String(digits.dropFirst(2)) }
        else if value.hasPrefix("0086") { digits = String(digits.dropFirst(4)) }
        else if value.hasPrefix("+") { return nil }
        return numbers[digits]
    }

    private static let numbers: [String: SMSServiceBrand] = {
        var table: [String: SMSServiceBrand] = [
            "10086": .mobile, "10010": .unicom, "10000": .telecom,
            "95588": .icbc, "95533": .ccb, "106980095533": .ccb,
            "95599": .abc, "1069095599": .abc, "10690955998": .abc,
            "95566": .boc, "95559": .bocom,
            "95338": .sf, "950616": .jd, "95311": .zto, "95554": .yto,
        ]
        let cmb = ["95555", "1065795555", "106941995555", "106807695555", "10694395555", "106913595555",
                   "106903695555", "106918195555", "1069170795555", "1069329095555", "1069411095555",
                   "1068338795555", "1068078595555", "1068775395555", "1068486095555", "1068039095555",
                   "106946895555", "1069208795555", "1069220695555", "106934095555", "106934795555",
                   "1069210395555", "1069232695555", "1069101695555", "106904095555", "106903395555",
                   "106929395555", "1068116095555", "106575595555", "1069118895555", "1068015195555",
                   "106910095555", "1068455695555", "106935295555", "1069109695555", "1069057295555",
                   "1069449695555", "1069249395555", "1069352995555", "106930095555", "106920095555",
                   "1069100995555", "1069001995555", "106900795555"]
        let minsheng = ["95568", "106980095568", "10680195568", "10685095568", "106857695568",
                        "106835195568", "1068071895568", "1069120695568", "106935595568",
                        "1069161795568", "10691895568", "106901195568"]
        for number in cmb { table[number] = .cmb }
        for number in minsheng { table[number] = .minsheng }
        return table
    }()
}

/// Small rounded logo tile shown next to a service sender's number.
struct SMSServiceLogo: View {
    let brand: SMSServiceBrand
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 20

    var body: some View {
        Image(brand.rawValue)
            .resizable()
            .scaledToFit()
            .padding(side * 0.12)
            .frame(width: side, height: side)
            .background(Color.white, in: RoundedRectangle(cornerRadius: side * 0.26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
