import Foundation

/// What the slime wears: one piece per slot, or a named set. Situational props the host adds
/// ("dress for the occasion") are layered on top at runtime and never stored here.
public struct SlimeOutfit: Sendable, Codable, Equatable, Hashable {
    public enum Headwear: String, Sendable, Codable, CaseIterable {
        case none, crown, tiara, mortarboard, santaHat, strawHat, beret, wizardHat, headphones, bow, flower, halo, nightcap, leaf
    }
    public enum Eyewear: String, Sendable, Codable, CaseIterable {
        case none, roundGlasses, sunglasses, monocle, mask, eyepatch
    }
    public enum Wrap: String, Sendable, Codable, CaseIterable {
        case none, royalCape, scarf, towel, hoodie, bowtie
    }
    public enum Charm: String, Sendable, Codable, CaseIterable {
        case none, duck, bell
    }

    public var headwear: Headwear
    public var eyewear: Eyewear
    public var wrap: Wrap
    public var charm: Charm

    public init(headwear: Headwear = .none, eyewear: Eyewear = .none, wrap: Wrap = .none, charm: Charm = .none) {
        self.headwear = headwear
        self.eyewear = eyewear
        self.wrap = wrap
        self.charm = charm
    }

    enum CodingKeys: String, CodingKey { case headwear, eyewear, wrap, charm }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headwear = try c.decodeIfPresent(Headwear.self, forKey: .headwear) ?? .none
        eyewear = try c.decodeIfPresent(Eyewear.self, forKey: .eyewear) ?? .none
        wrap = try c.decodeIfPresent(Wrap.self, forKey: .wrap) ?? .none
        charm = try c.decodeIfPresent(Charm.self, forKey: .charm) ?? .none
    }

    public var isEmpty: Bool { headwear == .none && eyewear == .none && wrap == .none && charm == .none }

    /// `other`'s pieces win where it has any (situational props over the chosen outfit).
    public func overlaid(with other: SlimeOutfit) -> SlimeOutfit {
        SlimeOutfit(headwear: other.headwear == .none ? headwear : other.headwear,
                    eyewear: other.eyewear == .none ? eyewear : other.eyewear,
                    wrap: other.wrap == .none ? wrap : other.wrap,
                    charm: other.charm == .none ? charm : other.charm)
    }

    // MARK: Sets

    public struct Set: Sendable, Equatable, Identifiable {
        public var name: String
        public var label: String
        public var outfit: SlimeOutfit
        public var id: String { name }
    }

    public static let sets: [Set] = [
        Set(name: "none", label: "Nothing", outfit: SlimeOutfit()),
        Set(name: "king", label: "King", outfit: SlimeOutfit(headwear: .crown, wrap: .royalCape)),
        Set(name: "scholar", label: "Scholar", outfit: SlimeOutfit(headwear: .mortarboard, eyewear: .roundGlasses)),
        Set(name: "wizard", label: "Wizard", outfit: SlimeOutfit(headwear: .wizardHat, wrap: .scarf)),
        Set(name: "santa", label: "Santa", outfit: SlimeOutfit(headwear: .santaHat, wrap: .scarf)),
        Set(name: "summer", label: "Summer", outfit: SlimeOutfit(headwear: .strawHat, eyewear: .sunglasses)),
        Set(name: "onsen", label: "Onsen", outfit: SlimeOutfit(wrap: .towel, charm: .duck)),
        Set(name: "night", label: "Night", outfit: SlimeOutfit(headwear: .nightcap)),
        Set(name: "idol", label: "Idol", outfit: SlimeOutfit(headwear: .headphones, wrap: .bowtie)),
    ]

    public static func set(named name: String) -> SlimeOutfit? {
        sets.first { $0.name == name }?.outfit
    }

    /// The set this outfit equals, if any.
    public var setName: String? { Self.sets.first { $0.outfit == self }?.name }
}
