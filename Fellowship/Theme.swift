import SwiftUI
import UIKit

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { t in
            let h = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(cgColor: CGColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                           blue: CGFloat(h & 0xFF) / 255, alpha: 1))
        })
    }

    /// 인주색. 채움용 (흰 글씨 대비 ≥4.5:1 in both modes)
    static let seal = Color(light: 0xB5361F, dark: 0xC8442B)
    /// 인주색 글씨용 (어두운 배경에서 조금 밝게)
    static let sealText = Color(light: 0xB5361F, dark: 0xE8725A)
    /// 말하기 버튼 기본 배경: 라이트=먹색, 다크=아이보리
    static let ink = Color(light: 0x1C1B1A, dark: 0xF2EFEA)
    /// ink 위의 글씨
    static let inkOn = Color(light: 0xF8F6F2, dark: 0x1C1B1A)
    static let amberBanner = Color(light: 0xF0C95C, dark: 0xE6BF52)
    static let amberText = Color(light: 0x2B2100, dark: 0x2B2100)
    static let readyGreen = Color(light: 0x2F7D4F, dark: 0x5FB57F)
    static let surface = Color(.secondarySystemBackground)
    static let hairline = Color.primary.opacity(0.08)
}
