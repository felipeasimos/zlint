const std = @import("std");
const builtin = @import("builtin");
const lint = @import("linter.zig");
const util = @import("util");
const Source = @import("source.zig").Source;
const semantic = @import("semantic.zig");
const Options = @import("./cli/Options.zig");

const fs = std.fs;
const path = std.path;
const assert = std.debug.assert;
const print = std.debug.print;

const Ast = std.zig.Ast;
const Linter = lint.Linter;

const print_cmd = @import("cmd/print_command.zig");
const lint_cmd = @import("cmd/lint_command.zig");

pub fn main() !void {
    // in debug builds, include more information for debugging memory leaks,
    // double-frees, etc.
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .never_unmap = util.IS_DEBUG,
        .retain_metadata = util.IS_DEBUG,
    }){};

    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var stack = std.heap.stackFallback(16, alloc);
    const stack_alloc = stack.get();

    var opts = Options.parseArgv(stack_alloc);
    defer opts.deinit(stack_alloc);

    if (opts.print_ast) {
        if (opts.args.items.len == 0) {
            print("No files to print\nUsage: zlint --print-ast [filename]", .{});
            std.process.exit(1);
        }

        const relative_path = opts.args.items[0];
        print("Printing AST for {s}\n", .{relative_path});
        const file = try fs.cwd().openFile(relative_path, .{});
        errdefer file.close();
        var source = try Source.init(alloc, file, null);
        defer source.deinit();
        return print_cmd.parseAndPrint(alloc, opts, source);
    }

    try lint_cmd.lint(alloc, opts);
}

test {
    std.testing.refAllDecls(@This());
}
