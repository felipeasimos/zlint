//! semantic analysis of a zig AST.
//!
//! We are intentionally not using Zig's AIR. That format strips away dead
//! code, which may be in the process of being authored. Instead, we perform
//! our own minimalist semantic analysis of an entire zig program.
//!
//! Additionally, we're avoiding an SoA (struct of arrays) format for now. Zig
//! (and many other parsers/analysis tools) use this to great perf advantage.
//! However, it sucks to work with when writing rules. We opt for simplicity to
//! reduce cognitive load and make contributing rules easier.
//!
//! Throughout this file you'll see mentions of a "program". This does not mean
//! an entire linked binary or library; rather it refers to a single parsed
//! file.

pub const Builder = struct {
    _gpa: Allocator,
    _arena: ArenaAllocator,
    _curr_scope_id: Semantic.Scope.Id = ROOT_SCOPE,
    _curr_symbol_id: ?Semantic.Symbol.Id = null,

    // stacks

    _scope_stack: std.ArrayListUnmanaged(Semantic.Scope.Id) = .{},
    /// When entering an initialization container for a symbol, that symbol's ID
    /// is pushed here. This lets us record members and exports.
    _symbol_stack: std.ArrayListUnmanaged(Semantic.Symbol.Id) = .{},
    _node_stack: std.ArrayListUnmanaged(NodeIndex) = .{},

    /// SAFETY: initialized after parsing. Same safety rationale as _root_scope.
    _semantic: Semantic = undefined,
    /// Errors encountered during parsing and analysis.
    ///
    /// Errors in this list are allocated using this list's allocator.
    _errors: std.ArrayListUnmanaged(Error) = .{},

    /// The root node always has an index of 0. Since it is never referenced by other nodes,
    /// the Zig team uses it to represent `null` without wasting extra memory.
    const NULL_NODE: NodeIndex = Semantic.NULL_NODE;
    const ROOT_SCOPE: Semantic.Scope.Id = Semantic.ROOT_SCOPE_ID;

    /// Parse and analyze a Zig source file.
    ///
    /// Analysis consists of:
    /// - Binding symbols to a symbol table
    /// - Scope analysis
    ///
    /// Parse and analysis errors are collected in the returned `Result`. An
    /// error union variant is only ever returned for fatal errors, such as (but not limited to):
    /// - Allocation failures (e.g. out of memory)
    /// - Unexpected nulls
    /// - Out-of-bounds access
    ///
    /// In some  cases, SemanticBuilder may choose to panic instead of
    /// returning an error union. These assertions produce better release
    /// binaries and catch bugs earlier.
    pub fn build(gpa: Allocator, source: stringSlice) !Result {
        var builder = Builder{ ._gpa = gpa, ._arena = ArenaAllocator.init(gpa) };
        defer builder.deinit();
        // NOTE: ast is moved
        const ast = try builder.parse(source);
        const meta = try AstMeta.init(gpa, &ast);
        assert(ast.nodes.len == meta._parents.items.len);

        // reserve capacity for stacks
        try builder._scope_stack.ensureTotalCapacity(gpa, 8); // TODO: use stack fallback allocator?
        try builder._symbol_stack.ensureTotalCapacity(gpa, 8);
        // TODO: verify this hypothesis. What is the max node stack len while
        // building? (avg over a representative sample of real Zig files.)
        try builder._node_stack.ensureTotalCapacity(gpa, @max(ast.nodes.len >> 2, 8));

        builder._semantic = Semantic{
            .ast = ast,
            .ast_meta = meta,
            ._arena = builder._arena,
            ._gpa = gpa,
        };
        errdefer builder._semantic.deinit();

        // Create root scope & symbol and push them onto their stacks. Also
        // pushes the root node. None of these are ever popped.
        try builder.enterRoot();
        builder.assertRoot(); // sanity check

        for (builder._semantic.ast.rootDecls()) |node| {
            builder.visitNode(node) catch |e| return e;
            builder.assertRoot();
        }

        return Result.new(builder._gpa, builder._semantic, builder._errors);
    }

    /// Deinitialize build-specific resources. Errors and the constructed
    /// `Semantic` instance are left untouched.
    pub fn deinit(self: *Builder) void {
        self._scope_stack.deinit(self._gpa);
        self._symbol_stack.deinit(self._gpa);
        self._node_stack.deinit(self._gpa);
    }

    fn parse(self: *Builder, source: stringSlice) !Ast {
        const ast = try Ast.parse(self._arena.allocator(), source, .zig);

        // Record parse errors
        if (ast.errors.len > 0) {
            try self._errors.ensureUnusedCapacity(self._gpa, ast.errors.len);
            for (ast.errors) |ast_err| {
                // Not an error. TODO: verify this assumption
                if (ast_err.is_note) continue;
                self.addAstError(&ast, ast_err) catch @panic("Out of memory");
            }
        }

        return ast;
    }

    // =========================================================================
    // ================================= VISIT =================================
    // =========================================================================

    /// Visit an AST node.
    ///
    /// Null and bounds checks are performed here, while actual logic is
    /// handled by `visitNode`. This lets us inline checks within caller
    /// functions, reducing unnecessary branching and stack pointer pushes.
    inline fn visit(self: *Builder, node_id: NodeIndex) anyerror!void {
        // when lhs/rhs are 0 (root node), it means `null`
        if (node_id == NULL_NODE) return;
        // Seeing this happen a log, needs debugging.
        if (node_id >= self.AST().nodes.len) {
            // TODO: hint to compiler that this branch is unlikely. @branchHint
            // is documented in the Zig language reference, but does not appear available in v0.13.0.
            // https://ziglang.org/documentation/master/#branchHint
            // @branchHint(.unlikely);
            //
            // print("ERROR: node ID out of bounds ({d})\n", .{node_id});
            return;
        }

        return self.visitNode(node_id);
    }

    /// Visit a node in the AST. Do not call this directly, use `visit` instead.
    fn visitNode(self: *Builder, node_id: NodeIndex) anyerror!void {
        assert(node_id > 0 and node_id < self.AST().nodes.len);
        try self.enterNode(node_id);
        defer self.exitNode();

        // TODO:
        // - bind function declarations
        // - record symbol types and signatures
        // - record symbol references
        // - Scope flags for unions, structs, and enums. Blocks are currently handled (TODO: that needs testing).
        // - Test the shit out of it
        const tag: Ast.Node.Tag = self._semantic.ast.nodes.items(.tag)[node_id];
        switch (tag) {
            // root node is never referenced b/c of NULL_NODE check at function start
            .root => unreachable,
            // containers and container members
            // ```zig
            // const Foo = struct { // <-- visits struct/enum/union containers
            // };
            // ```
            .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing => {
                var buf: [2]u32 = undefined;
                const container = self.AST().fullContainerDecl(&buf, node_id) orelse unreachable;
                return self.visitContainer(node_id, container);
            },
            .container_field, .container_field_align, .container_field_init => {
                const field = self.AST().fullContainerField(node_id) orelse unreachable;
                return self.visitContainerField(node_id, field);
            },
            // variable declarations
            .global_var_decl => {
                const decl = self.AST().fullVarDecl(node_id) orelse unreachable;
                self.visitGlobalVarDecl(node_id, decl);
            },
            .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const decl = self.AST().fullVarDecl(node_id) orelse unreachable;
                return self.visitVarDecl(node_id, decl);
            },

            // function-related nodes

            // function declarations
            .fn_decl => return self.visitFnDecl(node_id),
            .fn_proto, .fn_proto_one, .fn_proto_multi => {
                if (IS_DEBUG) {
                    std.debug.panic("visitNode should never encounter a function prototype. It should have been handled by visitFnDecl.", .{});
                }
                return self.visitRecursive(node_id);
            },

            // function calls
            .call, .call_comma, .async_call, .async_call_comma => {
                // fullCall uses callFull under the hood. Skipping the
                // middleman removes a redundant tag check. This check guards
                // against future API changes made by the Zig team.
                if (IS_DEBUG) {
                    var buf: [1]u32 = undefined;
                    assert(self.AST().fullCall(&buf, node_id) != null);
                }
                const call = self.AST().callFull(node_id);
                return self.visitCall(node_id, call);
            },
            .call_one, .call_one_comma, .async_call_one, .async_call_one_comma => {
                var buf: [1]u32 = undefined;
                // fullCall uses callOne under the hood. Skipping the
                // middleman removes a redundant tag check. This check guards
                // against future API changes made by the Zig team.
                if (IS_DEBUG) {
                    assert(self.AST().fullCall(&buf, node_id) != null);
                }
                const call = self.AST().callOne(&buf, node_id);
                return self.visitCall(node_id, call);
            },

            // control flow

            // loops
            .while_simple, .@"while", .while_cont => {
                const while_stmt = self.AST().fullWhile(node_id) orelse unreachable;
                return self.visitWhile(node_id, while_stmt);
            },
            .for_simple => {
                const for_stmt = self.AST().forSimple(node_id);
                return self.visitFor(node_id, for_stmt);
            },
            .@"for" => {
                const for_stmt = self.AST().forFull(node_id);
                return self.visitFor(node_id, for_stmt);
            },

            // conditionals
            .@"if", .if_simple => {
                const if_stmt = self.AST().fullIf(node_id) orelse unreachable;
                return self.visitIf(node_id, if_stmt);
            },

            // TODO: include .block_two and .block_two_semicolon?
            .block, .block_semicolon => {
                try self.enterScope(.{ .s_block = true });
                defer self.exitScope();
                return self.visitRecursive(node_id);
            },
            // .@"usingnamespace" => self.visitUsingNamespace(node),
            else => return self.visitRecursive(node_id),
        }
    }

    /// Basic lhs/rhs traversal. This is just a shorthand.
    inline fn visitRecursive(self: *Builder, node_id: NodeIndex) !void {
        const data: Node.Data = self.AST().nodes.items(.data)[node_id];
        try self.visit(data.lhs);
        try self.visit(data.rhs);
    }

    fn visitContainer(self: *Builder, _: NodeIndex, container: full.ContainerDecl) !void {
        try self.enterScope(.{ .s_block = true, .s_enum = container.ast.enum_token != null });
        defer self.exitScope();
        for (container.ast.members) |member| {
            try self.visit(member);
        }
    }

    /// Visit a container field (e.g. a struct property, enum variant, etc).
    ///
    /// ```zig
    /// const Foo = { // <-- Declared within this container's scope.
    ///   bar: u32    // <-- This is a container field. It is always Symbol.Visibility.public.
    /// };            //     It is added to Foo's member table.
    /// ```
    fn visitContainerField(self: *Builder, node_id: NodeIndex, field: full.ContainerField) !void {
        const main_token = self.AST().nodes.items(.main_token)[node_id];
        // main_token points to the field name
        const identifier = self.getIdentifier(main_token);
        const flags = Symbol.Flags{
            .s_comptime = field.comptime_token != null,
        };
        // NOTE: container fields are always public
        // TODO: record type annotations
        _ = try self.declareMemberSymbol(node_id, identifier, .public, flags);
        if (field.ast.value_expr != NULL_NODE) {
            try self.visit(field.ast.value_expr);
        }
    }

    fn visitGlobalVarDecl(self: *Builder, node_id: NodeIndex, var_decl: full.VarDecl) void {
        _ = self;
        _ = node_id;
        _ = var_decl;
        @panic("todo: visitGlobalVarDecl");
    }

    /// Visit a variable declaration. Global declarations are visited
    /// separately, because their lhs/rhs nodes and main token mean different
    /// things.
    fn visitVarDecl(self: *Builder, node_id: NodeIndex, var_decl: full.VarDecl) !void {
        const node = self.getNode(node_id);
        // main_token points to `var`, `const` keyword. `.identifier` comes immediately afterwards
        const identifier: string = self.getIdentifier(node.main_token + 1);
        const flags = Symbol.Flags{ .s_comptime = var_decl.comptime_token != null };
        const visibility = if (var_decl.visib_token == null) Symbol.Visibility.private else Symbol.Visibility.public;
        const symbol_id = try self.declareSymbolOnContainer(node_id, identifier, visibility, flags);
        try self.enterContainerSymbol(symbol_id);
        defer self.exitContainerSymbol();

        if (var_decl.ast.init_node != NULL_NODE) {
            assert(var_decl.ast.init_node < self.AST().nodes.len);
            try self.visit(var_decl.ast.init_node);
        }
    }

    // ============================== STATEMENTS ===============================

    inline fn visitWhile(self: *Builder, _: NodeIndex, while_stmt: full.While) !void {
        try self.visit(while_stmt.ast.cond_expr);
        try self.visit(while_stmt.ast.cont_expr); // what is this?
        try self.visit(while_stmt.ast.then_expr);
        try self.visit(while_stmt.ast.else_expr);
    }

    inline fn visitFor(self: *Builder, _: NodeIndex, for_stmt: full.For) !void {
        for (for_stmt.ast.inputs) |input| {
            try self.visit(input);
        }
        try self.visit(for_stmt.ast.then_expr);
        try self.visit(for_stmt.ast.else_expr);
    }

    inline fn visitIf(self: *Builder, _: NodeIndex, if_stmt: full.If) !void {
        try self.visit(if_stmt.ast.cond_expr);
        // HYPOTHESIS: these will contain blocks, which enter/exit a scope when
        // visited. Thus we can/should skip that here.
        try self.visit(if_stmt.ast.then_expr);
        try self.visit(if_stmt.ast.else_expr);
    }

    fn visitFnDecl(self: *Builder, node_id: NodeIndex) !void {
        var buf: [1]u32 = undefined;
        const ast = self.AST();
        // lhs is prototype, rhs is body
        const data: Node.Data = ast.nodes.items(.data)[node_id];
        const proto = ast.fullFnProto(&buf, data.lhs) orelse unreachable;
        const visibility = if (proto.visib_token == null) Symbol.Visibility.private else Symbol.Visibility.public;
        // TODO: bound name vs escaped name
        const identifier = if (proto.name_token) |tok| self.getIdentifier(tok) else "<anonymous>";
        // TODO: bind methods as members
        _ = try self.declareSymbolOnContainer(node_id, identifier, visibility, .{ .s_fn = true });

        // parameters are in a new scope b/c other symbols in the same scope as
        // the declared fn cannot access them.
        try self.enterScope(.{});
        defer self.exitScope();
        for (proto.ast.params) |param| {
            try self.visit(param);
        }

        // Function body is also in a new scope. Declaring a symbol with the
        // same name as a parameter is an illegal shadow, not a redeclaration
        // error.
        try self.enterScope(.{ .s_function = true });
        defer self.exitScope();
        try self.visit(data.rhs);
    }

    /// Visit a function call. Does not visit calls to builtins
    fn visitCall(self: *Builder, _: NodeIndex, call: full.Call) !void {
        // TODO: record reference
        try self.visit(call.ast.fn_expr);
        for (call.ast.params) |arg| {
            try self.visit(arg);
        }
    }

    // =========================================================================
    // ======================== SCOPE/SYMBOL MANAGEMENT ========================
    // =========================================================================

    fn enterRoot(self: *Builder) !void {
        @setCold(true);

        // initialize root scope
        // NOTE: root scope is entered differently to avoid unnecessary null checks
        // when getting parent scopes. Parent is only ever null for the root scope.
        assert(self._scope_stack.items.len == 0);
        const root_scope = try self._semantic.scopes.addScope(self._gpa, null, .{ .s_top = true });
        assert(root_scope.id == Semantic.ROOT_SCOPE_ID);

        // Builder.init() allocates enough space for 8 scopes.
        self._scope_stack.appendAssumeCapacity(root_scope.id);

        // push root node onto the stack. It is never popped.
        // Similar to root scope, the root node is pushed differently than
        // other nodes because parent->child node linking is skipped.
        self._node_stack.appendAssumeCapacity(Semantic.ROOT_NODE_ID);

        // Create root symbol and push it onto the stack. It too is never popped.
        // TODO: distinguish between bound name and escaped name.
        const root_symbol_id = try self.declareSymbol(Semantic.ROOT_NODE_ID, "@This()", .public, .{ .s_const = true });
        try self.enterContainerSymbol(root_symbol_id);
    }

    /// Panic if we're not currently within the root scope and node.
    inline fn assertRoot(self: *const Builder) void {
        assert(self._scope_stack.items.len == 1);
        assert(self._scope_stack.items[0] == Semantic.ROOT_SCOPE_ID);

        assert(self._node_stack.items.len == 1);
        assert(self._node_stack.items[0] == Semantic.ROOT_NODE_ID);

        assert(self._symbol_stack.items.len == 1);
        assert(self._symbol_stack.items[0] == 0); // TODO: create root symbol id.
    }

    /// Enter a new scope, pushing it onto the stack.
    fn enterScope(self: *Builder, flags: Scope.Flags) !void {
        // print("entering scope\n", .{});
        const parent_id = self._scope_stack.getLastOrNull();
        const scope = try self._semantic.scopes.addScope(self._gpa, parent_id, flags);
        try self._scope_stack.append(self._gpa, scope.id);
    }

    /// Exit the current scope. It is a bug to pop the root scope.
    inline fn exitScope(self: *Builder) void {
        // print("exiting scope\n", .{});
        assert(self._scope_stack.items.len > 1); // cannot pop root scope
        _ = self._scope_stack.pop();
    }

    /// Get the current scope.
    ///
    /// This should never panic because the root scope is never exited.
    inline fn currentScope(self: *const Builder) Scope.Id {
        assert(self._scope_stack.items.len != 0);
        return self._scope_stack.getLast();
    }

    fn currentNode(self: *const Builder) NodeIndex {
        util.assert(self._node_stack.items.len > 0, "Invariant violation: root node is missing from the node stack", .{});
        return self._node_stack.getLast();
    }

    inline fn enterNode(self: *Builder, node_id: NodeIndex) !void {
        const curr_node = self.currentNode();
        self._semantic.ast_meta.setParent(node_id, curr_node);
        try self._node_stack.append(self._gpa, node_id);
    }

    inline fn exitNode(self: *Builder) void {
        util.assert(self._node_stack.items.len > 0, "Invariant violation: Cannot pop the root node", .{});
        _ = self._node_stack.pop();
    }

    inline fn enterContainerSymbol(self: *Builder, symbol_id: Symbol.Id) !void {
        try self._symbol_stack.append(self._gpa, symbol_id);
    }

    /// Pop the most recent container symbol from the stack. Panics if the symbol stack is empty.
    inline fn exitContainerSymbol(self: *Builder) void {
        // NOTE: asserts stack is not empty
        _ = self._symbol_stack.pop();
    }

    /// Get the most recent container symbol, returning `null` if the stack is empty.
    ///
    /// `null` returns happen, for example, in the root scope. or within root
    /// functions.
    inline fn currentContainerSymbol(self: *const Builder) ?Symbol.Id {
        return self._symbol_stack.getLastOrNull();
    }

    /// Unconditionally get the most recent container symbol. Panics if no
    /// symbol has been entered.
    inline fn currentContainerSymbolUnwrap(self: *const Builder) Symbol.Id {
        if (IS_DEBUG and self._symbol_stack.items.len == 0) {
            std.debug.panic("Cannot get current container symbol: symbol stack is empty", .{});
        }
        return self._symbol_stack.getLast();
    }

    fn declareSymbolOnContainer(self: *Builder, declaration_node: Ast.Node.Index, name: string, visibility: Symbol.Visibility, flags: Symbol.Flags) !Symbol.Id {
        const symbol_id = try self.declareSymbol(declaration_node, name, visibility, flags);
        if (self.currentContainerSymbol()) |container_id| {
            assert(!self._semantic.symbols.get(container_id).flags.s_member);
            try self._semantic.symbols.addMember(self._gpa, symbol_id, container_id);
        }

        return symbol_id;
    }

    /// Declare a new symbol in the current scope and record it as a member to
    /// the most recent container symbol. Returns the new member symbol's ID.
    fn declareMemberSymbol(self: *Builder, declaration_node: Ast.Node.Index, name: string, visibility: Symbol.Visibility, flags: Symbol.Flags) !Symbol.Id {
        var member_flags = flags;
        member_flags.s_member = true;
        const member_symbol_id = try self.declareSymbol(declaration_node, name, visibility, member_flags);

        const container_symbol_id = self.currentContainerSymbolUnwrap();
        assert(!self._semantic.symbols.get(container_symbol_id).flags.s_member);
        try self._semantic.symbols.addMember(self._gpa, member_symbol_id, container_symbol_id);

        return member_symbol_id;
    }

    /// Declare a symbol in the current scope.
    inline fn declareSymbol(self: *Builder, declaration_node: Ast.Node.Index, name: string, visibility: Symbol.Visibility, flags: Symbol.Flags) !Symbol.Id {
        const symbol_id = try self._semantic.symbols.addSymbol(self._gpa, declaration_node, name, self.currentScope(), visibility, flags);
        return symbol_id;
    }

    // =========================================================================
    // ============================ RANDOM GETTERS =============================
    // =========================================================================

    /// Shorthand for getting the AST. Must be caps to avoid shadowing local
    /// `ast` declarations.
    inline fn AST(self: *const Builder) *const Ast {
        return &self._semantic.ast;
    }

    /// Shorthand for getting the symbol table.
    inline fn symbolTable(self: *Builder) *Semantic.SymbolTable {
        return &self._semantic.symbols;
    }

    /// Shorthand for getting the scope tree.
    inline fn scopeTree(self: *Builder) *Semantic.ScopeTree {
        return &self._semantic.scopes;
    }

    /// Get a node by its ID.
    ///
    /// ## Panics
    /// - If attempting to access the root node (which acts as null).
    /// - If `node_id` is out of bounds.
    inline fn getNode(self: *const Builder, node_id: NodeIndex) Node {
        // root node (whose id is 0) is used as null
        // NOTE: do not use assert here b/c that gets stripped in release
        // builds. We want more safety here.
        if (node_id == 0) @panic("attempted to access null node");
        assert(node_id < self.AST().nodes.len);

        return self.AST().nodes.get(node_id);
    }

    /// Get a node by its ID, returning `null` if its the root node (which acts as null).
    ///
    /// ## Panics
    /// - If `node_id` is out of bounds.
    inline fn maybeGetNode(self: *const Builder, node_id: NodeIndex) ?Node {
        if (node_id == 0) return null;
        assert(node_id < self.AST().nodes.len);

        return self.AST().nodes.get(node_id);
    }

    inline fn getToken(self: *const Builder, token_id: TokenIndex) RawToken {
        assert(token_id < self.AST().tokens.len);

        const t = self.AST().tokens.get(token_id);
        return .{
            .tag = t.tag,
            .start = t.start,
        };
    }

    /// Get an identifier name from an `.identifier` token.
    fn getIdentifier(self: *Builder, token_id: Ast.TokenIndex) string {
        const ast = self.AST();

        if (IS_DEBUG) {
            const tag = ast.tokens.items(.tag)[token_id];
            assert(tag == .identifier);
        }

        const slice = ast.tokenSlice(token_id);
        return slice;
    }

    // =========================================================================
    // =========================== ERROR MANAGEMENT ============================
    // =========================================================================

    fn addAstError(self: *Builder, ast: *const Ast, ast_err: Ast.Error) !void {
        var msg: std.ArrayListUnmanaged(u8) = .{};
        defer msg.deinit(self._gpa);
        try ast.renderError(ast_err, msg.writer(self._gpa));

        // TODO: render `ast_err.extra.expected_tag`
        const byte_offset: Ast.ByteOffset = ast.tokens.items(.start)[ast_err.token];
        const loc = ast.tokenLocation(byte_offset, ast_err.token);
        const labels = .{Span{ .start = @intCast(loc.line_start), .end = @intCast(loc.line_end) }};
        _ = labels;

        return self.addErrorOwnedMessage(try msg.toOwnedSlice(self._gpa), null);
    }

    /// Record an error encountered during parsing or analysis.
    ///
    /// All parameters are borrowed. Errors own their data, so each parameter gets cloned onto the heap.
    fn addError(self: *Builder, message: string, labels: []Span, help: ?string) !void {
        const alloc = self._errors.allocator;
        const heap_message = try alloc.dupeZ(u8, message);
        const heap_labels = try alloc.dupe(Span, labels);
        const heap_help: ?string = if (help == null) null else try alloc.dupeZ(help.?);
        const err = try Error{ .message = heap_message, .labels = heap_labels, .help = heap_help };
        try self._errors.append(err);
    }

    /// Create and record an error. `message` is an owned slice moved into the new Error.
    // fn addErrorOwnedMessage(self: *Builder, message: string, labels: []Span, help: ?string) !void {
    fn addErrorOwnedMessage(self: *Builder, message: string, help: ?string) !void {
        // const heap_labels = try alloc.dupe(labels);
        const heap_help: ?string = if (help == null) null else try self._gpa.dupeZ(u8, help.?);
        const err = Error{ .message = message, .help = heap_help };
        // const err = try Error{ .message = message, .labels = heap_labels, .help = heap_help };
        try self._errors.append(self._gpa, err);
    }

    pub const Result = Error.Result(Semantic);
};

