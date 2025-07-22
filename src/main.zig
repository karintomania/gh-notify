const std = @import("std");
const Allocator = std.mem.Allocator;

const interval_second: usize = 60;
const max_tries: usize = 60; // 1 min * 60 times
//
const DependencyError = error{
    GhNotInstalled,
    NotifySendNotInstalled,
};

pub fn main() !void {
    const pr_id = try parseArgs();
    try hasDependenciesInstalled();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const stdout_writer = std.io.getStdOut().writer();

    const url = try getRunUrl(allocator, pr_id);
    defer allocator.free(url);

    try stdout_writer.print("Will send you a notification when action ID: {s} is done!\n", .{pr_id});
    try stdout_writer.print("Action's URL: {s}\n", .{url});

    var i: usize = 0;

    while (i < max_tries) {
        const status = try getRunStatus(allocator, pr_id);
        defer status.deinit();

        const message = try status.toString(allocator);
        defer allocator.free(message);

        try stdout_writer.print("{s}\n", .{message});

        if (status.isFinished()) {
            try callNotifySend(allocator, message);
            break;
        }

        // sleep
        std.time.sleep(interval_second * std.time.ns_per_s);

        i += 1;
    }

    if (i == max_tries) {
        try callNotifySend(allocator, "Time out error. Please check the action manually.");
    }

    try stdout_writer.print("\nYou can see the result here: {s}\n", .{url});
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

fn hasDependenciesInstalled() !void {
    var buf: [50*1024]u8 = undefined;

    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    _ = std.process.Child.run(.{ .allocator=allocator, .argv = &.{ "gh", "--version" } }) catch |err| {
        if (err == error.NotDir) {
            std.debug.print("Make sure gh command is installed.\n", .{});
            return DependencyError.GhNotInstalled;
        } else {
            return err;
        }
    };

    _ = std.process.Child.run(.{ .allocator=allocator, .argv = &.{ "notify-send", "--version" } }) catch |err| {
        if (err == error.NotDir) {
            std.debug.print("Make sure notify-send command is installed.\n", .{});
            return DependencyError.NotifySendNotInstalled;
        } else {
            return err;
        }
    };
}

fn getRunUrl(allocator: Allocator, run_id: []const u8) ![]const u8 {
    const RunUrl = struct {url: []const u8};
    const argv: []const []const u8 = &.{"gh", "run",  "view", run_id, "--json", "url"};

    const output = try callGh(allocator, argv);
    defer allocator.free(output);

    const parsed = try std.json.parseFromSlice(
        RunUrl,
        allocator,
        output,
        .{},
    );

    parsed.deinit();

    const url = allocator.dupe(u8, parsed.value.url);

    return url;
}


fn getRunStatus(allocator: Allocator, run_id: []const u8) !Status {
    const argv: []const []const u8 = &.{"gh", "run",  "view", run_id, "--json", "status,conclusion,workflowName"};

    const output = try callGh(allocator, argv);

    defer allocator.free(output);

    const status = try Status.init(output, allocator);

    return status;
}

fn callGh(allocator: Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{.allocator = allocator,
        .argv = argv,
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stderr.len != 0) {
        std.debug.print("gh command failed with error: {s}\n", .{result.stderr});
        return error.CommandFailed;
    }

    const output= try allocator.dupe(u8, result.stdout);

    return output;
}

fn callNotifySend(allocator: Allocator, message: []const u8) !void {
    const argv: []const []const u8 = &.{"notify-send", message};

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stderr.len != 0) {
        std.debug.print("notify-send error: {s}\n", .{result.stderr});
        return error.CommandFailed;
    }
}


const Status = struct {
    arena: std.heap.ArenaAllocator,
    status: []const u8,
    conclusion: []const u8,
    workflowName: []const u8,

    pub fn init(str: []const u8, allocator: Allocator) !Status {
        var arena = std.heap.ArenaAllocator.init(allocator);

        const owned_str = try arena.allocator().dupe(u8, str);

        // const ParsedValues = ;
        const parsed = try std.json.parseFromSliceLeaky(
            struct {status: []const u8, conclusion: []const u8, workflowName: []const u8},
            // ParsedValues,
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
            const symbol = if (std.mem.eql(u8, self.conclusion,"success")) "✅" else "❌";
            const str = try std.fmt.allocPrint(allocator, "Task completed with {s} {s}, Workflow Name: {s}", .{
                self.conclusion,
                symbol,
                self.workflowName,
            });
            return str;
        } else {
            const str = try std.fmt.allocPrint(allocator, "Still running {s}...", .{
            self.workflowName,
            });
            return str;
        }
    }
};


test "status in progress" {
    const input = \\{ "conclusion": "", "status": "in_progress", "workflowName": "Automated Tests" }
    ;

    const result = try Status.init(input, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqualStrings(result.status, "in_progress");
    try std.testing.expectEqualStrings(result.conclusion, "");
    try std.testing.expectEqualStrings(result.workflowName, "Automated Tests");
    try std.testing.expectEqual(result.isFinished(), false);

    const str_result = try result.toString(std.testing.allocator);
    defer std.testing.allocator.free(str_result);

    try std.testing.expectEqualStrings(str_result, "Still running Automated Tests...");
}

test "status success output" {

    const input = \\{ "conclusion": "success", "status": "completed", "workflowName": "Automated Tests" }
    ;

    const result = try Status.init(input, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqualStrings(result.status, "completed");
    try std.testing.expectEqualStrings(result.conclusion, "success");
    try std.testing.expectEqual(result.isFinished(), true);

    const str_result = try result.toString(std.testing.allocator);
    defer std.testing.allocator.free(str_result);

    try std.testing.expectEqualStrings(str_result, "Task completed with success ✅, Workflow Name: Automated Tests");
}

test "status failure output" {

    const input = \\{ "conclusion": "failure", "status": "completed", "workflowName": "Automated Tests" }
    ;

    const result = try Status.init(input, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqualStrings(result.status, "completed");
    try std.testing.expectEqualStrings(result.conclusion, "failure");
    try std.testing.expectEqual(result.isFinished(), true);

    const str_result = try result.toString(std.testing.allocator);
    defer std.testing.allocator.free(str_result);

    try std.testing.expectEqualStrings(str_result, "Task completed with failure ❌, Workflow Name: Automated Tests");
}
