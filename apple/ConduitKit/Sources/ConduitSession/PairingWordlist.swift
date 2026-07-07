import Foundation

/// The pairing fingerprint wordlist: exactly 256 short, concrete, visually
/// distinct words. FROZEN — the same byte must map to the same word on every
/// implementation forever (vectors in proto/vectors pin this). Append-only
/// history: v1 is this list; any change would be a new list version.
public enum PairingWordlist {
    public static let words: [String] = [
        "acorn", "amber", "anchor", "apple", "arrow", "aspen", "atlas", "autumn",
        "badge", "bagel", "bamboo", "banjo", "basil", "beacon", "berry", "bison",
        "blanket", "blossom", "bolt", "bonfire", "breeze", "brick", "bridge", "bronze",
        "bubble", "butter", "cabin", "cactus", "camera", "canoe", "canyon", "carbon",
        "castle", "cedar", "cello", "chalk", "cherry", "chess", "cider", "cinnamon",
        "citrus", "cloud", "clover", "cobalt", "cocoa", "comet", "compass", "copper",
        "coral", "cotton", "cricket", "crystal", "cypress", "daisy", "dolphin", "domino",
        "donut", "dragon", "drum", "eagle", "echo", "ember", "engine", "falcon",
        "feather", "fern", "fiddle", "fig", "flame", "flint", "fossil", "fox",
        "frost", "galaxy", "garden", "garlic", "gecko", "geyser", "ginger", "glacier",
        "goose", "granite", "grape", "gravel", "guitar", "hammer", "harbor", "harvest",
        "hazel", "helmet", "heron", "hickory", "honey", "horizon", "hummus", "igloo",
        "indigo", "iris", "iron", "island", "ivory", "jade", "jasmine", "jigsaw",
        "journal", "jungle", "juniper", "kayak", "kernel", "kettle", "kiwi", "ladder",
        "lagoon", "lantern", "laurel", "lava", "lemon", "lentil", "lilac", "lily",
        "lobster", "locket", "lotus", "magnet", "mango", "maple", "marble", "meadow",
        "melon", "mesa", "meteor", "mint", "mocha", "monsoon", "moose", "moss",
        "mustang", "nectar", "noodle", "north", "nutmeg", "oasis", "ocean", "olive",
        "onyx", "opal", "orange", "orbit", "orchid", "otter", "owl", "oyster",
        "panda", "papaya", "parrot", "peach", "pearl", "pebble", "pecan", "penguin",
        "pepper", "petal", "piano", "pickle", "pigeon", "pine", "pistachio", "planet",
        "plum", "pocket", "polar", "pond", "poppy", "prairie", "prism", "pumpkin",
        "quartz", "quill", "rabbit", "raccoon", "radish", "rainbow", "raisin", "raven",
        "reef", "ribbon", "ridge", "river", "robin", "rocket", "rooster", "rose",
        "ruby", "saddle", "saffron", "sage", "salmon", "sandal", "sapphire", "scarf",
        "shadow", "shell", "sierra", "silver", "sketch", "slate", "sleet", "socket",
        "sonnet", "sparrow", "spruce", "squash", "stone", "storm", "summit", "sunset",
        "syrup", "tango", "tiger", "timber", "toast", "topaz", "torch", "trumpet",
        "tulip", "tundra", "turtle", "umbrella", "valley", "vanilla", "velvet", "violet",
        "volcano", "waffle", "walnut", "walrus", "willow", "winter", "wolf", "wren",
        "yarn", "yogurt", "zebra", "zephyr", "zinc", "zinnia", "acacia", "alder",
        "almond", "aurora", "basalt", "birch", "cardinal", "cascade", "condor", "cosmos",
    ]
}
