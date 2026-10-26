import Foundation

/// Project-authored kaomoji (text emoticons) in small categories. Original lists, Apache-2.0.
public struct KaomojiCategory: Sendable, Equatable {
    public let name: String
    public let items: [String]
}

public enum Kaomoji {
    public static let categories: [KaomojiCategory] = [
        KaomojiCategory(name: "Happy", items: [
            "(^_^)", "(^o^)", "(≧▽≦)", "(◕‿◕)", "٩(◕‿◕)۶", "(＾▽＾)", "ヽ(´▽`)/", "(*^‿^*)", "(๑˃ᴗ˂)ﻭ", "ʕ•ᴥ•ʔ",
        ]),
        KaomojiCategory(name: "Love", items: [
            "(♡´▽`♡)", "(´｡• ᵕ •｡`) ♡", "(｡♥‿♥｡)", "( ˘ ³˘)♥", "(づ｡◕‿‿◕｡)づ", "(*♡∀♡)", "♡(｡- ω -)", "(⁄ ⁄>⁄ ▽ ⁄<⁄ ⁄)",
        ]),
        KaomojiCategory(name: "Sad", items: [
            "(T_T)", "(；_；)", "(╥_╥)", "(´；ω；`)", "(ಥ﹏ಥ)", "(._.)", "(つ﹏<。)", "｡･ﾟ･(ﾉД`)･ﾟ･｡",
        ]),
        KaomojiCategory(name: "Angry", items: [
            "(╬ Ò﹏Ó)", "(｀Д´)", "ヽ(`Д´)ﾉ", "(¬_¬)", "(ノಠ益ಠ)ノ", "(＃`Д´)", "(҂◡_◡)", "(눈_눈)",
        ]),
        KaomojiCategory(name: "Shrug & Meh", items: [
            #"¯\_(ツ)_/¯"#, "(・_・)", "(－_－) zzz", "(￣ー￣)", "(⊙_⊙)?", "(・・?)", "(´-ω-`)", "(；一_一)",
        ]),
        KaomojiCategory(name: "Cheer", items: [
            "＼(^o^)／", "(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧", "o(≧▽≦)o", "☆*:.｡.o(≧▽≦)o.｡.:*☆", "٩(ˊᗜˋ*)و", "(ง •̀_•́)ง", "(b ᵔ▽ᵔ)b", "\\(★ω★)/",
        ]),
        KaomojiCategory(name: "Animals", items: [
            "(=^･ω･^=)", "ʕ•ᴥ•ʔ", "(◕ᴥ◕)", "U・ᴥ・U", "(ᵔᴥᵔ)", "(・ω・)ﾉ", "=＾● ⋏ ●＾=", "(｡•ᴗ•｡)🐾",
        ]),
        KaomojiCategory(name: "Table flip", items: [
            "(╯°□°)╯︵ ┻━┻", "┬─┬ノ( º _ ºノ)", "(ノಠ_ಠ)ノ彡┻━┻", "┻━┻ ︵ヽ(`Д´)ﾉ︵ ┻━┻",
        ]),
    ]
}
