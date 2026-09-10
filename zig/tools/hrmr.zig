//! HR/MR compiler for Array42.
//!
//! Implements the SOURCE / MR / HR doctrine for the Zig source tree:
//!
//!   - SOURCE: `src/*.zig` — canonical truth, comments + implementation.
//!     Partners edit this.
//!   - MR:     `zig-out/mr/*.zig` — machine runtime, comment-stripped.
//!     The Zig compiler consumes this (the "final runtime shape").
//!   - HR:     `zig-out/hr/*.zig.md` — human-readable projection, generated
//!     from the doc comments (`///` and `//!`).
//!
//! Usage: `hrmr <src-dir> <mr-dir> <hr-dir>`
//!
//! The MR pass is a lexical scan that strips line (`//`) and block (`/* */`,
//! nested) comments while preserving string, char, and multiline-string
//! literals verbatim — so `//` or `/*` inside a string is never mistaken for
//! a comment.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();

    _ = args.next(); // program name
    const src_dir = args.next() orelse {
        std.debug.print("usage: hrmr <src-dir> <mr-dir> <hr-dir>\n", .{});
        return error.Usage;
    };
    const mr_dir = args.next() orelse return error.Usage;
    const hr_dir = args.next() orelse return error.Usage;

    try std.Io.Dir.cwd().createDirPath(io, mr_dir);
    try std.Io.Dir.cwd().createDirPath(io, hr_dir);

    var src = try std.Io.Dir.cwd().openDir(io, src_dir, .{ .iterate = true });
    defer src.close(io);

    var it = src.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const src_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ src_dir, entry.name });
        defer a.free(src_path);
        const src_bytes = try std.Io.Dir.cwd().readFileAlloc(io, src_path, a, .unlimited);
        defer a.free(src_bytes);

        // MR — comment-stripped source.
        var mr = std.ArrayList(u8).empty;
        defer mr.deinit(a);
        try stripComments(src_bytes, &mr, a);
        const mr_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ mr_dir, entry.name });
        defer a.free(mr_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = mr_path, .data = mr.items });

        // HR — doc-comment projection.
        var hr = std.ArrayList(u8).empty;
        defer hr.deinit(a);
        try extractDocs(entry.name, src_bytes, &hr, a);
        const hr_path = try std.fmt.allocPrint(a, "{s}/{s}.md", .{ hr_dir, entry.name });
        defer a.free(hr_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = hr_path, .data = hr.items });

        std.debug.print("  {s} -> mr/{s} + hr/{s}.md\n", .{ entry.name, entry.name, entry.name });
    }
}

/// Strip comments from Zig source, preserving string/char/multiline literals.
fn stripComments(src: []const u8, out: *std.ArrayList(u8), a: Allocator) !void {
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];

        // String literal: "..." with backslash escapes.
        if (c == '"') {
            try out.append(a, c);
            i += 1;
            while (i < src.len) {
                const d = src[i];
                try out.append(a, d);
                if (d == '\\' and i + 1 < src.len) {
                    i += 1;
                    try out.append(a, src[i]);
                    i += 1;
                    continue;
                }
                if (d == '"') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Char literal: '...' with backslash escapes.
        if (c == '\'') {
            try out.append(a, c);
            i += 1;
            while (i < src.len) {
                const d = src[i];
                try out.append(a, d);
                if (d == '\\' and i + 1 < src.len) {
                    i += 1;
                    try out.append(a, src[i]);
                    i += 1;
                    continue;
                }
                if (d == '\'') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Multiline string: \\ ... \\ (may span lines).
        if (c == '\\' and i + 1 < src.len and src[i + 1] == '\\') {
            try out.appendSlice(a, "\\\\");
            i += 2;
            while (i < src.len) {
                if (src[i] == '\\' and i + 1 < src.len and src[i + 1] == '\\') {
                    try out.appendSlice(a, "\\\\");
                    i += 2;
                    break;
                }
                try out.append(a, src[i]);
                i += 1;
            }
            continue;
        }

        // Line comment: // ... (keep the newline).
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }

        // Block comment: /* ... */ (nested).
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            var depth: usize = 1;
            while (i < src.len and depth > 0) {
                if (src[i] == '/' and i + 1 < src.len and src[i + 1] == '*') {
                    depth += 1;
                    i += 2;
                } else if (src[i] == '*' and i + 1 < src.len and src[i + 1] == '/') {
                    depth -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            continue;
        }

        try out.append(a, c);
        i += 1;
    }
}

const DocKind = enum { file, decl };

const Doc = struct { kind: DocKind, text: []const u8 };

/// If `line` is a doc comment (`//!` or `///`), return its kind and stripped
/// text; otherwise null.
fn docText(line: []const u8) ?Doc {
    const t = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, t, "//!")) {
        return .{ .kind = .file, .text = std.mem.trim(u8, t[3..], " \t") };
    }
    if (std.mem.startsWith(u8, t, "///")) {
        return .{ .kind = .decl, .text = std.mem.trim(u8, t[3..], " \t") };
    }
    return null;
}

