//! Runs the shared scanner-boundary corpus against lish-zig.
//!
//! Cases come from `lish.scanner_corpus` (which @embedFiles them from
//! `src/scanner_corpus/`). Two runners share the corpus:
//!
//!   - `findPipeBoundary` drives the full `Lexer`, the canonical tokenizer, on
//!     the `|` (macro-body) cases.
//!   - `findExpressionBoundary` drives `lish.boundary`, the focused scanner that
//!     embedders call, on *every* case (both `|` and folio's `}`). This is what
//!     pins that shared function to the lexer's lexical rules.

const std = @import("std");
const lish = @import("lish");
const Lexer = lish.Lexer;

/// The opener that nests a given terminator: `{` for folio's `}` regions; the
/// macro `|` does not nest.
fn openFor(terminator: u8) ?u8 {
    return switch (terminator) {
        '}' => '{',
        else => null,
    };
}

/// Tokenize the source and return the byte offset of the first `macro_bracket`
/// (`|`) token. Returns null if the source contains no such token.
fn findPipeBoundary(source: []const u8) ?u32 {
    var lex = Lexer{ .source = source };
    while (true) {
        const t = lex.nextToken();
        switch (t.type) {
            .eof => return null,
            .macro_bracket => return t.start,
            else => {},
        }
    }
}

test "scanner corpus: every `|` case matches lish-zig's lexer" {
    var pipe_count: usize = 0;

    for (lish.scanner_corpus.cases) |case| {
        const parsed = try lish.scanner_corpus.parse(case.text);
        if (parsed.terminator != '|') continue;
        pipe_count += 1;

        const found = findPipeBoundary(parsed.source) orelse {
            std.debug.print("\nCASE FAILED: {s}\n  no `|` token found in source\n", .{case.name});
            return error.BoundaryNotFound;
        };
        if (found != parsed.expected_boundary) {
            std.debug.print(
                "\nCASE FAILED: {s}\n  expected boundary {d}, lexer reports {d}\n  source: {s}\n",
                .{ case.name, parsed.expected_boundary, found, parsed.source },
            );
            return error.BoundaryMismatch;
        }
    }

    try std.testing.expect(pipe_count > 0);
}

test "scanner corpus: findExpressionBoundary matches every case" {
    for (lish.scanner_corpus.cases) |case| {
        const parsed = try lish.scanner_corpus.parse(case.text);
        const open = openFor(parsed.terminator);

        const found = lish.findExpressionBoundary(parsed.source, open, parsed.terminator) orelse {
            std.debug.print("\nCASE FAILED: {s}\n  no boundary found\n", .{case.name});
            return error.BoundaryNotFound;
        };
        if (found != parsed.expected_boundary) {
            std.debug.print(
                "\nCASE FAILED: {s}\n  expected boundary {d}, got {d}\n  source: {s}\n",
                .{ case.name, parsed.expected_boundary, found, parsed.source },
            );
            return error.BoundaryMismatch;
        }
    }
}
