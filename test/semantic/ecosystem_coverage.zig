const test_runner = @import("../harness.zig");

const std = @import("std");
const fs = std.fs;
const path = fs.path;
const process = std.process;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const zlint = @import("zlint");
const Source = zlint.Source;

const utils = @import("../utils.zig");
const string = utils.string;
const Repo = utils.Repo;

const REPOS_DIR = "zig-out/repos";

var repos: std.json.Parsed([]Repo) = undefined;

pub fn globalSetup(_: Allocator) !void {
    var repos_dir_fd = fs.cwd().openDir(REPOS_DIR, .{}) catch |e| {
        switch (e) {
            error.FileNotFound => {
                print("Could not find git repos to test, please run `just submodules`", .{});
                return e;
            },
            else => return e,
        }
    };
    repos_dir_fd.close();
    repos = try Repo.load(Allocator.heap());
}

pub fn globalTeardown(_: Allocator) void {
    repos.deinit();
}

fn testSemantic(alloc: Allocator, source: *const Source) !void {
    var res = try zlint.semantic.Builder.build(alloc, source.contents);
    defer res.deinit();
    if (res.hasErrors()) return SemanticError.analysis_failed;
}

// const fns: test_runner.TestSuite.TestSuiteFns = .{
//     .test_fn = &testSemantic,
//     .setup_fn = &globalSetup,
//     .teardown_fn = &globalTeardown,
// };

pub fn run(alloc: Allocator) !void {
    for (repos.value) |repo| {
        const repo_dir = try utils.TestFolders.openRepo(alloc, repo.name);
        var suite = try test_runner.TestSuite.init(alloc, repo_dir, "semantic-coverage", repo.name, .{ .test_fn = &testSemantic });
        defer suite.deinit();

        try suite.run();
    }
}


pub const SemanticError = error{
    analysis_failed,
};

pub const SUITE = test_runner.TestFile{
    .name = "semantic_coverage",
    .globalSetup = globalSetup,
    .deinit = globalTeardown,
    .run = run,
};