fn lineEnd(src: []const u8, start: usize) usize {
    var e = start;
    while (e < src.len and src[e] != '\n') e += 1;
    return e;
}

/// Generate a markdown projection of the file's doc comments.
fn extractDocs(name: []const u8, src: []const u8, out: *std.ArrayList(u8), a: Allocator) !void {
    try out.appendSlice(a, "# ");
    try out.appendSlice(a, name);
    try out.appendSlice(a, "\n\n");

    // File-level docs (//!).
    var file_docs = std.ArrayList(u8).empty;
    defer file_docs.deinit(a);
    var pos: usize = 0;
    while (pos < src.len) {
        const e = lineEnd(src, pos);
        const line = src[pos..e];
        if (docText(line)) |d| {
            if (d.kind == .file) {
                if (file_docs.items.len > 0) try file_docs.appendSlice(a, "\n");
                try file_docs.appendSlice(a, d.text);
            }
        }
        pos = e + 1;
    }
    if (file_docs.items.len > 0) {
        try out.appendSlice(a, "## File\n\n");
        try out.appendSlice(a, file_docs.items);
        try out.appendSlice(a, "\n\n");
    }

    // Declaration docs (///) + the declaration they precede.
    pos = 0;
    while (pos < src.len) {
        const e = lineEnd(src, pos);
        const line = src[pos..e];
        if (docText(line)) |d| {
            if (d.kind == .decl) {
                // Collect consecutive /// lines.
                var doc = std.ArrayList(u8).empty;
                defer doc.deinit(a);
                try doc.appendSlice(a, d.text);
                var cursor = e + 1;
                while (cursor < src.len) {
                    const e2 = lineEnd(src, cursor);
                    const l2 = src[cursor..e2];
                    if (docText(l2)) |d2| {
                        if (d2.kind == .decl) {
                            try doc.appendSlice(a, "\n");
                            try doc.appendSlice(a, d2.text);
                            cursor = e2 + 1;
                            continue;
                        }
                    }
                    break;
                }
                // Find the declaration line (skip blanks and regular comments).
                var decl: ?[]const u8 = null;
                while (cursor < src.len) {
                    const e3 = lineEnd(src, cursor);
                    const l3 = std.mem.trim(u8, src[cursor..e3], " \t");
                    if (l3.len == 0 or std.mem.startsWith(u8, l3, "//")) {
                        cursor = e3 + 1;
                        continue;
                    }
                    decl = l3;
                    break;
                }
                try out.appendSlice(a, "### ");
                if (decl) |dl| {
                    try out.appendSlice(a, "`");
                    try out.appendSlice(a, dl);
                    try out.appendSlice(a, "`");
                } else {
                    try out.appendSlice(a, "`(declaration)`");
                }
                try out.appendSlice(a, "\n\n");
                try out.appendSlice(a, doc.items);
                try out.appendSlice(a, "\n\n");
                pos = cursor;
                continue;
            }
        }
        pos = e + 1;
    }
}
