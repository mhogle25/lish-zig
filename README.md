# sh-zig

A Lisp-family expression language interpreter for Zig. Designed to be embedded in other Zig projects as a scripting/configuration DSL.

## Features

- **Deferred evaluation** — arguments are evaluated on demand, not ahead of time
- **Macro system** — define reusable patterns with `|name params| body`
- **Existential truthiness** — no booleans; values either exist (`?Value`) or they don't (`null`)
- **Arena allocation** — parse and execute within a single arena lifecycle
- **Expression caching** — generic LRU cache avoids redundant parsing
- **41 built-in operations** — arithmetic, comparison, logic, control flow, string, list, and higher-order functions
- **Session API** — backend-agnostic REPL core; terminal now, custom UI later
- **Embeddable** — use as a Zig module with `zig fetch`

## Syntax Overview

Top-level expressions don't need parens:
```
say hello 42
```

Parens create sub-expressions:
```
+ 1 (* 2 3)
```

Bare terms, `'single-quoted'`, and `"double-quoted"` strings are all string literals:
```
say hello
say 'hello world'
say "hello world"
```

`$term` for single-term expressions, `:name` for scope references:
```
say $some :myVar
```

Lists and blocks (`[...]` is sugar for `list`, `{...}` is sugar for `proc`):
```
[1 2 3]
{(say hello) (say world)}
```

At the top level, use the operation names directly since the sugar forms become sub-expressions:
```
list 1 2 3
proc (say hello) (say world)
```

Macros (params accessed with `:`):
```
|greet name| say (concat "hello " :name)
```

### Key Concepts

- `$term` — single-term expression (evaluates the term as a zero-argument call)
- `:name` — scope thunk (looks up a named entry in the current scope; used to access macro parameters)
- `[...]` — list sugar
- `{...}` — block sugar (desugars to `proc`; evaluates each sub-expression in order, returns the last)
- `~param` — deferred parameter in macro definitions (not evaluated until accessed)
- `?Value` = truthy, `null` = falsy

## Built-in Operations

| Category     | Operations                                            |
|--------------|-------------------------------------------------------|
| Constants    | `some`, `none`                                        |
| Arithmetic   | `+`, `-`, `*`, `/`, `%`, `^`                          |
| Comparison   | `<`, `<=`, `>`, `>=`, `is`, `isnt`, `compare`         |
| Logic        | `and`, `or`, `not`                                    |
| Control Flow | `if`, `when`, `match`                                 |
| String       | `concat`, `join`                                      |
| Output       | `say`, `error`                                        |
| List         | `list`, `flat`, `length`, `first`, `rest`, `at`, `reverse`, `range`, `until` |
| Higher-Order | `map`, `foreach`, `apply`, `filter`, `reduce`         |
| Sequencing   | `proc`                                                |
| Utility      | `identity`                                            |

## Usage

Add as a dependency in your `build.zig.zon`:

```
zig fetch --save git+https://github.com/mhogle25/sh-zig.git
```

Then in your `build.zig`:

```zig
const sh_dep = b.dependency("sh", .{
    .target = target,
    .optimize = optimize,
});
your_module.addImport("sh", sh_dep.module("sh"));
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
    var env = sh.Env{
        .registry = &registry,
        .allocator = allocator,
    };

    // Process an expression
    const result = try sh.processRaw(&env, "+ 1 2", null);
    switch (result) {
        .ok => |maybe_value| {
            if (maybe_value) |value| {
                var buf: [256]u8 = undefined;
                std.debug.print("Result: {s}\n", .{value.getS(&buf)});
            }
        },
        .validation_err => |errors| {
            for (errors) |err| std.debug.print("Validation: {s}\n", .{err.message});
        },
        .runtime_err => |msg| std.debug.print("Runtime: {s}\n", .{msg}),
    }
}
```

### Using Sessions

The `Session` is the high-level integration point for interactive use. It owns the registry, cache, and arena, and processes one input at a time:

```zig
const sh = @import("sh");

var session = try sh.Session.init(allocator, .{
    .fragments = &.{&sh.builtins.registerAll},
    .stdout = sh.session.fdWriter(std.posix.STDOUT_FILENO),
    .stderr = sh.session.fdWriter(std.posix.STDERR_FILENO),
});
defer session.deinit();

const result = try session.execute("+ 1 2");
```

### Loading Macros

From source strings:

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

From `.shmacro` files:

```zig
// Load a single file
_ = try session.loadMacroFile("macros/math.shmacro");

// Or scan a directory for all .shmacro files
_ = try session.loadMacroDir("macros/");
```

Or pass macro directories at the CLI:

```sh
zig build run -- -m macros/
```

### Custom Operations

```zig
fn myOperation(args: sh.Args) sh.exec.ExecError!?sh.Value {
    const value = try args.at(0).resolve();
    return value; // echo back the first argument
}

try registry.registerOperation(allocator, "my-op", &myOperation);
```

## Building

Requires **Zig 0.15.2** or later.

```sh
# Run all tests
zig build test

# Build the library and CLI
zig build

# Launch the terminal REPL
zig build run

# Pass arguments to the REPL (e.g. macro directories)
zig build run -- -m path/to/macros
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
| `builtins.zig`     | 41 built-in operations                               |
| `macro_parser.zig` | Macro definition parser and validator                |
| `cache.zig`        | Generic LRU cache (`LruCache(V)`)                    |
| `process.zig`      | Convenience API: processRaw, macro file loading      |
| `session.zig`      | Session struct (backend-agnostic REPL core)           |
| `main.zig`         | Terminal REPL entry point                            |

## License

[MIT](LICENSE)
