import Foundation

// 架空の曲。音は無く、ゲームの流れを試すためだけに使う。
enum DemoCatalog {
    private static let raw: [(String, String, String, Int, Int)] = [
        ("Concrete Pulse", "Unit 909", "Techno", 2019, 372),
        ("Night Shift Machine", "Unit 909", "Techno", 2021, 405),
        ("Steel Garden", "Kaori Dub", "Techno", 2016, 341),
        ("Deep Tide", "Marina Lowe", "House", 2018, 330),
        ("Saturday Glow", "The Velvet Keys", "House", 1997, 296),
        ("Warm Room", "Marina Lowe", "House", 2022, 318),
        ("Skyline Euphoria", "Aurora Gate", "Trance", 2004, 452),
        ("Lucid Horizon", "Aurora Gate", "Trance", 2008, 417),
        ("Mushroom Valley", "Goa Satellite", "Psytrance", 2012, 486),
        ("Third Eye Engine", "Goa Satellite", "Psytrance", 1998, 511),
        ("Block Party 85", "MC Ripple", "Hip-Hop/Rap", 1985, 241),
        ("Concrete Poet", "MC Ripple", "Hip-Hop/Rap", 2020, 198),
        ("Neon Highway", "Static Riders", "Rock", 1989, 262),
        ("Last Train Home", "Static Riders", "Rock", 2003, 233),
        ("Iron Comet", "Black Halo", "Metal", 1993, 310),
        ("Throne of Ash", "Black Halo", "Metal", 2015, 355),
        ("Kimi to Natsu", "Hoshino Mirai", "J-Pop", 2019, 247),
        ("Ame no Hi", "Hoshino Mirai", "J-Pop", 1996, 268),
        ("Galaxy Hero OP", "Studio Comet", "Anime", 2014, 91),
        ("Final Boss Theme", "Studio Comet", "Anime", 2011, 203),
        ("Mirror Ball Love", "Funk Satellite", "Disco", 1979, 344),
        ("Boogie Shoes 2000", "Funk Satellite", "Disco", 2000, 301),
        ("Synth City 1984", "Laser Club", "Electronic", 1984, 287),
        ("Rave Signal", "Laser Club", "Dance", 1992, 319),
        ("Moonlight Drive", "Neon Weekend", "Electronic", 2017, 254),
        ("Winter Lights", "Neon Weekend", "Pop", 2009, 236),
        ("Rain Code", "Kaori Dub", "Electronic", 2023, 299),
        ("Cosmic Walk", "Orbit Kids", "Electronic", 1999, 377),
        ("Heartbreak Disco", "The Velvet Keys", "Disco", 1981, 279),
        ("Sunrise Anthem", "Aurora Gate", "Trance", 2001, 433),
    ]

    static let tracks: [Track] = {
        var out: [Track] = []
        for (i, r) in raw.enumerated() {
            let hue: Double = Double((i * 47) % 100) / 100
            let t = Track(id: "demo-\(i)", title: r.0, artist: r.1, album: "Demo",
                          genres: [r.2], releaseYear: r.3, duration: TimeInterval(r.4),
                          artworkURL: nil, source: .demo(hue: hue))
            out.append(t)
        }
        return out
    }()

    static func search(_ term: String) -> [Track] {
        let q = term.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
                || $0.genres.joined().lowercased().contains(q) || "\($0.releaseYear ?? 0)".contains(q)
        }
    }
}
