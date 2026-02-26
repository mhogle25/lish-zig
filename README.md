# lish-zig

A Lisp-family expression language interpreter for Zig. Designed to be embedded in other Zig projects as a scripting/configuration DSL or a shell-like utility.

## Features

- **Deferred evaluation** — arguments are evaluated on demand, not ahead of time
- **Macro system** — define reusable patterns with `|name params| body`
- **Existential truthiness** — no booleans; values either exist (`?Value`) or they don't (`null`)
- **Arena allocation** — parse and execute within a single arena lifecycle
- **Expression caching** — generic LRU cache avoids redundant parsing
- **75 built-in operations** — arithmetic, comparison, logic, control flow, string, list, higher-order, type, and math functions
- **Session API** — backend-agnostic REPL core
- **AST builder** — fluent Zig API for constructing lish expressions and macro definitions programmatically
- **AST serializer** — convert any AST node back to lish source text
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

Quoted strings support escape sequences:

| Sequence | Character |
|----------|-----------|
| `\\` | Backslash |
| `\"` | Double quote |
| `\'` | Single quote |
| `\n` | Newline |
| `\r` | Carriage return |
| `\t` | Tab |
| `\0` | Null |
| `\a` | Bell |
| `\b` | Backspace |
| `\e` | Escape (0x1B) |
| `\f` | Form feed |
| `\v` | Vertical tab |

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

Comments with `##` (inline or to end of line):
```
+ 1 ## this is a comment ## 2
say hello ## rest of line is ignored
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

| Category          | Operations                                                                    |
|-------------------|-------------------------------------------------------------------------------|
| Constants         | `some`, `none`                                                                |
| Arithmetic        | `+`, `-`, `*`, `/`, `%`, `^`                                                  |
| Comparison        | `<`, `<=`, `>`, `>=`, `is`, `isnt`, `compare`                                 |
| Logic             | `and`, `or`, `not`                                                            |
| Control Flow      | `if`, `when`, `match`, `assert`                                               |
| String            | `concat`, `join`, `split`, `trim`, `upper`, `lower`, `replace`, `format`      |
| String Predicates | `prefix`, `suffix`, `in`                                                      |
| Output            | `say`, `error`                                                                |
| List              | `list`, `flat`, `flatten`, `range`, `until`, `sort`, `sortby`                 |
| Collection        | `length`, `first`, `last`, `rest`, `at`, `reverse`, `take`, `drop`, `zip`     |
| Higher-Order      | `map`, `foreach`, `apply`, `filter`, `reduce`, `any`, `all`, `count`          |
| Math              | `min`, `max`, `clamp`, `abs`, `floor`, `ceil`, `round`, `even`, `odd`, `sign` |
| Type              | `type`, `int`, `float`, `string`                                              |
| Sequencing        | `proc`                                                                        |
| Utility           | `identity`                                                                    |

## Usage

Add as a dependency in your `build.zig.zon`:

```
zig fetch --save git+https://github.com/mhogle25/lish-zig.git
```

Then in your `build.zig`:

```zig
const lish_dep = b.dependency("lish", .{
    .target = target,
    .optimize = optimize,
});
your_module.addImport("lish", lish_dep.module("lish"));
```

### Basic Example

```zig
const std = @import("std");
const lish = @import("lish");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Set up a registry with built-in operations
    var registry = lish.Registry{};
    try lish.builtins.registerAll(&registry, allocator);

    // Create an execution environment
    var env = lish.Env{
        .registry = &registry,
        .allocator = allocator,
    };

    // Process an expression (use processRawCached with an ExpressionCache to
    // avoid re-parsing repeated inputs)
    const result = try lish.processRaw(&env, "+ 1 2", null);
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
const lish = @import("lish");

