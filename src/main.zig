const std = @import("std");
const zeit = @import("zeit");

const Allocator = std.mem.Allocator;

const interval_second: usize = 60;
const max_tries: usize = 60; // 1 min * 60 times

pub fn main() !void {
    const pr_id = try parseArgs();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const stdout_writer = std.io.getStdOut().writer();

    const url = try getRunUrl(allocator, pr_id);
    defer allocator.free(url);

    try stdout_writer.print("Run ID: {s}\n", .{pr_id});
    try stdout_writer.print("Action's URL: {s}\n", .{url});

    var i: usize = 0;

    while (i < max_tries) {
        const status = try getRunStatus(allocator, pr_id);
        defer status.deinit();

        const message = try status.toString(allocator);

        const time = try getTime(allocator);

        try time.strftime(stdout_writer, "[%H:%M] ");

        try stdout_writer.print("{s}\n", .{message});

        if (status.isFinished()) {
            try callNotifySend(allocator, message);
            allocator.free(message);
            break;
        }

        allocator.free(message);

        // sleep
        std.time.sleep(interval_second * std.time.ns_per_s);

        i += 1;
    }

    if (i == max_tries) {
        try callNotifySend(allocator, "Time out error. Please check the action manually.");
    }

    try stdout_writer.print("\nYou can see the result here: {s}\n", .{url});
}

fn getTime(allocator: Allocator) !zeit.Time {
    const local_tz = try zeit.loadTimeZone(allocator, .@"Europe/London", null);
    defer local_tz.deinit();

    const now = try zeit.instant(.{});
    return now.in(&local_tz).time();
}

fn parseArgs() ![]const u8 {
    var arg_it = std.process.args();

    _ = arg_it.next(); // skip the first argument (the program name)

    const pr_id = arg_it.next() orelse {
        std.debug.print("Usage: gh-notify [PR ID].\n", .{});
        return error.InvalidArgument;
    };

    return pr_id;
}

fn getRunUrl(allocator: Allocator, run_id: []const u8) ![]const u8 {
    const argv: []const []const u8 = &.{ "gh", "run", "view", run_id, "--json", "url", "--jq", ".url" };

    const url = try execute(allocator, argv);

    return url;
}

fn getRunStatus(allocator: Allocator, run_id: []const u8) !Status {
    const argv: []const []const u8 = &.{ "gh", "run", "view", run_id, "--json", "status,conclusion,workflowName" };

    const output = try execute(allocator, argv);
    defer allocator.free(output);

    const status = try Status.init(output, allocator);

    return status;
}

fn execute(allocator: Allocator, argv: []const []const u8) ![]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch |err| {
        // probably the command is not installed
        std.debug.print("Failed to run {s} command: {any}\nMake sure {s} is installed on your machine.\n", .{
            argv[0],
            err,
            argv[0],
        });
        return error.CommandFailed;
    };

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stderr.len != 0) {
        std.debug.print("{s} command failed with error: {s}\n", .{ argv[0], result.stderr });
        return error.CommandFailed;
    }

    const output = try allocator.dupe(u8, result.stdout);

    return output;
}

fn callNotifySend(allocator: Allocator, message: []const u8) !void {
    const argv: []const []const u8 = &.{ "notify-send", message };

    const output = try execute(allocator, argv);
    defer allocator.free(output);
}

const Status = struct {
    arena: std.heap.ArenaAllocator,
    status: []const u8,
    conclusion: []const u8,
    workflowName: []const u8,

    pub fn init(str: []const u8, allocator: Allocator) !Status {
        var arena = std.heap.ArenaAllocator.init(allocator);

        const owned_str = try arena.allocator().dupe(u8, str);

        const parsed = try std.json.parseFromSliceLeaky(
            // temporary struct to hold the parsed data
            struct { status: []const u8, conclusion: []const u8, workflowName: []const u8 },
            arena.allocator(),
            owned_str,
            .{},
        );

        return Status{
            .arena = arena,
            .status = parsed.status,
            .conclusion = parsed.conclusion,
            .workflowName = parsed.workflowName,
        };
    }

    pub fn deinit(self: Status) void {
        self.arena.deinit();
    }

    pub fn isFinished(self: Status) bool {
        return std.mem.eql(u8, self.status, "completed");
    }

    pub fn toString(self: Status, allocator: Allocator) ![]const u8 {
        if (self.isFinished()) {
            const symbol = if (std.mem.eql(u8, self.conclusion, "success")) "✅" else "❌";
            const str = try std.fmt.allocPrint(allocator, "{s} Task completed with {s}, Workflow Name: {s}", .{
                symbol,
                self.conclusion,
                self.workflowName,
            });
            return str;
        } else {
            const str = try std.fmt.allocPrint(allocator, "⏳ Still running {s}...", .{
                self.workflowName,
            });
            return str;
        }
    }
};

test "status in progress" {
    const input =
        \\{ "conclusion": "", "status": "in_progress", "workflowName": "Automated Tests" }
    ;

    const result = try Status.init(input, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqualStrings(result.status, "in_progress");
    try std.testing.expectEqualStrings(result.conclusion, "");
    try std.testing.expectEqualStrings(result.workflowName, "Automated Tests");
    try std.testing.expectEqual(result.isFinished(), false);

    const str_result = try result.toString(std.testing.allocator);
    defer std.testing.allocator.free(str_result);

    try std.testing.expectEqualStrings(str_result, "⏳ Still running Automated Tests...");
}

test "status success output" {
    const input =
        \\{ "conclusion": "success", "status": "completed", "workflowName": "Automated Tests" }
    ;

    const result = try Status.init(input, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqualStrings(result.status, "completed");
    try std.testing.expectEqualStrings(result.conclusion, "success");
    try std.testing.expectEqual(result.isFinished(), true);

    const str_result = try result.toString(std.testing.allocator);
    defer std.testing.allocator.free(str_result);

    try std.testing.expectEqualStrings(str_result, "✅ Task completed with success, Workflow Name: Automated Tests");
}

test "status failure output" {
    const input =
        \\{ "conclusion": "failure", "status": "completed", "workflowName": "Automated Tests" }
    ;

    const result = try Status.init(input, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqualStrings(result.status, "completed");
    try std.testing.expectEqualStrings(result.conclusion, "failure");
    try std.testing.expectEqual(result.isFinished(), true);

    const str_result = try result.toString(std.testing.allocator);
    defer std.testing.allocator.free(str_result);

    try std.testing.expectEqualStrings(str_result, "❌ Task completed with failure, Workflow Name: Automated Tests");
}
