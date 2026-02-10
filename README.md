# sh-zig

A Lisp-family expression language interpreter for Zig. Designed to be embedded in other Zig projects as a scripting/configuration DSL.

## Features

- **Lazy evaluation** — arguments are evaluated on demand
- **Macro system** — define reusable patterns with `|name params| body`
- **Existential truthiness** — no booleans; values either exist (`?Value`) or they don't (`null`)
- **Arena allocation** — parse and execute within a single arena lifecycle
- **33 built-in operations** — arithmetic, comparison, logic, control flow, string, list, and higher-order functions
- **Embeddable** — use as a Zig module with `zig fetch`

## Syntax Overview

```
# Top-level expressions don't need parens
say "hello" 42

# Parens create sub-expressions
+ 1 (* 2 3)

# Expressions and scope references
$term
:name

# Lists and blocks
[1 2 3]
{say "block"}

# Macros (params accessed with :)
|greet name| say (concat "hello " :name)
```

### Key Concepts

- `$term` — single-term expression (evaluates the term as a zero-argument call)
- `:name` — scope thunk (looks up a named entry in the current scope; used to access macro parameters)
- `[...]` — list sugar
- `{...}` — block/proc sugar
- `~param` — lazy parameter in macro definitions
- `?Value` = truthy, `null` = falsy

## Built-in Operations

| Category     | Operations                                               |
|--------------|----------------------------------------------------------|
| Constants    | `some`, `none`                                           |
| Arithmetic   | `+`, `-`, `*`, `/`, `%`, `^`                             |
| Comparison   | `<`, `<=`, `>`, `>=`, `is`, `isnt`, `compare`            |
| Logic        | `and`, `or`, `not`, `first`                              |
| Control Flow | `if`, `when`, `match`, `matchby`                         |
| String       | `concat`, `join`, `say`, `error`                         |
| List         | `list`, `flat`, `length`                                 |
| Higher-Order | `map`, `filter`, `reduce`, `each`, `count`, `any`, `all` |

## Usage

Add as a dependency in your `build.zig.zon`:

```
zig fetch --save git+https://your-repo-url/sh-zig
```

Then in your `build.zig`:

```zig
const sh = b.dependency("sh", .{
    .target = target,
    .optimize = optimize,
});
your_module.addImport("sh", sh.module("sh"));
```

### Basic Example

```zig
const std = @import("std");
const sh = @import("sh");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Set up a registry with built-in operations
    var registry = sh.Registry{};
    try sh.builtins.registerAll(&registry, allocator);

    // Create an execution environment
    var env = sh.Env.init(&registry, allocator);

    // Process an expression
    const result = try sh.processRaw(&env, "+ 1 2", null);
    switch (result) {
        .ok => |val| {
            if (val) |v| std.debug.print("Result: {}\n", .{v});
        },
        .validation_err => |errors| {
            for (errors) |err| std.debug.print("Validation: {s}\n", .{err.message});
        },
        .runtime_err => |msg| std.debug.print("Runtime: {s}\n", .{msg}),
    }
}
```

### Loading Macros

```zig
const macro_source =
    \\|double x| * :x 2
    \\|greet name| say (concat "Hello, " :name)
;

const load_result = try sh.loadMacroModule(allocator, &registry, macro_source);
switch (load_result) {
    .ok => |count| std.debug.print("Loaded {d} macros\n", .{count}),
    .validation_err => |errors| { /* handle errors */ },
}
```

### Custom Operations

```zig
fn myOperation(args: sh.Args) sh.exec.ExecError!?sh.Value {
    const first = try args.env.evaluate(args.args[0], args.scope);
    return first; // echo back the first argument
}

try registry.registerOperation(allocator, "my-op", &myOperation);
```

## Building

Requires **Zig 0.15.2** or later.

```sh
# Run all tests
zig build test

# Build the module
zig build
```

## Architecture

| File               | Purpose                                              |
|--------------------|------------------------------------------------------|
| `root.zig`         | Public API re-exports                                |
| `value.zig`        | Value tagged union (string, int, float, list)         |
| `token.zig`        | Token types, syntax constants, escape sequences      |
| `lexer.zig`        | Tokenizer with line/column tracking                  |
| `ast.zig`          | AST node types and construction helpers              |
| `parser.zig`       | Recursive descent expression parser                  |
| `validation.zig`   | AST to executable transformation with error checking |
| `exec.zig`         | Runtime: Thunk, Expression, Scope, Env, Registry     |
| `builtins.zig`     | 33 built-in operations                               |
| `macro_parser.zig` | Macro definition parser and validator                |
| `process.zig`      | Convenience API: processRaw, loadMacroModule         |

## License

[MIT](LICENSE)