var session = try lish.Session.init(allocator, .{
    .fragments = &.{&lish.builtins.registerAll},
    // Load all .lishmacro files from these directories at init time
    .macro_paths = &.{"macros/"},
    // LRU cache capacity for parsed expressions (default: 256)
    .expression_cache_capacity = 512,
    .stdout = lish.session.fdWriter(std.posix.STDOUT_FILENO),
    .stderr = lish.session.fdWriter(std.posix.STDERR_FILENO),
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

const load_result = try lish.loadMacroModule(allocator, &registry, macro_source);
switch (load_result) {
    .ok => |count| std.debug.print("Loaded {d} macros\n", .{count}),
    .validation_err => |errors| { /* handle errors */ },
}
```

From `.lishmacro` files:

```zig
// Load a single file
_ = try session.loadMacroFile("macros/math.lishmacro");

// Or scan a directory for all .lishmacro files
_ = try session.loadMacroDir("macros/");
```

Or pass macro directories at the CLI:

```sh
zig build run -- -m macros/
```

### Building AST Programmatically

`AstBuilder` provides a fluent API for constructing lish expressions and macro definitions from Zig code, without parsing source text.

```zig
const b = lish.AstBuilder.init(allocator);

// Leaf nodes
try b.int(42)            // 42
try b.float(3.14)        // 3.14
try b.string("hello")    // hello
try b.scope("x")         // :x  (scope reference)
try b.call("none")       // $none  (zero-argument call)

// Expressions — chain .arg(), finish with .build()
var eb = b.expr("+");
const node = try eb.arg(try b.int(1)).arg(try b.int(2)).build();
// → + 1 2

// Nested sub-expressions
var inner = b.expr("+");
const inner_node = try inner.arg(try b.int(1)).arg(try b.int(2)).build();
var outer = b.expr("+");
const root = try outer.arg(inner_node).arg(try b.int(3)).build();
// → + (+ 1 2) 3

// Sugar types — meta type locked at construction
var lb = b.list();
const list_node = try lb.arg(try b.int(1)).arg(try b.int(2)).build();  // .list_literal

var bb = b.block();
const block_node = try bb.arg(stmt1).arg(stmt2).build();                // .block_literal

// Top-level metadata override (rare)
var top_eb = b.expr("+");
const top_node = try top_eb.arg(try b.int(1)).asTopLevel().build();     // .top_level

// Macro definitions
var concat_eb = b.expr("concat");
const concat_node = try concat_eb
    .arg(try b.string("hello "))
    .arg(try b.scope("name"))
    .build();
var say_eb = b.expr("say");
const body = try say_eb.arg(concat_node).build();

var mb = b.macro("greet");
const macro_def = try mb.param("name").body(body);
// → |greet name| say (concat "hello " :name)
```

### Serializing AST to Source

Any AST node or macro definition can be serialized back to lish source text:

```zig
// Expression node → source string
try lish.serializeExpression(node, writer);

// Single macro definition
try lish.serializeMacro(macro_def, writer);

// Slice of macro definitions (newline-separated, suitable for a .lishmacro file)
try lish.serializeMacroModule(macros, writer);
```

Serialization always emits the canonical desugared form — `list` instead of `[...]`, `proc` instead of `{...}`. Comments are not preserved (they are discarded by the lexer during parsing).

### Populating a Scope

`Scope` lets you pass host state into lish expressions. Variables bound in a scope are accessible via `:varname` in any expression evaluated against that scope.

```zig
var scope = lish.Scope{};

// Bind a static value — accessed instantly, no re-evaluation
try scope.setValue(allocator, "playerName", .{ .string = "Aiden" });

// Bind a lazily-evaluated expression — re-evaluated each time :varName is accessed
const expr: lish.exec.Expression = ...; // built or validated externally
try scope.setExpression(allocator, "greeting", expr);

// Low-level: bind any Thunk with an explicit entry scope
try scope.setEntry(allocator, "key", thunk_ptr, entry_scope_ptr);
```

In lish expressions, reference scope entries with `:name`:
```
concat "Hello, " :playerName
```

### Custom Operations

```zig
// Stateless operation (no context)
fn myOperation(args: lish.Args) lish.exec.ExecError!?lish.Value {
    const value = try args.at(0).resolve();
    return value; // echo back the first argument
}

try registry.registerOperation(allocator, "my-op", lish.Operation.fromFn(myOperation));

// Bound operation (has access to a context struct)
const MySystem = struct {
    count: usize = 0,

    fn countOp(self: *MySystem, args: lish.Args) lish.exec.ExecError!?lish.Value {
        _ = args;
        self.count += 1;
        return null;
    }
};

var system = MySystem{};
try registry.registerOperation(
    allocator,
    "count",
    lish.Operation.fromBoundFn(MySystem, MySystem.countOp, &system),
);
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

# Pass macro directories to the REPL (-m/--macros may be repeated, max 16)
zig build run -- -m path/to/macros
zig build run -- --macros macros/math --macros macros/utils
```

### REPL Commands

| Command       | Action              |
|---------------|---------------------|
| `exit`, `quit`| Exit the REPL       |
| `clear`       | Clear the screen    |

The line editor supports history navigation (↑/↓), cursor movement (←/→, Home, End), and standard readline-style shortcuts (Ctrl+A/E/K/U/W/L).

### REPL Configuration

The REPL reads `$XDG_CONFIG_HOME/lish/config` on startup, falling back to `~/.config/lish/config`. The file is a lish script evaluated with the full set of core built-ins available. If the file does not exist all settings use their defaults.

| Setting | Default | Description |
|---------|---------|-------------|
| `autopair-insert` | `$some` | Typing `(`, `[`, or `{` inserts the matching closing bracket with the cursor positioned between the pair. |
| `autopair-delete` | `$some` | Pressing backspace between a matched pair deletes both brackets. |
| `macros` | — | Load all `.lishmacro` files from the given directory. May be called multiple times to add multiple directories. |

The config file is evaluated as a single lish expression. Use `proc` to sequence multiple settings:

```
proc
    (autopair-insert $off)
    (autopair-delete $off)
    (macros '~/.config/lish/macros')
```

The config context includes two convenience macros, `$on` and `$off`, for toggling boolean settings. Calling a boolean setting with no argument also enables it. `macros` takes exactly one path argument. An empty file or a file containing only comments is a no-op.

Note: `say` and `error` are not available in the config context — they are excluded to prevent accidental terminal output on every REPL startup.

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
| `builtins.zig`     | 75 built-in operations                               |
| `macro_parser.zig` | Macro definition parser and validator                |
| `cache.zig`        | Generic LRU cache (`LruCache(V)`)                    |
| `process.zig`      | Convenience API: processRaw, macro file loading      |
| `session.zig`      | Session struct (backend-agnostic REPL core)          |
| `ast_builder.zig`  | Fluent builder for AST nodes and macro definitions   |
| `serializer.zig`   | AST to lish source text serializer                   |
| `line_editor.zig`  | Terminal line editor: raw mode, history, keybindings |
| `main.zig`         | Terminal REPL entry point                            |

## License

[MIT](LICENSE)
