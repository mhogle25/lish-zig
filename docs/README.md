# lish documentation

- **[Syntax](syntax.md)**: top-level expressions, strings, sigils, sugar, macros, key concepts, and how lish differs from Lisp.
- **[Built-in Operations](operations.md)**: the operation vocabulary, the binding form for iterative ops, meta operations, and value-preserving comparison.
- **[Error handling](errors.md)**: errors as values via the Optional plus `given` pattern and the Result type (`ok`/`err`/`pass`/`fail`/`unwrap`).
- **[Embedding](embedding.md)**: using lish as a Zig library, covering sessions, loading macros, the AST builder/serializer, scopes, and custom operations.
- **[REPL & CLI](repl.md)**: the terminal REPL, script/CLI flags, configuration, and resource bounds.
- **[Architecture](architecture.md)**: source-file map.

The authoritative operation reference is always the live registry: `zig build run -- --dump-ops` (and `--dump-macros`).