pub const Semantic = @import("./semantic/Semantic.zig");
const Scope = Semantic.Scope;
const Symbol = Semantic.Symbol;
const AstMeta = Semantic.AstMeta;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Type = std.builtin.Type;

const assert = std.debug.assert;
const print = std.debug.print;

const Ast = std.zig.Ast;
const full = Ast.full;
const Node = Ast.Node;
const NodeIndex = Ast.Node.Index;
/// The struct used in AST tokens SOA is not pub so we hack it in here.
const RawToken = struct {
    tag: std.zig.Token.Tag,
    start: u32,
};
const TokenIndex = Ast.TokenIndex;

const Error = @import("./Error.zig");
const Span = @import("./source.zig").Span;

const util = @import("util");
const IS_DEBUG = util.IS_DEBUG;
const string = util.string;
const stringSlice = util.stringSlice;

test "Struct/enum fields are bound bound to the struct/enums's member table" {
    const alloc = std.testing.allocator;
    const programs = [_][:0]const u8{
        "const Foo = struct { bar: u32 };",
        "const Foo = enum { bar };",
    };
    for (programs) |program| {
        var result = try Builder.build(alloc, program);
        defer result.deinit();
        try std.testing.expect(!result.hasErrors());
        var semantic = result.value;

        // Find Foo and bar symbols
        var foo: ?*const Semantic.Symbol = null;
        var bar: ?*const Semantic.Symbol = null;
        {
            var iter = semantic.symbols.iter();
            const names = semantic.symbols.symbols.items(.name);
            while (iter.next()) |id| {
                const name = names[id];
                if (std.mem.eql(u8, name, "bar")) {
                    bar = semantic.symbols.get(id);
                } else if (std.mem.eql(u8, name, "Foo")) {
                    foo = semantic.symbols.get(id);
                }
            }
        }

        // they exist
        try std.testing.expect(bar != null);
        try std.testing.expect(foo != null);
        try std.testing.expect(bar.?.scope != Semantic.ROOT_SCOPE_ID);
        // Foo has exactly 1 member and it is bar
        const foo_members = semantic.symbols.getMembers(foo.?.id);
        try std.testing.expectEqual(1, foo_members.items.len);
        try std.testing.expectEqual(bar.?.id, foo_members.items[0]);
    }
}
