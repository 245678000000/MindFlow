import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

struct MapTheme {
    let name: String
    let root: [Color]
    let palette: [Color]
    let colorNames: [String]

    func color(_ i: Int) -> Color { palette[((i % palette.count) + palette.count) % palette.count] }
}

enum Themes {
    static let all: [MapTheme] = [
        MapTheme(name: "晴空",
                 root: [Color(hex: 0x5B7CFA), Color(hex: 0x7B5CF0)],
                 palette: [0x4C8DF6, 0x2FBF9F, 0xF5A524, 0xEF5D7A, 0x9B6CF0, 0x22B5D8].map(Color.init(hex:)),
                 colorNames: ["蓝", "绿松", "琥珀", "玫红", "紫", "青"]),
        MapTheme(name: "莫兰迪",
                 root: [Color(hex: 0x7D8FA3), Color(hex: 0x8C7F9E)],
                 palette: [0x7E9BB5, 0xC49A74, 0x8DAE8A, 0xC28499, 0x9F93C4, 0xC9AB6E].map(Color.init(hex:)),
                 colorNames: ["雾蓝", "陶土", "苔绿", "豆沙", "藕紫", "麦黄"]),
        MapTheme(name: "活力",
                 root: [Color(hex: 0xFF5E7E), Color(hex: 0xFF9A4D)],
                 palette: [0xFF5E7E, 0xFFAE33, 0x2ECC8F, 0x3AA0FF, 0xA66BFF, 0xFF6FCB].map(Color.init(hex:)),
                 colorNames: ["西瓜红", "橘", "薄荷", "天蓝", "葡萄", "桃粉"]),
        MapTheme(name: "森林",
                 root: [Color(hex: 0x2E8B6A), Color(hex: 0x3B7D9C)],
                 palette: [0x3A9D74, 0x5B8DB8, 0xC9963E, 0x9C6B4E, 0x6E9F3C, 0x4FA3A0].map(Color.init(hex:)),
                 colorNames: ["松绿", "湖蓝", "落叶", "树皮", "草绿", "溪青"]),
        MapTheme(name: "石墨",
                 root: [Color(hex: 0x3A3D45), Color(hex: 0x23252B)],
                 palette: [0x6B7280, 0x8A8F99, 0x565B66, 0x7C818C, 0x9CA1AB, 0x60656F].map(Color.init(hex:)),
                 colorNames: ["石墨 1", "石墨 2", "石墨 3", "石墨 4", "石墨 5", "石墨 6"]),
    ]

    static func at(_ i: Int) -> MapTheme { all[((i % all.count) + all.count) % all.count] }
}
