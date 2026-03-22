const output = @import("../output.zig");

pub fn execute() output.Summary {
    return .{
        .kind = .diff,
        .headline = "Artifact diffing is not implemented yet.",
        .detail =
            "This command will compare benchmark and profile outputs to surface regressions, new hotspots, and changed allocation pressure.",
    };
}
