import CArdk

public enum SemanticsChannelName: UInt8, CaseIterable, CustomStringConvertible {
        // Standard channels
        case sky = 0
        case ground
        case naturalGround
        case artificialGround
        case water
        case person
        case building
        case foliage
        case grass

        // Experimental channels
        case flowerExperimental = 100
        case treeTrunkExperimental
        case petExperimental
        case sandExperimental
        case tvExperimental
        case dirtExperimental
        case vehicleExperimental
        case foodExperimental
        case loungeableExperimental
        case snowExperimental
        
        public static var allChannels: [SemanticsChannelName] { return Array(Self.allCases) }

        /// Convert from C enum to Swift enum
        internal static func fromCEnum(_ cEnum: ARDK_Semantics_Channel) -> SemanticsChannelName? {
            return SemanticsChannelName(rawValue: cEnum.rawValue)
        }
        
        /// Convert from Swift enum to C enum
        internal func toCEnum() -> ARDK_Semantics_Channel {
            return ARDK_Semantics_Channel(rawValue: self.rawValue)
        }

        /// Convert to string
        public var description: String {
            switch self {
            case .sky: return "sky"
            case .ground: return "ground"
            case .naturalGround: return "natural_ground"
            case .artificialGround: return "artificial_ground"
            case .water: return "water"
            case .person: return "person"
            case .building: return "building"
            case .foliage: return "foliage"
            case .grass: return "grass"
            case .flowerExperimental: return "flower_experimental"
            case .treeTrunkExperimental: return "tree_trunk_experimental"
            case .petExperimental: return "pet_experimental"
            case .sandExperimental: return "sand_experimental"
            case .tvExperimental: return "tv_experimental"
            case .dirtExperimental: return "dirt_experimental"
            case .vehicleExperimental: return "vehicle_experimental"
            case .foodExperimental: return "food_experimental"
            case .loungeableExperimental: return "loungeable_experimental"
            case .snowExperimental: return "snow_experimental"
            }
        }
    }

/// A set of semantic channels represented as a bitmask.
/// This OptionSet allows for efficient bitwise operations on channel sets.
public struct SemanticsChannels {
    public let rawValue: UInt32

    // Map channel names to their channel indices (0-18)
    // Channel index c maps directly to bit position c (bit 0 = channel 0 = Sky, bit 1 = channel 1 = Ground, etc.)
    nonisolated(unsafe) private static let channelToIndex: [SemanticsChannelName: Int] = [
        .sky: 0,                     // channel 0
        .ground: 1,                  // channel 1
        .naturalGround: 2,           // channel 2
        .artificialGround: 3,        // channel 3
        .water: 4,                   // channel 4
        .person: 5,                  // channel 5
        .building: 6,                // channel 6
        .foliage: 7,                 // channel 7
        .grass: 8,                   // channel 8
        .flowerExperimental: 9,     // channel 9
        .treeTrunkExperimental: 10,  // channel 10
        .petExperimental: 11,        // channel 11
        .sandExperimental: 12,       // channel 12
        .tvExperimental: 13,         // channel 13
        .dirtExperimental: 14,       // channel 14
        .vehicleExperimental: 15,    // channel 15
        .foodExperimental: 16,       // channel 16
        .loungeableExperimental: 17, // channel 17
        .snowExperimental: 18        // channel 18
    ]

    // Map channel indices to channel names
    nonisolated(unsafe) private static let indexToChannel: [SemanticsChannelName] = [
        .sky,                       // channel 0
        .ground,                    // channel 1
        .naturalGround,             // channel 2
        .artificialGround,          // channel 3
        .water,                     // channel 4
        .person,                    // channel 5
        .building,                  // channel 6
        .foliage,                   // channel 7
        .grass,                     // channel 8
        .flowerExperimental,        // channel 9
        .treeTrunkExperimental,     // channel 10
        .petExperimental,           // channel 11
        .sandExperimental,          // channel 12
        .tvExperimental,            // channel 13
        .dirtExperimental,         // channel 14
        .vehicleExperimental,       // channel 15
        .foodExperimental,          // channel 16
        .loungeableExperimental,    // channel 17
        .snowExperimental           // channel 18
    ]

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Check if a specific channel is present in this set
    /// - Parameter channel: The channel to check for
    /// - Returns: `true` if the channel is present, `false` otherwise
    public func contains(_ channel: SemanticsChannelName) -> Bool {
        guard let channelIndex = Self.channelToIndex[channel] else {
            return false
        }
        
        return (rawValue & (1 << channelIndex)) != 0
    }

    /// Convert the bitmask to a Set of SemanticsChannelName values
    public func toChannelNames() -> Set<SemanticsChannelName> {
        var channels: Set<SemanticsChannelName> = []

        // Iterate through channel indices 0-18 and check if they're present in the bitmask
        for channelIndex in 0..<19 {
            if rawValue & (1 << channelIndex) != 0 {
                channels.insert(Self.indexToChannel[channelIndex])
            }
        }

        return channels
    }

    /// Create a SemanticsChannels OptionSet from a Set of SemanticsChannelName values
    public init(channelNames: Set<SemanticsChannelName>) {
        var bitmask: UInt32 = 0

        for channel in channelNames {
            if let channelIndex = Self.channelToIndex[channel] {
                bitmask |= (1 << channelIndex)
            }
        }

        self.rawValue = bitmask
    }

    /// Create a SemanticsChannels OptionSet directly from a C array of channel enums
    /// This avoids intermediate Set allocation by building the bitmask directly
    internal init(cChannels: UnsafePointer<ARDK_Semantics_Channel>, count: Int) {
        var bitmask: UInt32 = 0

        for i in 0..<count {
            let cChannel = cChannels[i]
            // Convert C enum to Swift enum, then look up channel index
            if let swiftChannel = SemanticsChannelName.fromCEnum(cChannel),
               let channelIndex = Self.channelToIndex[swiftChannel] {
                bitmask |= (1 << channelIndex)
            }
        }

        self.rawValue = bitmask
    }
}
